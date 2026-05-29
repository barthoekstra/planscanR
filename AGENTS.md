# AGENTS.md — planscanR project orientation

Written for AI agents and human contributors landing in the repo cold.
The full design rationale lives in the approved plan at
`~/.claude/plans/i-want-to-set-virtual-scroll.md`.

## 1. What this package is

`planscanR` is an R package for the **BIOGAIN** project (Net
Biodiversity Gain in spatial energy planning). It provides a single,
unified R API
([`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md))
for fetching environmental-assessment records (EIA, SEA, follow-up
advice) from European national portals — modelled on
[`aloftdata/getRad`](https://github.com/aloftdata/getRad).

**v0.1 scope.** Three country handlers ship: - Netherlands
([`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md))
— Commissie m.e.r. adviezenregister at `commissiemer.nl`. - Germany
([`get_assessments_de()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md))
— UVP-Verbund federated portal at `uvp-verbund.de`. - Austria
([`get_assessments_at()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md))
— Umweltbundesamt UVP-DB at `secure.umweltbundesamt.at/uvpdb`.
**Metadata-only**: the portal’s HTML pages and document attachments sit
behind a Keycloak login wall; only three open JSON service handlers
(`mapsdata`, `mapsgeom`, `vorhabenInfo`) expose record metadata
anonymously. The handler returns rich tibble rows but `attachment_urls`
and `local_path` are always empty, and `date_decision` is always `NA`
(the portal only exposes a `year`). Reflected in
`get_assessments_coverage()$status` as `"supported (metadata-only)"`.

The architecture is multi-country from day one — adding DK / etc. is a
pure additive change.

**Out of scope for v0.1.** Spatial output (`sf`), zoning/plan documents,
credential management (`keyring`), LLM-based classification &
normalisation. All are flagged on the roadmap (§6) so they don’t get
prematurely wedged in.

## 1a. The acquisition runbook is the central reference

[`data-raw/biogain_acquire.R`](https://barthoekstra.github.io/planscanR/data-raw/biogain_acquire.R)
is the **single source of truth for how ALL BIOGAIN data is acquired and
processed.** It is the canonical, top-to-bottom pipeline — scan + score
→ classify → **select** → download / discover → report — that every
country runs through. When the question is “how is the data processed?”,
the answer is this file, not an ad-hoc script.

Consequences for any agent working here: - **Selection gate =
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)**
(the BIOGAIN ensemble: cosine OR classifier OR keywords, minus the
confident fossil/oil-gas/nuclear trim). The DOWNLOAD and DISCOVER phases
gate on it, so the runbook downloads exactly the records it reports as
`selected`. Don’t reintroduce a bare-cosine download gate. - Any change
to processing logic (selection rule, thresholds, phase behaviour, new
signals) belongs **in this file** (or in the package functions it
calls), so the runbook stays authoritative. - One-off helper scripts
under `/tmp` are throwaway conveniences; if a behaviour matters, fold it
back into the runbook.

## 2. Architecture in one diagram

    get_assessments(country, ...)
      ├── normalise_country() / assert_country()
      ├── select_assessments_handler(country)    # switch() returning a function
      │     ├── get_assessments_nl(...)          # commissiemer.nl
      │     └── get_assessments_de(...)          # uvp-verbund.de
      │     # get_assessments_dk(...)            # post-v0.1
      │     # get_assessments_at(...)            # post-v0.1
      └── validate_result_schema()               # invariant gate before returning

Every per-country handler is a self-contained file at
`R/get_assessments_<cc>.R` and is selected purely by the `switch` in
`R/get_assessments.R`. There is no S3 / class hierarchy — explicit
functional dispatch only.

## 3. Return schema rules

**Required columns** (validated by `validate_result_schema()`, every
handler MUST emit them with the right types):

| Column | Type |
|----|----|
| `country` | chr (ISO-2, lowercase) |
| `source_portal` | chr |
| `document_id` | chr (unique within `source_portal`) |
| `url` | chr (canonical landing URL) |
| `retrieved_at` | POSIXct (UTC) |
| `attachment_urls` | list |
| `local_path` | list (parallel to `attachment_urls`; `character(0)` if `download = FALSE`) |

**Conventional columns** (use these names when the portal exposes the
concept, so cross-country tibbles can be `bind_rows()`-ed cleanly):

`title`, `summary`, `native_type`, `jurisdiction`, `status`,
`date_published`, `date_decision`, `competent_authority`, `proponent`,
`file_sha256`, `relevance_score`, `relevance_model`, `download_status`.

**Per-handler attachment splits.** A portal that groups its attachments
into named sections may add parallel list-columns. NL uses two:

- `attachment_urls_source` / `local_path_source` — files in *“Documenten
  waarop het advies is gebaseerd”* (the underlying EIA/SEA reports — the
  substantive documents for downstream analysis).
- `attachment_urls_advice` / `local_path_advice` — files in *“Adviezen
  en persberichten”* (Commissie advice + press releases).

DE uses four:

- `attachment_urls_uvp_bericht` / `local_path_uvp_bericht` —
  *“UVP-Bericht, ggf. Antragsunterlagen”* (substantive UVP report +
  applicant docs).
- `attachment_urls_berichte` / `local_path_berichte` — *“Berichte und
  Empfehlungen”*.
- `attachment_urls_auslegung` / `local_path_auslegung` —
  *“Auslegungsinformationen”* (public-consultation notices).
- `attachment_urls_weitere` / `local_path_weitere` — *“Weitere
  Unterlagen”* (other materials; often the biggest section).

`attachment_urls` / `local_path` remain the deduplicated **union**
(source / substantive sections first), so the required-columns schema is
always satisfied. `read_record_sidecar()` is country-agnostic: any
`attachment_urls_<section>` list-column a handler emits flows through
the sidecar and back out without changes here.

**`download_status` list-column** (when `download = TRUE`): one tibble
per record with columns
`url, local_path, status, size_bytes, sha256, reason`. Values for
`status`: `"downloaded"`, `"cached"`, `"skipped_size"`, `"failed"`.

**No normalisation at fetch time.** Status, type, jurisdiction strings
stay in the portal’s own vocabulary (Dutch / German / Danish / …).
Cross-portal normalisation is the responsibility of the future
[`classify_assessments()`](https://barthoekstra.github.io/planscanR/reference/classify_assessments.md)
step, not the fetcher.

**Extra columns are encouraged.** Handlers can add any country-specific
column they like — `validate_result_schema()` only enforces the required
set. New conventional columns can be promoted in a later minor release.

## 4. Conventions

- **License**: GPL-3.

- **Formatter**: [Air](https://posit-dev.github.io/air/) with
  `line-width = 120` (see `air.toml`). Run `air format .` before
  pushing.

- **HTTP**: every outbound call goes through `req_planscanr()` in
  `R/utils_http.R` so user-agent, retry, and HTTP-cache behaviour stay
  consistent.

- **Caching**: file cache root is
  `tools::R_user_dir("planscanR", "cache")`, overridable via the
  `cache_dir` argument or `options(planscanR.cache_dir)`. Layout:

      <root>/
        files/<country>/<document_id>/
          <document_id>.meta.json                          # sidecar (see §4b)
          <country>_<document_id>_<slug>.<ext>             # flatten-safe basename

  There is no separate HTTP cache — the sidecar JSONs ARE the cache, and
  per-country handlers consult them via `sidecar_url_index()` before
  going to the network. \[clear_cache()\] removes the `files/` tree
  (optionally scoped by `country`); pair with `refresh = TRUE` on the
  next call if you want fresh fetches afterwards. The download layer
  pre-flights every URL with HEAD; files exceeding
  `getOption("planscanR.max_file_size_mb", 50)` are skipped and recorded
  in `download_status`. Already-on-disk non-empty files become
  `status = "cached"` unless `overwrite = TRUE`.

- **Errors** carry classed conditions
  (`planscanR_error_unsupported_country`, `planscanR_error_bad_input`,
  `planscanR_error_bad_schema`, `planscanR_warning_partial`) so tests
  can target them cleanly.

- **Tests**: `testthat` (edition 3) + `httptest2` mocks; **no live HTTP
  in CI**. Live tests, if any, live under `tests/manual/` and are
  git-ignored.

- **Secrets**: deferred to a future release; no `keyring` dependency in
  v0.1.

## 4b. Persistence and offline indexing

Every successfully processed record is persisted to a sidecar JSON at
`files/<country>/<document_id>/<document_id>.meta.json` — written
**atomically inside the per-record loop**, so an interrupted run leaves
N fully-indexable records on disk (not N orphan dirs). The sidecar
carries the full record (country, source_portal, document_id, url,
title, summary, dates, competent authority, proponent, relevance_score,
etc.) plus a per-file `files[]` array mirroring the `download_status`
columns (status, size_bytes, sha256, reason, section). Schema version:
`2`.

**The sidecar is the authoritative cache.** Per-country handlers consult
`sidecar_url_index(country)` at the start of every call to build a
`url -> sidecar-path` lookup; any URL with an on-disk sidecar is loaded
**from JSON** rather than re-fetched over HTTP. This makes re-scoring an
already-scanned slice against a new topic essentially free (only the
embedding compute, zero network). Pass `refresh = TRUE` to bypass the
sidecar lookup and force fresh detail-page fetches.

Sidecar writes **merge** the `relevance_scores` array: prior topic
entries whose slug isn’t present in the current run are preserved. So
running with `topic = c(wind = "...")` after a multi-topic scan doesn’t
wipe the solar / power_grid scores from disk — only the wind entry is
replaced.

`index_cache(cache_dir = NULL, country = NULL)` walks every sidecar
under the root and reconstructs a tibble matching the planscanR schema —
no portal calls. Use it to: - re-read a previously-downloaded slice
offline; - enumerate what’s on disk before deciding what else to
fetch; - recover after manually relocating or flattening files (because
the basenames are globally unique, `find files/ -exec mv {} flat/` is
safe).

## 5. Adding a country

1.  Create `R/get_assessments_<cc>.R` with the same signature surface as
    [`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md).
    The handler must return a tibble that passes
    `validate_result_schema()`.
2.  Add one line to the `switch` in `R/get_assessments.R`:
    `<cc> = get_assessments_<cc>,`.
3.  Update
    [`supported_countries()`](https://barthoekstra.github.io/planscanR/reference/supported_countries.md)
    in `R/utils_dispatch.R` and the
    [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
    tibble accordingly.
4.  Record fixtures with
    [`httptest2::capture_requests()`](https://enpiar.com/httptest2/reference/capture_requests.html)
    into `tests/testthat/fixtures/<cc>/` and add
    `tests/testthat/test-get_assessments_<cc>.R`.
5.  Document portal-specific search-facet vocabularies (`status`,
    `native_type`, etc.) in the handler’s roxygen.

That’s the whole recipe — no edits to the core dispatcher are needed.

## 5a. BIOGAIN topic defaults

[`biogain_assessment_topics()`](https://barthoekstra.github.io/planscanR/reference/biogain_assessment_topics.md)
([R/topics.R](https://barthoekstra.github.io/planscanR/R/topics.R))
returns the canonical six-topic set the BIOGAIN project uses against
environmental-assessment registers:

| slug | topic phrase embedded |
|----|----|
| `wind` | `"wind energy"` |
| `solar` | `"solar energy"` |
| `power_grid` | `"power lines, distribution and transmission infrastructure"` |
| `renewable_energy` | `"renewable energy"` |
| `energy_transition_strategy` | `"regional energy transition strategy and planning"` (intended to bridge NL RES, DE Klimaschutzkonzept, FR SRADDET / PCAET, AT Energiestrategie, …) |
| `renewable_zoning` | `"renewable energy zoning and designated development areas"` (intended to bridge NL zoekgebieden, DE Vorrangzonen, EU RED III acceleration areas, …) |

It’s an **opt-in default**, not applied automatically — users pass the
return value as `topic` to \[get_assessments()\] when they want this
set, and non-BIOGAIN use-cases just pass their own. The English phrases
are deliberately generic so the multilingual embedding model can
semantically bridge to each portal’s vocabulary without translation.

### How the topics are used

The function is a thin helper that returns a named character vector.
Three places in the package consume it:

1.  **[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
    / per-country handlers** — pass it through the `topic` argument.
    Each record’s title + summary is embedded once and compared against
    all six topic vectors in a single pass; the result tibble gains one
    `relevance_score_<slug>` column per topic.

    ``` r

    options(planscanR.cache_dir = "/path/to/cache")
    res <- get_assessments(
      "nl",
      topic = biogain_assessment_topics(),
      download = FALSE         # score-only; no PDFs fetched
    )
    res$relevance_score_wind
    res$relevance_score_energy_transition_strategy
    ```

2.  **[`score_assessments()`](https://barthoekstra.github.io/planscanR/reference/score_assessments.md)**
    — same vector, but for re-scoring an existing tibble (e.g. one
    obtained from
    [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md))
    without re-fetching.

    ``` r

    recs   <- index_cache("/path/to/cache")
    scored <- score_assessments(
      recs,
      topic = biogain_assessment_topics(),
      write_sidecar = TRUE     # persist back to the sidecars on disk
    )
    ```

3.  **Sidecar JSON** — when `write_sidecar = TRUE`, each topic gets its
    own entry in the per-record `relevance_scores` array under the slug
    from the names of the vector. Subsequent runs *merge* into this
    array, so
    [`score_assessments()`](https://barthoekstra.github.io/planscanR/reference/score_assessments.md)
    against a different topic set adds new entries alongside the BIOGAIN
    ones rather than clobbering them. To restrict a sidecar to a
    specific topic set, re-score with that set and then sweep
    non-matching topic entries (see \[/tmp/biogain_rescan.R\] for the
    reference pattern).

### Filtering with the topic set

Pass a `relevance_threshold` to drop records that don’t clear any topic.
A scalar threshold applies to all topics (record passes if **any** topic
clears it); a named numeric vector lets you set per-topic cutoffs.

``` r

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

[`biogain_assessment_topics()`](https://barthoekstra.github.io/planscanR/reference/biogain_assessment_topics.md)
is just a named character vector; merge or override it freely.

``` r

extended <- c(
  biogain_assessment_topics(),
  battery_storage = "battery energy storage and grid balancing",
  geothermal      = "geothermal heat and underground energy"
)
get_assessments("nl", topic = extended, download = FALSE)
```

## 5b. Relevance gate (pluggable embedding models)

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
accepts an optional `topic` parameter. When set, each candidate record’s
title + summary is embedded **once** and scored by cosine similarity
against the topic vector(s) **before** any attachments are downloaded.
`relevance_threshold` is a **download-gate only**: records that fall
below it keep their sidecar JSON and remain in the returned tibble —
only their PDFs are skipped. This means a later re-run with a different
threshold (or none at all) costs nothing in network: the metadata +
per-file attachment URLs are already on disk and
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
/ a sidecar-first re-fetch can pick them up offline.

**Single vs multi-topic** — `topic` accepts either: - a single character
string (legacy mode): adds `relevance_score` + `relevance_model`
columns; - a named character vector like
`c(wind = "wind energy", solar = "solar energy", res = "regional energy transition strategy")`:
adds one `relevance_score_<slug>` per topic plus a shared
`relevance_model`. Adding extra topics is essentially free — the
per-record embed runs once and we only do an extra cosine per topic.

`relevance_threshold` accepts a scalar (any topic ≥ scalar passes) or a
named numeric vector matching topic slugs (any named topic clears its
own cutoff passes).

For offline rescoring of an existing tibble against new topics without
re-fetching anything from the portal, use
`score_assessments(records, topic, model, write_sidecar = ...)`. Pairs
well with
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md).

**Pluggable model interface (S3)** - Built-in default:
[`embedding_model_minilm()`](https://barthoekstra.github.io/planscanR/reference/embedding_model_minilm.md)
— sentence-transformers `paraphrase-multilingual-MiniLM-L12-v2` via
`reticulate`. Lazy Python init on first use; needs
`reticulate::py_install("sentence-transformers")` (or
`reticulate::py_require("sentence-transformers")` per session under the
modern uv-backed config). - Custom backend:
`embedding_model(name, languages, embed_fn)` returns an S3 object that
participates in the same interface without writing methods. - Required
S3 methods on any new subclass:
[`embed_text()`](https://barthoekstra.github.io/planscanR/reference/embed_text.md),
[`supported_languages()`](https://barthoekstra.github.io/planscanR/reference/supported_languages.md),
[`model_name()`](https://barthoekstra.github.io/planscanR/reference/model_name.md). -
The relevance scorer warns once per (country, model) when a record’s
country language falls outside the model’s documented
[`supported_languages()`](https://barthoekstra.github.io/planscanR/reference/supported_languages.md)
list. Country → language map lives in `R/utils_language.R`.

**Sidecar persistence of relevance scores** - Single-topic mode: legacy
`relevance_score` + `relevance_model` fields. - Multi-topic mode:
`relevance_scores: [{topic, score, model, scored_at}, ...]` array.
`read_record_sidecar()` fans this back out into `relevance_score_<slug>`
columns. Old sidecars (without the array) still read fine — they just
don’t add per-topic columns.

## 5c. The BIOGAIN review app (`inst/biogain-review/`)

A bundled Shiny app for inspecting how records flow through the pipeline
and for building a **human ground-truth selection** to benchmark the
automated
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)
gate against. Launched via the exported
[`run_biogain_review()`](https://barthoekstra.github.io/planscanR/reference/run_biogain_review.md)
(in `R/biogain_review_app.R`), which locates the app with
[`system.file()`](https://rdrr.io/r/base/system.file.html), checks the
optional UI deps, and forwards `cache_dir`/`data_dir`.

**It is a consumer of the package, never a modifier.** It reads the
sidecar cache read-only through
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
/
[`score_keywords()`](https://barthoekstra.github.io/planscanR/reference/score_keywords.md)
/
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md),
and only *writes* three things: human review decisions, cached
translations, and the trained selection-model artifact
(`selection_model.rds`; see §5d). All model *logic* lives in the package
— the app just calls
[`train_selection_model()`](https://barthoekstra.github.io/planscanR/reference/train_selection_model.md)
/
[`predict_selection()`](https://barthoekstra.github.io/planscanR/reference/predict_selection.md)
and persists the result.

**Where things live** - App: `inst/biogain-review/app.R` (UI + server)
plus self-contained helpers in `inst/biogain-review/R/` — Shiny
auto-sources that `R/` dir. Helpers reach the package via `planscanR::`
/ `planscanR:::`, so the app only needs planscanR installed (or
`load_all`-ed in dev). - `data.R` — `load_or_build_snapshot()` (walks
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
once → an enriched, scalar-column snapshot cached as
`corpus_snapshot.rds`), `apply_selection()` (live wrapper over
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)),
and `draw_random_sample()` / `build_review_queue()` (stratified +
prioritised sampling). - `store.R` — review decisions as a
human-readable CSV (`reviews.csv`), one row per **(country, document_id,
reviewer)** so multiple reviewers coexist; plus a reviewers-name list
(`reviewers.txt`). - `funnel.R` — per-stage funnel counts, the
interactive plotly funnel, `selection_vs_human()` (auto-vs-human
precision/recall/F1; ground truth is one decision per record via
[`planscanR::consensus_reviews()`](https://barthoekstra.github.io/planscanR/reference/consensus_reviews.md)
— each reviewer’s most-recent verdict, then kept only if all reviewers
agree, so conflicting records are excluded), and
`inter_reviewer_summary()`. - `table.R` — the styled reactable
(per-row + bulk keep/drop/unsure, lazy translation fold-down), the
single-record stepper card, and the metric / column info popovers. -
`translate.R` — offline **Argos Translate** (`argostranslate` via
reticulate) for title/summary → English.

**Data location (important).** The app’s artefacts default to the
**cache root** (`cache_dir`, i.e. alongside `files/`), NOT a separate
user dir, so reviews travel with a cache sync. They sit at the root —
`reviews.csv`, `reviewers.txt`, `corpus_snapshot.rds`,
`random_sample.rds`, `selection_model.rds` — not under `files/`, so
[`clear_cache()`](https://barthoekstra.github.io/planscanR/reference/clear_cache.md)
(which only wipes `files/`) leaves them intact. Override with the
`data_dir` arg or `BIOGAIN_REVIEW_DATA`. Cache root resolves:
`cache_dir` → `PLANSCANR_CACHE` → `getOption("planscanR.cache_dir")` →
package default.

**Translations are persisted into the sidecars NON-DESTRUCTIVELY** —
under each record’s `extras` as `translation_*` keys, via the package’s
own merge-write — so they survive a later scan/score/classify rewrite
and surface through
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md).
CTranslate2 is forced single-threaded (`OMP_NUM_THREADS=1`) to avoid an
OpenMP/Shiny segfault.

**Inter-reviewer workflow.** A reviewer name is required before
classifying (enforced by a load modal + server gates). A new reviewer’s
queue first serves records *others* have reviewed but they haven’t (to
measure cross-reviewer agreement); only once caught up does it sample
fresh, unreviewed records.

**Deps** are in `Suggests` (shiny, bslib, reactable, plotly, htmltools);
the app is excluded from `R CMD check`/build only in that its runtime
data dir is never shipped. The launcher errors helpfully if a Suggested
package is missing.

## 5d. Learned selection model (supervised, from human labels)

A trainable counterpart to the hand-tuned
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)
rule: instead of OR-ing the three signals at fixed thresholds, it
**learns** the keep/drop decision from the review app’s `reviews.csv`
labels over the per-record scores already on the sidecars. Lives
entirely in the package (the app is a consumer, §5c). Files:
[R/select_features.R](https://barthoekstra.github.io/planscanR/R/select_features.R),
[R/select_learner.R](https://barthoekstra.github.io/planscanR/R/select_learner.R),
[R/train_selection.R](https://barthoekstra.github.io/planscanR/R/train_selection.R).

- **Feature contract —
  [`selection_features()`](https://barthoekstra.github.io/planscanR/reference/selection_features.md).**
  The single function both training and prediction call (no train/serve
  skew). Default feature set is the 6 `relevance_score_<slug>` cosine
  scores + 13 `class_score_<label>` classifier scores + `kw_total`, all
  already persisted on sidecars and surfaced by
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md).
  Missing/NA numerics → `0`. **Deliberately country-agnostic** so a
  model transfers to a new portal; `country` / `native_type` are opt-in
  via `include =` but OFF by default.
- **Pluggable learner — `selection_learner*()`.** Mirrors the
  [`embedding_model()`](https://barthoekstra.github.io/planscanR/reference/embedding_model.md)
  / classifier S3 pattern, built on tidymodels. The built-in
  [`selection_learner_logistic()`](https://barthoekstra.github.io/planscanR/reference/selection_learners_builtin.md)
  uses the base-R `glm` engine (needs only the tidymodels *glue*:
  parsnip / recipes / rsample / workflows — all Suggests). To use
  another algorithm, wrap any parsnip classification spec with the
  generic `selection_learner(name, spec, engine_pkg = ...)`;
  `engine_pkg` lets training fail early with a clear message when the
  engine package isn’t installed.
  `selection_learners(available_only = TRUE)` returns the built-ins only
  when the tidymodels glue is present (the app dropdown). Specs are
  built lazily, so a learner can be listed without parsnip present.
- **Honest metrics —
  [`train_selection_model()`](https://barthoekstra.github.io/planscanR/reference/train_selection_model.md).**
  Fits the final model on all labels but reports **out-of-fold**
  (stratified k-fold CV) precision/recall/F1
  - confusion, default on the unbiased `source == "random"` sample —
    directly comparable to `selection_vs_human()` for the heuristic, no
    train-on-test inflation.
    [`predict_selection()`](https://barthoekstra.github.io/planscanR/reference/predict_selection.md)
    adds `select_prob` + `selected_model`.
    `selection_cv_metrics(model, threshold)` re-scores the stored OOF
    predictions at any threshold with no retrain (the app’s threshold
    slider).
- **NOT yet wired into `biogain_acquire.R`.** Intentional: prove the
  learned gate beats the heuristic first. When it does, the runbook /
  [`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)
  can gate on
  [`predict_selection()`](https://barthoekstra.github.io/planscanR/reference/predict_selection.md).

## 6. Roadmap (informational; not actionable in v0.1)

- **[`classify_assessments()`](https://barthoekstra.github.io/planscanR/reference/classify_assessments.md)**
  — separate function that takes the tibble from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  and produces canonical type (`"eia"` / `"sea"` / `"other"`) +
  confidence via an LLM. Pipeline:
  1.  For each row, find cached PDFs at `local_path`.
  2.  Split each PDF into `pages_per_chunk` chunks (default 5–10) —
      these documents can be hundreds of pages.
  3.  Convert each chunk to markdown via the Python
      [docling](https://github.com/docling-project/docling) package,
      called from R via `reticulate`.
  4.  Send the markdown to an LLM for classification.
  5.  Aggregate per-document classification + confidence; add **new**
      columns to the tibble (`classified_type`, `classified_confidence`,
      `classified_at`). Never overload existing columns. Implication for
      v0.1 design: don’t mutate downloaded PDFs, and leave room for a
      `derived/` subdir under the cache root.
- **Additional country handlers** — DE, DK, AT and beyond. Order not
  committed.
- **`keyring`-based secrets** for portals that grow to require API keys;
  slot naming convention reserved as `planscanR_<country>_<portal>`.
- **[`classify_assessments()`](https://barthoekstra.github.io/planscanR/reference/classify_assessments.md)
  is also the home for cross-portal vocabulary normalisation** (status,
  type, jurisdiction); the fetcher stays raw.

## 7. Pointers

- Architectural reference: <https://github.com/aloftdata/getRad>
- Original design rationale + scope decisions:
  `~/.claude/plans/i-want-to-set-virtual-scroll.md`
- Implementation handover notes (env snapshot, probe findings):
  `~/.claude/plans/i-want-to-set-virtual-scroll-progress.md`
- Per-portal vocabulary documentation lives in
  `vignettes/supported-portals.Rmd` (when added) — until then,
  `get_assessments_coverage()$facets` is the runtime-accessible source.
