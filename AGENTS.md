# AGENTS.md — planscanR project orientation

Written for AI agents and human contributors landing in the repo cold. The full
design rationale lives in the approved plan at
`~/.claude/plans/i-want-to-set-virtual-scroll.md`.

## 1. What this package is

`planscanR` is an R package for the **BIOGAIN** project (Net Biodiversity Gain
in spatial energy planning). It provides a single, unified R API
(`get_assessments()`) for fetching environmental-assessment records (EIA, SEA,
follow-up advice) from European national portals — modelled on
[`aloftdata/getRad`](https://github.com/aloftdata/getRad).

**v0.1 scope.** Three country handlers ship:
- Netherlands (`get_assessments_nl()`) — Commissie m.e.r. adviezenregister
  at `commissiemer.nl`.
- Germany (`get_assessments_de()`) — UVP-Verbund federated portal at
  `uvp-verbund.de`.
- Austria (`get_assessments_at()`) — Umweltbundesamt UVP-DB at
  `secure.umweltbundesamt.at/uvpdb`. **Metadata-only**: the portal's HTML
  pages and document attachments sit behind a Keycloak login wall; only
  three open JSON service handlers (`mapsdata`, `mapsgeom`, `vorhabenInfo`)
  expose record metadata anonymously. The handler returns rich tibble
  rows but `attachment_urls` and `local_path` are always empty, and
  `date_decision` is always `NA` (the portal only exposes a `year`).
  Reflected in `get_assessments_coverage()$status` as `"supported
  (metadata-only)"`.

The architecture is multi-country from day one — adding DK / etc. is a
pure additive change.

**Out of scope for v0.1.** Spatial output (`sf`), zoning/plan documents,
credential management (`keyring`), LLM-based classification & normalisation.
All are flagged on the roadmap (§6) so they don't get prematurely wedged in.

## 2. Architecture in one diagram

```
get_assessments(country, ...)
  ├── normalise_country() / assert_country()
  ├── select_assessments_handler(country)    # switch() returning a function
  │     ├── get_assessments_nl(...)          # commissiemer.nl
  │     └── get_assessments_de(...)          # uvp-verbund.de
  │     # get_assessments_dk(...)            # post-v0.1
  │     # get_assessments_at(...)            # post-v0.1
  └── validate_result_schema()               # invariant gate before returning
```

Every per-country handler is a self-contained file at `R/get_assessments_<cc>.R`
and is selected purely by the `switch` in `R/get_assessments.R`. There is no
S3 / class hierarchy — explicit functional dispatch only.

## 3. Return schema rules

**Required columns** (validated by `validate_result_schema()`, every handler
MUST emit them with the right types):

| Column | Type |
|---|---|
| `country` | chr (ISO-2, lowercase) |
| `source_portal` | chr |
| `document_id` | chr (unique within `source_portal`) |
| `url` | chr (canonical landing URL) |
| `retrieved_at` | POSIXct (UTC) |
| `attachment_urls` | list<chr> |
| `local_path` | list<chr> (parallel to `attachment_urls`; `character(0)` if `download = FALSE`) |

**Conventional columns** (use these names when the portal exposes the concept,
so cross-country tibbles can be `bind_rows()`-ed cleanly):

`title`, `summary`, `native_type`, `jurisdiction`, `status`, `date_published`,
`date_decision`, `competent_authority`, `proponent`, `file_sha256`,
`relevance_score`, `relevance_model`, `download_status`.

**Per-handler attachment splits.** A portal that groups its attachments into
named sections may add parallel list-columns. NL uses two:

- `attachment_urls_source` / `local_path_source` — files in
  *"Documenten waarop het advies is gebaseerd"* (the underlying EIA/SEA
  reports — the substantive documents for downstream analysis).
- `attachment_urls_advice` / `local_path_advice` — files in
  *"Adviezen en persberichten"* (Commissie advice + press releases).

DE uses four:

- `attachment_urls_uvp_bericht` / `local_path_uvp_bericht` —
  *"UVP-Bericht, ggf. Antragsunterlagen"* (substantive UVP report + applicant
  docs).
- `attachment_urls_berichte` / `local_path_berichte` —
  *"Berichte und Empfehlungen"*.
- `attachment_urls_auslegung` / `local_path_auslegung` —
  *"Auslegungsinformationen"* (public-consultation notices).
- `attachment_urls_weitere` / `local_path_weitere` —
  *"Weitere Unterlagen"* (other materials; often the biggest section).

`attachment_urls` / `local_path` remain the deduplicated **union** (source /
substantive sections first), so the required-columns schema is always
satisfied. `read_record_sidecar()` is country-agnostic: any
`attachment_urls_<section>` list-column a handler emits flows through the
sidecar and back out without changes here.

**`download_status` list-column** (when `download = TRUE`): one tibble per
record with columns `url, local_path, status, size_bytes, sha256, reason`.
Values for `status`: `"downloaded"`, `"cached"`, `"skipped_size"`, `"failed"`.

**No normalisation at fetch time.** Status, type, jurisdiction strings stay in
the portal's own vocabulary (Dutch / German / Danish / …). Cross-portal
normalisation is the responsibility of the future
`classify_assessments()` step, not the fetcher.

**Extra columns are encouraged.** Handlers can add any country-specific column
they like — `validate_result_schema()` only enforces the required set. New
conventional columns can be promoted in a later minor release.

## 4. Conventions

- **License**: GPL-3.
- **Formatter**: [Air](https://posit-dev.github.io/air/) with
  `line-width = 120` (see `air.toml`). Run `air format .` before pushing.
- **HTTP**: every outbound call goes through `req_planscanr()` in
  `R/utils_http.R` so user-agent, retry, and HTTP-cache behaviour stay
  consistent.
- **Caching**: file cache root is `tools::R_user_dir("planscanR", "cache")`,
  overridable via the `cache_dir` argument or `options(planscanR.cache_dir)`.
  Layout:
  ```
  <root>/
    files/<country>/<document_id>/
      <document_id>.meta.json                          # sidecar (see §4b)
      <country>_<document_id>_<slug>.<ext>             # flatten-safe basename
  ```
  There is no separate HTTP cache — the sidecar JSONs ARE the cache, and
  per-country handlers consult them via `sidecar_url_index()` before going
  to the network. [clear_cache()] removes the `files/` tree (optionally
  scoped by `country`); pair with `refresh = TRUE` on the next call if you
  want fresh fetches afterwards. The download
  layer pre-flights every URL with HEAD; files exceeding
  `getOption("planscanR.max_file_size_mb", 50)` are skipped and recorded in
  `download_status`. Already-on-disk non-empty files become `status = "cached"`
  unless `overwrite = TRUE`.
- **Errors** carry classed conditions (`planscanR_error_unsupported_country`,
  `planscanR_error_bad_input`, `planscanR_error_bad_schema`,
  `planscanR_warning_partial`) so tests can target them cleanly.
- **Tests**: `testthat` (edition 3) + `httptest2` mocks; **no live HTTP in
  CI**. Live tests, if any, live under `tests/manual/` and are git-ignored.
- **Secrets**: deferred to a future release; no `keyring` dependency in v0.1.

## 4b. Persistence and offline indexing

Every successfully processed record is persisted to a sidecar JSON at
`files/<country>/<document_id>/<document_id>.meta.json` — written **atomically
inside the per-record loop**, so an interrupted run leaves N fully-indexable
records on disk (not N orphan dirs). The sidecar carries the full record
(country, source_portal, document_id, url, title, summary, dates, competent
authority, proponent, relevance_score, etc.) plus a per-file `files[]` array
mirroring the `download_status` columns (status, size_bytes, sha256, reason,
section). Schema version: `1`.

**The sidecar is the authoritative cache.** Per-country handlers consult
`sidecar_url_index(country)` at the start of every call to build a
`url -> sidecar-path` lookup; any URL with an on-disk sidecar is loaded
**from JSON** rather than re-fetched over HTTP. This makes re-scoring an
already-scanned slice against a new topic essentially free (only the
embedding compute, zero network). Pass `refresh = TRUE` to bypass the
sidecar lookup and force fresh detail-page fetches.

Sidecar writes **merge** the `relevance_scores` array: prior topic entries
whose slug isn't present in the current run are preserved. So running with
`topic = c(wind = "...")` after a multi-topic scan doesn't wipe the solar /
power_grid scores from disk — only the wind entry is replaced.

`index_cache(cache_dir = NULL, country = NULL)` walks every sidecar under the
root and reconstructs a tibble matching the planscanR schema — no portal
calls. Use it to:
- re-read a previously-downloaded slice offline;
- enumerate what's on disk before deciding what else to fetch;
- recover after manually relocating or flattening files (because the basenames
  are globally unique, `find files/ -exec mv {} flat/` is safe).

## 5. Adding a country

1. Create `R/get_assessments_<cc>.R` with the same signature surface as
   `get_assessments_nl()`. The handler must return a tibble that passes
   `validate_result_schema()`.
2. Add one line to the `switch` in `R/get_assessments.R`:
   `<cc> = get_assessments_<cc>,`.
3. Update `supported_countries()` in `R/utils_dispatch.R` and the
   `get_assessments_coverage()` tibble accordingly.
4. Record fixtures with `httptest2::capture_requests()` into
   `tests/testthat/fixtures/<cc>/` and add `tests/testthat/test-get_assessments_<cc>.R`.
5. Document portal-specific search-facet vocabularies (`status`, `native_type`,
   etc.) in the handler's roxygen.

That's the whole recipe — no edits to the core dispatcher are needed.

## 5a. BIOGAIN topic defaults

`biogain_assessment_topics()` ([R/topics.R](R/topics.R)) returns the
canonical six-topic set the BIOGAIN project uses against
environmental-assessment registers:

| slug | topic phrase embedded |
|---|---|
| `wind` | `"wind energy"` |
| `solar` | `"solar energy"` |
| `power_grid` | `"power lines, distribution and transmission infrastructure"` |
| `renewable_energy` | `"renewable energy"` |
| `energy_transition_strategy` | `"regional energy transition strategy and planning"` (intended to bridge NL RES, DE Klimaschutzkonzept, FR SRADDET / PCAET, AT Energiestrategie, …) |
| `renewable_zoning` | `"renewable energy zoning and designated development areas"` (intended to bridge NL zoekgebieden, DE Vorrangzonen, EU RED III acceleration areas, …) |

It's an **opt-in default**, not applied automatically — users pass the
return value as `topic` to [get_assessments()] when they want this set, and
non-BIOGAIN use-cases just pass their own. The English phrases are
deliberately generic so the multilingual embedding model can semantically
bridge to each portal's vocabulary without translation.

### How the topics are used

The function is a thin helper that returns a named character vector. Three
places in the package consume it:

1. **`get_assessments()` / per-country handlers** — pass it through the
   `topic` argument. Each record's title + summary is embedded once and
   compared against all six topic vectors in a single pass; the result
   tibble gains one `relevance_score_<slug>` column per topic.

   ```r
   options(planscanR.cache_dir = "/path/to/cache")
   res <- get_assessments(
     "nl",
     topic = biogain_assessment_topics(),
     download = FALSE         # score-only; no PDFs fetched
   )
   res$relevance_score_wind
   res$relevance_score_energy_transition_strategy
   ```

2. **`score_assessments()`** — same vector, but for re-scoring an existing
   tibble (e.g. one obtained from `index_cache()`) without re-fetching.

   ```r
   recs   <- index_cache("/path/to/cache")
   scored <- score_assessments(
     recs,
     topic = biogain_assessment_topics(),
     write_sidecar = TRUE     # persist back to the sidecars on disk
   )
   ```

3. **Sidecar JSON** — when `write_sidecar = TRUE`, each topic gets its own
   entry in the per-record `relevance_scores` array under the slug from
   the names of the vector. Subsequent runs *merge* into this array, so
   `score_assessments()` against a different topic set adds new entries
   alongside the BIOGAIN ones rather than clobbering them. To restrict a
   sidecar to a specific topic set, re-score with that set and then sweep
   non-matching topic entries (see [/tmp/biogain_rescan.R] for the
   reference pattern).

### Filtering with the topic set

Pass a `relevance_threshold` to drop records that don't clear any topic.
A scalar threshold applies to all topics (record passes if **any** topic
clears it); a named numeric vector lets you set per-topic cutoffs.

```r
# Keep records that look like wind, solar, or grid (any topic >= 0.5)
get_assessments("nl",
  topic = biogain_assessment_topics(),
  relevance_threshold = 0.5,
  download = FALSE)

# Per-topic thresholds — tighter wind, looser everything else
get_assessments("nl",
  topic = biogain_assessment_topics(),
  relevance_threshold = c(wind = 0.6,
                          renewable_energy = 0.45,
                          energy_transition_strategy = 0.5),
  download = FALSE)
```

### Adding or swapping topics

`biogain_assessment_topics()` is just a named character vector; merge or
override it freely.

```r
extended <- c(
  biogain_assessment_topics(),
  battery_storage = "battery energy storage and grid balancing",
  geothermal      = "geothermal heat and underground energy"
)
get_assessments("nl", topic = extended, download = FALSE)
```

## 5b. Relevance gate (pluggable embedding models)

`get_assessments()` accepts an optional `topic` parameter. When set, each
candidate record's title + summary is embedded **once** and scored by cosine
similarity against the topic vector(s) **before** any attachments are
downloaded. `relevance_threshold` is a **download-gate only**: records that
fall below it keep their sidecar JSON and remain in the returned tibble —
only their PDFs are skipped. This means a later re-run with a different
threshold (or none at all) costs nothing in network: the metadata + per-file
attachment URLs are already on disk and `index_cache()` / a sidecar-first
re-fetch can pick them up offline.

**Single vs multi-topic** — `topic` accepts either:
- a single character string (legacy mode): adds `relevance_score` +
  `relevance_model` columns;
- a named character vector like
  `c(wind = "wind energy", solar = "solar energy", res = "regional energy
  transition strategy")`: adds one `relevance_score_<slug>` per topic plus
  a shared `relevance_model`. Adding extra topics is essentially free — the
  per-record embed runs once and we only do an extra cosine per topic.

`relevance_threshold` accepts a scalar (any topic ≥ scalar passes) or a
named numeric vector matching topic slugs (any named topic clears its own
cutoff passes).

For offline rescoring of an existing tibble against new topics without
re-fetching anything from the portal, use `score_assessments(records, topic,
model, write_sidecar = ...)`. Pairs well with `index_cache()`.

**Pluggable model interface (S3)**
- Built-in default: `embedding_model_minilm()` — sentence-transformers
  `paraphrase-multilingual-MiniLM-L12-v2` via `reticulate`. Lazy Python init
  on first use; needs `reticulate::py_install("sentence-transformers")` (or
  `reticulate::py_require("sentence-transformers")` per session under the
  modern uv-backed config).
- Custom backend: `embedding_model(name, languages, embed_fn)` returns an
  S3 object that participates in the same interface without writing methods.
- Required S3 methods on any new subclass: `embed_text()`,
  `supported_languages()`, `model_name()`.
- The relevance scorer warns once per (country, model) when a record's
  country language falls outside the model's documented `supported_languages()`
  list. Country → language map lives in `R/utils_language.R`.

**Sidecar persistence of relevance scores**
- Single-topic mode: legacy `relevance_score` + `relevance_model` fields.
- Multi-topic mode: `relevance_scores: [{topic, score, model, scored_at}, ...]`
  array. `read_record_sidecar()` fans this back out into
  `relevance_score_<slug>` columns. Old sidecars (without the array) still
  read fine — they just don't add per-topic columns.

## 6. Roadmap (informational; not actionable in v0.1)

- **`classify_assessments()`** — separate function that takes the tibble from
  `get_assessments()` and produces canonical type (`"eia"` / `"sea"` /
  `"other"`) + confidence via an LLM. Pipeline:
  1. For each row, find cached PDFs at `local_path`.
  2. Split each PDF into `pages_per_chunk` chunks (default 5–10) — these
     documents can be hundreds of pages.
  3. Convert each chunk to markdown via the Python
     [docling](https://github.com/docling-project/docling) package, called
     from R via `reticulate`.
  4. Send the markdown to an LLM for classification.
  5. Aggregate per-document classification + confidence; add **new** columns
     to the tibble (`classified_type`, `classified_confidence`,
     `classified_at`). Never overload existing columns.
  Implication for v0.1 design: don't mutate downloaded PDFs, and leave room
  for a `derived/` subdir under the cache root.
- **Additional country handlers** — DE, DK, AT and beyond. Order not committed.
- **`keyring`-based secrets** for portals that grow to require API keys; slot
  naming convention reserved as `planscanR_<country>_<portal>`.
- **`classify_assessments()` is also the home for cross-portal vocabulary
  normalisation** (status, type, jurisdiction); the fetcher stays raw.

## 7. Pointers

- Architectural reference: <https://github.com/aloftdata/getRad>
- Original design rationale + scope decisions:
  `~/.claude/plans/i-want-to-set-virtual-scroll.md`
- Implementation handover notes (env snapshot, probe findings):
  `~/.claude/plans/i-want-to-set-virtual-scroll-progress.md`
- Per-portal vocabulary documentation lives in
  `vignettes/supported-portals.Rmd` (when added) — until then,
  `get_assessments_coverage()$facets` is the runtime-accessible source.
