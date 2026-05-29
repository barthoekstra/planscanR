# Corpus snapshot: read the planscanR sidecar cache once (index_cache), enrich
# with the scalar helper columns the app needs, and cache the result to disk so
# subsequent launches are instant. A "Rebuild" button re-runs index_cache.

# Topic slugs whose relevance_score_<slug> columns drive the cosine arm.
biogain_slugs <- function() names(planscanR::biogain_assessment_topics())

# Per-record max cosine across the BIOGAIN topics (NA when none scored).
cosine_max_col <- function(df, slugs = biogain_slugs()) {
  cols <- paste0("relevance_score_", slugs)
  cols <- cols[cols %in% names(df)]
  if (length(cols) == 0L) {
    return(rep(NA_real_, nrow(df)))
  }
  mats <- lapply(cols, function(cn) {
    v <- as.numeric(df[[cn]])
    v[is.na(v)] <- -Inf
    v
  })
  m <- do.call(pmax, mats)
  m[!is.finite(m)] <- NA_real_
  m
}

# Count attachments / downloaded files from the list-columns, as plain integers
# (reactable does not handle list-columns, and the funnel needs scalar counts).
n_attachments_col <- function(df) {
  if (!"attachment_urls" %in% names(df)) {
    return(rep(0L, nrow(df)))
  }
  vapply(df$attachment_urls, function(v) length(v[!is.na(v) & nzchar(v)]), integer(1))
}

n_downloaded_col <- function(df) {
  if (!"download_status" %in% names(df)) {
    return(rep(0L, nrow(df)))
  }
  vapply(
    df$download_status,
    function(ds) {
      if (is.null(ds) || !is.data.frame(ds) || nrow(ds) == 0L) {
        return(0L)
      }
      sum(ds$status %in% c("downloaded", "cached"))
    },
    integer(1)
  )
}

# Enrich a raw index_cache() tibble with the scalar columns the app relies on.
# Drops the list-columns (kept only for counting) so the snapshot is light and
# reactable-friendly. Keeps all relevance_score_* / class_* columns for display.
enrich_records <- function(df) {
  if (nrow(df) == 0L) {
    return(df)
  }
  df$cosine_max <- cosine_max_col(df)
  df$n_attachments <- n_attachments_col(df)
  df$has_attachments <- df$n_attachments > 0L
  df$n_downloaded <- n_downloaded_col(df)
  df$has_downloaded <- df$n_downloaded > 0L

  # Keyword arm: compute kw_total if the package scorer is available and the
  # column is missing. Wrapped because score_keywords needs title/summary.
  if (!"kw_total" %in% names(df)) {
    df <- tryCatch(planscanR::score_keywords(df), error = function(e) {
      df$kw_total <- NA_integer_
      df
    })
  }

  # class_relevant may be absent on un-classified slices (e.g. AT scan-only).
  if (!"class_relevant" %in% names(df)) {
    df$class_relevant <- NA
  }
  if (!"class_label" %in% names(df)) {
    df$class_label <- NA_character_
  }
  if (!"class_score" %in% names(df)) {
    df$class_score <- NA_real_
  }

  # Drop list-columns: reactable can't render them and we've extracted the
  # counts we need. Keep everything else.
  list_cols <- names(df)[vapply(df, is.list, logical(1))]
  drop <- intersect(
    list_cols,
    c("attachment_urls", "local_path", "download_status", "discovery_log")
  )
  # also drop any per-section attachment/local_path list-columns
  drop <- union(drop, grep("^(attachment_urls_|local_path_)", names(df), value = TRUE))
  df <- df[, setdiff(names(df), drop), drop = FALSE]
  df
}

# Build the snapshot from scratch by walking the sidecar cache. Slow (reads tens
# of thousands of JSON files) — call behind a progress bar / Rebuild button.
build_snapshot <- function(cache_dir, countries) {
  parts <- lapply(countries, function(cc) {
    recs <- tryCatch(
      planscanR::index_cache(cache_dir = cache_dir, country = cc),
      error = function(e) NULL
    )
    if (is.null(recs) || nrow(recs) == 0L) {
      return(NULL)
    }
    enrich_records(recs)
  })
  parts <- Filter(Negate(is.null), parts)
  if (length(parts) == 0L) {
    return(empty_snapshot())
  }
  dplyr::bind_rows(parts)
}

empty_snapshot <- function() {
  tibble::tibble(
    country = character(0),
    document_id = character(0),
    title = character(0),
    summary = character(0),
    cosine_max = numeric(0),
    class_label = character(0),
    class_score = numeric(0),
    class_relevant = logical(0),
    kw_total = integer(0),
    n_attachments = integer(0),
    has_attachments = logical(0),
    n_downloaded = integer(0),
    has_downloaded = logical(0)
  )
}

snapshot_path <- function(data_dir) file.path(data_dir, "corpus_snapshot.rds")

# Load the cached snapshot if present; otherwise build it.
load_or_build_snapshot <- function(cache_dir, countries, data_dir, rebuild = FALSE) {
  p <- snapshot_path(data_dir)
  if (!rebuild && file.exists(p)) {
    return(readRDS(p))
  }
  snap <- build_snapshot(cache_dir, countries)
  saveRDS(snap, p)
  snap
}

# Draw an unbiased random sample for Random Review mode. STRATIFIED: `n` records
# per country (so the sample is balanced across countries rather than dominated
# by the largest register), drawn from every indexed record regardless of
# pre-selection, then shuffled so countries are interleaved. Returns a tibble of
# (document_id, country) — country is required because document_ids collide
# across countries. Browsing the sorted/selected list over-samples the "easy"
# on-topic records; this gives a fair estimate of filter performance.
draw_random_sample <- function(snap, countries, n, seed = NULL) {
  if (!is.null(seed) && !is.na(seed)) {
    set.seed(as.integer(seed))
  }
  parts <- lapply(countries, function(cc) {
    pool <- snap[snap$country == cc, , drop = FALSE]
    if (nrow(pool) == 0L) {
      return(NULL)
    }
    k <- min(as.integer(n), nrow(pool))
    idx <- sample.int(nrow(pool), k)
    tibble::tibble(document_id = pool$document_id[idx], country = pool$country[idx])
  })
  out <- dplyr::bind_rows(parts)
  if (nrow(out) == 0L) {
    return(tibble::tibble(document_id = character(0), country = character(0)))
  }
  out[sample.int(nrow(out)), , drop = FALSE] # interleave countries
}

# Build a PRIORITIZED review queue for one reviewer, to support inter-reviewer
# agreement. PRIORITY: records that SOMEONE else has already reviewed but this
# reviewer has NOT ("to_validate") come first — re-reviewing those is what yields
# cross-reviewer agreement, so we exhaust them before spending effort on records
# no one has seen. Only once this reviewer has caught up on every reviewed record
# do we fall back to a fresh stratified sample of as-yet-unreviewed records.
# Returns a tibble(document_id, country) with attr "mode" in
# c("validate","fresh","empty"). Respects `seed` for reproducibility.
build_review_queue <- function(snap, reviews, reviewer, countries, n_per_country, seed = NULL) {
  if (!is.null(seed) && !is.na(seed)) {
    set.seed(as.integer(seed))
  }
  empty <- tibble::tibble(document_id = character(0), country = character(0))

  snap <- snap[snap$country %in% countries, , drop = FALSE]
  if (nrow(snap) == 0L) {
    attr(empty, "mode") <- "empty"
    return(empty)
  }

  snap_keys <- review_key(snap$country, snap$document_id)
  reviewed_any <- keys_reviewed_any(reviews)
  reviewed_me <- keys_reviewed_by(reviews, reviewer)

  # Cross-reviewer agreement records: reviewed by someone, but not by me.
  validate_keys <- setdiff(reviewed_any, reviewed_me)
  pick <- snap_keys %in% validate_keys
  if (any(pick)) {
    sub <- snap[pick, , drop = FALSE]
    out <- tibble::tibble(document_id = sub$document_id, country = sub$country)
    out <- out[sample.int(nrow(out)), , drop = FALSE] # shuffle
    attr(out, "mode") <- "validate"
    return(out)
  }

  # Caught up on everything reviewed: draw fresh from records no one has seen.
  fresh <- snap[!(snap_keys %in% reviewed_any), , drop = FALSE]
  if (nrow(fresh) == 0L) {
    attr(empty, "mode") <- "empty"
    return(empty)
  }
  out <- draw_random_sample(fresh, countries, n_per_country)
  if (nrow(out) == 0L) {
    attr(empty, "mode") <- "empty"
    return(empty)
  }
  attr(out, "mode") <- "fresh"
  out
}

# Recompute the BIOGAIN ensemble selection (and cosine/kw arms) on the snapshot
# for the given thresholds. Thin wrapper over the package's select_assessments()
# so the funnel reflects the real selection rule, not a reimplementation.
apply_selection <- function(snap, relevance_threshold = 0.5, kw_min = 2L) {
  if (nrow(snap) == 0L) {
    snap$cosine_relevant <- logical(0)
    snap$selected <- logical(0)
    return(snap)
  }
  planscanR::select_assessments(
    snap,
    relevance_threshold = relevance_threshold,
    kw_min = as.integer(kw_min)
  )
}
