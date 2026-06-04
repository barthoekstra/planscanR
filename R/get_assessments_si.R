#' Fetch environmental-assessment records from Slovenia.
#'
#' Implementation of [get_assessments()] for Slovenia. Backed by the
#' Slovenian government portal gov.si (<https://www.gov.si/>), which
#' publishes the environmental-assessment registers as bulk JSON exports
#' under <https://www.gov.si/podrocja/okolje-in-prostor/okolje/okoljske-presoje/>.
#' Three adjacent registers are merged into a single result tibble:
#'
#' * **Predhodni postopek** — the EIA screening register
#'   (`predhodni-postopek`).
#' * **CPVO — državni prostorski načrti** — SEA decisions for state spatial
#'   plans (`cpvo-drzavni`).
#' * **CPVO — občinski prostorski načrti** — SEA decisions for municipal
#'   spatial plans (`cpvo-obcinski`).
#'
#' An `assessment_type` column (`"EIA"` for the screening register, `"SEA"`
#' for the two CPVO registers) tags each row and is preserved in the offline
#' metadata cache so downstream tooling can tell them apart without re-fetching
#' anything; a `register` column carries the raw portal register label.
#' `document_id` is prefixed with `"PRED-"` / `"CPVO-DRZ-"` / `"CPVO-OBC-"`
#' so the three registers never collide on disk.
#'
#' @section URL enumeration:
#' Each register exposes a single bulk JSON export at
#' `<list base URL><list>/export/json/`, returning the whole register as one
#' JSON array (NOT paginated). The handler issues one GET per register and
#' parses every element of the array, respecting the global `limit`. The
#' canonical detail URL for each record is `<list base URL><URLSegment>/`.
#'
#' @section Attachments:
#' The bulk-export document ids do not map to filenames, so attachments are
#' scraped from each record's detail page (sidecar-first via the cache).
#' The handler fetches the detail HTML, collects every `a[href^="/assets/seznami/"]`
#' link, and absolutises it against `https://www.gov.si`. These become
#' `attachment_urls` (a flat list — no per-section split). A record with no
#' such links yields an empty `attachment_urls` vector, which is valid.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (screening only), or `"SEA"` (both CPVO registers).
#'    Applied here in R, not server-side (the bulk exports are unfiltered).
#' * `date_range` — matched client-side against `date_published` (the
#'    portal's *Datum objave* / *Datum* field). `date_decision` is always
#'    `NA` because the portal exposes no separate decision date as a date.
#' * `limit` — caps the total number of records returned across all crawled
#'    registers.
#'
#' @section Performance:
#' The registers are small (a few hundred screening records, a few dozen CPVO
#' records). A cold crawl is one bulk-export GET per register plus one
#' detail-page fetch per record (sidecar-first, so repeat runs are fast). To
#' be polite to the shared government portal, SI requests are throttled to 5
#' requests per second by default; override via
#' `getOption("planscanR.si_throttle_rate")` (requests/sec; falsy disables).
#' The register covers roughly 2021 onward.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which register(s) to crawl.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_si(limit = 3, download = FALSE)
#'
#' # SEA only (both CPVO registers)
#' get_assessments_si(assessment_type = "SEA", limit = 10, download = FALSE)
#'
#' # Date range
#' get_assessments_si(
#'   date_range = c("2021-01-01", "2021-12-31"),
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_si <- function(
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
  assessment_type = "All",
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  assessment_type <- si_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.si_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "si")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("si")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("predhodni-postopek", "cpvo-drzavni", "cpvo-obcinski"),
    EIA = "predhodni-postopek",
    SEA = c("cpvo-drzavni", "cpvo-obcinski")
  )

  # Per-entry processing: sidecar-first detail fetch (for attachments),
  # client-side date filter, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry.
  process_entry <- function(entry) {
    rec <- tryCatch(
      si_load_or_fetch(entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {entry$url}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!si_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    si_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream each register's bulk export, persisting records as they are parsed.
  # `limit` is global across all crawled registers.
  records <- list()
  for (reg in registers) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    gen <- tryCatch(
      si_fetch_search(register = reg),
      error = function(e) {
        warn_partial(
          "Failed to enumerate gov.si {.val {reg}} export: {conditionMessage(e)}"
        )
        function() NULL
      }
    )
    block <- stream_crawl(gen, process_entry, limit = remaining, label = "si")
    records <- c(records, block)
  }

  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

#' Source portal identifier used in `source_portal` and sidecar JSON.
#' @noRd
si_source_portal <- function() "gov.si"

#' Public base URL for the portal.
#' @noRd
si_portal_base <- function() "https://www.gov.si"

#' Competent authority for every Slovenian record (fixed national ministry).
#' @noRd
si_competent_authority <- function() {
  "Ministrstvo za okolje, podnebje in energijo"
}

#' Base path for the okoljske-presoje register listing pages.
#' @noRd
si_list_base <- function() {
  "podrocja/okolje-in-prostor/okolje/okoljske-presoje"
}

#' Map a register code to its `assessment_type`.
#' @noRd
si_assessment_type_of <- function(register) {
  if (register == "predhodni-postopek") "EIA" else "SEA"
}

#' Map a register code to its `document_id` prefix.
#' @noRd
si_id_prefix <- function(register) {
  switch(
    register,
    `predhodni-postopek` = "PRED",
    `cpvo-drzavni` = "CPVO-DRZ",
    `cpvo-obcinski` = "CPVO-OBC"
  )
}

#' Map a register code to its list-page URL segment.
#'
#' The two CPVO registers crawl their own listing slug; the screening register
#' uses its short code. Returns the path segment appended after `si_list_base()`.
#' @noRd
si_register_segment <- function(register) {
  switch(
    register,
    `predhodni-postopek` = "predhodni-postopek",
    `cpvo-drzavni` = "odlocitve-o-izvedbi-celovite-presoje-vplivov-na-okolje-drzavnih-prostorskih-nacrtov",
    `cpvo-obcinski` = "odlocitve-o-izvedbi-celovite-presoje-vplivov-na-okolje-obcinskih-prostorskih-nacrtov-2"
  )
}

#' Full list base URL for a register (with trailing slash).
#' @noRd
si_register_base_url <- function(register) {
  sprintf(
    "%s/%s/%s/",
    si_portal_base(),
    si_list_base(),
    si_register_segment(register)
  )
}

#' Canonical detail URL for a record.
#' @noRd
si_canonical_url <- function(register, url_segment) {
  paste0(si_register_base_url(register), url_segment, "/")
}

#' Document-ID per register so the three registers never collide on disk.
#' @noRd
si_document_id <- function(register, url_segment) {
  sprintf("%s-%s", si_id_prefix(register), ascii_slug(url_segment, "record"))
}

#' Normalise the `assessment_type` argument.
#' @noRd
si_normalise_assessment_type <- function(x) {
  if (is.null(x) || !nzchar(x)) {
    return("All")
  }
  valid <- c("All", "EIA", "SEA")
  hit <- valid[tolower(valid) == tolower(x)]
  if (length(hit) == 0L) {
    cli::cli_abort(
      "{.arg assessment_type} must be one of {.val {valid}} (got {.val {x}}).",
      class = "planscanR_error_bad_input"
    )
  }
  hit
}

#' Tolerant parser for the Slovenian date format `"29. 09. 2021"`.
#'
#' Strips internal spaces around the dots and parses `%d.%m.%Y`. `NA` for
#' NULL / non-scalar / NA / empty / unparseable.
#' @noRd
si_parse_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  s <- gsub("\\s+", "", trimws(s))
  d <- suppressWarnings(as.Date(s, format = "%d.%m.%Y"))
  if (length(d) == 0L) as.Date(NA) else d
}

# -----------------------------------------------------------------------------
# Bulk-export enumeration
# -----------------------------------------------------------------------------

#' Build a page generator for one register's bulk JSON export.
#'
#' The export is not paginated: a single GET returns the whole register as one
#' JSON array. The generator yields all entries on its first call (mapped into
#' lightweight named lists), then signals exhausted. Pagination state lives in
#' the closure to satisfy the `stream_crawl()` contract.
#' @noRd
si_fetch_search <- function(register) {
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    req <- req_planscanr(si_register_base_url(register))
    req <- httr2::req_url_path_append(req, "export/json/")
    arr <- tryCatch(perform_json(req), error = function(e) NULL)
    if (is.null(arr) || length(arr) == 0L) {
      return(NULL)
    }
    si_map_entries(arr, register)
  }
}

#' Map a bulk-export array into lightweight listing entries.
#'
#' Each entry is a small named list carrying everything the detail-record build
#' needs except the attachments (which come from the detail page).
#' @noRd
si_map_entries <- function(arr, register) {
  out <- list()
  for (raw in arr) {
    url_segment <- si_field(raw, "URLSegment")
    if (is.null(url_segment) || !nzchar(url_segment)) {
      next
    }
    out[[length(out) + 1L]] <- list(
      register = register,
      url_segment = url_segment,
      url = si_canonical_url(register, url_segment),
      raw = raw
    )
  }
  out
}

# -----------------------------------------------------------------------------
# Detail-record building
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else build + scrape.
#' @noRd
si_load_or_fetch <- function(entry, sidecar_index) {
  url <- entry$url
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  attachments <- si_fetch_attachments(url)
  si_build_record(entry, attachments)
}

#' Fetch a detail page and collect its `/assets/seznami/` attachment URLs.
#' @noRd
si_fetch_attachments <- function(url) {
  req <- req_planscanr(url)
  html <- tryCatch(perform_html(req), error = function(e) NULL)
  if (is.null(html)) {
    return(character(0))
  }
  si_parse_attachments(html)
}

#' Parse `a[href^="/assets/seznami/"]` links from a detail page, absolutised.
#' @noRd
si_parse_attachments <- function(html) {
  anchors <- rvest::html_elements(html, "a[href^='/assets/seznami/']")
  if (length(anchors) == 0L) {
    return(character(0))
  }
  hrefs <- rvest::html_attr(anchors, "href")
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  if (length(hrefs) == 0L) {
    return(character(0))
  }
  unique(paste0(si_portal_base(), hrefs))
}

#' Build a 1-row record tibble from a listing entry + scraped attachments.
#' @noRd
si_build_record <- function(entry, attachments) {
  register <- entry$register
  raw <- entry$raw
  document_id <- si_document_id(register, entry$url_segment)

  if (register == "predhodni-postopek") {
    title <- si_field(raw, "Poseg")
    date_published <- si_parse_date(si_field(raw, "Datum objave"))
    proponent <- si_field(raw, "Naziv")
    proponent_address <- si_field(raw, "Naslov")
    case_number <- si_field(raw, "\u0160tevilka zadeve")
    annex_code <- si_field(raw, "Oznaka posega")
    native_type <- NA_character_
    decision <- NA_character_
  } else {
    title <- si_field(raw, "Title")
    if (is.null(title) || !nzchar(title)) {
      title <- si_field(raw, "Naziv")
    }
    date_published <- si_parse_date(si_field(raw, "Datum"))
    proponent <- NA_character_
    proponent_address <- NA_character_
    case_number <- NA_character_
    annex_code <- NA_character_
    decision <- si_field(raw, "Odlo\u010ditev")
    native_type <- decision
  }

  attachments <- attachments %||% character(0)

  tibble::tibble(
    country = "si",
    source_portal = si_source_portal(),
    document_id = document_id,
    url = entry$url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(attachments),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    summary = NA_character_,
    competent_authority = si_competent_authority(),
    proponent = proponent %||% NA_character_,
    date_published = date_published,
    date_decision = as.Date(NA),
    native_type = native_type %||% NA_character_,
    status = NA_character_,
    assessment_type = si_assessment_type_of(register),
    register = register,
    proponent_address = proponent_address %||% NA_character_,
    case_number = case_number %||% NA_character_,
    annex_code = annex_code %||% NA_character_,
    decision = decision %||% NA_character_,
    download_status = list(empty_download_status())
  )
}

#' Read a scalar field from a bulk-export record, returning NULL when absent.
#'
#' Values arrive as JSON scalars; some fields (e.g. `Sklep / Odločba`)
#' are nested objects and are deliberately not surfaced here. Returns a trimmed
#' non-empty character or NULL.
#' @noRd
si_field <- function(raw, key) {
  v <- raw[[key]]
  if (is.null(v) || length(v) != 1L || is.list(v)) {
    return(NULL)
  }
  s <- trimws(as.character(v))
  if (is.na(s) || !nzchar(s)) NULL else s
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed SI record: run downloads (if requested) and write sidecar.
#' @noRd
si_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "si"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "si",
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar) {
    tryCatch(
      write_record_sidecar(rec, downloads = rec$download_status[[1]]),
      error = function(e) {
        warn_partial(
          "Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}"
        )
      }
    )
  }
  rec
}

# -----------------------------------------------------------------------------
# Filters
# -----------------------------------------------------------------------------

#' Apply post-fetch client-side filters (only `date_range`).
#' @noRd
si_record_matches <- function(rec, date_range) {
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}
