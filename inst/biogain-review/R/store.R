# Review-decision store. Single local reviewer, so a plain CSV read-modify-write
# is enough — no DB, no concurrency handling. One row per reviewed record.
#
# The CSV is human-readable (open it in Excel) and keyed to the planscanR cache:
# `document_id` + `country` identify the record, and `sidecar_path` is the
# cache-relative path to that record's sidecar JSON
# (files/<country>/<document_id>/<document_id>.meta.json), so the decisions join
# straight back onto index_cache() output or the on-disk sidecars.
#
# `source` records HOW the decision was made — "browse" (sorted triage) or
# "random" (unbiased random sample) — so filter-performance metrics can be
# computed on the random sample alone for a fair estimate.

review_csv_path <- function(data_dir) file.path(data_dir, "reviews.csv")
review_rds_legacy <- function(data_dir) file.path(data_dir, "reviews.rds")

review_columns <- c(
  "document_id",
  "country",
  "decision",
  "source",
  "reviewer",
  "note",
  "reviewed_at",
  "sidecar_path"
)

empty_reviews <- function() {
  tibble::tibble(
    document_id = character(0),
    country = character(0),
    decision = character(0), # "keep" | "drop" | "unsure"
    source = character(0), # "browse" | "random"
    reviewer = character(0), # who made the decision
    note = character(0),
    reviewed_at = as.POSIXct(character(0), tz = "UTC"),
    sidecar_path = character(0)
  )
}

# Cache-relative sidecar path for a record (mirrors the planscanR cache layout).
sidecar_rel_path <- function(country, document_id) {
  file.path("files", country, document_id, paste0(document_id, ".meta.json"))
}

# Bring any tibble up to the current review schema (fills missing columns).
coerce_review_schema <- function(df) {
  if (!"source" %in% names(df)) {
    df$source <- "browse"
  }
  if (!"reviewer" %in% names(df)) {
    df$reviewer <- NA_character_
  }
  # All pre-existing manual classifications were done by Bart Hoekstra.
  df$reviewer[is.na(df$reviewer) | !nzchar(df$reviewer)] <- "Bart Hoekstra"
  if (!"note" %in% names(df)) {
    df$note <- NA_character_
  }
  if (!"sidecar_path" %in% names(df)) {
    df$sidecar_path <- sidecar_rel_path(df$country, df$document_id)
  }
  df$reviewed_at <- parse_reviewed_at(df$reviewed_at)
  df[, review_columns, drop = FALSE]
}

# Parse the stored ISO-8601 timestamp. The store writes "%Y-%m-%dT%H:%M:%S"
# (with the literal "T"); as.POSIXct's default formats DON'T match the "T", so a
# plain as.POSIXct() silently drops the time (midnight). Parse the "T" form
# explicitly, falling back to the default parser for any other shape, and leave
# POSIXct input untouched.
parse_reviewed_at <- function(x) {
  if (inherits(x, "POSIXct")) {
    return(x)
  }
  x <- as.character(x)
  ts <- as.POSIXct(x, format = "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  bad <- is.na(ts) & !is.na(x) & nzchar(x)
  if (any(bad)) {
    ts[bad] <- as.POSIXct(x[bad], tz = "UTC")
  }
  ts
}

load_reviews <- function(data_dir) {
  csv <- review_csv_path(data_dir)
  if (file.exists(csv)) {
    raw <- utils::read.csv(csv, stringsAsFactors = FALSE, colClasses = "character")
    if (nrow(raw) == 0L) {
      return(empty_reviews())
    }
    # Was the on-disk file already at the current schema (has a reviewer column)?
    had_reviewer <- "reviewer" %in% names(raw)
    result <- coerce_review_schema(tibble::as_tibble(raw))
    # Persist the reviewer backfill so the on-disk CSV gains the column too.
    if (!had_reviewer && nrow(result) > 0L) {
      save_reviews(result, data_dir)
    }
    return(result)
  }
  # One-time migration: an older RDS store -> the new CSV store.
  rds <- review_rds_legacy(data_dir)
  if (file.exists(rds)) {
    migrated <- tryCatch(coerce_review_schema(readRDS(rds)), error = function(e) NULL)
    if (!is.null(migrated)) {
      save_reviews(migrated, data_dir)
      return(migrated)
    }
  }
  empty_reviews()
}

# Atomic write (temp file + rename) so an interrupted save can't corrupt the store.
save_reviews <- function(reviews, data_dir) {
  csv <- review_csv_path(data_dir)
  out <- reviews
  out$reviewed_at <- format(out$reviewed_at, "%Y-%m-%dT%H:%M:%S", tz = "UTC")
  tmp <- paste0(csv, ".tmp")
  utils::write.csv(out[, review_columns, drop = FALSE], tmp, row.names = FALSE, na = "")
  file.rename(tmp, csv)
  invisible(reviews)
}

# Composite record key. document_id is only unique WITHIN a country (≈200 ids
# collide between nl and at), so every lookup keys on (country, document_id).
review_key <- function(country, document_id) {
  if (length(country) == 0L || length(document_id) == 0L) {
    return(character(0))
  }
  paste0(country, "::", document_id)
}

# Upsert decisions for a set of (document_id, country) records. decision = NA
# removes the rows (clear a decision). `source` is "browse" or "random".
upsert_reviews <- function(
  reviews,
  document_id,
  country,
  decision,
  source = "browse",
  reviewer = NA_character_,
  note = NA_character_
) {
  if (length(document_id) == 0L) {
    return(reviews)
  }
  drop_keys <- review_key(country, document_id)
  # De-dupe per (record, reviewer): only remove this reviewer's existing rows
  # for those records, so a second reviewer's decision coexists rather than
  # overwriting the first. `reviewer` is a scalar at every call site.
  reviews <- reviews[
    !(review_key(reviews$country, reviews$document_id) %in% drop_keys & reviews$reviewer %in% reviewer),
    ,
    drop = FALSE
  ]
  if (is.na(decision)) {
    return(reviews)
  }
  new <- tibble::tibble(
    document_id = as.character(document_id),
    country = as.character(country),
    decision = decision,
    source = source,
    reviewer = reviewer,
    note = note,
    reviewed_at = Sys.time(),
    sidecar_path = sidecar_rel_path(as.character(country), as.character(document_id))
  )
  dplyr::bind_rows(reviews, new)
}

# The scalar decision a single reviewer gave a single record, or NA_character_
# if that reviewer has no decision on it. country/document_id/reviewer scalar.
reviewer_decision <- function(reviews, country, document_id, reviewer) {
  if (nrow(reviews) == 0L) {
    return(NA_character_)
  }
  hit <- review_key(reviews$country, reviews$document_id) %in%
    review_key(country, document_id) &
    reviews$reviewer %in% reviewer
  if (!any(hit)) {
    return(NA_character_)
  }
  as.character(reviews$decision[hit][1L])
}

# Unique record keys this reviewer has decided. character(0) if none.
keys_reviewed_by <- function(reviews, reviewer) {
  if (nrow(reviews) == 0L) {
    return(character(0))
  }
  hit <- reviews$reviewer %in% reviewer
  unique(review_key(reviews$country[hit], reviews$document_id[hit]))
}

# Unique record keys decided by ANY reviewer. character(0) if none.
keys_reviewed_any <- function(reviews) {
  if (nrow(reviews) == 0L) {
    return(character(0))
  }
  unique(review_key(reviews$country, reviews$document_id))
}

# Known-reviewer name store: a plain newline-delimited list the app uses to
# populate a name dropdown.
reviewers_path <- function(data_dir) file.path(data_dir, "reviewers.txt")

# Sorted, de-duplicated known names: the default, names in reviewers.txt, and
# any reviewer values already recorded in reviews.csv. Never returns empty.
load_reviewers <- function(data_dir) {
  names <- "Bart Hoekstra"
  txt <- reviewers_path(data_dir)
  if (file.exists(txt)) {
    from_file <- trimws(readLines(txt, warn = FALSE))
    names <- c(names, from_file[nzchar(from_file)])
  }
  from_reviews <- tryCatch(load_reviews(data_dir)$reviewer, error = function(e) character(0))
  from_reviews <- from_reviews[!is.na(from_reviews) & nzchar(from_reviews)]
  sort(unique(c(names, from_reviews)))
}

# Append a new reviewer name to reviewers.txt (idempotent). Returns the updated
# vector of known names.
add_reviewer <- function(data_dir, name) {
  name <- trimws(name)
  if (nzchar(name) && !name %in% load_reviewers(data_dir)) {
    if (!dir.exists(data_dir)) {
      dir.create(data_dir, recursive = TRUE)
    }
    cat(name, "\n", sep = "", file = reviewers_path(data_dir), append = TRUE)
  }
  load_reviewers(data_dir)
}
