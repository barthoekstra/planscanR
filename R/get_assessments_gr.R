#' Fetch environmental-assessment records from Greece.
#'
#' Implementation of [get_assessments()] for the Greek **ΗΠΜ / EPRM**
#' (Ηλεκτρονικό Περιβαλλοντικό Μητρώο — Electronic Environmental Registry),
#' the Ministry of Environment & Energy's (ΥΠΕΝ) public registry of
#' environmental-permit decisions, served by a public JSON:API at
#' `api.eprm.ypen.gr`.
#'
#' @section What this handler returns (IMPORTANT — decisions only):
#' The public registry exposes **AEPO decisions only** — *Αποφάσεις Έγκρισης
#' Περιβαλλοντικών Όρων* (decisions approving the environmental terms of a
#' project), i.e. the regulatory **output** of the EIA (ΜΠΕ) process. The
#' underlying **ΜΠΕ study files and all ΣΜΠΕ / SEA records are behind the
#' gov.gr login** on `platform.eprm.ypen.gr` and are **not** reachable here.
#' So each record carries the decision metadata plus (at most) one decision
#' PDF — never the EIA study itself, and the SEA register is entirely
#' out of scope. Plan for a decisions-only corpus when using this handler.
#'
#' @section URL enumeration:
#' The portal is a SPA backed by a public, no-auth **JSON:API**. Listing is
#' `GET /v1/license-decisions`, paginated via JSON:API page parameters
#' (`page[number]`, 1-based; `page[size]`, default 100). Each list row is
#' **already the full record** — there is no separate detail call needed
#' (though `GET /v1/license-decisions/{id}` exists). The walk follows
#' `meta.total` / `links.next` until the register is exhausted (≈19,800
#' records). Every request carries `Accept: application/json`.
#'
#' Server-side JSON:API `filter[...]` parameters honoured here:
#' * `query` -> `filter[text_search]` (free-text over project/decision fields).
#' * `type` -> `filter[type]` (decision-type enum; see
#'   [get_assessments_coverage()] / `eprm_gr_facets()`).
#' * `date_range` -> `filter[issued_after]` / `filter[issued_before]` (matched
#'   server-side on the decision issue date), re-checked client-side as a guard.
#'
#' @section Geometry:
#' A record's `project_location` is an array of `{lat, lon}` pairs. When
#' present, the first pair is written as a **Point** geometry next to the
#' sidecar as `<document_id>.geometry.geojson`, in the family FeatureCollection
#' layout with the GeoJSON-2008 `crs` member naming
#' `urn:ogc:def:crs:EPSG::4326`. The coordinates are already geographic
#' **WGS84 (EPSG:4326)** — *not* the Greek Grid (EPSG:2100) — so no
#' reprojection happens. The sidecar carries `geometry_path` and
#' `geometry_crs` (`"EPSG:4326"`). Records with no `project_location` leave the
#' geometry columns `NA`.
#'
#' @section Attachments:
#' At most one document per decision — the AEPO decision PDF — taken verbatim
#' from `record.diavgeia_doc_url` (hosted on Διαύγεια / Diavgeia, the Greek
#' government transparency portal, form
#' `https://diavgeia.gov.gr/luminapi/api/decisions/{ADA}/document.pdf`; the ADA
#' contains Greek characters, left for `httr2` to percent-encode at request
#' time). It is emitted under the single slug `attachment_urls_aepo` /
#' `local_path_aepo`, with the deduplicated union at `attachment_urls` /
#' `local_path` (required by the schema). Records whose `diavgeia_doc_url` is
#' `null` yield zero attachments (still schema-valid).
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side full-text (`filter[text_search]`).
#' * `type` — server-side decision-type enum (`filter[type]`), e.g.
#'   `"aepo_creation"`; see `eprm_gr_facets()`.
#' * `date_range` — server-side window on the issue date
#'   (`filter[issued_after]` / `filter[issued_before]`), re-checked client-side
#'   against `date_decision`. `date_published` is the registry publication
#'   timestamp.
#'
#' @section Performance:
#' Enumeration is ≈200 paginated list calls (no per-record detail fetch). GR
#' requests are throttled to 5 requests per second by default; override via
#' `getOption("planscanR.gr_throttle_rate")` (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query; sent server-side as `filter[text_search]`.
#' @param type Optional decision-type code (server-side `filter[type]`), e.g.
#'   `"aepo_creation"`. See `eprm_gr_facets()` for the enum.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test (AEPO decisions only)
#' get_assessments_gr(limit = 3, download = FALSE)
#'
#' # Photovoltaic-themed slice (server-side full-text, Greek)
#' get_assessments_gr(query = "φωτοβολταϊκ", limit = 20, download = FALSE)
#'
#' # New AEPO approvals only
#' get_assessments_gr(type = "aepo_creation", limit = 20, download = FALSE)
#' }
get_assessments_gr <- function(
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
  type = NULL,
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
  # Politeness throttle. Enumeration is ~200 list calls plus one download per
  # attachment; cap at 5 req/s by default. Override via
  # `planscanR.gr_throttle_rate`.
  rate <- getOption("planscanR.gr_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "gr")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("gr")
  } else {
    stats::setNames(character(0), character(0))
  }

  index <- tryCatch(
    gr_fetch_records(query = query, type = type, date_range = date_range, limit = limit),
    error = function(e) {
      warn_partial("Failed to enumerate the EPRM registry: {conditionMessage(e)}")
      list()
    }
  )

  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling GR  ",
      "records {length(records)}",
      if (is.finite(limit)) paste0("/", limit) else paste0("/", length(index)),
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = if (is.finite(limit)) limit else length(index),
    clear = FALSE
  )
  on.exit(cli::cli_progress_done(), add = TRUE)

  for (entry in index) {
    if (length(records) >= limit) {
      break
    }
    id <- gr_record_id(entry)
    if (is.null(id)) {
      next
    }
    u <- gr_canonical_url(id)
    rec <- tryCatch(
      gr_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial(
          "Failed to load/parse {.url {u}}: {conditionMessage(e)}"
        )
        NULL
      }
    )
    if (is.null(rec)) {
      next
    }
    if (!gr_record_matches(rec, date_range = date_range)) {
      next
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    rec <- gr_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
    records[[length(records) + 1L]] <- rec
    cli::cli_progress_update()
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
gr_source_portal <- function() "eprm.ypen.gr"

#' Public landing-page base for the portal (where a human would open a record).
#' @noRd
gr_portal_base <- function() "https://eprm.ypen.gr"

#' JSON:API base for the EPRM service.
#' @noRd
gr_api_base <- function() "https://api.eprm.ypen.gr/v1"

#' Default JSON:API page size for the listing walk.
#' @noRd
gr_page_size <- function() 100L

#' Canonical landing URL for a record (HTML SPA detail route).
#'
#' The SPA page itself is robots-disallowed for crawling; we use it only as the
#' human-facing `url` and harvest everything from the JSON:API.
#' @noRd
gr_canonical_url <- function(id) {
  sprintf("%s/aepoView/%s", gr_portal_base(), id)
}

#' EPSG code of the geometry payloads. EPRM serves WGS84 lat/lon.
#' @noRd
gr_geometry_crs <- function() "EPSG:4326"

#' Known decision-type codes exposed by the API's `/license-decision-types`.
#'
#' Surfaced as the `type` server-side filter vocabulary; `aepo_*` are the
#' AEPO-decision variants, `pppa_creation` is the (rarer) PPPA variant.
#' @noRd
gr_decision_types <- function() {
  c(
    "aepo_creation",
    "aepo_essential_modification",
    "aepo_nonessential_modification",
    "aepo_renewal",
    "aepo_essential_modification_and_renewal",
    "aepo_nonessential_modification_and_renewal",
    "aepo_terms_review_and_revision",
    "pppa_creation"
  )
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Paginate `GET /v1/license-decisions` and return the full list of records.
#'
#' Each row is already the full record. Pagination is JSON:API style
#' (`page[number]` 1-based, `page[size]`); `meta.total` bounds the walk and a
#' missing / empty `data` page stops it. Server-side filters (`text_search`,
#' `type`, `issued_after` / `issued_before`) are forwarded as `filter[...]`.
#' We early-exit once we have comfortably more than `limit` rows (the caller may
#' still filter some out).
#' @noRd
gr_fetch_records <- function(query = NULL, type = NULL, date_range = NULL, limit = Inf) {
  out <- list()
  page <- 1L
  size <- gr_page_size()
  repeat {
    req <- req_planscanr(gr_api_base())
    req <- httr2::req_url_path_append(req, "license-decisions")
    req <- httr2::req_headers(req, Accept = "application/json")
    req <- httr2::req_url_query(req, "page[number]" = page, "page[size]" = size)
    if (!is.null(query) && nzchar(query)) {
      req <- httr2::req_url_query(req, "filter[text_search]" = query)
    }
    if (!is.null(type) && nzchar(type)) {
      req <- httr2::req_url_query(req, "filter[type]" = type)
    }
    if (!is.null(date_range)) {
      req <- httr2::req_url_query(
        req,
        "filter[issued_after]" = format(date_range[1], "%Y-%m-%d"),
        "filter[issued_before]" = format(date_range[2], "%Y-%m-%d")
      )
    }
    payload <- perform_json(req)
    if (!is.list(payload)) {
      break
    }
    data <- payload$data %||% list()
    if (length(data) == 0L) {
      break
    }
    out <- c(out, data)
    total <- as.integer((payload$meta %||% list())$total %||% length(out))
    if (length(out) >= total) {
      break
    }
    # Soft stop: stop paginating once we've enumerated comfortably more than
    # `limit` raw rows (the caller may still filter the list).
    if (is.finite(limit) && length(out) >= as.integer(limit) * 2L + size) {
      break
    }
    page <- page + 1L
  }
  out
}

# -----------------------------------------------------------------------------
# Record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else parse the record.
#'
#' When the sidecar is missing, parses the inline record into a 1-row tibble
#' and (when the record carries a `project_location`) saves a Point geometry to
#' a sibling `.geometry.geojson` so subsequent runs pick it up offline.
#' @noRd
gr_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  rec <- gr_parse_record(url, entry)
  geometry <- gr_geometry_of(entry)
  if (write_sidecar && !is.null(geometry)) {
    geo_path <- gr_save_geometry_to_geojson(
      country = "gr",
      document_id = rec$document_id,
      title = rec$title,
      created_iso = gr_text(entry$published_at),
      geometry = geometry
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- gr_geometry_crs()
    }
  }
  rec
}

#' Build a 1-row record tibble from one inline EPRM license-decision object.
#'
#' Maps the registry's fields onto the conventional planscanR columns, keeps
#' the source vocabulary verbatim (no normalisation at fetch time), and emits
#' the single `attachment_urls_aepo` / `local_path_aepo` pair for the decision
#' PDF when one is present.
#' @noRd
gr_parse_record <- function(url, entry) {
  id <- gr_record_id(entry)
  title <- gr_text(entry$project_name) %||%
    gr_text(entry$application_name) %||%
    NA_character_

  native_type <- gr_native_type(entry)
  proponent <- gr_text(entry$project_carrier_name) %||% NA_character_
  competent_authority <- gr_text((entry$license_authority %||% list())$name) %||%
    NA_character_
  jurisdiction <- gr_jurisdiction(entry$project_municipal_units) %||% NA_character_
  status <- gr_text(entry$outcome) %||% NA_character_

  date_published <- gr_parse_iso_date(entry$published_at)
  date_decision <- gr_parse_iso_date(entry$issued_at)

  doc_url <- gr_attachment_url(entry)
  per_section <- list()
  if (!is.null(doc_url)) {
    per_section[["aepo"]] <- doc_url
  }
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "gr",
    source_portal = gr_source_portal(),
    document_id = id %||% NA_character_,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    # No narrative abstract in the registry; classifier works off title +
    # native_type (the project-type taxonomy).
    summary = NA_character_,
    competent_authority = competent_authority,
    proponent = proponent,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction,
    status = status,
    decision_type = gr_text(entry$type) %||% NA_character_,
    project_category = gr_text(entry$project_category) %||% NA_character_,
    project_pet = gr_text(entry$project_pet) %||% NA_character_,
    project_natura2000 = gr_lgl(entry$project_natura2000),
    project_carrier_afm = gr_text(entry$project_carrier_afm) %||% NA_character_,
    doc_ada = gr_text(entry$doc_ada) %||% NA_character_,
    doc_protocol = gr_text(entry$doc_protocol) %||% NA_character_,
    source = gr_text(entry$source) %||% NA_character_,
    geometry_path = NA_character_,
    geometry_crs = NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Extract the stable record id (as a character document_id).
#' @noRd
gr_record_id <- function(entry) {
  gr_text(entry$id)
}

#' Compose `native_type` from the decision type + project-type taxonomy names.
#'
#' Keeps the Greek vocabulary verbatim (no normalisation) — the classifier
#' consumes it downstream.
#' @noRd
gr_native_type <- function(entry) {
  parts <- character(0)
  dt <- gr_text(entry$type)
  if (!is.null(dt)) {
    parts <- c(parts, dt)
  }
  pts <- entry$project_project_types %||% list()
  names <- vapply(
    pts,
    function(p) gr_text(p$name) %||% NA_character_,
    character(1)
  )
  names <- names[!is.na(names)]
  if (length(names) > 0L) {
    parts <- c(parts, paste(names, collapse = "; "))
  }
  if (length(parts) == 0L) {
    return(NULL)
  }
  paste(parts, collapse = " | ")
}

#' Compose a `jurisdiction` string from the nested municipal-unit objects.
#'
#' Each unit nests `municipality -> regional_unit -> region`; we emit
#' `region / regional_unit / municipality` per unit, joined with "; ".
#' @noRd
gr_jurisdiction <- function(units) {
  if (is.null(units) || length(units) == 0L) {
    return(NULL)
  }
  pieces <- vapply(
    units,
    function(u) {
      mun <- u$municipality %||% list()
      ru <- mun$regional_unit %||% list()
      reg <- ru$region %||% list()
      parts <- c(
        gr_text(reg$lowercase_name),
        gr_text(ru$lowercase_name),
        gr_text(mun$lowercase_name)
      )
      parts <- parts[!vapply(parts, is.null, logical(1))]
      if (length(parts) == 0L) NA_character_ else paste(unlist(parts), collapse = " / ")
    },
    character(1)
  )
  pieces <- pieces[!is.na(pieces)]
  if (length(pieces) == 0L) {
    return(NULL)
  }
  paste(unique(pieces), collapse = "; ")
}

#' The decision-PDF attachment URL for a record, or NULL.
#'
#' Taken verbatim from `diavgeia_doc_url`; the ADA in the path contains Greek
#' characters which are left for `httr2` to percent-encode at request time.
#' @noRd
gr_attachment_url <- function(entry) {
  gr_text(entry$diavgeia_doc_url)
}

#' Pull a Point geometry from a record's `project_location` array.
#'
#' Returns a bare GeoJSON Point geometry (`{type:"Point", coordinates:[lon,lat]}`)
#' built from the first `{lat, lon}` pair, or NULL when no usable location is
#' present.
#' @noRd
gr_geometry_of <- function(entry) {
  loc <- entry$project_location
  if (is.null(loc) || !is.list(loc) || length(loc) == 0L) {
    return(NULL)
  }
  first <- loc[[1]]
  if (!is.list(first)) {
    return(NULL)
  }
  lat <- suppressWarnings(as.numeric(first$lat))
  lon <- suppressWarnings(as.numeric(first$lon))
  if (length(lat) != 1L || length(lon) != 1L || is.na(lat) || is.na(lon)) {
    return(NULL)
  }
  list(type = "Point", coordinates = c(lon, lat))
}

# -----------------------------------------------------------------------------
# Geometry -> linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save a record's Point geometry next to its sidecar as GeoJSON.
#'
#' Wraps the geometry in a `FeatureCollection`, tags the CRS via the
#' GeoJSON-2008 `crs` member (`urn:ogc:def:crs:EPSG::4326`), and persists it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`. Coordinates are kept in the
#' source EPSG:4326 (WGS84 lat/lon).
#' @noRd
gr_save_geometry_to_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  if (is.null(geometry$type) || !nzchar(geometry$type)) {
    return(NULL)
  }
  out_path <- gr_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", gr_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = gr_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = gr_geometry_crs()
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
gr_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed GR record: run downloads (if requested) and write sidecar.
#'
#' Threads the single `aepo` section so `attachment_urls_aepo` gets a parallel
#' `local_path_aepo` once the download status is known.
#' @noRd
gr_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "gr"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "gr",
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

#' Apply post-fetch client-side filters to a parsed GR record.
#'
#' `query` / `type` / `date_range` are handled server-side via the JSON:API
#' `filter[...]` parameters; `date_range` is re-checked client-side here as a
#' belt-and-braces guard (and so the sidecar-first path, which never sees the
#' filters, still honours the window). The window is matched against
#' `date_decision` (the issue date the server filters on).
#' @noRd
gr_record_matches <- function(rec, date_range) {
  if (!is.null(date_range)) {
    d <- rec$date_decision
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
gr_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Coerce a scalar to a logical, defaulting to NA.
#' @noRd
gr_lgl <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NA)
  }
  as.logical(x)
}

#' Parse an ISO-8601 / "YYYY-MM-DD HH:MM:SS" timestamp into a Date.
#' @noRd
gr_parse_iso_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(as.Date(substr(s, 1L, 10L)))
  if (length(d) == 0L) as.Date(NA) else d
}
