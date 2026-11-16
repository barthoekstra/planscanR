#' Countries supported by the current version of planscanR.
#'
#' Returns a character vector of ISO-3166-1 alpha-2 country codes (lowercase).
#'
#' @return Character vector.
#' @export
#' @examples
#' supported_countries()
supported_countries <- function() {
  c(
    "nl",
    "de",
    "fr",
    "at",
    "dk",
    "be",
    "ee",
    "fi",
    "bg",
    "cz",
    "hr",
    "gr",
    "is",
    "ie",
    "si",
    "pt",
    "gb",
    "it",
    "sk",
    "no",
    "lv",
    "es"
  )
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

#' Registry of explicit, opt-in assessment sources.
#'
#' Named list `source_id -> list(handler, name, granularity, geography, scope,
#' limitations, url)`. Empty until source adapters register themselves here.
#' @noRd
assessment_sources <- function() {
  list()
}

#' Validate a scalar ISO-2 format (two ASCII letters), independent of
#' [supported_countries()].
#' @noRd
assert_iso2_format <- function(country) {
  if (!grepl("^[a-z]{2}$", country)) {
    cli::cli_abort(
      "{.arg country} must be a two-letter ISO-3166-1 alpha-2 code when {.arg source} is set, not {.val {country}}.",
      class = "planscanR_error_bad_input"
    )
  }
  invisible(country)
}

#' Look up the handler for an explicit source.
#' @noRd
select_source_handler <- function(source) {
  if (!is.character(source) || length(source) != 1L || is.na(source) || !nzchar(source)) {
    cli::cli_abort(
      "{.arg source} must be a single non-empty, non-NA string.",
      class = "planscanR_error_bad_input"
    )
  }
  reg <- assessment_sources()
  if (!source %in% names(reg)) {
    cli::cli_abort(
      c(
        "Unknown {.arg source} {.val {source}}.",
        i = if (length(reg)) {
          "Available sources: {.val {names(reg)}}. See {.fn get_assessments_sources}."
        } else {
          "No explicit sources are registered yet. See {.fn get_assessments_sources}."
        }
      ),
      class = "planscanR_error_bad_input"
    )
  }
  reg[[source]]$handler
}

#' Explicit assessment sources.
#'
#' Lists the opt-in sources selectable with `get_assessments(source = )`, in
#' addition to the national portals reported by [get_assessments_coverage()].
#'
#' @return A tibble with columns `source`, `name`, `granularity`, `geography`,
#'   `scope`, `limitations`, `url` (zero rows when no source is registered).
#' @seealso [get_assessments()], [get_assessments_coverage()]
#' @export
#' @examples
#' get_assessments_sources()
get_assessments_sources <- function() {
  reg <- assessment_sources()
  cols <- c("name", "granularity", "geography", "scope", "limitations", "url")
  out <- tibble::tibble(source = names(reg) %||% character(0))
  for (col in cols) {
    out[[col]] <- vapply(
      reg,
      function(r) as.character(r[[col]] %||% NA_character_)[1L],
      character(1),
      USE.NAMES = FALSE
    )
  }
  out
}
