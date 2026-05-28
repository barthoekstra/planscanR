# Sidecar JSON I/O.
#
# Each fully-processed record is persisted to
# `<cache>/files/<country>/<document_id>/<document_id>.meta.json`. The sidecar
# is the canonical offline record: it captures the full tibble row plus
# per-file download status, so the cache can be re-indexed without
# re-fetching anything from the portal.

SCHEMA_VERSION <- 2L

#' Path to a record's sidecar JSON file.
#'
#' `create = TRUE` (the default) creates the per-record directory as a side
#' effect — appropriate for the write path. Read-only callers (e.g. dedup
#' lookups during discovery) should pass `create = FALSE` so probing for a
#' sidecar's existence doesn't leave empty directories behind.
#' @noRd
sidecar_path <- function(country, document_id, root = NULL, create = TRUE) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = create, root = root),
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
  # Non-destructive write: a sidecar is the authoritative record, and any one
  # caller (scan / score / classify / download / discover) only knows about a
  # slice of it. So we never blindly overwrite — we MERGE the new payload over
  # whatever is already on disk, keeping every piece of original data the
  # current write doesn't itself supply. See merge_sidecar_payload().
  if (file.exists(path)) {
    existing <- tryCatch(
      jsonlite::fromJSON(path, simplifyVector = FALSE),
      error = function(e) NULL
    )
    if (!is.null(existing)) {
      payload <- merge_sidecar_payload(payload, existing)
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

#' Merge a freshly-built sidecar payload over the one already on disk.
#'
#' The guarantee: a write NEVER loses data the current caller didn't supply.
#' Each field is reconciled so the new value wins when present, and the
#' existing value is kept otherwise:
#'
#' * scalar metadata (title, summary, dates, authority, ...) — keep `old` when
#'   `new` is NULL (the caller didn't carry that column);
#' * `files[]` — union by URL: a new entry supersedes the same-URL old entry,
#'   and every old URL absent from the new set is KEPT (this is what stops a
#'   classify/score write, which carries no file rows, from wiping the portal
#'   attachment URLs);
#' * `relevance_scores[]` — union by topic slug (new wins);
#' * `extras{}` — union by key (new wins);
#' * `discovery_log[]` — appended (audit trail, never dropped);
#' * `classification` — keep `old` when `new` has none.
#'
#' Intentional resets go through [clear_cache()] + `refresh = TRUE`, not
#' through a lossy write.
#' @noRd
merge_sidecar_payload <- function(new, old) {
  # 1. Scalar metadata: keep old when the new write omits it.
  scalar_fields <- c(
    "source_portal",
    "url",
    "retrieved_at",
    "title",
    "summary",
    "competent_authority",
    "proponent",
    "date_decision",
    "relevance_model"
  )
  for (f in scalar_fields) {
    if (is.null(new[[f]]) && !is.null(old[[f]])) {
      new[[f]] <- old[[f]]
    }
  }
  # 2. files[]: union by URL (new supersedes same-URL old; all other old kept).
  if (length(old$files) > 0L) {
    new_urls <- vapply(
      new$files %||% list(),
      function(f) f$url %||% NA_character_,
      character(1)
    )
    kept <- Filter(function(f) !((f$url %||% "") %in% new_urls), old$files)
    new$files <- c(new$files %||% list(), kept)
  }
  # 3. relevance_scores[]: union by topic slug (new wins).
  if (length(old$relevance_scores) > 0L) {
    new_topics <- vapply(
      new$relevance_scores %||% list(),
      function(e) e$topic %||% "",
      character(1)
    )
    kept <- Filter(
      function(e) !((e$topic %||% "") %in% new_topics),
      old$relevance_scores
    )
    new$relevance_scores <- c(new$relevance_scores %||% list(), kept)
  }
  # 4. extras{}: union by key (new wins).
  if (length(old$extras) > 0L) {
    for (k in names(old$extras)) {
      if (is.null(new$extras[[k]])) {
        new$extras[[k]] <- old$extras[[k]]
      }
    }
  }
  # 5. discovery_log[]: append the prior audit trail.
  if (length(old$discovery_log) > 0L) {
    new$discovery_log <- c(new$discovery_log %||% list(), old$discovery_log)
  }
  # 6. classification: keep old verdict when this write carries none.
  if (is.null(new$classification) && !is.null(old$classification)) {
    new$classification <- old$classification
  }
  new
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
    # Conventional (optional) columns via `[[` so a record missing one doesn't
    # trip tibble's "unknown column" warning; nullable*() turn NULL into a
    # JSON null.
    title = nullable(record[["title"]]),
    summary = nullable(record[["summary"]]),
    competent_authority = nullable(record[["competent_authority"]]),
    proponent = nullable(record[["proponent"]]),
    date_decision = nullable_date(record[["date_decision"]]),
    # `[[` returns NULL silently when the column is absent (e.g. records
    # never went through the relevance gate). `$` would emit a tibble warning.
    relevance_model = nullable(record[["relevance_model"]]),
    # One entry per relevance_score_<slug> column found on the record. Each
    # entry stores topic-slug, score, model name, and time.
    relevance_scores = record_topic_scores(record),
    # Zero-shot classification verdict (NULL when the record hasn't been
    # classified). See record_classification().
    classification = record_classification(record)
  )
  # Carry through any extra columns we don't explicitly know about (other than
  # the required list-columns, which we treat below). Per-section attachment
  # and local_path columns follow the `attachment_urls_<section>` /
  # `local_path_<section>` convention and are excluded here regardless of
  # which sections a country uses (NL: source/advice; DE: uvp_bericht/
  # berichte/auslegung/weitere; future portals: whatever they expose).
  section_cols <- grep("^(attachment_urls|local_path)_", names(record), value = TRUE)
  # Classification columns are serialised into the `classification` block, not
  # `extras`.
  class_cols <- c(
    "class_label",
    "class_score",
    "class_relevant",
    "class_model",
    grep("^class_score_", names(record), value = TRUE)
  )
  reserved <- c(
    names(base),
    "retrieved_at",
    "attachment_urls",
    "local_path",
    section_cols,
    class_cols,
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
      entry <- list(
        url = r$url,
        section = section_of(r$url),
        # `source` is v2: provenance of the attachment URL.
        # "portal"    — found on the portal's own detail page (the v1 default)
        # "discovery" — surfaced by a web-search backend (e.g. Tavily)
        # Falls back to a column on the downloads tibble if present, otherwise
        # to "portal" so v1 callers don't need to set anything.
        source = if ("source" %in% names(downloads)) {
          nullable(r$source) %||% "portal"
        } else {
          "portal"
        },
        filename = if (is.na(r$local_path)) NULL else basename(r$local_path),
        local_path = nullable(r$local_path),
        status = r$status,
        size_bytes = nullable_numeric(r$size_bytes),
        sha256 = nullable(r$sha256),
        reason = nullable(r$reason)
      )
      # v2.1: per-file validation classification. Optional — `portal`-source
      # entries don't have a validator verdict, so the fields are simply
      # absent from the JSON for those. For `discovery`-source entries the
      # writer below records valid / rejected / skipped + the signal stack
      # that fired (or didn't) and a short notes string.
      if ("validation_status" %in% names(downloads)) {
        entry$validation_status <- nullable(r$validation_status)
      }
      if ("validation_notes" %in% names(downloads)) {
        entry$validation_notes <- nullable(r$validation_notes)
      }
      # Signals is a small character vector (potentially length 0).
      # Wrap into a list-column upstream; here we serialise the vector.
      if ("validation_signals" %in% names(downloads)) {
        sigs <- r$validation_signals
        if (is.list(sigs)) {
          sigs <- sigs[[1]]
        }
        entry$validation_signals <- if (length(sigs) == 0L) {
          list()
        } else {
          as.list(unname(sigs))
        }
      }
      entry
    })
  }
  base$files <- files
  # If the caller supplies a `discovery_log` list-column on the record,
  # include its entries. Portal handlers don't, so this is normally empty;
  # discover_attachments() sets it. write_record_sidecar() unions whatever
  # arrives here with whatever is already on disk.
  dlog <- record[["discovery_log"]]
  base$discovery_log <- if (is.list(dlog) && length(dlog) >= 1L) {
    val <- dlog[[1]]
    if (is.null(val)) list() else val
  } else {
    list()
  }
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

#' Build the `classification` JSON object from a record's `class_*` columns.
#'
#' Returns `NULL` when the record has no classification (so the sidecar field
#' serialises to null). Otherwise an object with the top label/score, the
#' relevant flag, the model, a timestamp, and the full per-label scores.
#' @noRd
record_classification <- function(record) {
  label <- record[["class_label"]]
  if (is.null(label) || length(label) != 1L || is.na(label) || !nzchar(label)) {
    return(NULL)
  }
  score_cols <- grep("^class_score_", names(record), value = TRUE)
  scores <- lapply(score_cols, function(col) {
    v <- record[[col]]
    list(
      label = sub("^class_score_", "", col),
      score = if (is.null(v) || is.na(v)) NULL else as.numeric(v)
    )
  })
  rel <- record[["class_relevant"]]
  list(
    label = label,
    score = nullable_numeric(record[["class_score"]]),
    relevant = if (is.null(rel) || is.na(rel)) NULL else isTRUE(rel),
    model = nullable(record[["class_model"]]),
    classified_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC"),
    scores = scores
  )
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
    reason = vapply(files, function(f) f$reason %||% NA_character_, character(1)),
    # v2: provenance. Defaults to "portal" so v1 sidecars (no source field
    # in the JSON) read back with the legacy meaning intact.
    source = vapply(files, function(f) f$source %||% "portal", character(1)),
    # v2.1: per-file validation classification (only present for
    # discovery-source entries; NA on portal-source rows so the column is
    # always defined).
    validation_status = vapply(
      files,
      function(f) f$validation_status %||% NA_character_,
      character(1)
    ),
    validation_signals = I(lapply(
      files,
      function(f) {
        sigs <- f$validation_signals
        if (is.null(sigs)) character(0) else unlist(sigs, use.names = FALSE)
      }
    )),
    validation_notes = vapply(
      files,
      function(f) f$validation_notes %||% NA_character_,
      character(1)
    )
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
    if (is.null(v)) {
      out[[nm]] <- NA
    } else if (length(v) > 1L || is.list(v)) {
      # Multi-element extras (arrays in JSON) become list-columns so the
      # single-row tibble can hold them without a recycle error.
      out[[nm]] <- list(unlist(v, use.names = FALSE))
    } else {
      out[[nm]] <- v
    }
  }
  # v2: expose the discovery audit trail as a list-column. Empty list when
  # the sidecar predates v2 or has had no discovery activity.
  out$discovery_log <- list(payload$discovery_log %||% list())

  # Fan the zero-shot classification verdict back into class_* columns, so a
  # round-tripped record matches what classify_assessments() returns at
  # runtime. Absent on sidecars that were never classified.
  cls <- payload$classification
  if (!is.null(cls) && !is.null(cls$label)) {
    out$class_label <- cls$label
    out$class_score <- if (is.null(cls$score)) NA_real_ else as.numeric(cls$score)
    out$class_relevant <- if (is.null(cls$relevant)) NA else isTRUE(cls$relevant)
    out$class_model <- cls$model %||% NA_character_
    for (entry in cls$scores %||% list()) {
      slug <- entry$label
      if (is.null(slug) || !nzchar(slug)) {
        next
      }
      out[[paste0("class_score_", slug)]] <-
        if (is.null(entry$score)) NA_real_ else as.numeric(entry$score)
    }
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
