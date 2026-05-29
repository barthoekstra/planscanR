# Launch the BIOGAIN review and pipeline-funnel app

A Shiny app for the BIOGAIN project that visualises how environmental-
assessment records flow through the planscanR pipeline (indexed -\>
embedding cosine / zero-shot classifier / keyword -\> ensemble selection
-\> downloaded) and lets a reviewer build a human ground-truth selection
to compare the automated pre-selection against. It reads the sidecar
cache **read-only** via
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
/
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)
and writes its review decisions, offline translations, and a cached
snapshot to the cache root (see `data_dir`).

## Usage

``` r
run_biogain_review(
  cache_dir = NULL,
  data_dir = NULL,
  launch.browser = interactive(),
  ...
)
```

## Arguments

- cache_dir:

  Sidecar cache root to read. `NULL` (default) uses `PLANSCANR_CACHE`,
  then `getOption("planscanR.cache_dir")`, then the package default
  ([`tools::R_user_dir()`](https://rdrr.io/r/tools/userdir.html)
  `"cache"`).

- data_dir:

  Writable directory for the app's snapshot, `reviews.csv`, and
  reviewers list. `NULL` (default) uses the **cache root**
  (`cache_dir`), so the human annotations sit alongside the data they
  describe and travel with any cache sync. They are written at the root,
  not under `files/`, so
  [`clear_cache()`](https://barthoekstra.github.io/planscanR/reference/clear_cache.md)
  leaves them intact.

- launch.browser:

  Passed to
  [`shiny::runApp()`](https://rdrr.io/pkg/shiny/man/runApp.html);
  defaults to
  [`interactive()`](https://rdrr.io/r/base/interactive.html).

- ...:

  Further arguments forwarded to
  [`shiny::runApp()`](https://rdrr.io/pkg/shiny/man/runApp.html) (e.g.
  `port`, `host`).

## Value

Invisibly, the value of
[`shiny::runApp()`](https://rdrr.io/pkg/shiny/man/runApp.html) (called
for its side effect of running the app).

## Details

Features: an interactive funnel + per-country breakdown,
automated-vs-human agreement metrics (precision / recall / F1), a
sortable review table with per-row and bulk keep/drop/unsure, an
unbiased stratified random-sample reviewer, a single-record stepper
(arrow-key navigation, decide-and-advance), required reviewer
attribution, and on-demand offline English translation of
titles/summaries.

Requires the optional packages shiny, bslib, reactable, plotly,
htmltools, and jsonlite. Title/summary translation uses the Python
`argostranslate` package via reticulate; its language-pair models
download once on first use.

## Examples

``` r
if (FALSE) { # \dontrun{
# Uses the package cache + per-user data dir:
run_biogain_review()

# Point at a specific cache and a fixed port:
run_biogain_review(cache_dir = "/path/to/plans", port = 7654)
} # }
```
