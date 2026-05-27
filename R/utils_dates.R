#' Parse a date-range argument.
#'
#' Accepts `NULL` (returns `NULL`), a length-2 vector of `Date`, `POSIXct`, or
#' character strings (any format parseable by [base::as.Date()]).
#'
#' @param x A length-2 vector or `NULL`.
#' @return Either `NULL`, or a length-2 `Date` vector `c(from, to)` with `from <= to`.
#' @noRd
parse_date_range <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 2L) {
    cli::cli_abort(
      "{.arg date_range} must be a length-2 vector, got length {length(x)}.",
      class = "planscanR_error_bad_input"
    )
  }
  out <- tryCatch(as.Date(x), error = function(e) {
    cli::cli_abort(
      c("Could not parse {.arg date_range} as dates.", x = conditionMessage(e)),
      class = "planscanR_error_bad_input"
    )
  })
  if (any(is.na(out))) {
    cli::cli_abort(
      "{.arg date_range} contains values that could not be parsed as dates.",
      class = "planscanR_error_bad_input"
    )
  }
  if (out[1] > out[2]) {
    cli::cli_abort(
      "{.arg date_range} must be in order: from <= to.",
      class = "planscanR_error_bad_input"
    )
  }
  out
}
