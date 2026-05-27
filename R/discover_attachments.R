#' Discover attachments for records the portal returned empty.
#'
#' For each input record, this function:
#'
#' 1. **Discovers** — generates a small set of search queries from the
#'    record's metadata and runs them through a [search_backend()].
#' 2. **Validates** — for each candidate URL that points at a PDF, downloads
#'    a copy and runs [discover_validate()] against the record. Failed
#'    candidates are discarded from disk.
#' 3. **Ingests** — for PDFs that pass, copies them into the canonical cache
#'    layout (`<cache>/files/<country>/<document_id>/`) and appends to the
#'    record's sidecar JSON with `source = "discovery"` plus a
#'    `discovery_log[]` audit entry.
#'
#' This is the package's escape hatch for portals that do not expose
#' document URLs to anonymous callers. The Austrian UVP-DB is the canonical
#' example — see [get_assessments_at()] — but the function is portal-agnostic
#' once a country supplies a discovery config.
#'
#' @param records A tibble of records (e.g. from [get_assessments()] or
#'   [index_cache()]). All rows must share the same `country`.
#' @param backend A [search_backend()]. Defaults to
#'   [search_backend_tavily()] (requires `TAVILY_API_KEY`).
#' @param country_config Per-country discovery config (e.g.
#'   [at_discovery_config()]). When `NULL`, resolved from `records$country`.
#' @param relevance_model Optional embedding model for the validator's
#'   semantic backup signal. When `NULL`, the validator runs without
#'   semantic check.
#' @param queries_per_record Cap on the number of templates fired per
#'   record. Lower = cheaper, less recall.
#' @param max_pdfs_per_record Cap on the number of validated PDFs kept per
#'   record.
#' @param max_results_per_query Pass-through to the backend's `max_results`.
#' @param cache_dir Optional cache root. Defaults to
#'   `getOption("planscanR.cache_dir")`.
#' @param max_file_size_mb Per-PDF size cap. Defaults to the package option.
#' @param dry_run If `TRUE`, runs phases 1-2 but skips ingest (no sidecar
#'   writes, no PDFs copied into the cache). The returned tibble carries the
#'   would-be discoveries in its `discovery_log` column for inspection.
#' @param skip_if_attached If `TRUE` (default), records that already have
#'   `length(attachment_urls) > 0` are skipped — discovery is only for
#'   records the portal returned empty.
#' @param semantic_threshold Cosine-similarity threshold for the validator's
#'   semantic backup signal.
#' @return The input tibble with `attachment_urls` and `local_path`
#'   augmented for records that got new validated PDFs, plus a
#'   `discovery_log` list-column with one entry per (record, query) attempt.
#' @export
#' @seealso [search_backend_tavily()], [discover_validate()],
#'   [at_discovery_config()].
discover_attachments <- function(
  records,
  backend = NULL,
  country_config = NULL,
  relevance_model = NULL,
  queries_per_record = 3L,
  max_pdfs_per_record = 100L,
  max_results_per_query = 20L,
  cache_dir = NULL,
  max_file_size_mb = NULL,
  dry_run = FALSE,
  skip_if_attached = TRUE,
  semantic_threshold = 0.5
) {
  if (!is.data.frame(records) || nrow(records) == 0L) {
    cli::cli_abort("{.arg records} must be a non-empty data frame.")
  }
  countries <- unique(records$country)
  if (length(countries) != 1L) {
    cli::cli_abort(
      "{.arg records} must contain a single country (got: {.val {countries}})."
    )
  }
  country <- countries[1]

  if (is.null(country_config)) {
    country_config <- resolve_discovery_config(country)
  }
  if (is.null(backend)) {
    backend <- search_backend_tavily()
  }

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }

  out <- records
  if (!"discovery_log" %in% names(out)) {
    out$discovery_log <- vector("list", nrow(out))
    out$discovery_log <- lapply(out$discovery_log, function(x) list())
  }

  workset_idx <- seq_len(nrow(out))
  if (skip_if_attached) {
    has_attach <- vapply(out$attachment_urls, function(v) length(v) > 0L, logical(1))
    workset_idx <- which(!has_attach)
  }

  if (length(workset_idx) == 0L) {
    cli::cli_inform(
      c(i = "All records already have attachments; nothing to discover.")
    )
    return(out)
  }

  cli::cli_inform(
    c(i = "Running discovery on {.val {length(workset_idx)}} record{?s} via backend {.val {backend_name(backend)}}.")
  )

  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} discovering ",
      "{cli::pb_current}/{cli::pb_total}",
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = length(workset_idx),
    clear = FALSE
  )
  on.exit(cli::cli_progress_done(), add = TRUE)

  for (i in workset_idx) {
    rec_row <- out[i, ]
    log_entries <- list()
    new_files <- list()

    # Idempotent re-run support: pre-load URLs that are already represented
    # by a real local file in the on-disk sidecar so a candidate already
    # successfully downloaded by a previous run is skipped without spending
    # bandwidth or sidecar bloat. Crucially we DO NOT dedup against URLs
    # whose sidecar entry has no local_path (status = "failed" /
    # "skipped_size" / "skipped"): those are precisely the candidates the
    # user might want retried — e.g. after raising `max_file_size_mb`, the
    # previously-too-big files become eligible again. New downloads with a
    # URL already on the sidecar replace the prior entry via the sidecar
    # writer's URL-match dedup.
    seen_urls <- character(0)
    sc_path <- sidecar_path(rec_row$country, rec_row$document_id, create = FALSE)
    if (file.exists(sc_path)) {
      existing <- tryCatch(
        jsonlite::fromJSON(sc_path, simplifyVector = FALSE),
        error = function(e) NULL
      )
      if (!is.null(existing)) {
        prior <- existing$files %||% list()
        on_disk <- vapply(
          prior,
          function(f) {
            lp <- f$local_path
            !is.null(lp) && nzchar(lp) && file.exists(lp)
          },
          logical(1)
        )
        prior_urls <- vapply(
          prior,
          function(f) f$url %||% NA_character_,
          character(1)
        )
        seen_urls <- prior_urls[on_disk & !is.na(prior_urls) & nzchar(prior_urls)]
      }
    }

    queries <- build_record_queries(rec_row, country_config, queries_per_record)
    domains <- at_domains_for(rec_row, country_config)

    # `processed` counts NEW candidates handled this run (downloaded +
    # validated, regardless of pass/fail). Bounded by max_pdfs_per_record so
    # a pathological backend response can't run away with disk or time.
    processed <- 0L
    for (q in queries) {
      if (processed >= max_pdfs_per_record) {
        break
      }
      backend_results <- tryCatch(
        web_search(
          backend,
          query = q,
          include_domains = domains,
          max_results = max_results_per_query
        ),
        error = function(e) {
          warn_partial(
            "Search backend failed on query {.val {q}}: {conditionMessage(e)}"
          )
          list()
        }
      )

      # Filter to PDF-looking URLs.
      pdf_results <- Filter(function(r) looks_like_pdf_url(r$url), backend_results)
      log_entries[[length(log_entries) + 1L]] <- list(
        query = q,
        backend = backend_name(backend),
        scoped_domains_n = length(domains),
        n_results = length(backend_results),
        n_pdf_candidates = length(pdf_results),
        scored_at = format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
      )

      for (cand in pdf_results) {
        if (processed >= max_pdfs_per_record) {
          break
        }
        if (cand$url %in% seen_urls) {
          next
        }
        seen_urls <- c(seen_urls, cand$url)

        # Download to scratch. We deliberately do NOT pre-flight with a HEAD
        # probe: several Austrian portals (bmimi.gv.at most notably) reject
        # HEAD requests with a 302->/403.html redirect even though the
        # underlying GET works fine, so HEAD-then-GET produces spurious
        # failures. Just GET; if the downloaded file exceeds the size cap,
        # discard it post-hoc with a clear status. Captures the actual
        # httr2 error message into the sidecar so failures are diagnosable.
        scratch <- tempfile(fileext = ".pdf")
        on.exit(if (file.exists(scratch)) unlink(scratch), add = TRUE)
        cap_bytes <- max_file_size_bytes(max_file_size_mb)
        dl_err <- NA_character_
        ok <- tryCatch(
          {
            httr2::req_perform(req_planscanr(cand$url), path = scratch)
            TRUE
          },
          error = function(e) {
            dl_err <<- conditionMessage(e)
            FALSE
          }
        )
        if (!ok || !file.exists(scratch) || file.info(scratch)$size == 0L) {
          if (file.exists(scratch)) {
            unlink(scratch)
          }
          new_files[[length(new_files) + 1L]] <- list(
            url = cand$url,
            local_path = NA_character_,
            status = "failed",
            size_bytes = NA_real_,
            sha256 = NA_character_,
            reason = dl_err %||% "empty response body",
            source = "discovery",
            validation_status = "skipped",
            validation_signals = character(0),
            validation_notes = sprintf(
              "never downloaded (%s)",
              dl_err %||% "empty response"
            )
          )
          processed <- processed + 1L
          next
        }

        # Post-download size check. The file's already on disk; if it's
        # over the cap, discard and record the skip.
        dl_size <- unname(file.info(scratch)$size)
        if (!is.na(dl_size) && dl_size > cap_bytes) {
          unlink(scratch)
          new_files[[length(new_files) + 1L]] <- list(
            url = cand$url,
            local_path = NA_character_,
            status = "skipped_size",
            size_bytes = dl_size,
            sha256 = NA_character_,
            reason = sprintf(
              "downloaded size %s exceeds cap %s",
              format(dl_size),
              format(cap_bytes)
            ),
            source = "discovery",
            validation_status = "skipped",
            validation_signals = character(0),
            validation_notes = sprintf(
              "never kept (size %.1f MB exceeds %.0f MB cap)",
              dl_size / 1024^2,
              cap_bytes / 1024^2
            )
          )
          processed <- processed + 1L
          next
        }

        # Validate every downloaded PDF, but classify rather than gate.
        v <- discover_validate(
          rec_row,
          pdf_path = scratch,
          cfg = country_config,
          relevance_model = relevance_model,
          semantic_threshold = semantic_threshold
        )
        validation_status <- if (isTRUE(v$passed)) "valid" else "rejected"
        signals_fired <- names(v$signals)[v$signals]

        # Promote EVERY downloaded PDF — no longer gated on v$passed. The
        # validator's verdict is now classification only, recorded in the
        # sidecar `validation_status` field. Cleanup of rejected files is a
        # separate, opt-in operation.
        if (!dry_run) {
          dest <- cache_path(cand$url, country, rec_row$document_id)
          dir.create(dirname(dest), recursive = TRUE, showWarnings = FALSE)
          if (!file.exists(dest)) {
            file.copy(scratch, dest, overwrite = FALSE)
          }
          size_b <- unname(file.info(dest)$size)
          sha <- file_sha256(dest)
          new_files[[length(new_files) + 1L]] <- list(
            url = cand$url,
            local_path = dest,
            status = "downloaded",
            size_bytes = size_b,
            sha256 = sha,
            reason = NA_character_,
            source = "discovery",
            validation_status = validation_status,
            validation_signals = signals_fired,
            validation_notes = v$notes
          )
        } else {
          # Dry run — log the verdict, no cache write.
          new_files[[length(new_files) + 1L]] <- list(
            url = cand$url,
            local_path = NA_character_,
            status = if (isTRUE(v$passed)) "dry-run-pass" else "dry-run-reject",
            size_bytes = unname(file.info(scratch)$size),
            sha256 = NA_character_,
            reason = NA_character_,
            source = "discovery",
            validation_status = validation_status,
            validation_signals = signals_fired,
            validation_notes = v$notes
          )
        }
        unlink(scratch)
        processed <- processed + 1L
      }
    }

    # Surface what discovery turned up. In dry_run we still write to
    # download_status (with status = "dry-run-pass") so callers can inspect
    # the candidates that would have been promoted — only the cache write
    # and sidecar update below are gated by `!dry_run`.
    if (length(new_files) > 0L) {
      new_urls <- vapply(new_files, function(f) f$url, character(1))
      new_paths <- vapply(new_files, function(f) f$local_path %||% NA_character_, character(1))

      ds_new <- tibble::tibble(
        url = new_urls,
        local_path = new_paths,
        status = vapply(new_files, function(f) f$status, character(1)),
        size_bytes = vapply(new_files, function(f) f$size_bytes %||% NA_real_, numeric(1)),
        sha256 = vapply(new_files, function(f) f$sha256 %||% NA_character_, character(1)),
        reason = vapply(new_files, function(f) f$reason %||% NA_character_, character(1)),
        source = vapply(new_files, function(f) f$source, character(1)),
        # Validation classification: these have to be pivoted out of the
        # new_files list-of-lists explicitly, otherwise `record_to_sidecar()`
        # doesn't see them (it only writes optional columns when they're
        # present in the downloads tibble). Without this the sidecar
        # silently drops the verdict.
        validation_status = vapply(
          new_files,
          function(f) f$validation_status %||% NA_character_,
          character(1)
        ),
        validation_signals = I(lapply(
          new_files,
          function(f) {
            sigs <- f$validation_signals
            if (is.null(sigs)) character(0) else unlist(sigs, use.names = FALSE)
          }
        )),
        validation_notes = vapply(
          new_files,
          function(f) f$validation_notes %||% NA_character_,
          character(1)
        )
      )
      ds_existing <- out$download_status[[i]]
      if (is.null(ds_existing) || nrow(ds_existing) == 0L) {
        out$download_status[[i]] <- ds_new
      } else {
        if (!"source" %in% names(ds_existing)) {
          ds_existing$source <- "portal"
        }
        # Drop existing rows whose URL re-appears in this run's batch — the
        # new entry supersedes the old (e.g. a previously skipped_size or
        # failed candidate that successfully downloaded under a higher cap
        # or after a transient server issue cleared).
        ds_existing <- ds_existing[!ds_existing$url %in% ds_new$url, , drop = FALSE]
        out$download_status[[i]] <- dplyr::bind_rows(ds_existing, ds_new)
      }

      # Real ingest: only outside dry_run, append URLs to attachment_urls and
      # local_path. In dry_run these are left untouched — the candidates live
      # only in `download_status` until you flip `dry_run = FALSE`.
      if (!dry_run) {
        existing_urls <- out$attachment_urls[[i]] %||% character(0)
        existing_paths <- out$local_path[[i]] %||% character(0)
        out$attachment_urls[[i]] <- unique(c(existing_urls, new_urls))
        out$local_path[[i]] <- unique(c(existing_paths, new_paths))
      }
    }

    # Always record the discovery_log (even for empty runs — they're audit-worthy).
    out$discovery_log[[i]] <- c(
      out$discovery_log[[i]] %||% list(),
      log_entries
    )

    # Persist sidecar.
    if (!dry_run) {
      tryCatch(
        write_record_sidecar(out[i, ], downloads = out$download_status[[i]]),
        error = function(e) {
          warn_partial(
            "Could not write sidecar for {.val {rec_row$document_id}}: {conditionMessage(e)}"
          )
        }
      )
    }

    cli::cli_progress_update()
  }

  out
}

#' Per-country dispatch for the discovery config.
#' @noRd
resolve_discovery_config <- function(country) {
  switch(
    country,
    at = at_discovery_config(),
    cli::cli_abort(
      c(
        "No discovery config for country {.val {country}}.",
        i = "Add a `<cc>_discovery_config()` function and wire it into `resolve_discovery_config()`."
      ),
      class = "planscanR_error_unsupported_country"
    )
  )
}

#' Materialise queries for a single record from the country config.
#'
#' Runs each query template in `cfg$query_templates` (an ordered named list);
#' filters out templates that return `NULL`; returns up to `cap` queries.
#' @noRd
build_record_queries <- function(record, cfg, cap) {
  raw <- lapply(cfg$query_templates, function(f) {
    tryCatch(f(record), error = function(e) NULL)
  })
  raw <- Filter(function(q) !is.null(q) && is.character(q) && nzchar(q), raw)
  if (length(raw) == 0L) {
    return(character(0))
  }
  head(unname(unlist(raw)), cap)
}

#' Loose URL heuristic for "this is a PDF". Tavily mostly lies about
#' content-type in the response, so we go by file extension or trailing
#' slug.
#' @noRd
looks_like_pdf_url <- function(url) {
  if (is.null(url) || is.na(url) || !nzchar(url)) {
    return(FALSE)
  }
  u <- tolower(url)
  # Strip query/fragment for the suffix test.
  base <- sub("[?#].*$", "", u)
  grepl("\\.pdf$", base) || grepl("/pdf/?$", base) || grepl("filetype=pdf", u)
}
