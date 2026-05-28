# =============================================================================
# biogain_acquire.R — BIOGAIN assessment acquisition runbook
# =============================================================================
#
# One-stop, top-to-bottom runnable script that drives the planscanR pipeline
# for the BIOGAIN project (Net Biodiversity Gain in spatial energy planning).
# It scans the supported national portals, scores every record against the
# BIOGAIN topic set, and — opt-in — downloads documents for the relevant
# subset.
#
# Acquisition philosophy: harvest broad, select later.
#   * Record level — the SCAN phase scores EVERY record in both registers
#     (no category/relevance pre-filter at scan time) and persists the scores
#     + native_type + all metadata to the sidecars. Choosing which records
#     "fit BIOGAIN" is deferred to a downstream, cross-country aggregation
#     step that reads the sidecars (via index_cache()) and applies whatever
#     relevance / category / spatial criteria the analysis needs.
#   * File level — when a record IS downloaded we fetch ALL its document
#     sections, recording each file's `section` type in the sidecar so a
#     later classification routine can decide which files are useful
#     (UVP-Bericht vs. lubricant datasheet, which project a file belongs to,
#     etc.). The fetcher stays deliberately undiscriminating.
# The only knob that still gates the (opt-in) DOWNLOAD/DISCOVER phases is the
# relevance threshold below — it's the lever for "once I've decided, pull the
# PDFs for the records above score X". Leave downloads off for a pure
# information harvest.
#
# Run it:
#   Rscript data-raw/biogain_acquire.R
# or source it interactively after `devtools::load_all()`.
#
# Phases (toggle in the CONFIG block, or via BIOGAIN_RUN_* env vars):
#   A. SCAN     — metadata + relevance scoring → per-record sidecar JSONs.
#   B. CLASSIFY — local zero-shot classification (title + summary + category)
#                 into BIOGAIN classes incl. explicit negatives; persists a
#                 calibrated verdict to each sidecar. Off by default. This is
#                 the precise "is this relevant?" signal that replaces a bare
#                 cosine cutoff.
#   C. DOWNLOAD — gated PDF downloads for portals that expose documents
#                 (NL, DE). Off by default; flip RUN_DOWNLOAD once you've
#                 eyeballed the scan.
#   D. DISCOVER — Tavily-backed document discovery for portals that hide
#                 their PDFs behind auth (AT). Off by default; needs
#                 TAVILY_API_KEY.
#   E. REPORT   — per-country summary of what's on disk.
#
# Everything is idempotent and resumable: sidecars short-circuit re-fetches,
# and each record is persisted inside the per-record loop, so an interrupted
# run leaves N fully-indexable records on disk.
# =============================================================================

# ----------------------------------------------------------------------------
# CONFIG
# ----------------------------------------------------------------------------

# Cache root. Every sidecar + downloaded file lands under <CACHE_DIR>/files/.
# Override with the PLANSCANR_CACHE env var without editing this file.
CACHE_DIR <- Sys.getenv("PLANSCANR_CACHE", "/Users/barthoekstra/Development/plans")

# Which portals to process, in order.
COUNTRIES <- c("nl", "de", "at")

# Phase toggles. Default = scan only; classification, downloads, and discovery
# are deliberate opt-ins. Each is overridable from the environment without
# editing this file, e.g.
#   BIOGAIN_RUN_SCAN=false BIOGAIN_RUN_CLASSIFY=true Rscript data-raw/biogain_acquire.R
env_flag <- function(name, default) {
  v <- Sys.getenv(name, unset = NA_character_)
  if (is.na(v) || !nzchar(v)) {
    return(default)
  }
  isTRUE(as.logical(v))
}
RUN_SCAN <- env_flag("BIOGAIN_RUN_SCAN", TRUE)
RUN_CLASSIFY <- env_flag("BIOGAIN_RUN_CLASSIFY", FALSE)
RUN_DOWNLOAD <- env_flag("BIOGAIN_RUN_DOWNLOAD", FALSE)
RUN_DISCOVER <- env_flag("BIOGAIN_RUN_DISCOVER", FALSE)

# Relevance gate for the DOWNLOAD and DISCOVER phases: a record is a download
# candidate if ANY BIOGAIN topic clears this cosine threshold. Scan-phase
# scoring is unconditional (every record gets scored regardless).
DL_THRESHOLD <- 0.50

# Per-file size cap (MiB) for downloads. Our DE probe averaged ~2.4 MB/PDF and
# never hit 50 MB; bump only if you see lots of "skipped_size".
DL_MAX_MB <- 100

# Cap records per country during exploration. Inf = whole register.
# (A small value here is the quickest way to smoke-test the whole script.)
SCAN_LIMIT <- Inf

# BIOGAIN topic set (six topics; see ?biogain_assessment_topics).
TOPICS <- NULL # filled in after the package loads, below.

# Per-country acquisition config. The script is the single source of truth for
# how each portal is treated; add a country by adding a list entry.
#
#   scan_args        — extra args forwarded to get_assessments() in the scan
#                      phase (e.g. a server-side query to narrow the crawl).
#   download_sections— which per-section attachment list-columns to fetch in
#                      the DOWNLOAD phase. "all" = every section the records
#                      carry (whatever the handler discovered, including
#                      newly-appearing types). A character vector names
#                      specific slugs (e.g. c("uvp_bericht", "entscheidung")).
#                      NULL/character(0) = no portal downloads for this country
#                      (e.g. AT, where PDFs are hidden and only DISCOVER
#                      applies).
#   category_regex   — optional ASCII-safe regex on the record's `native_type`
#                      (the portal's own topic taxonomy). NULL = no category
#                      gate. For DE this restricts to the energy UVP-Kategorien
#                      ("...Bergbau und Energie", "Leitungsanlagen...") which
#                      cover ~98% of BIOGAIN wind hits with little leakage.
#   discover         — TRUE to route this country through the DISCOVER phase
#                      instead of (or in addition to) portal downloads.
COUNTRY_CFG <- list(
  nl = list(
    scan_args = list(),
    download_sections = "all",
    category_regex = NULL,
    discover = FALSE
  ),
  de = list(
    scan_args = list(),
    download_sections = "all",
    # No category pre-filter: we harvest every record's information and defer
    # the BIOGAIN selection to a downstream, cross-country aggregation step
    # (see the acquisition philosophy in the header). `native_type` (the
    # portal's UVP-Kategorie) is still captured on every sidecar, so a
    # category-based selection remains possible later — it's just not applied
    # at acquisition time.
    category_regex = NULL,
    discover = FALSE
  ),
  at = list(
    scan_args = list(),
    download_sections = NULL,
    category_regex = NULL,
    discover = TRUE
  )
)


# ----------------------------------------------------------------------------
# SETUP
# ----------------------------------------------------------------------------

# Load the package (dev tree if available, else installed).
if (file.exists("DESCRIPTION") && requireNamespace("devtools", quietly = TRUE)) {
  suppressMessages(devtools::load_all("."))
} else {
  library(planscanR)
}

options(planscanR.cache_dir = CACHE_DIR)
options(planscanR.max_file_size_mb = DL_MAX_MB)
TOPICS <- biogain_assessment_topics()
BIOGAIN_SLUGS <- names(TOPICS)

# Python deps via reticulate, declared up front so an env problem surfaces
# before a long run rather than mid-way. The relevance scorer needs
# sentence-transformers; the zero-shot classifier needs transformers + torch
# plus the mDeBERTa tokenizer deps (sentencepiece, protobuf).
py_pkgs <- character(0)
if (RUN_SCAN || RUN_DISCOVER) {
  py_pkgs <- c(py_pkgs, "sentence-transformers")
}
if (RUN_CLASSIFY) {
  py_pkgs <- c(py_pkgs, "transformers", "torch", "sentencepiece", "protobuf")
}
if (length(py_pkgs) > 0L) {
  reticulate::py_require(unique(py_pkgs))
  Sys.setenv(TRANSFORMERS_NO_ADVISORY_WARNINGS = "1")
  Sys.setenv(HF_HUB_DISABLE_PROGRESS_BARS = "1")
}

`%||%` <- function(a, b) if (is.null(a)) b else a

log_step <- function(...) {
  cli::cli_inform("{format(Sys.time(), '%H:%M:%S')}  {sprintf(...)}")
}


# ----------------------------------------------------------------------------
# HELPERS
# ----------------------------------------------------------------------------

#' Per-record max BIOGAIN topic score (−Inf where a record has no scores).
biogain_topic_max <- function(recs, slugs = BIOGAIN_SLUGS) {
  cols <- paste0("relevance_score_", slugs)
  cols <- cols[cols %in% names(recs)]
  if (length(cols) == 0L) {
    return(rep(NA_real_, nrow(recs)))
  }
  mats <- lapply(cols, function(cn) {
    v <- recs[[cn]]
    v[is.na(v)] <- -Inf
    v
  })
  do.call(pmax, mats)
}

#' Download one country's gated slice, section-selectively, and merge results
#' back into the on-disk sidecars.
#'
#' Stacks three gates: relevance (any BIOGAIN topic >= threshold), optional
#' category regex on native_type, and section selection. Only the URLs in the
#' configured sections are fetched; pending entries for the other sections stay
#' on the sidecar untouched.
download_slice <- function(country, cfg, threshold = DL_THRESHOLD, max_mb = DL_MAX_MB) {
  sections <- cfg$download_sections
  if (is.null(sections) || length(sections) == 0L) {
    log_step("[%s] no download_sections configured; skipping portal downloads.", country)
    return(invisible(NULL))
  }

  log_step("[%s] loading sidecars for download gating (index_cache)...", country)
  recs <- index_cache(country = country)
  if (nrow(recs) == 0L) {
    log_step("[%s] no sidecars on disk; run the SCAN phase first.", country)
    return(invisible(NULL))
  }

  # Gate 1: relevance.
  tmax <- biogain_topic_max(recs)
  keep <- !is.na(tmax) & tmax >= threshold

  # Gate 2: category (optional).
  if (!is.null(cfg$category_regex)) {
    nt <- if ("native_type" %in% names(recs)) recs$native_type else rep(NA_character_, nrow(recs))
    keep <- keep & !is.na(nt) & grepl(cfg$category_regex, nt)
  }

  target <- recs[keep, , drop = FALSE]
  # "all" = every section the records actually carry (whatever the handler
  # discovered, including section types added after this config was written).
  if (identical(sections, "all")) {
    sec_cols <- grep("^attachment_urls_", names(target), value = TRUE)
  } else {
    sec_cols <- paste0("attachment_urls_", sections)
    sec_cols <- sec_cols[sec_cols %in% names(target)]
  }
  if (length(sec_cols) == 0L) {
    log_step(
      "[%s] none of the configured sections (%s) present on records; nothing to download.",
      country,
      paste(sections, collapse = ", ")
    )
    return(invisible(NULL))
  }

  # Count the work up front.
  urls_per_rec <- lapply(seq_len(nrow(target)), function(i) {
    unique(unlist(lapply(sec_cols, function(cn) target[[cn]][[i]]), use.names = FALSE))
  })
  urls_per_rec <- lapply(urls_per_rec, function(u) u[!is.na(u) & nzchar(u)])
  n_urls <- sum(lengths(urls_per_rec))
  has_work <- lengths(urls_per_rec) > 0L
  target <- target[has_work, , drop = FALSE]
  urls_per_rec <- urls_per_rec[has_work]

  log_step(
    "[%s] download slice: %d records pass gates, %d URLs in sections {%s}.",
    country,
    nrow(target),
    n_urls,
    paste(sections, collapse = ", ")
  )
  if (nrow(target) == 0L) {
    return(invisible(NULL))
  }

  all_section_cols <- grep("^attachment_urls_", names(target), value = TRUE)
  stats <- list(downloaded = 0L, cached = 0L, skipped = 0L, failed = 0L, bytes = 0)

  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} [",
      country,
      "] downloading {cli::pb_current}/{cli::pb_total}",
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = nrow(target),
    clear = FALSE
  )

  for (i in seq_len(nrow(target))) {
    rec <- target[i, ]
    urls <- urls_per_rec[[i]]

    ds_new <- planscanR:::download_attachments(
      urls,
      country = country,
      document_id = rec$document_id,
      overwrite = FALSE,
      max_file_size_mb = max_mb
    )
    stats$downloaded <- stats$downloaded + sum(ds_new$status == "downloaded")
    stats$cached <- stats$cached + sum(ds_new$status == "cached")
    stats$skipped <- stats$skipped + sum(ds_new$status == "skipped_size")
    stats$failed <- stats$failed + sum(ds_new$status == "failed")
    stats$bytes <- stats$bytes + sum(ds_new$size_bytes, na.rm = TRUE)

    # Merge: drop superseded rows (same URL), keep everything else (the
    # untouched sections' pending rows + any prior discovery rows).
    ds_old <- rec$download_status[[1]]
    if (is.null(ds_old) || nrow(ds_old) == 0L) {
      ds_merged <- ds_new
    } else {
      ds_old_keep <- ds_old[!ds_old$url %in% ds_new$url, , drop = FALSE]
      ds_merged <- dplyr::bind_rows(ds_old_keep, ds_new)
    }

    rec$download_status <- list(ds_merged)
    rec$local_path <- list(ds_merged$local_path)
    rec$file_sha256 <- list(ds_merged$sha256)
    for (col in all_section_cols) {
      slug <- sub("^attachment_urls_", "", col)
      sec_urls <- rec[[col]][[1]]
      rec[[paste0("local_path_", slug)]] <-
        list(ds_merged$local_path[match(sec_urls, ds_merged$url)])
    }

    tryCatch(
      planscanR:::write_record_sidecar(rec, downloads = ds_merged),
      error = function(e) {
        cli::cli_warn("sidecar write failed for {rec$document_id}: {conditionMessage(e)}")
      }
    )
    cli::cli_progress_update()
  }
  cli::cli_progress_done()

  log_step(
    "[%s] downloads done: %d new, %d cached, %d skipped(size), %d failed, %s on disk.",
    country,
    stats$downloaded,
    stats$cached,
    stats$skipped,
    stats$failed,
    format(structure(stats$bytes, class = "object_size"), units = "auto")
  )
  invisible(stats)
}

#' Route a country's relevant records through Tavily-backed discovery.
discover_slice <- function(country, threshold = DL_THRESHOLD, max_mb = DL_MAX_MB) {
  if (!nzchar(Sys.getenv("TAVILY_API_KEY"))) {
    log_step("[%s] DISCOVER skipped: TAVILY_API_KEY not set.", country)
    return(invisible(NULL))
  }
  log_step("[%s] loading sidecars for discovery gating...", country)
  recs <- index_cache(country = country)
  if (nrow(recs) == 0L) {
    log_step("[%s] no sidecars; run SCAN first.", country)
    return(invisible(NULL))
  }
  tmax <- biogain_topic_max(recs)
  target <- recs[!is.na(tmax) & tmax >= threshold, , drop = FALSE]
  log_step("[%s] discovery slice: %d records pass relevance gate.", country, nrow(target))
  if (nrow(target) == 0L) {
    return(invisible(NULL))
  }
  discover_attachments(
    target,
    backend = search_backend_tavily(),
    relevance_model = embedding_model_minilm(),
    max_file_size_mb = max_mb
  )
}


# ----------------------------------------------------------------------------
# PHASE A — SCAN + SCORE
# ----------------------------------------------------------------------------

if (RUN_SCAN) {
  log_step("=== PHASE A: scan + score (%s) ===", paste(COUNTRIES, collapse = ", "))
  for (cc in COUNTRIES) {
    cfg <- COUNTRY_CFG[[cc]]
    log_step("[%s] scanning + scoring (download = FALSE)...", cc)
    res <- tryCatch(
      do.call(
        get_assessments,
        c(
          list(
            country = cc,
            topic = TOPICS,
            limit = SCAN_LIMIT,
            download = FALSE,
            write_sidecar = TRUE
          ),
          cfg$scan_args %||% list()
        )
      ),
      error = function(e) {
        cli::cli_warn("[{cc}] scan failed: {conditionMessage(e)}")
        NULL
      }
    )
    if (!is.null(res)) {
      saveRDS(res, file.path(CACHE_DIR, sprintf("%s_scan.rds", cc)))
      log_step("[%s] scan done: %d records, snapshot -> %s_scan.rds", cc, nrow(res), cc)
    }
  }
}


# ----------------------------------------------------------------------------
# PHASE B — ZERO-SHOT CLASSIFICATION
# ----------------------------------------------------------------------------
# Local multilingual NLI model classifies title + summary + category into the
# BIOGAIN classes (incl. explicit negative classes). The verdict is persisted
# to each sidecar (class_label / class_score / class_relevant / per-label
# scores), giving a calibrated relevance signal that filters the planning /
# water-management false-positives a bare cosine cutoff lets through. Runs on
# ALL records (the negatives do the filtering), per the harvest-broad ethos.

if (RUN_CLASSIFY) {
  log_step("=== PHASE B: zero-shot classification ===")
  clf <- classify_model_zeroshot() # default mDeBERTa, batch_size = 16
  labels <- biogain_classification_labels()
  for (cc in COUNTRIES) {
    log_step("[%s] loading sidecars for classification...", cc)
    recs <- tryCatch(index_cache(country = cc), error = function(e) NULL)
    if (is.null(recs) || nrow(recs) == 0L) {
      log_step("[%s] no sidecars on disk; run the SCAN phase first.", cc)
      next
    }
    log_step("[%s] classifying %d records (title + summary + category)...", cc, nrow(recs))
    res <- tryCatch(
      classify_assessments(
        recs,
        classifier = clf,
        labels = labels,
        write_sidecar = TRUE
      ),
      error = function(e) {
        cli::cli_warn("[{cc}] classification failed: {conditionMessage(e)}")
        NULL
      }
    )
    if (!is.null(res)) {
      saveRDS(res, file.path(CACHE_DIR, sprintf("%s_classified.rds", cc)))
      log_step(
        "[%s] classification done: %d relevant / %d records, snapshot -> %s_classified.rds",
        cc,
        sum(res$class_relevant, na.rm = TRUE),
        nrow(res),
        cc
      )
    }
  }
}


# ----------------------------------------------------------------------------
# PHASE C — GATED DOWNLOADS (portals that expose PDFs)
# ----------------------------------------------------------------------------

if (RUN_DOWNLOAD) {
  log_step("=== PHASE C: gated downloads ===")
  for (cc in COUNTRIES) {
    cfg <- COUNTRY_CFG[[cc]]
    if (isTRUE(cfg$discover)) {
      next # discovery-only country; handled in phase D
    }
    download_slice(cc, cfg)
  }
}


# ----------------------------------------------------------------------------
# PHASE D — DISCOVERY (portals that hide PDFs)
# ----------------------------------------------------------------------------

if (RUN_DISCOVER) {
  log_step("=== PHASE D: discovery ===")
  for (cc in COUNTRIES) {
    cfg <- COUNTRY_CFG[[cc]]
    if (!isTRUE(cfg$discover)) {
      next
    }
    discover_slice(cc)
  }
}


# ----------------------------------------------------------------------------
# PHASE E — REPORT
# ----------------------------------------------------------------------------

log_step("=== PHASE E: report ===")
report <- lapply(COUNTRIES, function(cc) {
  recs <- tryCatch(index_cache(country = cc), error = function(e) NULL)
  if (is.null(recs) || nrow(recs) == 0L) {
    return(tibble::tibble(
      country = cc,
      records = 0L,
      cosine_relevant = 0L,
      class_relevant = 0L,
      with_attachments = 0L,
      downloaded_files = 0L,
      bytes = 0
    ))
  }
  tmax <- biogain_topic_max(recs)
  cosine_relevant <- sum(!is.na(tmax) & tmax >= DL_THRESHOLD)
  # Classifier verdict, if the CLASSIFY phase has run on this slice.
  class_relevant <- if ("class_relevant" %in% names(recs)) {
    sum(recs$class_relevant, na.rm = TRUE)
  } else {
    NA_integer_
  }
  # Final selection (the ensemble procedure). Degrades gracefully on slices
  # that haven't been classified yet (cosine OR keyword only).
  selected <- tryCatch(
    sum(select_assessments(recs)$selected, na.rm = TRUE),
    error = function(e) NA_integer_
  )
  with_att <- sum(vapply(recs$attachment_urls, function(v) length(v) > 0L, logical(1)))
  dl_files <- 0L
  bytes <- 0
  for (ds in recs$download_status) {
    if (is.null(ds) || nrow(ds) == 0L) {
      next
    }
    done <- ds$status %in% c("downloaded", "cached")
    dl_files <- dl_files + sum(done)
    bytes <- bytes + sum(ds$size_bytes[done], na.rm = TRUE)
  }
  tibble::tibble(
    country = cc,
    records = nrow(recs),
    cosine_relevant = cosine_relevant,
    class_relevant = class_relevant,
    selected = selected,
    with_attachments = with_att,
    downloaded_files = dl_files,
    bytes = bytes
  )
})
report <- dplyr::bind_rows(report)
report$size <- vapply(
  report$bytes,
  function(b) format(structure(b, class = "object_size"), units = "auto"),
  character(1)
)
print(report[, c(
  "country",
  "records",
  "cosine_relevant",
  "class_relevant",
  "selected",
  "with_attachments",
  "downloaded_files",
  "size"
)])
saveRDS(report, file.path(CACHE_DIR, "biogain_acquire_report.rds"))
log_step("Report written -> biogain_acquire_report.rds")
