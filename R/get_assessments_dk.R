#' Fetch environmental-assessment records from Denmark.
#'
#' Implementation of [get_assessments()] for Denmark. Backed by Danmarks
#' Miljøportal's EA-Hub (<https://eahub.miljoeportal.dk/>), the national
#' register for both EIA ("miljøvurdering af projekter", the old VVM /
#' *Miljøkonsekvensrapport*) and SEA ("miljøvurdering af planer",
#' *miljørapport*).
#'
#' @section URL enumeration:
#' EA-Hub is a Vue SPA sitting on a public REST API at
#' `https://eahub.miljoeportal.dk/api/` (Swagger lives at
#' `/api/swagger/v1/swagger.json`). One `POST /assessments/search` call
#' returns the entire register (~2700 records at the time of writing); each
#' row already carries title, year range, status, authorities, EIA-Directive
#' Annex I/II categories, plan types/categories, and a `hasGeometry` flag.
#' No detail call is needed during the scan phase — every field a downstream
#' classifier needs is present in the search response.
#'
#' @section Geometry:
#' Records with `hasGeometry == TRUE` carry a polygon (typically a
#' MULTIPOLYGON in EPSG:25832 / ETRS89-UTM32N — the standard Danish
#' projection). When `write_sidecar = TRUE`, the geometry is fetched from
#' `GET /assessments/{id}/geometry` and saved next to the sidecar as
#' `<document_id>.geometry.geojson`. The sidecar carries `geometry_path`
#' (absolute path to the .geojson) and `geometry_crs` (`"EPSG:25832"`).
#'
#' The GeoJSON is written with the GeoJSON-2008 `crs` member naming
#' `urn:ogc:def:crs:EPSG::25832`; tools like QGIS / `sf::read_sf()` read
#' this fine, even though RFC 7946 deprecated the field. Coordinates are
#' kept in the source CRS — reproject downstream with `sf` if you need
#' WGS84.
#'
#' @section Attachments:
#' EA-Hub exposes PDFs at public Azure blob URLs reachable via
#' `GET /assessments/{id}/documents/{docId}/links`, but resolving those
#' costs an extra HTTP call per document. The current handler is
#' **scan + classify only**: it returns `attachment_urls = character(0)`
#' and an empty `download_status` for every record. A future download
#' phase will fetch the per-document links and populate the per-section
#' columns. Reflected as `"supported (metadata-only)"` in
#' `get_assessments_coverage()`.
#'
#' @section Filter coverage (v0.1):
#' * `query` — forwarded to the API's server-side `freeText` field.
#' * `assessment_type` — one of `"All"` (default), `"Plans"`, or
#'   `"Project"`. API-defined values; client API accepts these only.
#' * `date_range` — matched client-side against each record's `fromYear`
#'   / `toYear` (treated as Jan 1 – Dec 31 spans). `date_decision` is
#'   always `NA` because EA-Hub exposes only year fields, no decision
#'   timestamp.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()]. `download`, `overwrite`, and
#'   `max_file_size_mb` are accepted for API symmetry but currently
#'   ignored — no PDFs are fetched in this version.
#' @param query Free-text query; forwarded to the API's `freeText`.
#' @param assessment_type One of `"All"`, `"Plans"`, `"Project"`.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_dk(limit = 3, download = FALSE)
#'
#' # Wind-themed slice
#' get_assessments_dk(query = "vindmølle", limit = 20, download = FALSE)
#'
#' # Plans only
#' get_assessments_dk(assessment_type = "Plans", download = FALSE)
#' }
get_assessments_dk <- function(
  date_range = NULL,
  limit = Inf,
  download = TRUE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  assessment_type = "All",
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  assessment_type <- dk_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  # Be polite. The DK throttle is opt-in: handlers calling thousands of
  # tiny geometry GETs (one per record-with-geometry) shouldn't hammer
  # the Azure backend. The user can override via the option.
  rate <- getOption("planscanR.dk_throttle_rate", 5)
  withr::local_options(list(planscanR.throttle_rate = rate))

  rel <- setup_relevance(topic, relevance_model, country = "dk")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("dk")
  } else {
    stats::setNames(character(0), character(0))
  }

  index <- tryCatch(
    dk_fetch_search(assessment_type = assessment_type, free_text = query),
    error = function(e) {
      warn_partial("Failed to fetch EA-Hub search index: {conditionMessage(e)}")
      list()
    }
  )

  # Cheap pre-filter: drop entries whose year span cannot overlap the
  # window before paying for any geometry call.
  if (!is.null(date_range)) {
    index <- Filter(
      function(e) dk_year_in_range(e$fromYear, e$toYear, date_range),
      index
    )
  }

  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling DK  ",
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
    u <- dk_canonical_url(entry$id)
    rec <- tryCatch(
      dk_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
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
    if (!dk_record_matches(rec, date_range = date_range)) {
      next
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    rec <- dk_finalise_record(rec, write_sidecar = write_sidecar)
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
dk_source_portal <- function() "miljoeportal.dk/eahub"

#' Base URL for the EA-Hub REST API.
#' @noRd
dk_api_base <- function() "https://eahub.miljoeportal.dk/api/"

#' Canonical landing URL for an assessment id (Vue SPA detail route).
#' @noRd
dk_canonical_url <- function(id) {
  sprintf("https://eahub.miljoeportal.dk/assessment-detail/%s", id)
}

#' EPSG code of the geometry payloads returned by EA-Hub.
#'
#' EA-Hub serves Danish projected coordinates in ETRS89 / UTM zone 32N
#' (EPSG:25832). Recorded on every geojson sidecar and on the record's
#' `geometry_crs` column.
#' @noRd
dk_geometry_crs <- function() "EPSG:25832"

#' Normalise an `assessment_type` value to one of the API's accepted strings.
#' @noRd
dk_normalise_assessment_type <- function(x) {
  if (is.null(x) || !nzchar(x)) {
    return("All")
  }
  valid <- c("All", "Plans", "Project")
  hit <- valid[tolower(valid) == tolower(x)]
  if (length(hit) == 0L) {
    cli::cli_abort(
      "{.arg assessment_type} must be one of {.val {valid}} (got {.val {x}})."
    )
  }
  hit
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Fetch the EA-Hub search index in one POST call.
#'
#' Returns a list of search-result rows; each carries everything the scan
#' phase needs (title, year range, status, authorities, annex categories,
#' hasGeometry). No pagination — the API returns the full filtered set.
#' @noRd
dk_fetch_search <- function(assessment_type = "All", free_text = NULL) {
  body <- list(
    assessmentType = assessment_type,
    includeAssessmentsWithoutGeometry = TRUE
  )
  if (!is.null(free_text) && nzchar(free_text)) {
    body$freeText <- as.character(free_text)
  }
  req <- req_planscanr(dk_api_base())
  req <- httr2::req_url_path_append(req, "assessments", "search")
  req <- httr2::req_body_json(req, body)
  payload <- perform_json(req)
  if (!is.list(payload)) {
    return(list())
  }
  payload
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else build from `entry`.
#'
#' Re-uses the sidecar geojson on disk if it's already there. When the sidecar
#' is missing, builds a 1-row tibble from the search-index entry and fetches
#' the geometry (if any) into a sibling .geojson file.
#' @noRd
dk_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  rec <- dk_parse_entry(url, entry)
  if (isTRUE(rec$has_geometry) && write_sidecar) {
    geo_path <- dk_fetch_geometry_to_geojson(
      assessment_id = entry$id,
      country = "dk",
      document_id = entry$id,
      title = rec$title,
      created_iso = if ("created" %in% names(entry)) entry$created else NULL
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- dk_geometry_crs()
    }
  }
  rec
}

#' Build a 1-row record tibble from one search-result entry.
#' @noRd
dk_parse_entry <- function(url, entry) {
  id <- as.character(entry$id)
  title <- dk_text(entry$name)
  status <- dk_label_da(entry$status)

  annex1_labels <- dk_collect_labels(entry$annex1$categories)
  annex2_labels <- dk_collect_labels(entry$annex2$categories)
  plan_types <- dk_collect_labels(entry$planTypesAndCategories$planTypes)
  plan_cats <- dk_collect_labels(entry$planTypesAndCategories$planCategories)
  spec_cats <- dk_collect_labels(entry$planTypesAndCategories$specificCategories)

  # native_type: the portal's own topic taxonomy, fed to the classifier as
  # the third part of its input (after title + summary). Concatenate Annex
  # I/II labels and plan type/category labels so projects (Annex-driven)
  # and plans (planType-driven) both get a useful category string.
  native_type <- dk_paste_labels(c(annex1_labels, annex2_labels, plan_types, plan_cats, spec_cats))

  authorities <- dk_collect_chr(entry$responsibleAuthorities, "name")
  if (length(authorities) == 0L) {
    authorities <- dk_collect_chr(entry$planningAuthorities, "name")
  }
  developers <- dk_collect_chr(entry$developers, "name")
  affected_states <- dk_collect_chr(entry$affectedStates, "name")
  # `affectedStates` items are bilingual {en-US, da-DK} dicts (per
  # /master-data/states); fall back to dk_collect_labels if `name` is a dict.
  if (length(affected_states) == 0L) {
    affected_states <- dk_collect_labels(entry$affectedStates)
  }

  from_year <- dk_int(entry$fromYear)
  to_year <- dk_int(entry$toYear)
  year_val <- if (is.na(from_year)) to_year else from_year

  date_published <- dk_parse_iso_date(entry$created)

  tibble::tibble(
    country = "dk",
    source_portal = dk_source_portal(),
    document_id = id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    # EA-Hub has no narrative abstract; classifier still works on title +
    # native_type (the annex / plan-type labels).
    summary = NA_character_,
    competent_authority = if (length(authorities) == 0L) {
      NA_character_
    } else {
      paste(authorities, collapse = "; ")
    },
    proponent = if (length(developers) == 0L) {
      NA_character_
    } else {
      paste(developers, collapse = "; ")
    },
    date_published = date_published,
    date_decision = as.Date(NA),
    native_type = native_type,
    jurisdiction = if (length(affected_states) == 0L) {
      NA_character_
    } else {
      paste(affected_states, collapse = "; ")
    },
    status = status %||% NA_character_,
    year = if (is.na(year_val)) NA_integer_ else as.integer(year_val),
    from_year = from_year,
    to_year = to_year,
    is_project_assessment = isTRUE(entry$isProjectAssessment),
    is_related_to_plan = isTRUE(entry$isRelatedToPlan),
    is_draft = isTRUE(entry$isDraft),
    has_geometry = isTRUE(entry$hasGeometry),
    geometry_path = NA_character_,
    geometry_crs = NA_character_,
    annex1 = if (length(annex1_labels) == 0L) NA_character_ else paste(annex1_labels, collapse = "; "),
    annex2 = if (length(annex2_labels) == 0L) NA_character_ else paste(annex2_labels, collapse = "; "),
    plan_types = if (length(plan_types) == 0L) NA_character_ else paste(plan_types, collapse = "; "),
    plan_categories = if (length(plan_cats) == 0L) NA_character_ else paste(plan_cats, collapse = "; "),
    download_status = list(empty_download_status())
  )
}

# -----------------------------------------------------------------------------
# Geometry → linked GeoJSON file
# -----------------------------------------------------------------------------

#' Fetch a record's geometry and save it next to the sidecar as GeoJSON.
#'
#' Returns the absolute path to the .geojson on success, or NULL if the
#' fetch / WKT parse failed (the sidecar is still written; just without a
#' geometry link).
#'
#' The file lives at `<sidecar_dir>/<document_id>.geometry.geojson`. The
#' GeoJSON keeps the source projection (EPSG:25832) and tags it via the
#' GeoJSON-2008 `crs` member — RFC 7946 deprecated that, but QGIS and
#' `sf::read_sf()` still honour it, and we avoid pulling sf in as a hard
#' dependency just to reproject.
#' @noRd
dk_fetch_geometry_to_geojson <- function(
  assessment_id,
  country,
  document_id,
  title = NULL,
  created_iso = NULL
) {
  out_path <- dk_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  req <- req_planscanr(dk_api_base())
  req <- httr2::req_url_path_append(req, "assessments", assessment_id, "geometry")
  payload <- tryCatch(perform_json(req), error = function(e) NULL)
  if (is.null(payload) || !is.list(payload)) {
    return(NULL)
  }
  wkt <- payload$geometryWkt %||% payload$wkt %||% NULL
  if (is.null(wkt) || !is.character(wkt) || !nzchar(wkt)) {
    return(NULL)
  }
  geometry <- tryCatch(wkt_to_geojson_geometry(wkt), error = function(e) NULL)
  if (is.null(geometry)) {
    return(NULL)
  }
  feature <- list(
    type = "FeatureCollection",
    # GeoJSON-2008 crs member. Deprecated by RFC 7946 but still understood
    # by QGIS / sf; keeps the file self-describing without reprojection.
    crs = list(
      type = "name",
      properties = list(name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", dk_geometry_crs())))
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = dk_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = dk_geometry_crs()
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
dk_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

#' Tiny WKT → GeoJSON-geometry parser for POLYGON / MULTIPOLYGON.
#'
#' EA-Hub only ever serves polygon footprints (project / plan extents), so
#' we don't need the full WKT grammar — a small hand-rolled parser keeps
#' the package free of a heavy geometry dependency (sf / wk). Throws if the
#' WKT is anything other than POLYGON or MULTIPOLYGON.
#' @noRd
wkt_to_geojson_geometry <- function(wkt) {
  s <- trimws(wkt)
  # Extract the geometry type token.
  m <- regmatches(s, regexpr("^[A-Za-z]+", s))
  if (length(m) == 0L || !nzchar(m)) {
    stop("WKT has no leading type token")
  }
  type <- toupper(m)
  body <- trimws(sub("^[A-Za-z]+", "", s))
  if (toupper(type) == "POLYGON") {
    list(type = "Polygon", coordinates = wkt_parse_polygon(body))
  } else if (toupper(type) == "MULTIPOLYGON") {
    list(type = "MultiPolygon", coordinates = wkt_parse_multipolygon(body))
  } else {
    stop(sprintf("Unsupported WKT geometry type: %s", type))
  }
}

#' Parse a WKT polygon body (the part after the type token).
#'
#' Returns a list of rings; each ring is a list of length-2 numeric vectors
#' (x, y). Both POLYGON ((...)) and bare ((...)) bodies are accepted.
#' @noRd
wkt_parse_polygon <- function(body) {
  body <- trimws(body)
  if (startsWith(body, "(") && endsWith(body, ")")) {
    body <- substr(body, 2L, nchar(body) - 1L)
  }
  # Body is now a sequence of "(x y, x y, ...)" rings separated by commas
  # that sit OUTSIDE any parentheses. Walk character-by-character to split.
  rings <- wkt_split_rings(body)
  lapply(rings, function(ring_str) {
    pts <- strsplit(ring_str, ",", fixed = TRUE)[[1]]
    lapply(pts, function(p) {
      xy <- as.numeric(strsplit(trimws(p), "\\s+")[[1]])
      if (length(xy) < 2L || any(is.na(xy[1:2]))) {
        stop("Bad WKT coordinate: ", p)
      }
      xy[1:2]
    })
  })
}

#' Parse a WKT multipolygon body.
#' @noRd
wkt_parse_multipolygon <- function(body) {
  body <- trimws(body)
  if (startsWith(body, "(") && endsWith(body, ")")) {
    body <- substr(body, 2L, nchar(body) - 1L)
  }
  polys <- wkt_split_paren_blocks(body)
  lapply(polys, function(p) wkt_parse_polygon(p))
}

#' Split a string like "(a, b), (c, d)" into c("(a, b)", "(c, d)") respecting
#' top-level parentheses only.
#' @noRd
wkt_split_paren_blocks <- function(s) {
  chars <- strsplit(s, "", fixed = TRUE)[[1]]
  depth <- 0L
  start <- NA_integer_
  blocks <- character(0)
  for (i in seq_along(chars)) {
    ch <- chars[i]
    if (ch == "(") {
      if (depth == 0L) {
        start <- i
      }
      depth <- depth + 1L
    } else if (ch == ")") {
      depth <- depth - 1L
      if (depth == 0L && !is.na(start)) {
        blocks <- c(blocks, substr(s, start, i))
        start <- NA_integer_
      }
    }
  }
  blocks
}

#' Split a polygon body into ring strings (without the wrapping parens).
#'
#' Input looks like `(x y, x y), (x y, x y)` — rings are paren blocks. We
#' strip the parens off each.
#' @noRd
wkt_split_rings <- function(s) {
  blocks <- wkt_split_paren_blocks(s)
  vapply(blocks, function(b) {
    if (startsWith(b, "(") && endsWith(b, ")")) {
      substr(b, 2L, nchar(b) - 1L)
    } else {
      b
    }
  }, character(1), USE.NAMES = FALSE)
}

# -----------------------------------------------------------------------------
# Per-record finalise (no downloads in v0.1 — see Attachments section above)
# -----------------------------------------------------------------------------

#' Finalise a parsed DK record by writing the sidecar.
#' @noRd
dk_finalise_record <- function(rec, write_sidecar) {
  ds <- empty_download_status()
  rec$download_status <- list(ds)
  rec$local_path <- list(character(0))
  if (write_sidecar) {
    tryCatch(
      write_record_sidecar(rec, downloads = ds),
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

#' Apply client-side filters to a parsed DK record.
#'
#' Only `date_range` is enforced here — `query` is handled server-side via
#' the API's `freeText` field, so by the time a record lands in this loop
#' it has already passed the text filter.
#' @noRd
dk_record_matches <- function(rec, date_range) {
  if (!is.null(date_range)) {
    if (!dk_year_in_range(rec$from_year, rec$to_year, date_range)) {
      return(FALSE)
    }
  }
  TRUE
}

#' Does a from/to year span overlap the given date window?
#'
#' Treats `[fromYear, toYear]` as the Jan 1 (from) – Dec 31 (to) span. A
#' NULL or NA `fromYear` AND `toYear` fails the test (no overlap possible).
#' @noRd
dk_year_in_range <- function(from_year, to_year, date_range) {
  fy <- suppressWarnings(as.integer(from_year))
  ty <- suppressWarnings(as.integer(to_year))
  if (is.na(fy) && is.na(ty)) {
    return(FALSE)
  }
  if (is.na(fy)) fy <- ty
  if (is.na(ty)) ty <- fy
  yr_start <- as.Date(sprintf("%04d-01-01", fy))
  yr_end <- as.Date(sprintf("%04d-12-31", ty))
  !(yr_end < date_range[1] || yr_start > date_range[2])
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Coerce a single scalar field into a non-empty trimmed character or NULL.
#' @noRd
dk_text <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Coerce an integer-ish field to integer (NA on failure).
#' @noRd
dk_int <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NA_integer_)
  }
  v <- suppressWarnings(as.integer(x))
  if (length(v) == 0L) NA_integer_ else v
}

#' Pull the da-DK label out of a bilingual `{ name: { en-US, da-DK } }` block.
#' @noRd
dk_label_da <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  nm <- x$name
  if (is.list(nm)) {
    return(nm[["da-DK"]] %||% nm[["en-US"]] %||% NULL)
  }
  if (is.character(nm) && length(nm) == 1L && nzchar(nm)) {
    return(nm)
  }
  NULL
}

#' Collect da-DK labels from a list of `{ name: { en-US, da-DK } }` items.
#' @noRd
dk_collect_labels <- function(items) {
  if (is.null(items) || length(items) == 0L) {
    return(character(0))
  }
  out <- vapply(
    items,
    function(it) dk_label_da(it) %||% NA_character_,
    character(1)
  )
  out <- trimws(out[!is.na(out)])
  out[nzchar(out)]
}

#' Collect a scalar field from a list of objects, dropping NA / empty.
#' @noRd
dk_collect_chr <- function(items, field) {
  if (is.null(items) || length(items) == 0L) {
    return(character(0))
  }
  out <- vapply(
    items,
    function(it) {
      v <- it[[field]]
      if (is.null(v)) NA_character_ else as.character(v)
    },
    character(1)
  )
  out <- trimws(out[!is.na(out)])
  out[nzchar(out)]
}

#' Join a vector of category labels into a single "; "-separated scalar.
#' @noRd
dk_paste_labels <- function(labels) {
  labels <- labels[!is.na(labels) & nzchar(labels)]
  if (length(labels) == 0L) {
    return(NA_character_)
  }
  paste(unique(labels), collapse = "; ")
}

#' Parse an ISO-8601 created/lastUpdated timestamp into a Date.
#' @noRd
dk_parse_iso_date <- function(x) {
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
