# Tavily search backend.
#
# Default production backend for [discover_attachments()]. Calls
# https://api.tavily.com/search with an API key read from the environment.
# The key is **per-session**; the package never persists it to disk and never
# logs it.

#' Build a Tavily search backend.
#'
#' Requires a Tavily API key in the `TAVILY_API_KEY` environment variable
#' (set in `~/.Renviron` or per-session with `Sys.setenv()`).
#'
#' @param api_key Optional explicit key. Defaults to
#'   `Sys.getenv("TAVILY_API_KEY")`. Stored on the backend object — never
#'   logged or persisted by the package.
#' @param search_depth Either `"basic"` (default, cheaper) or `"advanced"`
#'   (deeper crawl per result, ~3x the cost).
#' @param max_results_cap Maximum results to request per query, passed through
#'   as `max_results` (default `10`, allowed range 1-100). Tavily may return
#'   fewer than requested.
#' @return A `planscanR_search_backend`.
#' @export
#' @examples
#' \dontrun{
#' Sys.setenv(TAVILY_API_KEY = "tvly-...")
#' tav <- search_backend_tavily()
#' web_search(tav, "Windpark Parndorf Bescheid filetype:pdf")
#' }
search_backend_tavily <- function(
  api_key = NULL,
  search_depth = c("basic", "advanced"),
  max_results_cap = 10L
) {
  search_depth <- match.arg(search_depth)
  api_key <- api_key %||% Sys.getenv("TAVILY_API_KEY", unset = "")
  if (!nzchar(api_key)) {
    cli::cli_abort(
      c(
        "Tavily API key not found.",
        i = "Set the {.envvar TAVILY_API_KEY} environment variable, or pass {.arg api_key} explicitly."
      ),
      class = "planscanR_error_missing_credentials"
    )
  }
  if (!is.numeric(max_results_cap) || max_results_cap < 1 || max_results_cap > 100) {
    cli::cli_abort("{.arg max_results_cap} must be an integer 1-100.")
  }

  structure(
    list(
      name = "tavily",
      api_key = api_key,
      search_depth = search_depth,
      max_results_cap = as.integer(max_results_cap)
    ),
    class = c(
      "planscanR_search_backend_tavily",
      "planscanR_search_backend"
    )
  )
}

#' @export
web_search.planscanR_search_backend_tavily <- function(
  backend,
  query,
  include_domains = NULL,
  max_results = 10L
) {
  if (!is.character(query) || length(query) != 1L || !nzchar(query)) {
    cli::cli_abort("{.arg query} must be a single non-empty string.")
  }
  cap <- min(as.integer(max_results), backend$max_results_cap)

  body <- list(
    api_key = backend$api_key,
    query = query,
    search_depth = backend$search_depth,
    max_results = cap,
    include_answer = FALSE,
    include_raw_content = FALSE,
    include_images = FALSE
  )
  if (length(include_domains) > 0L) {
    body$include_domains <- as.list(include_domains)
  }

  req <- req_planscanr("https://api.tavily.com/search")
  req <- httr2::req_method(req, "POST")
  req <- httr2::req_headers(req, `Content-Type` = "application/json")
  req <- httr2::req_body_raw(
    req,
    jsonlite::toJSON(body, auto_unbox = TRUE)
  )
  resp <- httr2::req_perform(req)
  parsed <- httr2::resp_body_json(resp, simplifyVector = FALSE)
  results <- parsed$results %||% list()

  # Normalise to the package-internal result shape: list of named lists with
  # url, title, content, score. Drop entries missing a url outright.
  norm <- lapply(results, function(r) {
    list(
      url = r$url %||% NA_character_,
      title = r$title %||% NA_character_,
      content = r$content %||% NA_character_,
      score = if (is.null(r$score)) NA_real_ else as.numeric(r$score),
      raw_content = r$raw_content
    )
  })
  Filter(function(r) !is.na(r$url) && nzchar(r$url), norm)
}
