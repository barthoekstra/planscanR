#' Countries supported by the current version of planscanR.
#'
#' Returns a character vector of ISO-3166-1 alpha-2 country codes (lowercase).
#'
#' @return Character vector.
#' @export
#' @examples
#' supported_countries()
supported_countries <- function() {
  c("nl")
}

#' Normalise a country code to lowercase ISO-2.
#'
#' Accepts any case; rejects non-character or non-scalar input.
#'
#' @param country Character scalar.
#' @return Lowercase character scalar.
#' @noRd
normalise_country <- function(country) {
  if (!is.character(country) || length(country) != 1L || is.na(country) || !nzchar(country)) {
    cli::cli_abort(
      "{.arg country} must be a single non-empty character string.",
      class = "planscanR_error_bad_input"
    )
  }
  tolower(country)
}

#' Assert that a country code is supported.
#'
#' @param country Country code (lowercase).
#' @noRd
assert_country <- function(country) {
  if (!country %in% supported_countries()) {
    abort_unsupported_country(country)
  }
  invisible(country)
}
