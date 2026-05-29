# Launcher for the bundled BIOGAIN review & pipeline-funnel Shiny app. The app
# itself lives in inst/biogain-review/ (app.R + R/ helpers) and is run as a
# self-contained Shiny app; this thin wrapper locates it, checks the optional
# dependencies, and forwards the cache / data directories.

#' Launch the BIOGAIN review and pipeline-funnel app
#'
#' A Shiny app for the BIOGAIN project that visualises how environmental-
#' assessment records flow through the planscanR pipeline (indexed -> embedding
#' cosine / zero-shot classifier / keyword -> ensemble selection -> downloaded)
#' and lets a reviewer build a human ground-truth selection to compare the
#' automated pre-selection against. It reads the sidecar cache **read-only** via
#' [index_cache()] / [select_assessments()] and keeps its own review decisions,
#' offline translations, and a cached snapshot in a separate user directory.
#'
#' Features: an interactive funnel + per-country breakdown, automated-vs-human
#' agreement metrics (precision / recall / F1), a sortable review table with
#' per-row and bulk keep/drop/unsure, an unbiased stratified random-sample
#' reviewer, a single-record stepper (arrow-key navigation, decide-and-advance),
#' required reviewer attribution, and on-demand offline English translation of
#' titles/summaries.
#'
#' @param cache_dir Sidecar cache root to read. `NULL` (default) uses
#'   `PLANSCANR_CACHE`, then `getOption("planscanR.cache_dir")`, then the
#'   package default ([tools::R_user_dir()] `"cache"`).
#' @param data_dir Writable directory for the app's snapshot, `reviews.csv`, and
#'   reviewers list. `NULL` (default) uses `tools::R_user_dir("planscanR",
#'   "data")`.
#' @param launch.browser Passed to [shiny::runApp()]; defaults to
#'   [interactive()].
#' @param ... Further arguments forwarded to [shiny::runApp()] (e.g. `port`,
#'   `host`).
#'
#' @details Requires the optional packages \pkg{shiny}, \pkg{bslib},
#'   \pkg{reactable}, \pkg{plotly}, \pkg{htmltools}, and \pkg{jsonlite}.
#'   Title/summary translation uses the Python `argostranslate` package via
#'   \pkg{reticulate}; its language-pair models download once on first use.
#'
#' @return Invisibly, the value of [shiny::runApp()] (called for its side
#'   effect of running the app).
#' @export
#' @examples
#' \dontrun{
#' # Uses the package cache + per-user data dir:
#' run_biogain_review()
#'
#' # Point at a specific cache and a fixed port:
#' run_biogain_review(cache_dir = "/path/to/plans", port = 7654)
#' }
run_biogain_review <- function(
  cache_dir = NULL,
  data_dir = NULL,
  launch.browser = interactive(),
  ...
) {
  needed <- c("shiny", "bslib", "reactable", "plotly", "htmltools", "jsonlite")
  missing <- needed[!vapply(needed, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing) > 0L) {
    cli::cli_abort(c(
      "The BIOGAIN review app needs additional package{?s}: {.pkg {missing}}.",
      i = "Install {?it/them} and retry."
    ))
  }

  app_dir <- system.file("biogain-review", package = "planscanR")
  if (!nzchar(app_dir) || !file.exists(file.path(app_dir, "app.R"))) {
    cli::cli_abort("Review app not found; reinstall {.pkg planscanR}.")
  }

  if (!is.null(cache_dir)) {
    Sys.setenv(PLANSCANR_CACHE = cache_dir)
  }
  if (!is.null(data_dir)) {
    Sys.setenv(BIOGAIN_REVIEW_DATA = data_dir)
  }

  shiny::runApp(app_dir, launch.browser = launch.browser, ...)
}
