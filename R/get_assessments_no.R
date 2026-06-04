#' Fetch environmental-assessment records from Norway.
#'
#' Implementation of [get_assessments()] for Norway. Backed by the
#' *Norges vassdrags- og energidirektorat* (NVE — Norwegian Water Resources &
#' Energy Directorate) concession-case register (`konsesjonssaker`,
#' <https://www.nve.no/konsesjon/konsesjonssaker>). Each case is an
#' energy/water concession application that carries the application itself, the
#' *konsekvensutredning* (environmental impact assessment / EIA), and the
#' hearing documents as downloadable PDFs. The handler talks to NVE's JSON list
#' API and server-rendered detail HTML directly (pure `httr2`, no browser).
#'
#' NVE publishes a single concession-case register (there is no separate
#' EIA/SEA split), so there is no `assessment_type` argument — these are
#' energy-concession cases that carry EIA documents. `document_id` is the
#' globally unique numeric `SoknadId`, prefixed `"NVE-"` (e.g. `"NVE-8934"`), so
#' records never collide on disk.
#'
#' @section URL enumeration:
#' The list endpoint is
#' `GET /umbraco/api/license/getall?caseType=00&county=00&filterText=&municipality=00&pageNumber=N`
#' (JSON). Its `Licenses` array carries the case records; `Counties`,
#' `Municipalities`, `CaseTypes`, and `LicenseStatuses` are filter-vocab facets
#' returned inline, and `TotalCount` is the unfiltered count. The defaults
#' `caseType=00&county=00&municipality=00&filterText=` mean "all". The page
#' generator (`no_fetch_search()`) paginates `pageNumber = 1, 2, …` until a page
#' returns no `Licenses` (parsed with `perform_json`). The canonical detail URL
#' for each record is the human page
#' `https://www.nve.no/konsesjon/konsesjonssaker/konsesjonssak?id={SoknadId}&type={Type}`.
#'
#' @section Attachments:
#' Each detail page renders the case documents in one or more `div.n-filelist`
#' sections, each with an `<h2>` section heading (e.g. *Konsesjon*) and a list
#' of `<a>` links to downloadable PDFs at
#' `https://webfileservice.nve.no/API/PublishedFiles/Download/<saksnummer>/<fileId>`
#' (and a UUID variant `.../Download/<uuid>/<saksnummer>/<fileId>`); no
#' authentication is needed. The handler scrapes those links (sidecar-first),
#' grouping the URLs by the section heading into per-section
#' `attachment_urls_<slug>` columns (the DE / IT / SK pattern; the slug is the
#' ASCII-folded Norwegian heading) plus the deduplicated union in
#' `attachment_urls`. EIA documents are **not** type-flagged in the markup, so
#' every case document is collected; the document label/title is kept verbatim
#' (in the link's `<h3>`) so downstream can identify
#' "konsekvensutredning" / "KU" / "melding" by filename. A case with no
#' published files yields an empty `attachment_urls` vector, which is valid.
#'
#' @section Filter coverage (v0.1):
#' * `query` — forwarded **server-side** as the API `filterText` parameter (the
#'    getall API matches it against the case title/proponent and returns a
#'    filtered list + `TotalCount`).
#' * `date_range` — matched client-side against `date_published` (the case
#'    `Dato`). `date_decision` is always `NA` (the API exposes no separate
#'    decision date).
#' * `limit` — caps the total number of records returned.
#'
#' The getall API also accepts server-side `caseType` / `county` /
#' `municipality` filters (via the facet codes in `CaseTypes` / `Counties` /
#' `Municipalities`, returned inline by the API); these are documented for
#' reference but are not first-class arguments in v0.1.
#'
#' @section Geometry:
#' No geometry is exposed in v0.1. NVE's spatial concession layers live in a
#' separate keyed ArcGIS service that is out of scope for this handler.
#'
#' @section Performance:
#' The register is ~7 300 cases (~730 pages of 10). A cold crawl is one list GET
#' per page plus one detail GET per record (sidecar-first, so repeat runs are
#' fast). A `limit` keeps exploratory runs bounded. NVE's `robots.txt` requests
#' a `Crawl-delay: 20`, so NO requests are throttled to **0.05 requests per
#' second (~20 s between requests)** by default — intentionally conservative.
#' Override via `getOption("planscanR.no_throttle_rate")` (requests/sec; falsy
#' disables). The *konsekvensutredning* (EIA) documents are identified by their
#' filename / label, not a type flag.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query, forwarded server-side as the API
#'   `filterText` parameter.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_no(limit = 3, download = FALSE)
#'
#' # Wind-themed slice (server-side filterText)
#' get_assessments_no(query = "vind", limit = 20, download = FALSE)
#' }
get_assessments_no <- function(
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
  date_range <- parse_date_range(date_range)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.no_throttle_rate", 0.05)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "no")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("no")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Per-entry processing: sidecar-first detail fetch (for attachments), the
  # client-side date filter, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry.
  process_entry <- function(entry) {
    u <- no_canonical_url(entry$soknad_id, entry$type)
    rec <- tryCatch(
      no_load_or_fetch(u, entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!no_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    no_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  gen <- tryCatch(
    no_fetch_search(query = query),
    error = function(e) {
      warn_partial(
        "Failed to enumerate nve.no konsesjonssaker: {conditionMessage(e)}"
      )
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "no")

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
no_source_portal <- function() "nve.no"

#' Public base URL for the portal.
#' @noRd
no_portal_base <- function() "https://www.nve.no"

#' Constant competent authority for every NVE concession case.
#' @noRd
no_competent_authority <- function() "Norges vassdrags- og energidirektorat (NVE)"

#' Canonical human detail URL for a record (sidecar key).
#' @noRd
no_canonical_url <- function(soknad_id, type) {
  sprintf(
    "%s/konsesjon/konsesjonssaker/konsesjonssak?id=%s&type=%s",
    no_portal_base(),
    soknad_id,
    utils::URLencode(as.character(type %||% ""), reserved = TRUE)
  )
}

#' Document-ID for a record: the globally-unique numeric SoknadId, `NVE-`-prefixed.
#' @noRd
no_document_id <- function(soknad_id) {
  sprintf("NVE-%s", soknad_id)
}

#' Absolutise a webfileservice download href (already absolute https in markup).
#' @noRd
no_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (startsWith(href, "//")) {
    return(paste0("https:", href))
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(no_portal_base(), href)
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Build a page generator for the getall list endpoint.
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call fetches the next `?pageNumber=N` of the getall endpoint, parses its
#' `Licenses` array into lightweight listing entries, and stops when a page
#' returns no records. A free-text `query` is forwarded server-side as the API
#' `filterText` parameter.
#' @noRd
no_fetch_search <- function(query = NULL) {
  page <- 1L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(no_portal_base())
    req <- httr2::req_url_path_append(req, "umbraco", "api", "license", "getall")
    req <- httr2::req_url_query(
      req,
      caseType = "00",
      county = "00",
      filterText = if (!is.null(query) && nzchar(query)) as.character(query) else "",
      municipality = "00",
      pageNumber = page
    )
    payload <- tryCatch(perform_json(req), error = function(e) NULL)
    if (is.null(payload)) {
      done <<- TRUE
      return(NULL)
    }
    licenses <- payload[["Licenses"]]
    if (is.null(licenses) || length(licenses) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    page <<- page + 1L
    no_map_entries(licenses)
  }
}

#' Map license objects into lightweight listing entries.
#'
#' Each entry carries the keys needed to build the canonical URL and the raw
#' record (used as a fallback when the detail page is unavailable). The detail
#' parser is sidecar-first, so the full HTML is fetched only on a cache miss.
#' @noRd
no_map_entries <- function(licenses) {
  out <- list()
  for (raw in licenses) {
    soknad_id <- no_field(raw, "SoknadId")
    if (is.null(soknad_id)) {
      next
    }
    out[[length(out) + 1L]] <- list(
      soknad_id = soknad_id,
      type = no_field(raw, "Type"),
      url = no_canonical_url(soknad_id, no_field(raw, "Type")),
      raw = raw
    )
  }
  out
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch + parse detail.
#' @noRd
no_load_or_fetch <- function(url, entry, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  html <- tryCatch(no_fetch_detail(url), error = function(e) NULL)
  per_section <- if (is.null(html)) list() else no_parse_documents(html)
  no_build_record(url, entry$raw, per_section)
}

#' Fetch one case detail page as parsed HTML.
#' @noRd
no_fetch_detail <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Parse the `div.n-filelist` sections into a named list of URL vectors.
#'
#' Each `div.n-filelist` carries an `<h2>` section heading and a `<ul>` of
#' `<li><a href=...>` document links to `webfileservice.nve.no` PDFs. URLs are
#' grouped by the (ASCII-folded) heading; empty headings fall back to
#' `"dokumenter"`.
#' @noRd
no_parse_documents <- function(html) {
  blocks <- rvest::html_elements(html, "div.n-filelist")
  if (length(blocks) == 0L) {
    return(list())
  }
  per_section <- list()
  for (block in blocks) {
    heading <- rvest::html_text2(rvest::html_element(block, "h2"))
    slug <- no_section_slug(heading)
    anchors <- rvest::html_elements(block, "a[href]")
    urls <- character(0)
    for (a in anchors) {
      href <- rvest::html_attr(a, "href")
      if (is.na(href) || !nzchar(href)) {
        next
      }
      if (!grepl("webfileservice\\.nve\\.no/API/PublishedFiles/Download", href)) {
        next
      }
      urls <- c(urls, no_absolute_url(href))
    }
    urls <- unique(urls[nzchar(urls)])
    if (length(urls) > 0L) {
      per_section[[slug]] <- unique(c(per_section[[slug]], urls))
    }
  }
  per_section
}

#' Build a 1-row record tibble from a license record object + parsed documents.
#'
#' Conventional planscanR columns are filled from the API fields; English
#' snake_case extras keep Norwegian values verbatim. Per-section attachment
#' columns come from the detail page's `div.n-filelist` sections.
#' @noRd
no_build_record <- function(url, raw, per_section = list()) {
  soknad_id <- no_field(raw, "SoknadId") %||% "record"
  document_id <- no_document_id(soknad_id)

  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "no",
    source_portal = no_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = no_field(raw, "Tittel") %||% NA_character_,
    summary = NA_character_,
    competent_authority = no_competent_authority(),
    proponent = no_field(raw, "Tiltakshaver") %||% NA_character_,
    date_published = parse_iso_date(no_field(raw, "Dato")),
    date_decision = as.Date(NA),
    native_type = no_field(raw, "Sakstype") %||% NA_character_,
    status = no_field(raw, "Status") %||% no_field(raw, "Stadium") %||% NA_character_,
    county = no_field(raw, "Fylke") %||% NA_character_,
    municipality = no_field(raw, "Kommune") %||% NA_character_,
    case_type = no_field(raw, "Sakstype") %||% NA_character_,
    case_type_id = no_field(raw, "SakstypeID") %||% NA_character_,
    case_type_code = no_field(raw, "Type") %||% NA_character_,
    stage = no_field(raw, "Stadium") %||% NA_character_,
    progress = no_field(raw, "Fremdrift") %||% NA_character_,
    hearing_deadline = no_field(raw, "HoeringsfristText") %||% NA_character_,
    mw = no_field(raw, "MW") %||% NA_character_,
    gwh = no_field(raw, "GWh") %||% NA_character_,
    installed_effect = no_field(raw, "InstallertEffekt") %||% NA_character_,
    estimated_production = no_field(raw, "EstimertProduksjon") %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Slug an NVE section heading to an ASCII column-suffix slug.
#'
#' Transliterates the Norwegian vowels that show up in headings, then folds to
#' an ASCII slug. Empty input gets `"dokumenter"` as a deterministic fallback.
#' @noRd
no_section_slug <- function(heading) {
  if (is.null(heading) || !is.character(heading) || length(heading) != 1L || is.na(heading) || !nzchar(heading)) {
    return("dokumenter")
  }
  ascii_slug(no_transliterate(heading), "dokumenter")
}

#' Transliterate Norwegian diacritics to ASCII (for slugs only).
#' @noRd
no_transliterate <- function(s) {
  from <- c("æ", "ø", "å", "Æ", "Ø", "Å")
  to <- c("ae", "oe", "aa", "ae", "oe", "aa")
  for (i in seq_along(from)) {
    s <- gsub(from[i], to[i], s, fixed = TRUE)
  }
  s
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed NO record: run downloads (if requested) and write sidecar.
#' @noRd
no_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)
  section_urls <- stats::setNames(
    lapply(section_cols, function(cn) rec[[cn]][[1]]),
    sub("^attachment_urls_", "", section_cols)
  )
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "no"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "no",
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

#' Apply post-fetch client-side filters (`date_range`).
#'
#' `query` is honoured server-side (the API `filterText` param), so by the time
#' a record arrives here it has already passed it. Only `date_range` is
#' enforced here, against `date_published`.
#' @noRd
no_record_matches <- function(rec, date_range = NULL) {
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Read a scalar field from a license object, returning NULL when absent / empty.
#'
#' Numeric fields (e.g. `MW`, `SoknadId`) come back as doubles; coerce to a
#' trimmed character. Returns a non-empty character or NULL.
#' @noRd
no_field <- function(raw, key) {
  if (is.null(raw) || !is.list(raw)) {
    return(NULL)
  }
  v <- raw[[key]]
  if (is.null(v) || length(v) != 1L || is.list(v)) {
    return(NULL)
  }
  # Integers/doubles that are whole numbers print without a trailing ".0".
  if (is.numeric(v) && !is.na(v) && v == as.integer(v)) {
    v <- as.integer(v)
  }
  s <- trimws(as.character(v))
  if (is.na(s) || !nzchar(s)) NULL else s
}
