# Sidecar JSON I/O.
#
# Each fully-processed record is persisted to
# `<cache>/files/<country>/<document_id>/<document_id>.meta.json`. The sidecar
# is the canonical offline record: it captures the full tibble row plus
# per-file download status, so the cache can be re-indexed without
# re-fetching anything from the portal.

SCHEMA_VERSION <- 1L

#' Path to a record's sidecar JSON file.
#' @noRd
sidecar_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".meta.json")
  )
}

#' Write a sidecar JSON for a single record.
#'
#' Atomic write: data is serialised to a temp file in the target dir and then
#' renamed over the destination, so a crash mid-write cannot leave a
#' half-written sidecar in place.
#'
#' @param record A 1-row tibble in the planscanR result shape.
#' @param downloads The structured download-status tibble produced by
#'   `download_attachments()`. May be empty when `download = FALSE`.
#' @param root Cache root (or `NULL` to use the default).
#' @return Path to the written sidecar, invisibly.
#' @noRd
write_record_sidecar <- function(record, downloads = NULL, root = NULL) {
  stopifnot(is.data.frame(record), nrow(record) == 1L)
  path <- sidecar_path(record$country, record$document_id, root = root)
  payload <- record_to_sidecar(record, downloads)
  # If a sidecar already exists, preserve any topic entries in
  # `relevance_scores` whose slugs are NOT being rewritten this run. Lets a
  # later call extend a previously-scored record without clobbering earlier
  # scores, and lets per-topic model metadata stay accurate over time.
  if (file.exists(path)) {
    existing <- tryCatch(
      jsonlite::fromJSON(path, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(existing$relevance_scores)) {
      new_topics <- vapply(
        payload$relevance_scores %||% list(),
        function(e) e$topic %||% "",
        character(1)
      )
      preserved <- Filter(
        function(e) !(e$topic %||% "" %in% new_topics),
        existing$relevance_scores
      )
      payload$relevance_scores <- c(
        payload$relevance_scores %||% list(),
        preserved
      )
    }
  }
  tmp <- tempfile(tmpdir = dirname(path), fileext = ".json")
  con <- file(tmp, open = "wb", encoding = "UTF-8")
  on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = TRUE, null = "null"), con)
  close(con)
  file.rename(tmp, path)
  invisible(path)
}

#' Serialise a record + downloads into the sidecar JSON shape.
#' @noRd
record_to_sidecar <- function(record, downloads = NULL) {
  base <- list(
    schema_version = SCHEMA_VERSION,
    country = record$country,
    source_portal = record$source_portal,
    document_id = record$document_id,
    url = record$url,
    retrieved_at = format(record$retrieved_at, "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    title = nullable(record$title),
    summary = nullable(record$summary),
    competent_authority = nullable(record$competent_authority),
    proponent = nullable(record$proponent),
    date_decision = nullable_date(record$date_decision),
    # `[[` returns NULL silently when the column is absent (e.g. records
    # never went through the relevance gate). `$` would emit a tibble warning.
    relevance_model = nullable(record[["relevance_model"]]),
    # One entry per relevance_score_<slug> column found on the record. Each
    # entry stores topic-slug, score, model name, and time.
    relevance_scores = record_topic_scores(record)
  )
  # Carry through any extra columns we don't explicitly know about (other than
  # the required list-columns, which we treat below). Per-section attachment
  # and local_path columns follow the `attachment_urls_<section>` /
  # `local_path_<section>` convention and are excluded here regardless of
  # which sections a country uses (NL: source/advice; DE: uvp_bericht/
  # berichte/auslegung/weitere; future portals: whatever they expose).
  section_cols <- grep("^(attachment_urls|local_path)_", names(record), value = TRUE)
  reserved <- c(
    names(base),
    "retrieved_at",
    "attachment_urls",
    "local_path",
    section_cols,
    "file_sha256",
    "download_status"
  )
  extras <- setdiff(names(record), reserved)
  if (length(extras) > 0L) {
    base$extras <- lapply(extras, function(cn) {
      v <- record[[cn]]
      if (is.list(v)) v[[1]] else v
    })
    names(base$extras) <- extras
  }
  # Per-file status
  if (is.null(downloads) || nrow(downloads) == 0L) {
    files <- list()
  } else {
    # Map each URL back to whichever `attachment_urls_<section>` list-column
    # it appeared in. Works for any country: NL exposes source/advice, DE
    # exposes uvp_bericht/berichte/auslegung/weitere, future portals are free
    # to declare their own. First match wins (sections shouldn't overlap; if
    # they do, the order in `section_cols` is the tiebreak).
    section_cols <- grep("^attachment_urls_", names(record), value = TRUE)
    section_lookup <- lapply(section_cols, function(cn) record[[cn]][[1]])
    names(section_lookup) <- sub("^attachment_urls_", "", section_cols)
    section_of <- function(url) {
      for (nm in names(section_lookup)) {
        if (url %in% section_lookup[[nm]]) {
          return(nm)
        }
      }
      NA_character_
    }
    files <- lapply(seq_len(nrow(downloads)), function(i) {
      r <- downloads[i, ]
      list(
        url = r$url,
        section = section_of(r$url),
        filename = if (is.na(r$local_path)) NULL else basename(r$local_path),
        local_path = nullable(r$local_path),
        status = r$status,
        size_bytes = nullable_numeric(r$size_bytes),
        sha256 = nullable(r$sha256),
        reason = nullable(r$reason)
      )
    })
  }
  base$files <- files
  base
}

#' Build the `relevance_scores` JSON array from a 1-row record's columns.
#'
#' Looks for any column named `relevance_score_*` and emits one entry per
#' topic. Returns `list()` (serialises to `[]`) when the record has no
#' per-topic relevance columns.
#' @noRd
record_topic_scores <- function(record) {
  cols <- grep("^relevance_score_", names(record), value = TRUE)
  if (length(cols) == 0L) {
    return(list())
  }
  ts <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  model <- nullable(record[["relevance_model"]])
  lapply(cols, function(col) {
    val <- record[[col]]
    list(
      topic = sub("^relevance_score_", "", col),
      score = if (is.null(val) || is.na(val)) NULL else as.numeric(val),
      model = model,
      scored_at = ts
    )
  })
}

#' Read a sidecar JSON back into a 1-row tibble matching the planscanR schema.
#'
#' @param path Path to a `<document_id>.meta.json` file.
#' @return A 1-row tibble.
#' @noRd
read_record_sidecar <- function(path) {
  payload <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  files <- payload$files %||% list()
  urls <- vapply(files, function(f) f$url %||% NA_character_, character(1))
  sections <- vapply(files, function(f) f$section %||% NA_character_, character(1))
  paths <- vapply(files, function(f) f$local_path %||% NA_character_, character(1))

  download_status <- tibble::tibble(
    url = urls,
    local_path = paths,
    status = vapply(files, function(f) f$status %||% NA_character_, character(1)),
    size_bytes = vapply(
      files,
      function(f) {
        v <- f$size_bytes
        if (is.null(v)) NA_real_ else as.numeric(v)
      },
      numeric(1)
    ),
    sha256 = vapply(files, function(f) f$sha256 %||% NA_character_, character(1)),
    reason = vapply(files, function(f) f$reason %||% NA_character_, character(1))
  )

  out <- tibble::tibble(
    country = payload$country,
    source_portal = payload$source_portal,
    document_id = payload$document_id,
    url = payload$url,
    retrieved_at = as.POSIXct(payload$retrieved_at, tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ"),
    attachment_urls = list(urls),
    local_path = list(paths),
    title = payload$title %||% NA_character_,
    summary = payload$summary %||% NA_character_,
    competent_authority = payload$competent_authority %||% NA_character_,
    proponent = payload$proponent %||% NA_character_,
    date_decision = if (is.null(payload$date_decision)) as.Date(NA) else as.Date(payload$date_decision),
    relevance_model = payload$relevance_model %||% NA_character_,
    download_status = list(download_status)
  )

  # Fan out per-section URLs and local paths from the `files[]` array's
  # `section` tags. Any non-NA section name in the JSON gets two columns:
  # `attachment_urls_<section>` and `local_path_<section>`.
  section_names <- unique(sections[!is.na(sections) & nzchar(sections)])
  for (nm in section_names) {
    mask <- !is.na(sections) & sections == nm
    out[[paste0("attachment_urls_", nm)]] <- list(urls[mask])
    out[[paste0("local_path_", nm)]] <- list(paths[mask])
  }
  # Fan out per-topic scores into one column per topic so they line up with
  # what get_assessments() returns at runtime.
  for (entry in payload$relevance_scores %||% list()) {
    slug <- entry$topic
    if (is.null(slug) || !nzchar(slug)) {
      next
    }
    out[[paste0("relevance_score_", slug)]] <-
      if (is.null(entry$score)) NA_real_ else as.numeric(entry$score)
  }
  # Restore any country-specific extras the writer stashed under `extras`.
  # These are scalar columns the writer didn't recognise as required /
  # conventional (e.g. DE's `native_type`, `jurisdiction`); they round-trip
  # straight through without any per-country knowledge here.
  for (nm in names(payload$extras %||% list())) {
    v <- payload$extras[[nm]]
    out[[nm]] <- if (is.null(v)) NA else v
  }
  out
}

#' Walk a planscanR cache and reconstruct a tibble from every sidecar.
#'
#' Lets you re-index a previously-populated cache without going back to any
#' portal. Useful when:
#'   * you've downloaded a large slice and want a quick offline tibble of it,
#'   * you've manually flattened or relocated files,
#'   * you want to enumerate what's already on disk before deciding what else
#'     to fetch.
#'
#' @param cache_dir Optional cache root. Defaults to
#'   `tools::R_user_dir("planscanR", "cache")`.
#' @param country Optional ISO-2 country code to filter by. `NULL` returns all.
#' @return A tibble in the planscanR schema, possibly with zero rows.
#' @export
#' @examples
#' \dontrun{
#' # Re-index everything currently in the cache
#' index_cache()
#'
#' # Re-index just the Dutch records
#' index_cache(country = "nl")
#' }
index_cache <- function(cache_dir = NULL, country = NULL) {
  root <- if (is.null(cache_dir)) {
    cache_dir_default()
  } else {
    cache_dir
  }
  files_root <- file.path(root, "files")
  if (!dir.exists(files_root)) {
    return(empty_result_tibble())
  }
  pattern <- "\\.meta\\.json$"
  if (is.null(country)) {
    sidecars <- list.files(
      files_root,
      pattern = pattern,
      recursive = TRUE,
      full.names = TRUE
    )
  } else {
    country_root <- file.path(files_root, country)
    if (!dir.exists(country_root)) {
      return(empty_result_tibble())
    }
    sidecars <- list.files(
      country_root,
      pattern = pattern,
      recursive = TRUE,
      full.names = TRUE
    )
  }
  if (length(sidecars) == 0L) {
    return(empty_result_tibble())
  }
  rows <- lapply(sidecars, function(p) {
    tryCatch(read_record_sidecar(p), error = function(e) {
      warn_partial("Could not read sidecar {.file {p}}: {conditionMessage(e)}")
      NULL
    })
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!rows)
}

#' Default cache directory (with the same resolution as `cache_dir()` but
#' without auto-creation; for use in read-only paths).
#' @noRd
cache_dir_default <- function() {
  root <- getOption("planscanR.cache_dir")
  if (is.null(root) || !nzchar(root)) {
    root <- tools::R_user_dir("planscanR", "cache")
  }
  root
}

#' Build a portal-URL -> sidecar-path lookup for one country.
#'
#' Scans every `<doc_id>.meta.json` under `<cache>/files/<country>/` and reads
#' the `url` field. Used by per-country handlers to short-circuit detail-page
#' fetches when a record's metadata is already on disk.
#'
#' @param country ISO-2 country code.
#' @param cache_dir Optional cache root.
#' @return Named character vector (names = portal URLs, values = sidecar paths).
#'   Empty `character(0)` (with no names) when no sidecars exist.
#' @noRd
sidecar_url_index <- function(country, cache_dir = NULL) {
  root <- if (is.null(cache_dir)) cache_dir_default() else cache_dir
  country_root <- file.path(root, "files", tolower(country))
  if (!dir.exists(country_root)) {
    return(stats::setNames(character(0), character(0)))
  }
  paths <- list.files(
    country_root,
    pattern = "\\.meta\\.json$",
    recursive = TRUE,
    full.names = TRUE
  )
  if (length(paths) == 0L) {
    return(stats::setNames(character(0), character(0)))
  }
  urls <- vapply(
    paths,
    function(p) {
      tryCatch(
        {
          payload <- jsonlite::fromJSON(p, simplifyVector = FALSE)
          payload$url %||% NA_character_
        },
        error = function(e) NA_character_
      )
    },
    character(1),
    USE.NAMES = FALSE
  )
  keep <- !is.na(urls) & nzchar(urls)
  stats::setNames(paths[keep], urls[keep])
}

#' Pack a scalar into a JSON-null when missing.
#' @noRd
nullable <- function(x) {
  if (length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x) || (is.character(x) && !nzchar(x))) NULL else unname(x)
}
#' @noRd
nullable_numeric <- function(x) {
  if (length(x) != 1L || is.na(x)) NULL else unname(as.numeric(x))
}
#' @noRd
nullable_date <- function(x) {
  if (length(x) != 1L || is.na(x)) NULL else format(x, "%Y-%m-%d")
}
