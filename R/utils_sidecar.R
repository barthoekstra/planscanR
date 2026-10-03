# Sidecar JSON I/O.
#
# Each fully-processed record is persisted to
# `<cache>/files/<country>/<document_id>/<document_id>.meta.json`. The sidecar
# is the canonical offline record: it captures the full tibble row plus
# per-file download status, so the cache can be re-indexed without
# re-fetching anything from the portal.

SCHEMA_VERSION <- 3L

# Sidecar updates are read/merge/write transactions.  The lock is a separate
# special file so the JSON can still be replaced atomically; filelock releases
# an OS advisory lock when a worker exits, including an interrupted worker.
sidecar_lock_timeout <- function() {
  timeout <- getOption("planscanR.sidecar_lock_timeout_ms", 30000)
  if (length(timeout) != 1L || is.na(timeout) ||
      (!is.infinite(timeout) && (!is.numeric(timeout) || timeout < 0))) {
    cli::cli_abort(
      "Option {.code planscanR.sidecar_lock_timeout_ms} must be a non-negative number or {.val Inf}.",
      class = "planscanR_error_bad_input"
    )
  }
  as.numeric(timeout)
}

#' @noRd
sidecar_lock_path <- function(path) paste0(path, ".lock")

#' @noRd
with_sidecar_lock <- function(path, code, exclusive = TRUE, timeout = sidecar_lock_timeout()) {
  if (length(path) != 1L || is.na(path) || !nzchar(path)) {
    cli::cli_abort("A sidecar path is required for locking.", class = "planscanR_error_bad_input")
  }
  parent <- dirname(path)
  if (!dir.exists(parent)) {
    cli::cli_abort(
      "Sidecar directory {.file {parent}} does not exist.",
      class = "planscanR_error_sidecar_lock"
    )
  }
  lock <- filelock::lock(sidecar_lock_path(path), exclusive = exclusive, timeout = timeout)
  if (is.null(lock)) {
    cli::cli_abort(
      "Timed out waiting for sidecar lock {.file {sidecar_lock_path(path)}}.",
      class = "planscanR_error_sidecar_lock_timeout"
    )
  }
  on.exit(filelock::unlock(lock), add = TRUE)
  force(code)
}

#' @noRd
read_sidecar_payload <- function(path) {
  payload <- tryCatch(
    jsonlite::fromJSON(path, simplifyVector = FALSE),
    error = function(e) {
      cli::cli_abort(
        c(
          "Sidecar {.file {path}} is not valid JSON; refusing to overwrite it.",
          i = "Repair or remove the corrupt sidecar explicitly before retrying."
        ),
        class = "planscanR_error_sidecar_corrupt"
      )
    }
  )
  assert_sidecar_schema(payload, path)
  payload
}

#' @noRd
write_sidecar_payload <- function(payload, path) {
  tmp <- tempfile(tmpdir = dirname(path), fileext = ".json")
  con <- file(tmp, open = "wb", encoding = "UTF-8")
  on.exit({
    try(close(con), silent = TRUE)
    if (file.exists(tmp)) unlink(tmp, force = TRUE)
  }, add = TRUE)
  writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, pretty = TRUE, null = "null"), con)
  close(con)
  if (!isTRUE(file.rename(tmp, path))) {
    cli::cli_abort(
      "Atomic sidecar publication failed for {.file {path}}.",
      class = "planscanR_error_sidecar_publish"
    )
  }
  invisible(path)
}

#' Assert a sidecar's schema version is one this package understands.
#'
#' The sidecar JSON is the shared contract between `planscanR` (writer)
#' and the downstream `planscanR.screen` reader. A
#' sidecar written by a *newer* planscanR (a higher `schema_version`) may carry
#' fields or semantics this version doesn't know about, so we fail loudly rather
#' than silently misread it. Missing field = legacy v1, which reads cleanly.
#' @noRd
assert_sidecar_schema <- function(payload, path = NULL) {
  ver <- payload$schema_version
  if (is.null(ver)) {
    return(invisible(1L)) # legacy v1 sidecar: no version field.
  }
  ver <- suppressWarnings(as.integer(ver))
  # cli interpolates {ver}, {SCHEMA_VERSION}, and {.file {path}} from this
  # frame; build the optional location suffix as cli markup, not via sprintf.
  where <- if (is.null(path)) "" else " ({.file {path}})"
  if (is.na(ver)) {
    cli::cli_abort(
      paste0("Sidecar has a non-integer {.field schema_version}", where, "."),
      class = "planscanR_error_sidecar_schema"
    )
  }
  if (ver > SCHEMA_VERSION) {
    cli::cli_abort(
      c(
        paste0(
          "Sidecar {.field schema_version} {ver} is newer than this ",
          "planscanR understands ({SCHEMA_VERSION})",
          where,
          "."
        ),
        i = "Upgrade {.pkg planscanR} to read this cache."
      ),
      class = "planscanR_error_sidecar_schema"
    )
  }
  invisible(ver)
}

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
#' This is part of the sidecar I/O contract between `planscanR` (the cache
#' owner) and the downstream `planscanR.screen` package, which persists its
#' derived columns (relevance / class scores) by calling
#' `planscanR::write_record_sidecar()`. The merge logic that preserves existing
#' `files[]` / `relevance_scores[]` / `class_*` arrays lives here, so adding a
#' new score family never wipes existing ones.
#'
#' @param record A 1-row tibble in the planscanR result shape.
#' @param downloads The structured download-status tibble produced by
#'   `download_attachments()`. May be empty when `download = FALSE`.
#' @param root Cache root (or `NULL` to use the default).
#' @return Path to the written sidecar, invisibly.
#' @examples
#' \dontrun{
#' # Persist a single fetched record to the offline metadata cache.
#' write_record_sidecar(record)
#' }
#' @export
write_record_sidecar <- function(record, downloads = NULL, root = NULL) {
  stopifnot(is.data.frame(record), nrow(record) == 1L)
  path <- sidecar_path(record$country, record$document_id, root = root)
  root_resolved <- if (is.null(root)) cache_dir_default() else root
  payload <- record_to_sidecar(record, downloads, root = root_resolved)
  # Non-destructive write: a sidecar is the authoritative record, and any one
  # caller (scan / score / classify / download / discover) only knows about a
  # slice of it. Read/merge/write is one locked transaction so independent
  # workers cannot replace one another's outcomes. See merge_sidecar_payload().
  with_sidecar_lock(path, {
    if (file.exists(path)) {
      payload <- merge_sidecar_payload(payload, read_sidecar_payload(path))
    }
    write_sidecar_payload(payload, path)
  })
  invisible(path)
}

#' @noRd
fetched_record_projection <- function(record) {
  derived <- c(
    grep("^(class_|kw_|translation_)", names(record), value = TRUE),
    c(
      "cosine_max",
      "n_attachments",
      "has_attachments",
      "n_downloaded",
      "has_downloaded",
      "selected",
      "selected_model",
      "select_prob",
      "discovery_log"
    )
  )
  record[, setdiff(names(record), derived), drop = FALSE]
}

#' Persist a portal fetch without replaying downstream curation columns.
#'
#' Sidecar-first country handlers can receive a row carrying classification,
#' translation, or selection values that another worker refreshed after the row
#' was read. Download finalisation owns the portal fields, attachment outcomes,
#' and any newly computed fetch-time relevance fields; the derived curation
#' columns remain owned by their writers. Existing sidecars are updated from
#' their latest locked row so those derived values cannot be replayed from a
#' stale fetch snapshot.
#' @noRd
write_fetched_record_sidecar <- function(record, downloads = NULL, root = NULL) {
  stopifnot(is.data.frame(record), nrow(record) == 1L)
  projected <- fetched_record_projection(record)
  record_downloads <- projected[["download_status"]]
  if (is.null(downloads) && is.list(record_downloads) && length(record_downloads) >= 1L) {
    downloads <- record_downloads[[1L]]
  }
  country <- as.character(projected$country[[1L]])
  document_id <- as.character(projected$document_id[[1L]])
  path <- sidecar_path(country, document_id, root = root, create = FALSE)
  if (file.exists(path)) {
    update_record_sidecar(country, document_id, function(current) {
      for (field in names(projected)) {
        current[[field]] <- projected[[field]]
      }
      if (is.data.frame(downloads)) {
        current$download_status <- list(downloads)
      }
      current
    }, root = root)
  } else {
    write_record_sidecar(projected, downloads = downloads, root = root)
  }
  invisible(path)
}

#' @noRd
sidecar_discovery_entries <- function(record) {
  value <- record[["discovery_log"]]
  if (!is.list(value) || length(value) == 0L || is.null(value[[1L]])) {
    return(list())
  }
  value[[1L]]
}

#' @noRd
sidecar_log_contains <- function(container, fragment) {
  if (length(fragment) == 0L) {
    return(TRUE)
  }
  if (length(container) < length(fragment)) {
    return(FALSE)
  }
  starts <- seq_len(length(container) - length(fragment) + 1L)
  any(vapply(
    starts,
    function(start) identical(container[start:(start + length(fragment) - 1L)], fragment),
    logical(1)
  ))
}

#' Atomically update one record sidecar from its latest on-disk value.
#'
#' This is the compound-operation counterpart to [write_record_sidecar()]. A
#' caller such as a translation worker can read, add one extra field, and write
#' while holding the same per-record lock as download/classification workers.
#' The callback must return the one-row record to persist; the existing merge
#' rules still protect fields it does not touch.
#'
#' @param country ISO-2 country code.
#' @param document_id Portal-native document ID.
#' @param update_fn A function accepting the current one-row sidecar tibble and
#'   returning its updated one-row tibble.
#' @param root Cache root (or `NULL` to use the default).
#' @return Path to the written sidecar, invisibly.
#' @export
update_record_sidecar <- function(country, document_id, update_fn, root = NULL) {
  if (!is.character(country) || length(country) != 1L || is.na(country) || !nzchar(country) ||
      !is.character(document_id) || length(document_id) != 1L || is.na(document_id) || !nzchar(document_id)) {
    cli::cli_abort(
      "{.arg country} and {.arg document_id} must be single non-empty strings.",
      class = "planscanR_error_bad_input"
    )
  }
  if (!is.function(update_fn)) {
    cli::cli_abort("{.arg update_fn} must be a function.", class = "planscanR_error_bad_input")
  }
  path <- sidecar_path(country, document_id, root = root, create = FALSE)
  if (!file.exists(path)) {
    cli::cli_abort(
      "No sidecar exists for {.val {country}/{document_id}}.",
      class = "planscanR_error_sidecar_missing"
    )
  }
  root_resolved <- if (is.null(root)) cache_dir_default() else root
  with_sidecar_lock(path, {
    existing <- read_sidecar_payload(path)
    current <- read_record_sidecar_unlocked(path)
    prior_discovery_log <- sidecar_discovery_entries(current)
    updated <- update_fn(current)
    if (!is.data.frame(updated) || nrow(updated) != 1L) {
      cli::cli_abort(
        "{.arg update_fn} must return exactly one data-frame row.",
        class = "planscanR_error_bad_input"
      )
    }
    validate_result_schema(updated)
    downloads <- updated[["download_status"]]
    downloads <- if (is.list(downloads) && length(downloads) >= 1L) downloads[[1]] else NULL
    payload <- record_to_sidecar(updated, downloads = downloads, root = root_resolved)
    returned_discovery_log <- sidecar_discovery_entries(updated)
    # Callbacks may either return the complete history (the normal pattern for
    # an update callback) or supply only new discovery events. Merge old
    # history only for the latter; otherwise unchanged callbacks would append
    # the same log on every serialized update.
    complete_history <- identical(returned_discovery_log, prior_discovery_log) ||
      sidecar_log_contains(returned_discovery_log, prior_discovery_log)
    merge_existing <- existing
    if (complete_history) {
      merge_existing$discovery_log <- list()
    }
    write_sidecar_payload(merge_sidecar_payload(payload, merge_existing), path)
  })
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
#' * `files[]` — union by URL: a new entry supersedes the same-URL old entry
#'   unless it is a weaker stale download outcome, and every old URL absent
#'   from the new set is KEPT (this is what stops a classify/score write from
#'   wiping portal attachment URLs);
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
    old_by_url <- old$files
    for (old_file in old_by_url) {
      old_url <- old_file$url %||% ""
      match <- which(new_urls == old_url)
      if (length(match) == 0L) {
        new$files <- c(new$files %||% list(), list(old_file))
        next
      }
      # Classification/translation workers often pass the download_status
      # row they read before a downloader finished. Never let that stale
      # pending/failed projection regress a stronger verified outcome already
      # on disk; a new outcome at the same strength still wins as before.
      new_file <- new$files[[match[[1]]]]
      if (download_file_status_rank(old_file$status) > download_file_status_rank(new_file$status)) {
        new$files[[match[[1]]]] <- old_file
      }
    }
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
      # v3: never carry forward a v2 sidecar's stale `relevance_score_*` extras
      # duplicate — the canonical `relevance_scores[]` array (merged above) owns
      # those, and a re-scoring write would otherwise resurrect the old value.
      if (grepl("^relevance_score_", k)) {
        next
      }
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

#' @noRd
download_file_status_rank <- function(status) {
  switch(
    as.character(status %||% ""),
    downloaded = 3L,
    cached = 3L,
    exists = 3L,
    failed = 2L,
    skipped_size = 2L,
    pending = 1L,
    0L
  )
}

#' Serialise a record + downloads into the sidecar JSON shape.
#' @noRd
record_to_sidecar <- function(record, downloads = NULL, root = NULL) {
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
    # v3: per-topic relevance columns are serialised once into the canonical
    # relevance_scores[] array (record_topic_scores), so keep them out of extras.
    grep("^relevance_score_", names(record), value = TRUE),
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
    # v3: store on-disk geometry path relative to the cache root (portable cache).
    if (!is.null(base$extras$geometry_path)) {
      base$extras$geometry_path <- relativise_cache_path(base$extras$geometry_path, root)
    }
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
        # v3: store relative to the cache root; absolutised again on read.
        local_path = relativise_cache_path(nullable(r$local_path), root),
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
#' Part of the sidecar I/O contract: downstream family packages read a single
#' record's persisted columns via `planscanR::read_record_sidecar()` rather than
#' parsing the JSON themselves. Asserts the schema version on read (see
#' [cache_dir_default()] for the cache-root contract).
#'
#' @param path Path to a `<document_id>.meta.json` file.
#' @return A 1-row tibble in the planscanR schema.
#' @examples
#' \dontrun{
#' # Read one record's cached metadata back into a 1-row tibble.
#' read_record_sidecar("path/to/<document_id>.meta.json")
#' }
#' @export
read_record_sidecar <- function(path) {
  # Atomic same-filesystem rename means a standalone reader observes either
  # the old complete JSON or the new complete JSON. Do not create a lock file
  # here: readers must work against read-only or mounted cache trees.
  read_record_sidecar_unlocked(path)
}

#' @noRd
read_record_sidecar_unlocked <- function(path) {
  payload <- read_sidecar_payload(path)
  files <- payload$files %||% list()
  urls <- vapply(files, function(f) f$url %||% NA_character_, character(1))
  sections <- vapply(files, function(f) f$section %||% NA_character_, character(1))
  # v3: paths are stored relative to the cache root. Recover the root from the
  # sidecar's own location (<root>/files/<country>/<document_id>/<id>.meta.json)
  # and absolutise each stored path back to a working path. Already-absolute
  # legacy (v1/v2) paths pass through unchanged.
  cache_root <- dirname(dirname(dirname(dirname(path))))
  paths <- vapply(
    files,
    function(f) absolutise_cache_path(f$local_path %||% NA_character_, cache_root),
    character(1)
  )

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
    retrieved_at = parse_iso_utc(payload$retrieved_at),
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
    # v3: the canonical relevance_scores[] loop above already populated the
    # per-topic columns; a (legacy v2) `relevance_score_*` extras key must not
    # overwrite them with a possibly-stale value.
    if (grepl("^relevance_score_", nm)) {
      next
    }
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
  # `date_published` is the one conventional date column that is NOT a
  # first-class sidecar field (unlike `date_decision`), so it round-trips
  # through `extras` above as an ISO "YYYY-MM-DD" string (or a logical NA when
  # absent). Handlers emit it as a `Date`, so without this coercion a record
  # read back from a sidecar carries a `character`/`logical` `date_published`
  # while a freshly-parsed record carries a `Date` — and `bind_rows()` over a
  # mix of cached and fresh records then aborts with a class-mismatch. Coerce
  # it back to `Date` here so the column is type-stable regardless of cache
  # state. No JSON-schema change: the on-disk value is unchanged.
  if ("date_published" %in% names(out)) {
    dp <- out[["date_published"]]
    out[["date_published"]] <- if (length(dp) != 1L || is.na(dp[[1]])) {
      as.Date(NA)
    } else {
      as.Date(as.character(dp[[1]]))
    }
  }
  # v3: geometry_path round-trips through extras as a cache-relative path;
  # absolutise it back to a working path (mirrors files[].local_path above).
  if ("geometry_path" %in% names(out)) {
    gp <- out[["geometry_path"]]
    out[["geometry_path"]] <- if (length(gp) != 1L || is.na(gp)) {
      gp
    } else {
      absolutise_cache_path(gp, cache_root)
    }
  }
  # v2: expose the discovery audit trail as a list-column. Empty list when
  # the sidecar predates v2 or has had no discovery activity.
  out$discovery_log <- list(payload$discovery_log %||% list())

  # Fan the zero-shot classification verdict back into class_* columns, so a
  # round-tripped record matches what planscanR.screen's classifier writes
  # into the sidecar. Absent on sidecars that were never classified.
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
#' @param row_transform Optional function applied to each successfully decoded
#'   one-row record before rows are combined. It must accept one data-frame
#'   argument, retain the required planscanR schema columns and their types
#'   (`country`, `source_portal`, `document_id`, and `url` as character;
#'   `retrieved_at` as `POSIXct`; and `attachment_urls` and `local_path` as
#'   list columns), and return exactly one data-frame row. Read errors are
#'   still warned and skipped; transform errors and invalid returns abort the
#'   index operation so a partial projection cannot be mistaken for a complete
#'   cache.
#' @param batch_size Positive integer number of decoded rows combined at a time.
#'   Defaults to 512. It bounds the intermediate row list while preserving the
#'   existing result schema when `row_transform = NULL`.
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
index_cache <- function(
  cache_dir = NULL,
  country = NULL,
  row_transform = NULL,
  batch_size = 512L
) {
  if (!is.null(row_transform) && !is.function(row_transform)) {
    cli::cli_abort(
      "{.arg row_transform} must be NULL or a function.",
      class = "planscanR_error_bad_input"
    )
  }
  if (!is.numeric(batch_size) || length(batch_size) != 1L ||
      is.na(batch_size) || !is.finite(batch_size) ||
      batch_size < 1 || batch_size != trunc(batch_size) ||
      batch_size > .Machine$integer.max) {
    cli::cli_abort(
      "{.arg batch_size} must be one positive integer.",
      class = "planscanR_error_bad_input"
    )
  }
  batch_size <- as.integer(batch_size)
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
  read_one <- function(p) {
    record <- tryCatch(read_record_sidecar(p), error = function(e) {
      warn_partial("Could not read sidecar {.file {p}}: {conditionMessage(e)}")
      NULL
    })
    if (is.null(record) || is.null(row_transform)) {
      return(record)
    }
    transformed <- row_transform(record)
    if (!is.data.frame(transformed) || nrow(transformed) != 1L) {
      cli::cli_abort(
        "{.arg row_transform} must return exactly one data-frame row for {.file {p}}.",
        class = "planscanR_error_bad_input"
      )
    }
    validate_result_schema(transformed)
    transformed
  }
  starts <- seq.int(1L, length(sidecars), by = batch_size)
  batches <- lapply(starts, function(start) {
    stop <- min(length(sidecars), as.double(start) + as.double(batch_size) - 1)
    rows <- lapply(sidecars[start:as.integer(stop)], read_one)
    rows <- Filter(Negate(is.null), rows)
    if (length(rows) == 0L) {
      return(NULL)
    }
    bind_results(!!!rows)
  })
  batches <- Filter(Negate(is.null), batches)
  if (length(batches) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!batches)
}

#' Upgrade every sidecar in a cache to the current schema (v3) in place.
#'
#' Walks `<cache>/files/.../<id>.meta.json`, reads each record, and rewrites it
#' through [write_record_sidecar()] so on-disk paths become cache-relative,
#' `schema_version` is bumped to 3, and the v2 `relevance_score_*` `extras`
#' duplication is dropped. The merging writer already upgrades a sidecar lazily
#' on the next write, so this is only needed to upgrade a whole cache eagerly in
#' one pass. Idempotent — re-running on a v3 cache just rewrites it unchanged.
#'
#' @param cache_dir Optional cache root. Defaults to [cache_dir_default()].
#' @return The number of sidecars rewritten, invisibly.
#' @export
#' @examples
#' \dontrun{
#' migrate_sidecars_v3()
#' }
migrate_sidecars_v3 <- function(cache_dir = NULL) {
  root <- if (is.null(cache_dir)) cache_dir_default() else cache_dir
  files_root <- file.path(root, "files")
  if (!dir.exists(files_root)) {
    return(invisible(0L))
  }
  sidecars <- list.files(
    files_root,
    pattern = "\\.meta\\.json$",
    recursive = TRUE,
    full.names = TRUE
  )
  n <- 0L
  for (p in sidecars) {
    rec <- tryCatch(read_record_sidecar(p), error = function(e) {
      warn_partial("Could not read sidecar {.file {p}}: {conditionMessage(e)}")
      NULL
    })
    if (is.null(rec)) {
      next
    }
    dl <- rec[["download_status"]]
    downloads <- if (is.list(dl) && length(dl) >= 1L) dl[[1]] else NULL
    write_record_sidecar(rec, downloads = downloads, root = root)
    n <- n + 1L
  }
  invisible(n)
}

#' Resolve the planscanR cache root.
#'
#' The cache root is owned by `planscanR`: it is `getOption("planscanR.cache_dir")`
#' when set, otherwise [tools::R_user_dir()]`("planscanR", "cache")`. This is the
#' same resolution as the internal `cache_dir()` but without auto-creating the
#' directory, so it is safe in read-only paths. Exported so the downstream
#' `planscanR.screen` package reads and writes through the one cache root
#' without reimplementing the resolution chain.
#'
#' @return A single path string (the cache root; not guaranteed to exist).
#' @export
#' @examples
#' cache_dir_default()
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
        read_sidecar_payload(p)$url %||% NA_character_,
        error = function(e) NA_character_
      )
    },
    character(1),
    USE.NAMES = FALSE
  )
  keep <- !is.na(urls) & nzchar(urls)
  stats::setNames(paths[keep], urls[keep])
}

#' Is a path absolute (cross-platform: POSIX `/`, Windows `C:\`/`C:/`, UNC `\\`)?
#' @noRd
is_absolute_path <- function(p) {
  grepl("^(/|[A-Za-z]:[/\\\\]|\\\\\\\\)", p)
}

#' Store a cache path relative to the cache root (v3).
#'
#' Paths under `root` are stored relative so a relocated cache still resolves.
#' Paths outside the root (legacy absolute paths) and `NULL`/`NA`/empty pass
#' through unchanged.
#' @noRd
relativise_cache_path <- function(p, root) {
  if (is.null(root) || is.null(p) || length(p) != 1L || is.na(p) || !nzchar(p)) {
    return(p)
  }
  rootn <- normalizePath(root, winslash = "/", mustWork = FALSE)
  pn <- normalizePath(p, winslash = "/", mustWork = FALSE)
  prefix <- paste0(rootn, "/")
  if (startsWith(pn, prefix)) substring(pn, nchar(prefix) + 1L) else p
}

#' Resolve a stored (relative) cache path back to an absolute working path (v3).
#'
#' Relative paths are joined onto `root`; already-absolute (legacy) paths and
#' `NULL`/`NA`/empty pass through unchanged.
#' @noRd
absolutise_cache_path <- function(p, root) {
  if (is.null(p) || length(p) != 1L || is.na(p) || !nzchar(p)) {
    return(p)
  }
  if (is_absolute_path(p)) p else file.path(root, p)
}

#' Parse an ISO-8601 UTC timestamp, tolerating a missing trailing `Z` (v3).
#'
#' v3 writes always carry `Z`; legacy sidecars may not. Falls back to the
#' no-`Z` format so older caches still read.
#' @noRd
parse_iso_utc <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(as.POSIXct(NA_character_, tz = "UTC"))
  }
  t <- as.POSIXct(x, tz = "UTC", format = "%Y-%m-%dT%H:%M:%SZ")
  if (is.na(t)) {
    t <- as.POSIXct(x, tz = "UTC", format = "%Y-%m-%dT%H:%M:%S")
  }
  t
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
