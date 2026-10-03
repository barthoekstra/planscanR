# Small helpers shared by campaign adapters and the generic result contract.

#' Collect a record's generic and per-section attachment URL columns.
#'
#' A few older sidecars only have the required `attachment_urls` column, while
#' newer handlers may additionally expose `attachment_urls_<section>` columns.
#' Keep both shapes usable by downstream acquisition code.
#' @param record A one-row planscanR result data frame.
#' @return A named list of non-empty character URL vectors. The generic column
#'   is named `generic`; section columns use their suffix.
#' @noRd
collect_attachment_sections <- function(record) {
  if (!is.data.frame(record) || nrow(record) != 1L) {
    cli::cli_abort("{.arg record} must be exactly one data-frame row.")
  }
  clean <- function(value) {
    if (is.list(value)) {
      value <- value[[1]]
    }
    value <- as.character(value %||% character(0))
    value[!is.na(value) & nzchar(value)]
  }
  out <- list()
  if ("attachment_urls" %in% names(record)) {
    generic <- clean(record[["attachment_urls"]])
    if (length(generic) > 0L) {
      out$generic <- generic
    }
  }
  cols <- grep("^attachment_urls_", names(record), value = TRUE)
  for (col in cols) {
    urls <- clean(record[[col]])
    if (length(urls) > 0L) {
      out[[sub("^attachment_urls_", "", col)]] <- urls
    }
  }
  out
}
