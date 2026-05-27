# Pluggable web-search backend for the attachment-discovery pipeline.
#
# Same S3 shape as `embedding_model`: a base constructor returns a generic
# object, with subclasses providing the real implementation behind one method
# (`web_search()`). Tests inject a mock backend that replays canned responses
# from disk; the package's default production backend talks to Tavily.

#' Build a custom search backend.
#'
#' Wraps a user-supplied search function as a `planscanR_search_backend`
#' object compatible with [discover_attachments()]. Use this when you have an
#' in-house search service, want to swap to Bing / Brave / Google CSE without
#' waiting for first-party support, or need a deterministic mock in tests.
#'
#' @param name Short identifier for the backend (e.g. `"tavily"`,
#'   `"google-cse"`). Surfaced in logs and the sidecar `discovery_log[]`.
#' @param search_fn A function `function(query, include_domains, max_results)`
#'   returning a list of result objects, each a named list with at minimum
#'   `url` (character) and optionally `title`, `content`, `score`.
#' @return A `planscanR_search_backend` object.
#' @export
#' @examples
#' \dontrun{
#' my_backend <- search_backend(
#'   name = "fake-google",
#'   search_fn = function(query, include_domains, max_results) {
#'     list(list(url = "https://example.org/x.pdf", title = "Test", score = 1))
#'   }
#' )
#' web_search(my_backend, "windpark parndorf", NULL, 5)
#' }
search_backend <- function(name, search_fn) {
  if (!is.character(name) || length(name) != 1L || !nzchar(name)) {
    cli::cli_abort("{.arg name} must be a single non-empty string.")
  }
  if (!is.function(search_fn)) {
    cli::cli_abort("{.arg search_fn} must be a function.")
  }
  structure(
    list(name = name, search_fn = search_fn),
    class = c("planscanR_search_backend_custom", "planscanR_search_backend")
  )
}

#' Run a single web-search query through a backend.
#'
#' The dispatching half of the search-backend interface. Returns a list of
#' result objects; each is a named list with at least `url`. Implementations
#' are responsible for honouring `include_domains` and `max_results` to the
#' best of the underlying API's ability.
#'
#' @param backend A `planscanR_search_backend`.
#' @param query Character scalar.
#' @param include_domains Character vector, or `NULL` for no domain
#'   restriction.
#' @param max_results Integer cap on results (default 10).
#' @return List of result objects.
#' @export
web_search <- function(backend, query, include_domains = NULL, max_results = 10L) {
  UseMethod("web_search")
}

#' @export
web_search.default <- function(backend, query, include_domains = NULL, max_results = 10L) {
  cli::cli_abort(
    "No web_search() method for class {.cls {class(backend)[1]}}.",
    class = "planscanR_error_bad_input"
  )
}

#' @export
web_search.planscanR_search_backend_custom <- function(
  backend,
  query,
  include_domains = NULL,
  max_results = 10L
) {
  backend$search_fn(
    query = query,
    include_domains = include_domains,
    max_results = max_results
  )
}

#' Printable name of a search backend.
#' @param backend A backend object.
#' @return Character scalar.
#' @export
backend_name <- function(backend) {
  UseMethod("backend_name")
}

#' @export
backend_name.default <- function(backend) {
  class(backend)[1]
}

#' @export
backend_name.planscanR_search_backend <- function(backend) {
  backend$name %||% class(backend)[1]
}

#' @export
format.planscanR_search_backend <- function(x, ...) {
  paste0("<planscanR_search_backend: ", backend_name(x), ">")
}

#' @export
print.planscanR_search_backend <- function(x, ...) {
  cat(format(x, ...), "\n", sep = "")
  invisible(x)
}
