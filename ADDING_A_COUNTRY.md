# Adding a new country to planscanR

A walk-through of what it actually takes to plug a new national
environmental-assessment portal into planscanR. Written as a conceptual
reference, not a step-by-step recipe — the goal is to show how small and
well-shaped the work is, so a new portal is "another afternoon", not "another
quarter".

Existing handlers (NL Commissie m.e.r., DE UVP-Verbund, AT UVP-DB, DK
EA-Hub, BE MER-register, EE KOTKAS) are referenced throughout as
illustrations of specific patterns — pick whichever is closest to the
shape of the portal you're adding.

---

## 1. The architecture in one line

`get_assessments(country, ...)` is a single `switch()` over country code. Each
country lives in one self-contained file at `R/get_assessments_<cc>.R` and
returns a tibble. There is no S3 class hierarchy, no plugin registration, no
lifecycle dance. Adding a country is **one file plus one switch arm**.

Everything else — caching, sidecar persistence, relevance scoring, classification,
downloads, the review app — is country-agnostic and consumes whatever the new
handler emits, as long as the result satisfies the planscanR schema.

That schema is small: seven required columns
(`country`, `source_portal`, `document_id`, `url`, `retrieved_at`,
`attachment_urls`, `local_path`) checked by `validate_result_schema()`.
Everything else is optional and free-form.

---

## 2. What the work actually looks like

The work for a new portal breaks down into six conceptual steps. None of them
depends on the others' implementation details — you can stop after step 4 and
already have a working country in the package.

### Step 1 — Map the portal

A few hours of light reverse-engineering, not a research project. For most
public registers in Europe the backend is a JSON API behind a JavaScript SPA;
the goal is to find:

* the listing endpoint (and how it paginates — page/size? cursor? single-shot?)
* the detail endpoint (what fields it exposes — title, summary, dates,
  authorities, document URLs, geometry)
* any server-side filters you'd want to honour (free-text, municipality,
  date, dossier type)
* any throttling you should respect

Two patterns cover most of what you'll encounter:

* **JSON API behind an SPA.** Open the network panel, watch the listing call,
  then watch a detail call. Sometimes the SPA bootstraps from a small
  `/config` endpoint that names the real backend host (the BE MER-register
  works this way; DK and EE expose the backend directly). One listing call
  + one detail call is usually the whole API surface you need.
* **HTML detail pages, no JSON.** Some portals only render results
  server-side (NL Commissie m.e.r., DE UVP-Verbund). Enumeration goes
  through the portal's sitemap or its own search HTML, and detail pages
  are parsed with `rvest`. Slower per record but conceptually no harder.

### Step 2 — Decide what maps onto what

planscanR has a small set of **conventional column names** that handlers reuse
when the portal exposes the concept (`title`, `summary`, `date_published`,
`date_decision`, `competent_authority`, `proponent`, `native_type`,
`jurisdiction`, `status`). The point of using these names is that
`dplyr::bind_rows()` over a mixed-country tibble Just Works.

You decide once:

* what becomes `title` / `summary` (often raw "titel" + a narrative paragraph,
  sometimes the summary doesn't exist and stays `NA`);
* what becomes `date_published` and `date_decision` (some portals expose
  neither, only years — leave them `NA`);
* what carries the portal's own taxonomy into `native_type` (used by the
  classifier);
* what becomes `jurisdiction` (municipalities, federal state, NUTS region).

**Critically: no normalisation at fetch time.** The portal's vocabulary stays
in the portal's language. Cross-portal normalisation happens later, in
classification.

### Step 3 — Decide how attachments are grouped

Most portals group documents into named sections — *"Documenten waarop het
advies is gebaseerd"* vs. *"Adviezen en persberichten"*, or *"UVP-Bericht"* vs.
*"Berichte"* vs. *"Auslegung"* vs. *"Weitere"*. The schema allows you to emit
one list-column per section:
`attachment_urls_<slug>` / `local_path_<slug>`.

You don't have to enumerate sections up-front — `read_record_sidecar()` is
country-agnostic, so a slug that appears in your handler appears on disk and
flows back out without any extra code. Two patterns work:

* **Curated map + auto-slug fallback** (DE handler). A small named vector
  of `"Section heading" = "stable_slug"` covers the known cases; anything
  unrecognised is auto-slugged from the heading. New section types appear
  in their own column the next time the portal adds one, without a code
  change.
* **Pure auto-slug from a typed API field** (BE handler). When the portal
  hands you a `type` string on each document, lowercasing + collapsing
  non-alphanumerics to `_` is enough; no curation needed.

The deduplicated union goes into `attachment_urls` / `local_path` to satisfy
the schema.

### Step 4 — Decide what to do with geometry (if any)

Many portals expose a polygon footprint per record (project extent, plan
boundary). The convention is:

* save the geometry next to the sidecar as `<document_id>.geometry.geojson`;
* keep coordinates in the source CRS — no reprojection at fetch time;
* tag the CRS via the GeoJSON-2008 `crs` member with the URN form
  (`urn:ogc:def:crs:EPSG::<code>`) so QGIS / `sf::read_sf()` read it without
  fuss;
* record `geometry_path` and `geometry_crs` as columns on the record.

The DK handler is the canonical reference here; any other handler whose
portal exposes a footprint follows the same shape with a different EPSG
code (BE writes the same GeoJSON layout, differing only in the projection
metadata).

### Step 5 — Write the handler

The body of `get_assessments_<cc>()` always follows the same shape, regardless
of the portal:

1. validate args; resolve `cache_dir`; set a politeness throttle if the portal
   warrants one (each handler picks its own rate via
   `getOption("planscanR.<cc>_throttle_rate")` — NL is the most conservative
   at 1 req/s for a frequent-rate-limit-er; portals that 429 less aggressively
   sit at 5 req/s; large server-side search APIs are typically unthrottled);
2. `setup_relevance(topic, model, country = "<cc>")` — one line, shared
   helper;
3. `sidecar_url_index("<cc>")` — every URL with an on-disk sidecar is read from
   JSON instead of refetched, so a re-run with a different topic is essentially
   free;
4. enumerate the index (paginated or single-shot, whatever the portal gives
   you);
5. per-record loop: sidecar-first `load_or_fetch`; client-side filters;
   `apply_relevance`; `finalise` (downloads + sidecar write);
6. return the tibble; `bind_results()` validates the schema before handing it
   to the caller.

Steps 2, 3, 5 (relevance + sidecar + finalise) reuse shared helpers from
`utils_relevance.R` / `utils_sidecar.R` / `utils_download.R`. Only the
enumeration loop and the per-record parse function are country-specific.

### Step 6 — Wire it up

Three small files, one line each:

* `R/get_assessments.R` — add `cc = get_assessments_<cc>,` to the switch;
* `R/utils_dispatch.R` — add the code to `supported_countries()`;
* `R/get_assessments_coverage.R` — add a row to the coverage tibble plus a
  small facets list documenting whatever server-side vocabularies the portal
  honours.

Optionally:

* `R/utils_language.R` already maps the country to its languages — if you're
  adding a country it doesn't know about yet, add it so the relevance gate's
  language-support warning fires correctly.

---

## 3. After the handler — the pipeline picks it up automatically

The acquisition runbook ([data-raw/biogain_acquire.R](data-raw/biogain_acquire.R))
loops over `COUNTRIES` and treats every country the same. Adding the new
country there is one entry in `COUNTRY_CFG`:

* `scan_args` — extra args forwarded to the scan call (almost always empty);
* `download_sections` — `"all"` for portals that expose direct download URLs,
  `NULL` for metadata-only portals, or a specific slug vector to restrict;
* `category_regex` — optional `native_type` filter (almost always `NULL`);
* `discover` — `TRUE` for portals that hide PDFs behind auth (then the
  discovery phase uses Tavily instead).

Once that entry exists, every phase — scan + score, zero-shot classification,
gated downloads, discovery, reporting — picks up the new country with no
further code changes. The review app (`run_biogain_review()`) also reads from
the same sidecars, so labelling works the moment the scan has run.

**The review app discovers countries from the cache itself** — the `COUNTRIES`
vector at the top of `inst/biogain-review/app.R` is derived from
`list.dirs(<cache_dir>/files)` (filtered to lowercase two-letter names), so a
new handler that has written sidecars shows up in the country filter, funnel,
and queue without any edit to the app. After a fresh scan, click "Rebuild
snapshot" in the sidebar once to fold the new records into
`corpus_snapshot.rds` and the country becomes selectable immediately.

**One review-app file does still need the new country added by hand.** The
offline-translation layer ([inst/biogain-review/R/translate.R](inst/biogain-review/R/translate.R))
keeps a small country → source-language map so it knows which Argos
Translate pair to download (e.g. `nl → en`, `de → en`):

```r
# inst/biogain-review/R/translate.R
country_src_lang <- function(country) {
  m <- c(nl = "nl", de = "de", at = "de", dk = "da", be = "nl", ee = "et", ...)
  ...
}
```

Add the new country to that vector with its ISO-639-1 source language code
(country and language don't always match: BE Flanders uses `nl`, AT uses
`de`, and so on — go by what the records are actually written in). If the
source language is one Argos Translate already supports (every major
European language is covered), the first time a reviewer clicks "Translate"
on a record from the new country the app downloads the `<lang>→en` model
on-the-fly via `argos_ensure_pair()` and caches it for the rest of the
session. No explicit pre-download step is needed — but the country must be
in the map, otherwise `country_src_lang()` returns `NA` and the
translation silently no-ops.

To warm the cache ahead of a labelling session (e.g. on a machine that won't
have internet during review), you can pre-install the pack from R — swap in
the ISO-639-1 source code for your new country:

```r
reticulate::py_require("argostranslate")
pkg <- reticulate::import("argostranslate.package")
pkg$update_package_index()
avail <- pkg$get_available_packages()
hit <- Filter(function(p) identical(p$from_code, "<lang>") &&
                          identical(p$to_code, "en"), avail)
pkg$install_from_path(hit[[1]]$download())
```

---

## 4. Tests and docs

Once the handler is wired up, six doc/test surfaces need to be brought along
with it. None of them is more than a paragraph or a table row, but missing
one leaves the new country invisible somewhere — broken cross-refs in the
getting-started vignette, absent from the pkgdown reference index, dropped
off the README's "what's supported" table. Worth doing in one pass:

**Tests** — required, not optional. Schema drift in one handler can poison
the cross-country tibble for every downstream consumer (review app,
selection model, runbook report), and the cost of catching it at fetch time
is too high if it's only noticed during a labelling session. So:

* `tests/testthat/test-get_assessments_<cc>.R` — **required.** One file per
  handler, modelled on `test-get_assessments_nl.R` / `_de.R` / `_at.R` /
  `_dk.R` / `_be.R` / `_ee.R`. Every handler ships with:
  1. **Parse-function unit test** against a recorded fixture, asserting
     every conventional column the handler emits (title, summary, dates,
     authority, proponent, native_type, jurisdiction, the section-specific
     `attachment_urls_<slug>` columns, geometry path + CRS if any).
  2. **Filter tests** for every filter the handler honours (`query`,
     `date_range`, `jurisdiction`, `dossier_type`, …) — at minimum one
     positive and one negative match per filter.
  3. **End-to-end with sidecar** — mock the network, run a tiny crawl,
     assert the sidecar JSONs land on disk, and assert a second call with
     `refresh = FALSE` returns the same records *without* re-invoking the
     parse function (i.e. it actually reads from the sidecar). Use the
     `local_mocked_bindings(<parse_fn> = function(...) stop("..."))`
     trick from the existing tests to prove no re-parse happens.
  4. **Sidecar round-trip** — assert that the country-specific extras
     written by the handler survive `index_cache()` (i.e. that the extras
     channel works for whatever fields are not part of the canonical
     schema).
  5. **Relevance scoring** with the deterministic `make_fake_model()` from
     `helper-planscanr.R` — asserts `relevance_score_<slug>` columns appear
     with numeric values. Never call the real Python model in tests.
  6. **Live integration test** at the bottom of the file, gated by
     `skip_if_offline_tests()` — a single `get_assessments("<cc>", limit
     = 1, download = FALSE)` against the real portal, asserting the result
     validates and the canonical URL prefix is correct. Skipped on CI; runs
     locally to detect upstream-portal breakage.
* `tests/testthat/fixtures/<cc>/` — **required.** Small, anonymised
  recordings of the API/HTML responses the handler parses. Two to three
  records is enough; pick at least one with attachments and one without (or
  one with geometry and one without, for portals that have geometry).
  Recordings are captured by hand (`curl ... > fixture.json`, or saving a
  detail page's HTML) and replayed in the tests by rebinding the handler's
  `perform_*` seam with `testthat::local_mocked_bindings()`.
* `tests/testthat/test-dispatch.R` — widen the `supported_countries()`
  set-equality check and add a `select_assessments_handler("<cc>")`
  identity assertion.
* `tests/testthat/test-coverage.R` — one new `test_that(...)` block for the
  new coverage row, asserting `source_portal`, `status`, and the facet
  vocab.

**User-facing docs (the surfaces a reader will hit)**
* [`README.md`](README.md) — add a row to the "Supported portals" table at
  the top.
* [`vignettes/supported_sources.Rmd`](vignettes/supported_sources.Rmd) — one
  per-portal section (portal URL, status, throttle, filter coverage,
  attachment layout, geometry). This is where the per-portal vocabulary
  lives.
* [`vignettes/planscanR.Rmd`](vignettes/planscanR.Rmd) — add the
  `?get_assessments_<cc>` cross-ref to the "Where to go next" list at the
  bottom of the getting-started vignette.

**Package metadata + site index**
* [`NEWS.md`](NEWS.md) — one bullet describing the portal, the filter surface,
  attachment layout, and any geometry / metadata-only quirks.
* [`DESCRIPTION`](DESCRIPTION) — update the country list in the package
  Description field.
* [`_pkgdown.yml`](_pkgdown.yml) — add `get_assessments_<cc>` to the
  "Fetching assessments" reference index so the pkgdown site links to it.
* [`AGENTS.md`](AGENTS.md) — update the v0.1 scope bullet list at the top of
  the file. This is the document agents (and humans) read first when landing
  in the repo, so out-of-date entries here cost the most.

The fixture-backed tests run offline in CI; the live integration test is
the only piece that touches the real portal, and it's gated by
`skip_if_offline_tests()` so it only fires locally. Together they cost
~5 seconds per handler in normal test runs and catch both portal-side
breakage (via the live test, when you run locally) and handler-side
regressions (via the fixture tests, on every CI run).

**Before committing — regenerate `man/` and `NAMESPACE`.** The new handler
has `@export` roxygen, so it needs a `.Rd` file and a `NAMESPACE` export
entry. Run from the repo root:

```r
devtools::document()
```

This regenerates `man/get_assessments_<cc>.Rd` and adds
`export(get_assessments_<cc>)` to `NAMESPACE`. Both files must be staged in
the same commit — the pre-commit hook validates that every topic listed in
`_pkgdown.yml` resolves to a known `.Rd` page, and fails the commit (with
a message like *"reference[1].contents[5] (get_assessments_<cc>) must be a
known topic name or alias"*) if the regenerated files weren't included.

It's also worth a quick `Rscript -e 'pkgload::load_all("."); ...'` smoke
call against the live portal before pushing — just `limit = 1, download =
TRUE` is enough to confirm the schema validates, the sidecar writes, and
geometry (if any) lands on disk.

**Before pushing — the standard package gates.** Run them locally; CI only
builds the pkgdown site, so anything `R CMD check` catches will land in
`main` if you skip it here. In rough order of cost:

```r
# 1. Format. Air is the project's formatter (see air.toml); it normalises
#    style across every R file you touched.
system("air format .")

# 2. Regenerate man/ + NAMESPACE (covered above, restated here so the
#    sequence is complete).
devtools::document()

# 3. Run the test suite. Fast; replays recorded fixtures via mocked bindings
#    and skips live HTTP, so it works offline. The dispatch / coverage tests
#    you just widened fail loudly if you forgot to wire something through.
devtools::test()

# 4. Full R CMD check. The gold standard — catches roxygen tag typos,
#    undocumented arguments, missing examples, NAMESPACE drift, broken
#    cross-references between `[fn()]` links, and stale Rd files. Slow
#    (a minute or two), but the only way to be sure CI on a hypothetical
#    downstream user won't blow up.
devtools::check()

# 5. (Optional) Verify the pkgdown site renders the new handler's reference
#    page cleanly. This is what the pkgdown.yaml CI workflow will do on
#    push — running it locally first shortens the feedback loop.
pkgdown::build_reference()
```

A clean `devtools::check()` (0 errors, 0 warnings, 0 notes — or only the
familiar pre-existing notes) is the canonical "ready to push" signal.

---

## 5. What a typical addition touches

A complete addition for a new country `<cc>` lands across one new file
and roughly a dozen small touches in existing files. Use this as a
checklist — the order doesn't matter, but each entry is small enough that
forgetting one is the most common failure mode.

| File | What changes |
|---|---|
| `R/get_assessments_<cc>.R` | **New.** Typically 400-700 lines including roxygen, depending on how much HTML parsing the portal forces. The only file written from scratch. |
| `R/get_assessments.R` | One line in the switch (`<cc> = get_assessments_<cc>,`); update the country list in the docstring. |
| `R/utils_dispatch.R` | One code added to `supported_countries()`. |
| `R/get_assessments_coverage.R` | One row in the coverage tibble; one small facets helper documenting whichever server-side vocabularies the portal honours. |
| `R/utils_language.R` | One entry in `country_languages()` if the new country isn't already there, so the relevance gate's language warning fires correctly. |
| `tests/testthat/test-get_assessments_<cc>.R` | **New.** Parse + filter + end-to-end + sidecar round-trip + relevance + live-integration tests. Roughly 200-300 lines. |
| `tests/testthat/fixtures/<cc>/` | **New.** Two to three recorded JSON/HTML files the offline tests parse. |
| `tests/testthat/test-dispatch.R` | Widen `supported_countries()` set-equality; add a `select_assessments_handler()` identity assertion. |
| `tests/testthat/test-coverage.R` | One new `test_that(...)` block for the coverage row. |
| `README.md` | One row in the "Supported portals" table. |
| `vignettes/supported_sources.Rmd` | One new per-portal section (portal URL, status, throttle, filter coverage, attachment layout, geometry). |
| `vignettes/planscanR.Rmd` | `?get_assessments_<cc>` added to the "Where to go next" cross-ref list. |
| `_pkgdown.yml` | `get_assessments_<cc>` added to the reference index. |
| `NEWS.md` | One bullet describing portal, filter surface, attachment layout, and any quirks. |
| `DESCRIPTION` | One updated sentence in the package Description. |
| `AGENTS.md` | Updated scope list at the top. |
| `data-raw/biogain_acquire.R` | One `<cc> = list(...)` entry in `COUNTRY_CFG`; one entry in the default `COUNTRIES` vector. |
| `inst/biogain-review/R/translate.R` | One entry in `country_src_lang()` so the review app's offline translator knows which Argos pair to use. |
| `NAMESPACE`, `man/get_assessments_<cc>.Rd` | Both regenerated by `devtools::document()`; no hand-editing. |

End-to-end: one new file, roughly twelve one-or-two-line touches, two
regenerated files, and the entire pipeline — scan, score, classify,
download, review-app labelling — picks up the new portal without any
further code.

A typical cold run on a national register of ~3,000 records: scan +
embedding scoring takes ~15 minutes (gated by the portal's throttle);
zero-shot classification with the local mDeBERTa model takes a similar
amount of time on a laptop CPU; downloads (when enabled) are bounded by
portal bandwidth and the per-file size cap. After this single run, the
records are in the review app's labelling queue.

---

## 6. The smaller invariants worth remembering

A few things worth keeping in mind that aren't obvious from the file count:

* **Sidecars are the cache.** There is no separate HTTP cache. Anything the
  handler ever produced lives on disk as `<document_id>.meta.json`, and the
  next run reads from there unless `refresh = TRUE`.
* **Persistence is per-record, atomic, and inside the per-record loop.** A
  crash mid-run leaves N fully-indexable records, not N orphan directories.
* **Sidecar writes merge.** Re-scoring a slice against a new topic adds entries
  to the relevance_scores array without wiping existing ones. The same is true
  for classification verdicts and per-file download statuses.
* **No normalisation at fetch time.** Vocabulary stays in the source language.
  Cross-portal normalisation is the classifier's job.
* **Extra columns are encouraged.** `validate_result_schema()` only checks the
  seven required ones. Anything country-specific just gets serialised to the
  sidecar's `extras{}` block and round-trips through `index_cache()` without
  any per-country code.

These invariants are why a new handler doesn't need to touch the cache layer,
the classification layer, or the review app: it just has to emit a tibble.
