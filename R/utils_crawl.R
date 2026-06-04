# -----------------------------------------------------------------------------
# Streaming crawl driver, shared by every paginated country handler.
#
# The handlers used to enumerate a register's ENTIRE listing into an in-memory
# index before fetching a single detail page or writing a single sidecar. For a
# full (limit = Inf) crawl that meant a long, silent, unpersisted phase up
# front — no progress, nothing on disk, and an interrupted run lost the whole
# listing pass and had to re-enumerate from scratch on resume.
#
# stream_crawl() interleaves the two phases instead: it pulls ONE page of
# listing rows at a time and processes each row (sidecar-first detail fetch +
# score + sidecar write) before pulling the next page. So records are persisted
# from the very first page, progress is visible immediately, and a re-run
# resumes via the sidecar-first `process` callback having re-paid only the
# listing pages it had not yet consumed.
#
# Contract — a handler supplies two closures:
#   * `next_page()` : a zero-arg PAGE GENERATOR. Each call returns the next
#       batch of lightweight listing entries (a list), or NULL / an empty list
#       when the register is exhausted. All pagination state (page number,
#       offset, seen-codes for clamped-last-page portals, ...) lives in the
#       closure. The per-handler `*_fetch_search()` / `*_fetch_records()` etc.
#       now BUILD and return such a generator rather than the full list — which
#       keeps them the single mock boundary the test-suite stubs.
#   * `process(entry)` : turns one listing entry into a 1-row record tibble
#       (sidecar-first detail fetch, client-side filters, relevance, downloads,
#       sidecar write) or returns NULL to drop the row (filtered / unparseable).
# -----------------------------------------------------------------------------

#' Drive a streaming, page-at-a-time crawl.
#'
#' @param next_page Zero-arg page generator (see file header). Returns the next
#'   list of listing entries, or `NULL` / `list()` when exhausted.
#' @param process Function of one entry returning a 1-row record tibble or
#'   `NULL`. Responsible for the sidecar write, so an interrupted crawl leaves
#'   every processed record on disk.
#' @param limit Maximum number of records to KEEP (after `process` filters);
#'   `Inf` for the whole register. Pages are pulled only until this many kept
#'   records exist, so no listing overshoot is needed.
#' @param label Country code, shown in the progress bar.
#' @return A list of kept record rows (caller binds with [bind_results()]).
#' @noRd
stream_crawl <- function(next_page, process, limit = Inf, label = "") {
  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling ", toupper(label), "  ",
      "records {length(records)}",
      if (is.finite(limit)) paste0("/", limit) else "",
      "  |  elapsed {cli::pb_elapsed}"
    ),
    total = NA,
    clear = FALSE
  )
  on.exit(cli::cli_progress_done(), add = TRUE)

  while (length(records) < limit) {
    entries <- next_page()
    if (is.null(entries) || length(entries) == 0L) {
      break
    }
    for (entry in entries) {
      if (length(records) >= limit) {
        break
      }
      rec <- process(entry)
      if (is.null(rec)) {
        next
      }
      records[[length(records) + 1L]] <- rec
      cli::cli_progress_update()
    }
  }
  records
}
