#' Slug a string to an ASCII column suffix: lowercase, collapse runs of
#' non-alphanumerics to a single `_`, trim leading/trailing `_`. Transliteration
#' of non-ASCII is the CALLER's responsibility (per-handler maps are
#' deliberately language-specific). NULL / non-scalar / NA / empty returns
#' `fallback`.
#' @noRd
ascii_slug <- function(s, fallback = "x") {
  if (is.null(s) || length(s) != 1L || is.na(s) || !nzchar(s)) {
    return(fallback)
  }
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) fallback else s
}
