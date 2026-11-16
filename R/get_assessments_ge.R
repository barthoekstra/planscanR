#' Fetch environmental-assessment records from Georgia.
#'
#' Implementation of [get_assessments()] for Georgia. Backed by the **recent
#' environmental decision portal** of the Ministry of Environmental Protection
#' and Agriculture (<https://ei.gov.ge/>, Georgian-language `/ka` pages). The
#' legacy archive is out of scope, and the portal's own historical horizon is
#' not documented: only what the listing returns is covered, so results are
#' **not national completeness**. Native Georgian values are kept verbatim.
#'
#' @section Records:
#' The listing (`POST /ka/Home/Table`, anonymous JSON body, 5 rows per page, a
#' finite page count) holds procedure *events*; the stable case key is the
#' `/ka/info/<GUID>` link. One output record is returned per case (deduplicated
#' across pages and procedures) with `document_id = "ge_<GUID>"`. The case
#' detail JSON (`GET /ka/record?id=<GUID>`) is captured in full in
#' `detail_json`; `title` (project name), `proponent` (implementer),
#' `jurisdiction` (activity address, free text "region/municipality"),
#' `date_published` (earliest procedure publication date, else the listing
#' date), `status` / `status_date` (of the procedure that surfaced the case),
#' `procedure_native`, `category_native` and `procedures_native` (all procedures
#' of the case) are columns. `competent_authority` is not exposed (`NA`).
#' `assessment_type` comes from the procedure filter that found the case
#' (`"EIA"` or `"SEA"`); no title heuristic is used.
#'
#' @section Procedures:
#' `procedure` selects which procedure types to enumerate: `"eia"`,
#' `"eia_screening"`, `"eia_scoping"`, `"sea_screening"`, `"sea_scoping"`,
#' `"sea_report_review"`. The default is all six; exemption and permit-change
#' procedures are not covered.
#'
#' @section Attachments:
#' Files are listed from the detail JSON for every procedure and nested
#' document, never guessed: `attachment_urls_main_document` holds
#' `/download/files/?file=<GUID>&accompany=false` PDFs (application letters,
#' decisions) where `HasDocument` is true; `attachment_urls_accompanying_bundle`
#' holds `accompany=true` downloads only where the record says
#' `HasAccompanyingDocument`. **The EIA report itself lives inside the RAR5
#' accompanying bundle.** Bundles are downloaded as-is (no extraction, no new
#' dependency). SEA report-review bundles are often 500+ MB and exceed the
#' default size cap (status `skipped_size`). `attachment_labels_native` is a
#' JSON object mapping each URL to its native category label.
#'
#' @section Filter coverage:
#' `procedure` is applied server-side. `query` (case-insensitive title
#' substring) and `date_range` (against `date_published`) are client-side, so a
#' selective filter still pages through the listing. Requests are throttled to
#' 2 req/s (`getOption("planscanR.ge_throttle_rate")`). Page failures or short
#' pages give a `planscanR_warning_partial`; a response without the expected
#' table is an error.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param procedure Optional character vector of procedure keys (see
#'   *Procedures*); `NULL` (default) enumerates all six.
#' @param query Optional free-text query, matched client-side as a
#'   case-insensitive substring of the record title.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' get_assessments_ge(limit = 3, download = FALSE, procedure = "eia")
#' }
get_assessments_ge <- function(
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
  procedure = NULL,
  query = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  keys <- ge_resolve_procedures(procedure)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.ge_throttle_rate", 2)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "ge")
  sidecar_index <- if (!refresh) {
    sidecar_url_index("ge")
  } else {
    stats::setNames(character(0), character(0))
  }

  process_entry <- function(entry) {
    rec <- tryCatch(
      ge_load_or_fetch(entry, sidecar_index),
      error = function(e) {
        # No sidecar is written for a failed detail, so a re-run retries it.
        warn_partial("Failed to load/parse {.url {entry$url}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec) || !ge_record_matches(rec, query = query, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    ge_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  records <- stream_crawl(ge_fetch_search(keys), process_entry, limit = limit, label = "ge")
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

#' @noRd
ge_source_portal <- function() "ei.gov.ge"

#' @noRd
ge_portal_base <- function() "https://ei.gov.ge"

#' Procedure key -> portal procedure GUID.
#' @noRd
ge_procedure_ids <- function() {
  c(
    eia = "e57dcc15-b9c8-456d-8cdb-7b1581df629c",
    eia_screening = "861d3afd-b2ba-4d11-88de-c8ef0aeca8e6",
    eia_scoping = "52f8d22f-78f1-4acd-bdb1-7a2a3fbbeb8b",
    sea_screening = "c91649ad-2715-4e8f-8391-971c6711884a",
    sea_scoping = "1d218e08-d4a9-43a4-bdfd-12812b9fd963",
    sea_report_review = "1ba52ee5-cac9-42a3-b5b5-2a0760c3b85d"
  )
}

#' Validate the `procedure` argument.
#' @noRd
ge_resolve_procedures <- function(procedure) {
  all <- names(ge_procedure_ids())
  if (is.null(procedure)) {
    return(all)
  }
  if (!is.character(procedure) || length(procedure) == 0L || !all(procedure %in% all)) {
    cli::cli_abort(
      "{.arg procedure} must be a subset of {.val {all}}.",
      class = "planscanR_error_bad_input"
    )
  }
  unique(procedure)
}

#' Collapse whitespace and trim.
#' @noRd
ge_text <- function(x) {
  trimws(gsub("[[:space:]\u00a0\ufeff]+", " ", x))
}

#' Scalar string or NA (NULL, empty and NA all become NA).
#' @noRd
ge_chr <- function(x) {
  if (is.null(x) || length(x) == 0L || is.na(x[[1]]) || !nzchar(trimws(x[[1]]))) {
    return(NA_character_)
  }
  as.character(x[[1]])
}

#' `/Date(ms)/` (WCF JSON) or `DD.MM.YYYY` -> Date (Georgia is UTC+4, no DST).
#' @noRd
ge_parse_date <- function(x) {
  x <- ge_chr(x)
  if (is.na(x)) {
    return(as.Date(NA))
  }
  ms <- regmatches(x, regexpr("(?<=Date\\()-?[0-9]+", x, perl = TRUE))
  if (length(ms) == 1L) {
    return(as.Date(as.POSIXct(as.numeric(ms) / 1000, origin = "1970-01-01", tz = "Asia/Tbilisi"), tz = "Asia/Tbilisi"))
  }
  m <- regmatches(x, regexpr("[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}", x))
  if (length(m) == 1L) {
    d <- suppressWarnings(as.Date(m, format = "%d.%m.%Y"))
    return(d)
  }
  as.Date(NA)
}

#' @noRd
ge_download_url <- function(id, bundle) {
  sprintf(
    "%s/download/files/?file=%s&accompany=%s&type=%s",
    ge_portal_base(),
    id,
    if (bundle) "true" else "false",
    if (bundle) "false" else "true"
  )
}

# -----------------------------------------------------------------------------
# Network seams
# -----------------------------------------------------------------------------

#' POST one listing page for one procedure GUID (HTML fragment). Network seam.
#' @noRd
ge_fetch_table <- function(procedure_id, page) {
  req <- req_planscanr(ge_portal_base(), "ka/Home/Table")
  req <- httr2::req_body_json(req, list(ProcedureIDs = list(procedure_id), Page = page))
  perform_html(req)
}

#' GET the case detail JSON. Network seam.
#' @noRd
ge_fetch_record <- function(id) {
  req <- req_planscanr(ge_portal_base(), "ka/record")
  req <- httr2::req_url_query(req, id = id)
  perform_json(req)
}

# -----------------------------------------------------------------------------
# Listing
# -----------------------------------------------------------------------------

#' Parse one listing page into `list(entries, last_page)`. Errors when the
#' expected results table is missing (malformed envelope).
#' @noRd
ge_parse_table <- function(html) {
  if (length(rvest::html_elements(html, "table.table-main")) == 0L) {
    cli::cli_abort(
      "ei.gov.ge listing response has no results table; the portal layout may have changed.",
      class = "planscanR_error_bad_response"
    )
  }
  pages <- suppressWarnings(as.integer(rvest::html_attr(
    rvest::html_elements(html, ".pagination a[data-page]"),
    "data-page"
  )))
  last <- if (all(is.na(pages))) 1L else max(pages, na.rm = TRUE)
  entries <- list()
  for (tr in rvest::html_elements(html, "table.table-main tbody tr")) {
    href <- rvest::html_attr(rvest::html_element(tr, "a[href*='/ka/info/']"), "href")
    if (is.na(href)) {
      next
    }
    cells <- ge_text(rvest::html_text(rvest::html_elements(tr, "td")))
    id <- sub(".*/ka/info/([0-9a-fA-F-]{36}).*", "\\1", href)
    if (length(cells) < 11L || !grepl("^[0-9a-fA-F-]{36}$", id)) {
      warn_partial("Skipped Georgia listing row with {length(cells)} cells: {.val {href}}")
      next
    }
    entries[[length(entries) + 1L]] <- list(
      id = tolower(id),
      url = paste0(ge_portal_base(), "/ka/info/", tolower(id)),
      row_id = sub("^item-", "", ge_chr(rvest::html_attr(tr, "id"))),
      listing_date = cells[1],
      listing_category = cells[2],
      listing_procedure = cells[4],
      listing_title = cells[6],
      listing_status = cells[11]
    )
  }
  list(entries = entries, last_page = last)
}

#' Page generator over procedure keys x pages; dedupes cases across both.
#' Page failures warn (partial) rather than silently truncating.
#' @noRd
ge_fetch_search <- function(keys) {
  ids <- ge_procedure_ids()
  queue <- keys
  key <- NULL
  page <- 0L
  last <- 1L
  seen <- character(0)
  function() {
    repeat {
      if (is.null(key)) {
        if (length(queue) == 0L) {
          return(NULL)
        }
        key <<- queue[[1]]
        queue <<- queue[-1]
        page <<- 0L
        last <<- 1L
      }
      page <<- page + 1L
      if (page > last) {
        key <<- NULL
        next
      }
      parsed <- tryCatch(
        ge_parse_table(ge_fetch_table(ids[[key]], page)),
        error = function(e) {
          if (inherits(e, "planscanR_error_bad_response")) {
            return(e) # re-raised below: malformed envelope is an error
          }
          warn_partial(
            "Georgia listing {.val {key}} page {page} failed: {conditionMessage(e)}"
          )
          NULL
        }
      )
      if (inherits(parsed, "error")) {
        stop(parsed)
      }
      if (is.null(parsed)) {
        if (page == 1L) {
          key <<- NULL
        } # last page unknown: abandon this procedure
        next
      }
      if (page == 1L) {
        last <<- min(parsed$last_page, 5000L)
      } else if (length(parsed$entries) == 0L) {
        warn_partial("Georgia listing {.val {key}} page {page} of {last} was empty; skipping.")
      }
      fresh <- Filter(function(e) !e$id %in% seen, parsed$entries)
      fresh <- fresh[!duplicated(vapply(fresh, `[[`, "", "id"))]
      if (length(fresh) > 0L) {
        seen <<- c(seen, vapply(fresh, `[[`, "", "id"))
        return(lapply(fresh, function(e) c(e, list(procedure = key))))
      }
    }
  }
}

# -----------------------------------------------------------------------------
# Detail
# -----------------------------------------------------------------------------

#' @noRd
ge_load_or_fetch <- function(entry, sidecar_index) {
  hit <- sidecar_index[entry$url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  ge_build_record(entry, ge_fetch_record(entry$id))
}

#' Build a 1-row record from a listing entry and its `/ka/record` JSON.
#' @noRd
ge_build_record <- function(entry, json) {
  res <- json$res
  if (!is.list(res) || is.null(res$PermitsPublicPortalInfluenceProjectProcedureGrid)) {
    cli::cli_abort(
      "Georgia record {.val {entry$id}} has no procedure grid.",
      class = "planscanR_error_bad_response"
    )
  }
  grid <- res$PermitsPublicPortalInfluenceProjectProcedureGrid
  gid <- vapply(grid, function(g) ge_chr(g$ID), "")
  idx <- match(entry$row_id, gid, nomatch = 1L)
  prim <- if (length(grid) > 0L) grid[[idx]] else list()

  urls <- list(main_document = character(0), accompanying_bundle = character(0))
  labels <- list()
  add <- function(x, label) {
    id <- ge_chr(x$ID)
    if (is.na(id)) {
      return()
    }
    for (b in c(FALSE, TRUE)) {
      flag <- if (b) x$HasAccompanyingDocument else x$HasDocument
      if (isTRUE(flag)) {
        u <- ge_download_url(id, b)
        sec <- if (b) "accompanying_bundle" else "main_document"
        urls[[sec]] <<- c(urls[[sec]], u)
        labels[[u]] <<- label
      }
    }
  }
  for (g in grid) {
    add(g, ge_chr(g$CategoryName))
    for (d in g$PermitsPublicPortalInfluenceProjectProcedureDocuments) {
      add(d, ge_chr(d$StatementCategoryName))
    }
  }
  urls <- lapply(urls, unique)
  pub <- do.call(c, lapply(grid, function(g) ge_parse_date(g$PublishDate)))
  pub <- if (length(pub)) suppressWarnings(min(pub, na.rm = TRUE)) else as.Date(NA)
  if (!is.finite(pub)) {
    pub <- ge_parse_date(entry$listing_date)
  }

  or_listing <- function(x, fallback) if (is.na(x)) fallback else x
  proc_native <- or_listing(ge_chr(prim$ProcedureName), entry$listing_procedure)
  rec <- tibble::tibble(
    country = "ge",
    source_portal = ge_source_portal(),
    document_id = paste0("ge_", entry$id),
    url = entry$url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(unique(unlist(urls, use.names = FALSE))),
    local_path = list(character(0)),
    title = or_listing(ge_chr(res$ProjectName), entry$listing_title),
    summary = NA_character_,
    competent_authority = NA_character_,
    proponent = ge_chr(res$ImplementerName),
    date_published = pub,
    date_decision = as.Date(NA),
    native_type = proc_native,
    jurisdiction = ge_chr(res$AddressOfActivity),
    assessment_type = if (grepl("^sea", entry$procedure)) "SEA" else "EIA",
    procedure = entry$procedure,
    procedure_native = proc_native,
    category_native = or_listing(ge_chr(prim$CategoryName), entry$listing_category),
    status = or_listing(ge_chr(prim$ProcedureStatusName), entry$listing_status),
    status_date = as.character(ge_parse_date(prim$ProcedureStatusDate)), # ISO text: extras round-trip as text
    native_id = entry$id,
    procedures_native = paste(
      vapply(
        grid,
        function(g) sprintf("%s [%s]", ge_chr(g$ProcedureName), ge_chr(g$ProcedureStatusName)),
        ""
      ),
      collapse = "; "
    ),
    attachment_labels_native = as.character(jsonlite::toJSON(labels, auto_unbox = TRUE)),
    detail_json = as.character(jsonlite::toJSON(json, auto_unbox = TRUE, null = "null")),
    download_status = list(empty_download_status())
  )
  for (sec in names(urls)) {
    if (length(urls[[sec]]) > 0L) {
      rec[[paste0("attachment_urls_", sec)]] <- list(urls[[sec]])
      rec[[paste0("local_path_", sec)]] <- list(character(0))
    }
  }
  rec
}

# -----------------------------------------------------------------------------
# Finalise + filters
# -----------------------------------------------------------------------------

#' Run downloads (RAR bundles kept as-is) and write the sidecar.
#' @noRd
ge_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)
  section_urls <- stats::setNames(
    lapply(section_cols, function(cn) rec[[cn]][[1]]),
    sub("^attachment_urls_", "", section_cols)
  )
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "ge"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "ge",
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  for (slug in names(section_urls)) {
    rec[[paste0("local_path_", slug)]] <- list(ds$local_path[match(section_urls[[slug]], ds$url)])
  }
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar) {
    tryCatch(
      write_fetched_record_sidecar(rec, downloads = rec$download_status[[1]]),
      error = function(e) {
        warn_partial("Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}")
      }
    )
  }
  rec
}

#' Client-side `query` + `date_range` filters.
#' @noRd
ge_record_matches <- function(rec, query = NULL, date_range = NULL) {
  if (!is.null(query) && nzchar(query)) {
    if (is.na(rec$title) || !grepl(tolower(query), tolower(rec$title), fixed = TRUE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}
