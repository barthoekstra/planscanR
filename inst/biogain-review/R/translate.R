# Local offline translation via Argos Translate (argostranslate, CTranslate2).
# No API key, no quota — models run on-device. argostranslate is declared with
# reticulate::py_require() at app start; the needed language pairs (de->en,
# nl->en) are downloaded once on first use and then cached on disk by Argos.
#
# Translations are cached NON-DESTRUCTIVELY into each record's sidecar (extras
# translation_* keys) via the package's own merge-write. Re-translating with a
# different engine overwrites only the translation_* text — every other field
# (machine classification, relevance scores, files) is preserved, and human
# review decisions live in a separate store (reviews.csv), untouched.

TRANSLATE_ENGINE <- "argos"
# Cap per field so a single (synchronous, UI-blocking) translation stays
# responsive; longer text is truncated with a marker.
ARGOS_MAX_CHARS <- 4000L

# Country -> source language (NL Dutch; DE/AT German).
country_src_lang <- function(country) {
  m <- c(nl = "nl", de = "de", at = "de")
  v <- m[[country]]
  if (is.null(v)) NA_character_ else v
}

# --- Argos engine (lazy import + per-pair model install, cached per session) --
.argos <- new.env(parent = emptyenv())

argos_modules <- function() {
  if (is.null(.argos$pkg)) {
    .argos$pkg <- reticulate::import("argostranslate.package")
    .argos$tr <- reticulate::import("argostranslate.translate")
    .argos$pairs <- list()
  }
  .argos
}

# Ensure the from->to model is installed (downloads once). Cheap after the first
# call thanks to the per-session pairs cache.
argos_ensure_pair <- function(from, to = "en") {
  m <- argos_modules()
  key <- paste0(from, "->", to)
  if (isTRUE(m$pairs[[key]])) {
    return(invisible(TRUE))
  }
  installed <- m$pkg$get_installed_packages()
  have <- any(vapply(
    installed,
    function(p) identical(p$from_code, from) && identical(p$to_code, to),
    logical(1)
  ))
  if (!have) {
    m$pkg$update_package_index()
    avail <- m$pkg$get_available_packages()
    hit <- Filter(
      function(p) identical(p$from_code, from) && identical(p$to_code, to),
      avail
    )
    if (length(hit) == 0L) {
      stop("No Argos translation package for ", from, "->", to)
    }
    m$pkg$install_from_path(hit[[1]]$download())
  }
  .argos$pairs[[key]] <- TRUE
  invisible(TRUE)
}

# Translate one field. Returns NA on any failure so the UI falls back to the
# original text. Argos handles sentence segmentation internally, so no chunking
# is needed — only a length cap to bound the blocking time.
argos_translate <- function(text, from, to = "en") {
  if (is.null(text) || is.na(text) || !nzchar(trimws(text)) || is.na(from)) {
    return(NA_character_)
  }
  txt <- text
  truncated <- nchar(txt) > ARGOS_MAX_CHARS
  if (truncated) {
    txt <- substr(txt, 1L, ARGOS_MAX_CHARS)
  }
  out <- tryCatch(
    {
      argos_ensure_pair(from, to)
      argos_modules()$tr$translate(txt, from, to)
    },
    error = function(e) NA_character_
  )
  if (is.null(out) || is.na(out) || !nzchar(out)) {
    return(NA_character_)
  }
  if (truncated) paste0(out, " …[translation truncated]") else out
}

sidecar_file_path <- function(cache_dir, country, document_id) {
  file.path(
    cache_dir,
    "files",
    country,
    document_id,
    paste0(document_id, ".meta.json")
  )
}

# Read a cached translation straight from the sidecar's extras (no network).
read_translation <- function(cache_dir, country, document_id) {
  path <- sidecar_file_path(cache_dir, country, document_id)
  if (!file.exists(path)) {
    return(NULL)
  }
  p <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) NULL
  )
  ex <- p$extras
  if (
    is.null(ex) ||
      (is.null(ex$translation_title_en) && is.null(ex$translation_summary_en))
  ) {
    return(NULL)
  }
  list(
    title_en = ex$translation_title_en %||% NA_character_,
    summary_en = ex$translation_summary_en %||% NA_character_,
    src_lang = ex$translation_src_lang %||% NA_character_,
    service = ex$translation_service %||% NA_character_,
    at = ex$translation_at %||% NA_character_
  )
}

# Persist a translation NON-DESTRUCTIVELY: read the full record, attach the
# translation_* columns, and write it back through the package's merge-write
# (which keeps every other field and unions extras). Translations therefore
# survive a later scan/score/classify rewrite, and no other field is touched.
save_translation <- function(cache_dir, country, document_id, fields) {
  path <- sidecar_file_path(cache_dir, country, document_id)
  if (!file.exists(path)) {
    return(invisible(FALSE))
  }
  rec <- tryCatch(planscanR:::read_record_sidecar(path), error = function(e) NULL)
  if (is.null(rec)) {
    return(invisible(FALSE))
  }
  rec$translation_title_en <- fields$title_en %||% NA_character_
  rec$translation_summary_en <- fields$summary_en %||% NA_character_
  rec$translation_src_lang <- fields$src_lang %||% NA_character_
  rec$translation_service <- TRANSLATE_ENGINE
  rec$translation_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
  tryCatch(
    planscanR:::write_record_sidecar(rec, root = cache_dir),
    error = function(e) NULL
  )
  invisible(TRUE)
}

# Cached-or-fetch: return the record's English translation. Re-translates when
# there is no cache OR the cache came from a different engine. Returns a list
# with title_en, summary_en, src_lang, service, at.
ensure_translation <- function(cache_dir, country, document_id, title, summary) {
  cached <- read_translation(cache_dir, country, document_id)
  if (
    !is.null(cached) &&
      identical(cached$service, TRANSLATE_ENGINE) &&
      (!is.na(cached$title_en) || !is.na(cached$summary_en))
  ) {
    return(cached)
  }
  src <- country_src_lang(country)
  fields <- list(
    title_en = argos_translate(title, src, "en"),
    summary_en = argos_translate(summary, src, "en"),
    src_lang = src
  )
  if (!is.na(fields$title_en) || !is.na(fields$summary_en)) {
    save_translation(cache_dir, country, document_id, fields)
  }
  c(
    fields,
    list(
      service = TRANSLATE_ENGINE,
      at = format(Sys.time(), "%Y-%m-%dT%H:%M:%S")
    )
  )
}
