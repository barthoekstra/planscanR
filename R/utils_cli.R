#' Abort with classed condition for an unsupported country
#' @param country Country code that was requested.
#' @param supported Vector of supported codes.
#' @noRd
abort_unsupported_country <- function(country, supported = supported_countries()) {
  cli::cli_abort(
    c(
      "Country {.val {country}} is not supported in this version of planscanR.",
      i = "Supported countries: {.val {supported}}",
      i = "Open an issue or contribute a handler: see {.file vignettes/adding-a-country.Rmd}."
    ),
    class = "planscanR_error_unsupported_country"
  )
}

#' Inform user a download is starting.
#' @noRd
inform_download <- function(n_files, dest_dir) {
  cli::cli_inform(c(
    i = "Downloading {.val {n_files}} attachment{?s} to {.file {dest_dir}}"
  ))
}

#' Warn that a portal returned partial / unexpected data.
#'
#' `.envir` defaults to `parent.frame()` so cli's `{var}` interpolation
#' resolves against the caller's environment, not `warn_partial`'s own.
#' @noRd
warn_partial <- function(message, ..., .envir = parent.frame()) {
  cli::cli_warn(message, ..., class = "planscanR_warning_partial", .envir = .envir)
}
