#' Build an in-memory mock search backend.
#'
#' Returns a `planscanR_search_backend` that looks up incoming queries in a
#' static map and returns the canned responses. Used by the test suite (no
#' live HTTP) and by [discover_attachments()] when you want a fully
#' deterministic replay against a cached corpus.
#'
#' @param responses Named list. Names are queries (matched exactly first,
#'   then by `grepl()` substring) and values are lists of result objects
#'   (each `list(url, title, content, score)`). Names not used are matched
#'   via the special key `"_default"` if supplied; absent that, an unmatched
#'   query yields an empty list.
#' @return A `planscanR_search_backend`.
#' @export
#' @examples
#' \dontrun{
#' mock <- search_backend_mock(list(
#'   "windpark parndorf" = list(
#'     list(url = "https://x.example/parndorf.pdf", title = "Bescheid")
#'   ),
#'   "_default" = list()
#' ))
#' web_search(mock, "windpark parndorf")
#' }
search_backend_mock <- function(responses = list()) {
  if (!is.list(responses)) {
    cli::cli_abort("{.arg responses} must be a named list.")
  }
  search_fn <- function(query, include_domains, max_results) {
    if (query %in% names(responses)) {
      return(head(responses[[query]], max_results))
    }
    for (key in setdiff(names(responses), "_default")) {
      if (grepl(key, query, ignore.case = TRUE, fixed = FALSE)) {
        return(head(responses[[key]], max_results))
      }
    }
    head(responses[["_default"]] %||% list(), max_results)
  }
  structure(
    list(name = "mock", search_fn = search_fn),
    class = c(
      "planscanR_search_backend_mock",
      "planscanR_search_backend_custom",
      "planscanR_search_backend"
    )
  )
}
