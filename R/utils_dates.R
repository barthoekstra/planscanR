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

#' Parse the leading `YYYY-MM-DD` of an ISO-8601 string to a `Date`.
#' Takes the first 10 characters, so an ISO datetime yields its date. `NA` for
#' NULL / non-scalar / NA / empty / unparseable. (was the per-portal
#' `*_parse_iso_date()`.)
#' @noRd
parse_iso_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(tryCatch(
    as.Date(substr(s, 1L, 10L)),
    error = function(e) as.Date(NA)
  ))
  if (length(d) == 0L) as.Date(NA) else d
}

#' Parse a `DD.MM.YYYY` date appearing anywhere in a string to a `Date`.
#' Extracts the first `DD.MM.YYYY` (1- or 2-digit day/month) match, so a date
#' embedded in surrounding text (e.g. `"от 12.05.2024 г."`) parses. `NA` for
#' NULL / non-scalar / NA / empty / no-match.
#' @noRd
parse_dmy <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  m <- regmatches(s, regexpr("[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}", s))
  if (length(m) == 0L || !nzchar(m)) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(as.Date(m, format = "%d.%m.%Y"))
  if (length(d) == 0L) as.Date(NA) else d
}

#' Parse a Dutch-language date (`"26 mei 2026"`) to a `Date`. Full + common
#' abbreviated Dutch month names. `NA` for NULL / non-scalar / NA / empty /
#' unrecognised.
#' @noRd
parse_dutch_date <- function(s) {
  if (is.null(s) || length(s) != 1L || is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  months <- c(
    "januari" = 1, "februari" = 2, "maart" = 3, "april" = 4, "mei" = 5,
    "juni" = 6, "juli" = 7, "augustus" = 8, "september" = 9, "oktober" = 10,
    "november" = 11, "december" = 12, "jan" = 1, "feb" = 2, "mrt" = 3,
    "apr" = 4, "jun" = 6, "jul" = 7, "aug" = 8, "sept" = 9, "sep" = 9,
    "okt" = 10, "nov" = 11, "dec" = 12
  )
  parts <- strsplit(tolower(trimws(s)), "\\s+")[[1]]
  if (length(parts) != 3L) {
    return(as.Date(NA))
  }
  day <- suppressWarnings(as.integer(parts[1]))
  mon <- months[parts[2]]
  yr <- suppressWarnings(as.integer(parts[3]))
  if (is.na(day) || is.na(mon) || is.na(yr)) {
    return(as.Date(NA))
  }
  as.Date(sprintf("%04d-%02d-%02d", yr, mon, day))
}

#' Parse a leading numeric German date (`"12.03.2024"`) to a `Date`. Anchored at
#' the START (a date embedded later in prose does NOT match, by design). `NA`
#' for NULL / non-scalar / NA / empty / no-leading-date.
#' @noRd
parse_german_date <- function(s) {
  if (is.null(s) || length(s) != 1L || is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  s <- trimws(s)
  m <- regmatches(s, regexpr("^([0-9]{1,2})\\.([0-9]{1,2})\\.([0-9]{4})", s))
  if (length(m) == 0L) {
    return(as.Date(NA))
  }
  parts <- strsplit(m, "\\.")[[1]]
  day <- suppressWarnings(as.integer(parts[1]))
  mon <- suppressWarnings(as.integer(parts[2]))
  yr <- suppressWarnings(as.integer(parts[3]))
  if (is.na(day) || is.na(mon) || is.na(yr)) {
    return(as.Date(NA))
  }
  as.Date(sprintf("%04d-%02d-%02d", yr, mon, day))
}
