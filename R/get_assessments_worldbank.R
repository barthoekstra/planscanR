#' Fetch World Bank assessment documents for a country.
#'
#' Implementation of [get_assessments()] for the explicit source `"worldbank"`
#' (`get_assessments("ke", source = "worldbank")`). Backed by the World Bank
#' Documents & Reports search API (WDS,
#' <https://search.worldbank.org/api/v3/wds?format=json>). This is a global
#' development-bank source, not a national register: records are disclosed
#' project documents of World Bank financed projects, one record per WDS
#' document (not per project or case).
#'
#' @section Geography:
#' The ISO-2 `country` is sent server-side as `countrycode=<ISO2>`. Records
#' whose native country-code list contains the code are kept, including
#' multi-country records (such as `"World,Georgia"`); the same source-prefixed
#' `document_id` is then returned for each requested country. Purely global or
#' regional records without the code are not returned. The native `count`
#' (names) and `countrycode` strings are kept verbatim as extra columns. A code
#' with no matching assessment documents yields a typed empty result only if
#' the World Bank holds other documents for it; a code with no documents at all
#' (an unknown code, or one the bank spells differently, such as `"gb"` rather
#' than `"uk"`) raises `planscanR_error_bad_input`, checked with one extra
#' `rows = 0` request.
#'
#' @section Document types:
#' Only documents whose native `docty` is one of
#' `"Environmental Assessment"`, `"Environmental and Social Assessment"` or
#' `"Strategic Environmental Assessment/Analysis"` are requested (server-side
#' `docty_exact` filter). Frameworks, management plans, review summaries and
#' safeguards data sheets are excluded by type. The raw `docty` and `majdocty`
#' strings are kept as the native role. **Limitation:** the World Bank type
#' label does not separate full EA/ESIA reports from site-level ESMP-grade
#' files, stakeholder engagement plans, volumes or annexes filed under
#' "Environmental Assessment"; no title heuristic is applied, so such files can
#' appear and the downstream relevance/review step decides.
#'
#' @section Attachments:
#' `attachment_urls_document` holds the document's `pdfurl` (rewritten from
#' `http` to `https`); `url` is the document landing page. `projectid`, `guid`,
#' `txturl` and every other field the API returns are kept as extra columns
#' (nested values joined with `"; "`).
#'
#' @section Pagination:
#' Pages are requested with `rows`/`os`, sorted by `docdt` descending, until the
#' offset reaches the (re-read) `total`. Records are de-duplicated on the native
#' id, so repeated pages and offset shifts from records added mid-crawl are
#' harmless. A mid-crawl failure, an empty page before `total` is reached, a
#' `total` that falls between pages, a response without `total`, or a crawl
#' that cannot finish within a bounded number of pages raises a
#' `planscanR_warning_partial`.
#'
#' @param country Lower-case ISO-3166-1 alpha-2 code (supplied by
#'   [get_assessments()]).
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,topic,relevance_threshold,relevance_model
#'   See [get_assessments()]. `date_range` is applied server-side
#'   (`strdate`/`enddate`) and again client-side on `docdt`.
#' @param refresh Ignored: every call queries the live API.
#' @param query Optional free-text query, forwarded as the API `qterm`.
#' @param ... Reserved; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_sources()].
#' @keywords internal
#' @noRd
get_assessments_worldbank <- function(
  country,
  date_range = NULL,
  limit = Inf,
  download = FALSE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  assert_iso2_format(country)
  date_range <- parse_date_range(date_range)
  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rel <- setup_relevance(topic, relevance_model, country = country)

  process_entry <- function(entry) {
    rec <- wb_build_record(entry, country)
    if (!wb_record_matches(rec, date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    wb_finalise_record(rec, should_download, overwrite, max_file_size_mb, write_sidecar)
  }

  gen <- wb_fetch_search(country, date_range = date_range, query = query)
  records <- stream_crawl(gen, process_entry, limit = limit, label = country)
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

wb_source_portal <- function() "worldbank.org"

wb_api_base <- function() "https://search.worldbank.org"

#' Assessment document types requested server-side (exact WDS facet strings).
#' @noRd
wb_doc_types <- function() {
  c(
    "Environmental Assessment",
    "Environmental and Social Assessment",
    "Strategic Environmental Assessment/Analysis"
  )
}

wb_page_size <- function() {
  v <- suppressWarnings(as.integer(getOption("planscanR.wb_page_size", 100L)))
  if (length(v) != 1L || is.na(v) || v < 1L) 100L else min(v, 1000L)
}

#' Page generator over the WDS listing (the stream_crawl() `next_page` contract).
#'
#' Advances `os` by the number of raw records received, re-reads `total` every
#' page, drops ids already seen, and loops internally past all-duplicate pages
#' so an empty batch only ever means "finished".
#' @noRd
wb_fetch_search <- function(country, date_range = NULL, query = NULL) {
  rows <- wb_page_size()
  os <- 0L
  pages <- 0L
  max_pages <- Inf
  done <- FALSE
  seen <- character(0)
  prev_total <- NULL
  fetch_page <- function() {
    req <- req_planscanr(wb_api_base(), c("api", "v3", "wds"))
    req <- httr2::req_url_query(
      req,
      format = "json",
      rows = rows,
      os = os,
      srt = "docdt",
      order = "desc",
      countrycode = toupper(country),
      # "^" ORs the exact types (live KE: 395 + 25 + 1 = 421 = the "^" total).
      docty_exact = paste(wb_doc_types(), collapse = "^"),
      fl = wb_fields(),
      strdate = if (!is.null(date_range)) format(date_range[1]),
      enddate = if (!is.null(date_range)) format(date_range[2]),
      qterm = if (!is.null(query) && nzchar(query)) as.character(query)
    )
    perform_json(req)
  }
  # Country-only probe (rows = 0): distinguishes an unknown code from no documents.
  probe_country <- function() {
    req <- req_planscanr(wb_api_base(), c("api", "v3", "wds"))
    req <- httr2::req_url_query(req, format = "json", rows = 0L, countrycode = toupper(country))
    suppressWarnings(as.integer(perform_json(req)$total %||% 0L))
  }
  function() {
    while (!done) {
      payload <- tryCatch(
        fetch_page(),
        error = function(e) {
          if (pages == 0L) {
            cli::cli_abort(
              c(
                "Could not query the World Bank documents API.",
                x = conditionMessage(e)
              ),
              class = "planscanR_error_http",
              parent = e
            )
          }
          warn_partial(
            "World Bank listing stopped at offset {os} ({conditionMessage(e)}); results are incomplete."
          )
          NULL
        }
      )
      if (is.null(payload)) {
        done <<- TRUE
        return(NULL)
      }
      total <- suppressWarnings(as.integer(payload$total %||% 0L))
      if (is.na(total)) {
        total <- 0L
      }
      docs <- Filter(function(d) is.list(d) && !is.null(d$id), payload$documents %||% list())
      if (pages == 0L) {
        max_pages <<- 2L * ceiling(total / rows) + 5L
        if (total == 0L && length(docs) == 0L) {
          done <<- TRUE
          n_country <- probe_country()
          if (is.na(n_country) || n_country == 0L) {
            cli::cli_abort(
              c(
                "The World Bank has no documents for country code {.val {toupper(country)}}.",
                i = "It uses its own codes (for example {.val gb}, not {.val uk}); check the ISO-2 code."
              ),
              class = "planscanR_error_bad_input"
            )
          }
          return(NULL)
        }
        if (is.null(payload$total) && length(docs) > 0L) {
          warn_partial("World Bank response had no total; results may be incomplete.")
        }
      } else if (!is.null(prev_total) && total < prev_total) {
        warn_partial(
          "World Bank total fell from {prev_total} to {total}; records may have shifted past the offset, results may be incomplete."
        )
      }
      prev_total <<- total
      pages <<- pages + 1L
      os <<- os + length(docs)
      ids <- vapply(docs, function(d) as.character(d$id), character(1))
      keep <- !ids %in% seen & !duplicated(ids)
      seen <<- c(seen, ids[keep])
      if (length(docs) == 0L) {
        done <<- TRUE
        if (length(seen) < total) {
          warn_partial(
            "World Bank listing ended at offset {os} with {length(seen)} of {total} documents; results are incomplete."
          )
        }
        return(NULL)
      }
      # Repeated ids (offset shifts) mean os >= total can arrive before every id is seen.
      if (os >= total && length(seen) >= total) {
        done <<- TRUE
      } else if (pages >= max_pages) {
        done <<- TRUE
        warn_partial(
          "World Bank listing did not finish within {max_pages} pages (total changed during the crawl); results are incomplete."
        )
      }
      if (any(keep)) {
        return(unname(docs[keep]))
      }
    }
    NULL
  }
}

#' Field list requested from WDS: all of them.
#'
#' The default response omits `countrycode` and varies by record age; an explicit
#' field list drops further fields (authors, datestored, ...). `"*"` returned a
#' strict superset of the default on 1990s and current Kenya records (see
#' probe/WB/NOTES.md, "Correction pass").
#' @noRd
wb_fields <- function() "*"

#' Flatten a WDS value (scalar, nested list, empty) to one string or NA.
#' @noRd
# Also used by get_assessments_ifc.R.
wb_flat <- function(v) {
  s <- if (is.list(v)) unlist(v, use.names = FALSE) else v
  s <- trimws(as.character(s))
  s <- s[!is.na(s) & nzchar(s)]
  if (length(s) == 0L) NA_character_ else paste(s, collapse = "; ")
}

wb_https <- function(u) sub("^http://", "https://", u)

#' Build the 1-row record for one WDS document.
#' @noRd
wb_build_record <- function(raw, country) {
  id <- wb_flat(raw$id)
  pdf <- wb_flat(raw$pdfurl)
  pdf <- if (is.na(pdf)) character(0) else wb_https(pdf)
  landing <- wb_flat(raw$url)
  landing <- if (is.na(landing)) {
    paste0("https://documents.worldbank.org/en/publication/documents-reports/documentdetail/", id)
  } else {
    wb_https(landing)
  }
  rec <- tibble::tibble(
    country = country,
    source_portal = wb_source_portal(),
    document_id = paste0("worldbank_", id),
    url = landing,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(pdf),
    local_path = list(character(0)),
    title = wb_flat(raw$display_title),
    summary = wb_flat(raw$abstracts),
    competent_authority = NA_character_,
    proponent = NA_character_,
    date_published = parse_iso_date(substr(wb_flat(raw$docdt), 1, 10)),
    date_decision = as.Date(NA),
    native_type = wb_flat(raw$docty),
    status = wb_flat(raw$disclstat),
    download_status = list(empty_download_status())
  )
  skip <- c("id", "url", "abstracts")
  for (nm in setdiff(names(raw), skip)) {
    col <- if (nm %in% names(rec)) paste0("wb_", nm) else nm
    rec[[col]] <- wb_flat(raw[[nm]])
  }
  rec$native_id <- id
  if (length(pdf) > 0L) {
    rec$attachment_urls_document <- list(pdf)
    rec$local_path_document <- list(character(0))
  }
  rec
}

#' Client-side `date_range` check on `docdt` (the server filter is the first pass).
#' @noRd
wb_record_matches <- function(rec, date_range = NULL) {
  if (is.null(date_range)) {
    return(TRUE)
  }
  d <- rec$date_published
  !is.na(d) && d >= date_range[1] && d <= date_range[2]
}

#' Download (if requested) and write the sidecar.
#' @noRd
wb_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", rec$country), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = rec$country,
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  if ("attachment_urls_document" %in% names(rec)) {
    rec$local_path_document <- list(ds$local_path[match(urls, ds$url)])
  }
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar) {
    tryCatch(
      write_fetched_record_sidecar(rec, downloads = ds),
      error = function(e) {
        warn_partial("Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}")
      }
    )
  }
  rec
}
