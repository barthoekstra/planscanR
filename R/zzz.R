.onLoad <- function(libname, pkgname) {
  op <- options()
  defaults <- list(
    planscanR.user_agent = NULL,
    planscanR.timeout = 60,
    planscanR.max_tries = 5,
    planscanR.max_file_size_mb = 50
  )
  toset <- !(names(defaults) %in% names(op))
  if (any(toset)) {
    options(defaults[toset])
  }
  invisible()
}
