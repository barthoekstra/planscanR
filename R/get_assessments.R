#' Retrieve environmental-assessment records from a national portal.
#'
#' Unified entry point that dispatches on `country` to a per-country handler.
#' Returns a tibble of records. The shape of the returned tibble follows the
#' planscanR schema: a small required-columns set is guaranteed across
#' countries, and any additional columns exposed by the portal are appended
#' freely. See **Return value** for details.
#'
#' Per-country search parameters are forwarded through `...`. Some are
#' implemented by every handler that supports them (e.g. `theme`,
#' `advice_type`, `province`, `status`, `query`); consult the per-country
#' handler's documentation (e.g. [get_assessments_nl()]) for the exact
#' parameter surface and the vocabulary of valid values.
#'
#' @param country Character scalar, ISO-3166-1 alpha-2 country code (any case).
#'   v0.1 supports `"nl"`, `"de"`, `"at"`, and `"dk"`. See [supported_countries()].
#' @param date_range Optional length-2 vector `c(from, to)` of `Date`,
#'   `POSIXct`, or character. Filters by `date_published` / `date_decision`
#'   semantics decided per handler.
#' @param limit Maximum number of records to return (default `Inf`).
#' @param download Logical. If `TRUE` (default), attachment files referenced by
#'   each record are downloaded into the local cache. If `FALSE`, only metadata
#'   is returned; `local_path` is `character(0)` in every row.
#' @param cache_dir Optional cache root. Defaults to
#'   `tools::R_user_dir("planscanR", "cache")`.
#' @param overwrite Logical. If `TRUE`, re-download attachments even when a
#'   cached copy exists.
#' @param max_file_size_mb Numeric cap (in MiB) on per-file download size.
#'   URLs whose announced or actual size exceeds the cap are skipped and
#'   recorded in the `download_status` column with status `"skipped_size"`.
#'   `NULL` (default) defers to `getOption("planscanR.max_file_size_mb", 50)`;
#'   `Inf` disables the cap.
#' @param write_sidecar Logical. If `TRUE` (default), every returned record is
#'   persisted to a `<document_id>.meta.json` file alongside its attachments
#'   so the cache can be re-indexed offline via [index_cache()].
#' @param refresh Logical. If `FALSE` (default), records for URLs that already
#'   have a sidecar JSON on disk are loaded directly from the sidecar — no
#'   detail-page HTTP request at all. This makes re-scoring against new topics
#'   essentially free once a slice has been cached. Set to `TRUE` to force
#'   fresh detail-page fetches (useful if the portal genuinely changed).
#' @param topic Optional character vector of topic phrases. Pass a single
#'   string (e.g. `"wind energy infrastructure"`) or a named vector like
#'   `c(wind = "wind energy", solar = "solar energy",
#'   res = "regional energy transition strategy")`. Each candidate record's
#'   title+summary is embedded **once** per call and scored by cosine
#'   similarity against every topic, **before** any attachments are downloaded.
#'   Adds one `relevance_score_<slug>` column per topic plus a shared
#'   `relevance_model`. Unnamed topics get auto-slugified from the phrase.
#'   Adding extra topics costs essentially nothing — the per-record embed is
#'   the expensive step and runs once. Every scored record is sidecar'd and
#'   returned regardless of its score.
#' @param relevance_threshold Optional cutoff in `[-1, 1]`. This **only affects
#'   downloading**: records that score below the threshold still appear in the
#'   returned tibble and still get a sidecar JSON on disk — only their PDF
#'   attachments are skipped. This lets you re-run with a different threshold
#'   (or no threshold) later without re-hitting the portal. Scalar threshold:
#'   PDFs are downloaded if **any** topic clears it. Named numeric vector
#'   (e.g. `c(wind = 0.5, solar = 0.4)`): per-topic cutoffs, downloads happen
#'   if **any** named topic clears its own cutoff. `NULL` (default) is
#'   score-only; every record's PDFs are downloaded (when `download = TRUE`).
#' @param relevance_model A `planscanR_embedding_model`. Defaults to
#'   [embedding_model_minilm()] (sentence-transformers
#'   `paraphrase-multilingual-MiniLM-L12-v2` via reticulate). Pass a custom
#'   one built with [embedding_model()] to plug in a different backend.
#' @param discover Logical. If `TRUE`, after the portal handler returns,
#'   records that came back with no attachments (`length(attachment_urls)
#'   == 0`) are passed through [discover_attachments()] to find PDFs via a
#'   web-search backend. Off by default in v0.x — metadata-only handlers
#'   like AT emit a one-shot informational message pointing at this flag.
#'   See [discover_attachments()] for backend / config controls.
#' @param search_backend Optional [search_backend()] for the discovery
#'   pass. Defaults to [search_backend_tavily()] when `discover = TRUE`.
#' @param ... Forwarded to the country handler. Common search parameters are
#'   documented in [get_assessments_nl()].
#'
#' @return A tibble with at least these required columns:
#'   \describe{
#'     \item{`country`}{Character (ISO-2, lowercase).}
#'     \item{`source_portal`}{Character (e.g. `"commissiemer.nl"`).}
#'     \item{`document_id`}{Character. Portal-native ID, unique within the portal.}
#'     \item{`url`}{Character. Canonical portal landing URL.}
#'     \item{`retrieved_at`}{POSIXct (UTC).}
#'     \item{`attachment_urls`}{List-column of character vectors.}
#'     \item{`local_path`}{List-column of character vectors (parallel to `attachment_urls`).}
#'   }
#'   Handlers may add further columns such as `title`, `native_type`, `status`,
#'   `date_published`, `competent_authority`, `proponent`, `jurisdiction`, etc.
#'   No cross-portal normalisation is applied to these — values stay in the
#'   source portal's vocabulary.
#'
#' @seealso [get_assessments_coverage()], [get_assessments_nl()],
#'   [supported_countries()].
#' @export
get_assessments <- function(
  country,
  date_range = NULL,
  limit = Inf,
  download = TRUE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  discover = FALSE,
  search_backend = NULL,
  ...
) {
  country <- normalise_country(country)
  assert_country(country)
  handler <- select_assessments_handler(country)
  result <- handler(
    date_range = date_range,
    limit = limit,
    download = download,
    cache_dir = cache_dir,
    overwrite = overwrite,
    max_file_size_mb = max_file_size_mb,
    write_sidecar = write_sidecar,
    refresh = refresh,
    topic = topic,
    relevance_threshold = relevance_threshold,
    relevance_model = relevance_model,
    ...
  )
  validate_result_schema(result)

  # Discovery hook. Off by default; the per-handler "metadata-only" status in
  # get_assessments_coverage() is the trigger for the one-shot hint nudging
  # users towards `discover = TRUE`.
  if (isTRUE(discover) && download && nrow(result) > 0L) {
    n_empty <- sum(vapply(result$attachment_urls, function(v) length(v) == 0L, logical(1)))
    if (n_empty > 0L) {
      result <- discover_attachments(
        result,
        backend = search_backend,
        relevance_model = relevance_model,
        cache_dir = cache_dir,
        max_file_size_mb = max_file_size_mb
      )
      validate_result_schema(result)
    }
  } else if (!isTRUE(discover) && download && country %in% metadata_only_countries()) {
    nudge_discover_for_metadata_only(country)
  }

  result
}

#' Countries whose handler is metadata-only (no public attachments).
#'
#' Sourced from [get_assessments_coverage()] — any handler whose `status`
#' field starts with `"supported (metadata-only"` qualifies.
#' @noRd
metadata_only_countries <- function() {
  cov <- get_assessments_coverage()
  cov$country[grepl("^supported \\(metadata-only", cov$status)]
}

#' One-shot hint when a metadata-only handler is invoked with `discover = FALSE`.
#' @noRd
nudge_discover_for_metadata_only <- function(country) {
  flag <- paste0("planscanR.nudged_discover_", country)
  if (isTRUE(getOption(flag))) {
    return(invisible())
  }
  cli::cli_inform(c(
    i = "Country {.val {country}} has no public attachments via the portal.",
    i = "Pass {.code discover = TRUE} (and set {.envvar TAVILY_API_KEY}) to look for PDFs on the open web. See {.help discover_attachments}."
  ))
  do.call(options, stats::setNames(list(TRUE), flag))
  invisible()
}

#' Dispatch to the per-country handler.
#' @noRd
select_assessments_handler <- function(country) {
  switch(
    country,
    nl = get_assessments_nl,
    de = get_assessments_de,
    at = get_assessments_at,
    dk = get_assessments_dk,
    abort_unsupported_country(country)
  )
}
