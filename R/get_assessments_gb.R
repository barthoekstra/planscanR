#' Fetch environmental-assessment records from the United Kingdom.
#'
#' Implementation of [get_assessments()] for the United Kingdom. Backed by the
#' Planning Inspectorate's **National Infrastructure Consenting** service
#' (<https://national-infrastructure-consenting.planninginspectorate.gov.uk/>),
#' the register of **Nationally Significant Infrastructure Projects (NSIPs)**.
#' Every NSIP application carries a statutory **Environmental Statement (ES)**,
#' so the register is an EIA-equivalent source; each row is therefore an
#' EIA-equivalent procedure and there is no `assessment_type` selector (this is
#' a single-register handler).
#'
#' Scope is **NSIP only**. Local-authority / Town-and-Country-Planning EIAs
#' (the much larger body of smaller English/Welsh consents) are *not* in this
#' register and are out of scope here.
#'
#' @section URL enumeration:
#' The whole register is published as a single bulk CSV export at
#' `…/api/applications-download` (≈540 rows). One GET fetches the entire
#' register; it is parsed with base [utils::read.csv()] (no new package
#' dependency). The handler's page generator returns every row on its first
#' call and then signals exhausted, respecting the global `limit`. The
#' canonical record URL is the project landing page
#' `…/projects/{REF}` where `{REF}` is the *Project reference* (e.g.
#' `EN010001`), which is the clean, path-safe, unique `document_id`.
#'
#' @section Attachments:
#' Per record (sidecar-first via the cache) the handler fetches the project's
#' Environmental Statement document list
#' (`…/projects/{REF}/documents?type=Environmental Statement`) and scrapes the
#' published-document PDF hrefs, which live on
#' `https://nsip-documents.planninginspectorate.gov.uk/published-documents/{REF}-{NNNNNN}-{title}.pdf`.
#' The list is **server-paginated**, so the handler walks every page
#' (`itemsPerPage = 100`, the portal maximum) and returns the deduplicated union
#' of hrefs — a large project (e.g. `EN010098` with >1,000 ES documents) yields
#' all of them, not just the first page. These become `attachment_urls` (a flat
#' list — no per-section split). A project with no ES documents yet yields an
#' empty `attachment_urls` vector, which is valid.
#'
#' @section Geometry (point):
#' Each row carries an Ordnance Survey National Grid point (*Grid reference -
#' Easting* / *Northing*). When both are present, a point `.geometry.geojson`
#' is written next to the sidecar (GeoJSON `Point`, OSGB36 **EPSG:27700**, with
#' the GeoJSON-2008 `crs` member naming `urn:ogc:def:crs:EPSG::27700`).
#' `geometry_path` (relative to the cache root, per schema v3) and
#' `geometry_crs` (`"EPSG:27700"`) are recorded on the sidecar. Coordinates are
#' kept in the source CRS — reproject downstream with `sf` if you need WGS84.
#' The raw easting/northing and the portal's WGS84 *GPS co-ordinates* string
#' are also surfaced as extras.
#'
#' @section Filter coverage (v0.1):
#' Every filter is applied **client-side** (the bulk export is unfiltered):
#'
#' * `query` — case-insensitive substring match on `title` (the project name).
#' * `date_range` — matched against `date_decision` when present, otherwise
#'    `date_published` (the application-accepted date).
#' * `status` — case-insensitive match on the portal *Stage* (e.g.
#'    `"Pre-application"`, `"Examination"`, `"Post-decision"`, `"Withdrawn"`).
#' * `limit` — caps the total number of records returned.
#'
#' @section Performance:
#' Enumeration is a single bulk-CSV GET plus, per record, one document-list GET
#' for each page of its Environmental Statement list — at `itemsPerPage = 100`
#' that is `ceil(n_ES_documents / 100)` fetches (one for most projects, ~12 for
#' the largest). All are sidecar-first, so repeat runs are fast. To honour the
#' portal's `robots.txt` `Crawl-delay: 10`, GB requests are throttled to 0.1
#' requests per second by default (one request every 10 s); override via
#' `getOption("planscanR.gb_throttle_rate")` (requests/sec; falsy disables).
#' The package's neutral `planscanR/…` User-Agent is allowed by the portal's
#' `robots.txt` (AI-crawler agents such as ClaudeBot / GPTBot / CCBot are
#' `Disallow: /`).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query. Applied as a client-side
#'   case-insensitive substring match on the project name.
#' @param status Optional project *Stage* (client-side, case-insensitive).
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_gb(limit = 3, download = FALSE)
#'
#' # Substring query on the project name
#' get_assessments_gb(query = "solar", limit = 20, download = FALSE)
#'
#' # Only projects at the Examination stage
#' get_assessments_gb(status = "Examination", limit = 20, download = FALSE)
#'
#' # Date range (matched against the decision / acceptance date)
#' get_assessments_gb(
#'   date_range = c("2020-01-01", "2020-12-31"),
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_gb <- function(
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
  status = NULL,
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
  # Politeness throttle: the portal's robots.txt sets Crawl-delay: 10, so cap
  # at 0.1 req/s (one request every 10 s) by default. Override via
  # `planscanR.gb_throttle_rate`.
  rate <- getOption("planscanR.gb_throttle_rate", 0.1)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "gb")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("gb")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Per-entry processing: sidecar-first detail fetch (for ES attachments),
  # client-side filters, relevance scoring, optional download, and the sidecar
  # write. Returns the 1-row record or NULL to drop the entry.
  process_entry <- function(entry) {
    u <- gb_canonical_url(entry$reference)
    rec <- tryCatch(
      gb_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!gb_record_matches(rec, date_range = date_range, query = query, status = status)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    gb_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  gen <- tryCatch(
    gb_fetch_search(),
    error = function(e) {
      warn_partial(
        "Failed to enumerate the NSIP applications export: {conditionMessage(e)}"
      )
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "gb")

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
gb_source_portal <- function() "planninginspectorate.gov.uk"

#' Public base URL for the NSIP consenting portal.
#' @noRd
gb_portal_base <- function() {
  "https://national-infrastructure-consenting.planninginspectorate.gov.uk"
}

#' Host serving the published Environmental Statement PDFs.
#' @noRd
gb_documents_host <- function() {
  "https://nsip-documents.planninginspectorate.gov.uk"
}

#' Competent authority for every UK NSIP record (fixed national body).
#' @noRd
gb_competent_authority <- function() "Planning Inspectorate"

#' EPSG code of the point geometry (Ordnance Survey National Grid, OSGB36).
#' @noRd
gb_geometry_crs <- function() "EPSG:27700"

#' Canonical landing URL for a project record.
#' @noRd
gb_canonical_url <- function(reference) {
  sprintf("%s/projects/%s", gb_portal_base(), reference)
}

#' Document-list URL for one page of a project's Environmental Statement docs.
#'
#' The list is server-paginated; `itemsPerPage = 100` (the portal's maximum)
#' minimises the number of throttled requests, and `page` selects the 1-based
#' page. Defaults reproduce the first page at the largest page size.
#' @noRd
gb_documents_url <- function(reference, page = 1L, items_per_page = 100L) {
  req <- req_planscanr(gb_portal_base())
  req <- httr2::req_url_path_append(req, "projects", reference, "documents")
  req <- httr2::req_url_query(
    req,
    type = "Environmental Statement",
    itemsPerPage = items_per_page,
    page = page
  )
  req$url
}

# -----------------------------------------------------------------------------
# Bulk-export enumeration
# -----------------------------------------------------------------------------

#' Build a page generator over the NSIP applications bulk CSV export.
#'
#' The export is not paginated: a single GET returns the whole register as one
#' CSV. The generator yields all rows on its first call (mapped into lightweight
#' named lists), then signals exhausted. Pagination state lives in the closure
#' to satisfy the `stream_crawl()` contract.
#' @noRd
gb_fetch_search <- function() {
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    req <- req_planscanr(gb_portal_base())
    req <- httr2::req_url_path_append(req, "api", "applications-download")
    text <- tryCatch(
      {
        resp <- httr2::req_perform(req)
        httr2::resp_body_string(resp)
      },
      error = function(e) NULL
    )
    if (is.null(text) || !nzchar(text)) {
      return(NULL)
    }
    gb_map_rows(gb_parse_csv(text))
  }
}

#' Parse the bulk CSV text into a data frame with verbatim column names.
#' @noRd
gb_parse_csv <- function(text) {
  utils::read.csv(
    text = text,
    check.names = FALSE,
    stringsAsFactors = FALSE,
    colClasses = "character"
  )
}

#' Map a parsed CSV data frame into lightweight listing entries.
#'
#' Each entry is a small named list carrying the row's fields and a stable
#' `reference` (Project reference). Rows without a reference are skipped.
#' @noRd
gb_map_rows <- function(df) {
  if (is.null(df) || nrow(df) == 0L) {
    return(list())
  }
  out <- list()
  for (i in seq_len(nrow(df))) {
    row <- as.list(df[i, , drop = FALSE])
    reference <- gb_field(row, "Project reference")
    if (is.null(reference)) {
      next
    }
    out[[length(out) + 1L]] <- list(reference = reference, row = row)
  }
  out
}

# -----------------------------------------------------------------------------
# Detail-record building
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else build + scrape.
#'
#' When the sidecar is missing, builds the record from the CSV row, scrapes the
#' ES document list, and (when the row carries a grid reference) saves the point
#' geometry to a sibling `.geometry.geojson`.
#' @noRd
gb_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  attachments <- gb_fetch_attachments(entry$reference)
  parsed <- gb_build_record(url, entry, attachments)
  rec <- parsed$record
  if (write_sidecar && !is.null(parsed$geometry)) {
    geo_path <- gb_save_point_geojson(
      country = "gb",
      document_id = rec$document_id,
      title = rec$title,
      created_iso = if (is.na(rec$date_published)) NULL else format(rec$date_published, "%Y-%m-%d"),
      geometry = parsed$geometry
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- gb_geometry_crs()
    }
  }
  rec
}

#' Hard cap on ES document-list pages fetched per project.
#'
#' At `itemsPerPage = 100` this bounds the crawl to 10,000 documents — far above
#' the largest real NSIP library — and prevents a runaway loop should the portal
#' ever clamp out-of-range pages to the last page instead of ending pagination.
#' @noRd
gb_max_doc_pages <- function() 100L

#' Does an ES document-list page advertise a *Next* page?
#'
#' Detects the `moj-pagination` "Next" control; absent on the last (or only)
#' page.
#' @noRd
gb_has_next_page <- function(html) {
  length(rvest::html_elements(html, "li.moj-pagination__item--next a")) > 0L
}

#' Fetch a project's ES document list and scrape its published-document PDFs.
#'
#' The list is server-paginated, so this walks every page (`itemsPerPage = 100`)
#' and returns the deduplicated union of published-document PDF hrefs. Paging
#' stops at the last page (no *Next* control), when a page adds no new href
#' (a defensive guard against the portal clamping out-of-range pages), or at the
#' `gb_max_doc_pages()` cap. A failed page fetch ends the walk and returns
#' whatever was gathered so far rather than dropping the whole record.
#' @noRd
gb_fetch_attachments <- function(reference) {
  urls <- character(0)
  page <- 1L
  max_pages <- gb_max_doc_pages()
  repeat {
    req <- req_planscanr(gb_documents_url(reference, page = page))
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      break
    }
    new_urls <- setdiff(gb_parse_attachments(html), urls)
    urls <- c(urls, new_urls)
    if (!gb_has_next_page(html) || length(new_urls) == 0L || page >= max_pages) {
      break
    }
    page <- page + 1L
  }
  urls
}

#' Parse published-document PDF hrefs from an ES document-list page.
#'
#' Collects every `a.section-results__result-link` whose href is on the
#' published-documents host, deduplicated.
#' @noRd
gb_parse_attachments <- function(html) {
  anchors <- rvest::html_elements(html, "a.section-results__result-link")
  if (length(anchors) == 0L) {
    return(character(0))
  }
  hrefs <- rvest::html_attr(anchors, "href")
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  hrefs <- hrefs[startsWith(hrefs, gb_documents_host())]
  if (length(hrefs) == 0L) {
    return(character(0))
  }
  unique(hrefs)
}

#' Build a 1-row record tibble (+ point geometry) from a CSV row entry.
#'
#' Returns `list(record = <tibble>, geometry = <list or NULL>)`. The geometry is
#' a bare GeoJSON Point (coordinates in EPSG:27700); the caller persists it next
#' to the sidecar.
#' @noRd
gb_build_record <- function(url, entry, attachments) {
  row <- entry$row
  reference <- entry$reference

  title <- gb_field(row, "Project name")
  proponent <- gb_field(row, "Applicant name")
  native_type <- gb_field(row, "Application type")
  status <- gb_field(row, "Stage")
  summary_text <- gb_field(row, "Description")
  region <- gb_field(row, "Region")
  project_location <- gb_field(row, "Location")
  grid_easting <- gb_field(row, "Grid reference - Easting")
  grid_northing <- gb_field(row, "Grid reference - Northing:")
  gps_coordinates <- gb_field(row, "GPS co-ordinates")

  date_decision <- parse_iso_date(gb_field(row, "Date of decision"))
  date_published <- parse_iso_date(gb_field(row, "Date application accepted"))
  if (is.na(date_published)) {
    date_published <- parse_iso_date(gb_field(row, "Date of application"))
  }

  attachments <- attachments %||% character(0)
  geometry <- gb_point_geometry(grid_easting, grid_northing)

  rec <- tibble::tibble(
    country = "gb",
    source_portal = gb_source_portal(),
    document_id = reference,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(attachments),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    summary = summary_text %||% NA_character_,
    competent_authority = gb_competent_authority(),
    proponent = proponent %||% NA_character_,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    status = status %||% NA_character_,
    # Country-specific extras (English snake_case, verbatim values).
    region = region %||% NA_character_,
    project_location = project_location %||% NA_character_,
    grid_easting = grid_easting %||% NA_character_,
    grid_northing = grid_northing %||% NA_character_,
    gps_coordinates = gps_coordinates %||% NA_character_,
    date_application = gb_field(row, "Date of application") %||% NA_character_,
    date_examination_started = gb_field(row, "Date Examination started") %||% NA_character_,
    date_examination_closed = gb_field(row, "Date Examination closed") %||% NA_character_,
    date_recommendation = gb_field(row, "Date of recommendation") %||% NA_character_,
    date_withdrawn = gb_field(row, "Date withdrawn") %||% NA_character_,
    anticipated_submission = gb_field(row, "Anticipated submission period") %||% NA_character_,
    geometry_path = NA_character_,
    geometry_crs = NA_character_,
    download_status = list(empty_download_status())
  )
  list(record = rec, geometry = geometry)
}

#' Build a bare GeoJSON Point from easting / northing strings, or NULL.
#'
#' Coordinates are kept in the source EPSG:27700 (OSGB National Grid).
#' @noRd
gb_point_geometry <- function(easting, northing) {
  x <- suppressWarnings(as.numeric(easting))
  y <- suppressWarnings(as.numeric(northing))
  if (length(x) != 1L || length(y) != 1L || is.na(x) || is.na(y)) {
    return(NULL)
  }
  list(type = "Point", coordinates = c(x, y))
}

#' Read a scalar field from a CSV row, returning NULL when absent / empty.
#' @noRd
gb_field <- function(row, key) {
  v <- row[[key]]
  if (is.null(v) || length(v) != 1L) {
    return(NULL)
  }
  s <- trimws(as.character(v))
  if (is.na(s) || !nzchar(s)) NULL else s
}

# -----------------------------------------------------------------------------
# Geometry -> linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save a record's Point geometry next to its sidecar as GeoJSON.
#'
#' Wraps the geometry in a `FeatureCollection`, tags the CRS via the
#' GeoJSON-2008 `crs` member (`urn:ogc:def:crs:EPSG::27700`), and persists it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`. Coordinates are kept in the
#' source EPSG:27700 (Ordnance Survey National Grid).
#' @noRd
gb_save_point_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  if (is.null(geometry$type) || !nzchar(geometry$type)) {
    return(NULL)
  }
  out_path <- gb_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", gb_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = gb_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = gb_geometry_crs()
        )
      )
    )
  )
  tmp <- tempfile(tmpdir = dirname(out_path), fileext = ".geojson")
  on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
  writeLines(
    jsonlite::toJSON(feature, auto_unbox = TRUE, digits = NA, null = "null"),
    con = tmp,
    useBytes = TRUE
  )
  file.rename(tmp, out_path)
  out_path
}

#' Path to a record's geometry geojson (always alongside its sidecar JSON).
#' @noRd
gb_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed GB record: run downloads (if requested) and write sidecar.
#' @noRd
gb_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "gb"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "gb",
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

#' Apply client-side filters to a single parsed GB record.
#'
#' `query` is a case-insensitive substring match on the title. `date_range`
#' matches `date_decision` when present, otherwise `date_published`. `status`
#' is a case-insensitive match on the portal Stage.
#' @noRd
gb_record_matches <- function(rec, date_range, query, status) {
  if (!is.null(query) && nzchar(query)) {
    t <- rec$title %||% ""
    if (!grepl(query, t, ignore.case = TRUE, fixed = FALSE)) {
      return(FALSE)
    }
  }
  if (!is.null(status) && nzchar(status)) {
    s <- rec$status %||% ""
    if (!identical(tolower(trimws(s)), tolower(trimws(status)))) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    d <- rec$date_decision
    if (is.na(d)) {
      d <- rec$date_published
    }
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}
