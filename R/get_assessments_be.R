#' Fetch environmental-assessment records from Belgium (Flanders).
#'
#' Implementation of [get_assessments()] for the Flemish *MER-register*
#' (<https://merregister.omgeving.vlaanderen.be/>), the Departement Omgeving's
#' public register of Project-MER dossiers (project-level EIA) and
#' dossier-MER-plicht ontheffingsaanvragen (exemption requests). Plan-MER
#' (SEA) lives in a separate Flemish register and is out of scope for this
#' handler.
#'
#' @section URL enumeration:
#' The portal is a Vue SPA backed by a public REST API. The SPA reads the
#' backend host from `GET /rest/configuratie` (which exposes a `dmvbURL` field
#' pointing at `https://dmvb.omgeving.vlaanderen.be/`) and then paginates
#' `GET /api/v1/dossier?page=<n>&size=<k>` to enumerate the register. Page
#' size is capped server-side at 25; this handler walks every page until
#' `totalElements` is reached. The search index already carries `nummer`,
#' `dossierType`, `titel`, and `initiatiefnemer`; the full record (locatie,
#' coordinator, domeinen, documenten) is one
#' `GET /api/v1/dossier/{nummer}` away.
#'
#' @section Geometry:
#' Every detail record carries a `locatie` field in GeoJSON-style
#' (typically `MultiPolygon`) directly inline — no separate geometry call is
#' needed. Coordinates are in **EPSG:31370** (Belgian Lambert 72), the
#' standard Flemish projection. When `write_sidecar = TRUE`, the geometry is
#' saved next to the sidecar as `<document_id>.geometry.geojson`. The
#' sidecar carries `geometry_path` (absolute path to the .geojson) and
#' `geometry_crs` (`"EPSG:31370"`).
#'
#' The GeoJSON is written with the GeoJSON-2008 `crs` member naming
#' `urn:ogc:def:crs:EPSG::31370`; tools like QGIS / `sf::read_sf()` read
#' this fine, even though RFC 7946 deprecated the field. Coordinates are
#' kept in the source CRS — reproject downstream with `sf` if you need
#' WGS84.
#'
#' @section Attachments:
#' Each `documenten[]` entry has a direct, public download URL
#' (`https://dmvb.omgeving.vlaanderen.be/api/v1/dossier/{nummer}/document/{uuid}`)
#' that requires no authentication. Documents are grouped by their portal
#' `type` (e.g. *"Aanmelding"*, *"Ontheffingsaanvraag"*,
#' *"Verslag toekenning ontheffing"*); the set is open-ended, so the handler
#' discovers whatever types a record has and emits one
#' `attachment_urls_<slug>` / `local_path_<slug>` list-column per discovered
#' type. The slug is the `type` string lowercased with non-alphanumerics
#' collapsed to underscores; `aanmelding`, `ontheffingsaanvraag`, and
#' `verslag_toekenning_ontheffing` are the common ones. `attachment_urls` /
#' `local_path` remain the deduplicated union (required by the schema).
#'
#' @section Filter coverage (v0.1):
#' * `query` — case-insensitive substring match on `title` + `document_id`
#'    (the `PR####` `nummer`). Client-side.
#' * `niscode` — server-side NIS-code municipality filter (forwarded as the
#'    API's `niscode` parameter). The list of municipalities + niscodes is
#'    served at `https://dmvb.omgeving.vlaanderen.be/api/v1/locatie`.
#' * `nummer` — server-side exact / prefix match (forwarded as `nummer`).
#' * `dossier_type` — client-side filter on `administratieveGegevens.dossierType`
#'    (`"PROJECT_MER"` or `"VERZOEK_TOT_ONTHEFFING"`). The portal API ignores
#'    this filter server-side, so it has to be applied after the fact.
#' * `date_range` — matched client-side against `date_published` (the earliest
#'    `aanmaakdatum` across the record's documents). `date_decision` is always
#'    `NA` because the API does not expose a separate decision timestamp.
#'
#' @section Performance:
#' The register is ~3,000 records. A cold full crawl is a single search
#' enumeration (~120 paginated calls) plus one detail call per record. To
#' avoid hammering the backend, BE requests are throttled to 5 requests per
#' second by default; override via `getOption("planscanR.be_throttle_rate")`
#' (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query, substring-matched client-side against
#'   `title` + `document_id`.
#' @param niscode Optional NIS-code (5-digit municipality code, e.g.
#'   `"11024"` = Kontich). Forwarded server-side.
#' @param nummer Optional dossier number (e.g. `"PR4037"`). Forwarded
#'   server-side.
#' @param dossier_type Optional character; one of `"PROJECT_MER"` or
#'   `"VERZOEK_TOT_ONTHEFFING"`. Applied client-side.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_be(limit = 3, download = FALSE)
#'
#' # Wind-themed slice
#' get_assessments_be(query = "wind", limit = 20, download = FALSE)
#'
#' # All dossiers for Kontich (NIS 11024)
#' get_assessments_be(niscode = "11024", download = FALSE)
#' }
get_assessments_be <- function(
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
  niscode = NULL,
  nummer = NULL,
  dossier_type = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  dossier_type <- be_normalise_dossier_type(dossier_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  # Politeness throttle. A cold full crawl fires ~3000 detail-page GETs at the
  # backend; cap at 5 req/s by default to avoid disrupting other users of the
  # service. Override via `planscanR.be_throttle_rate`.
  rate <- getOption("planscanR.be_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "be")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("be")
  } else {
    stats::setNames(character(0), character(0))
  }

  index <- tryCatch(
    be_fetch_search(nummer = nummer, niscode = niscode, limit = limit),
    error = function(e) {
      warn_partial("Failed to enumerate MER-register: {conditionMessage(e)}")
      list()
    }
  )

  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling BE  ",
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
    # Cheap pre-filters: skip records we know we don't want before the
    # detail-page fetch. `query` matches the search-result title + nummer;
    # `dossier_type` is on the search-result row directly.
    if (!is.null(dossier_type) && !identical(entry$dossierType, dossier_type)) {
      next
    }
    if (!is.null(query) && !be_text_match(query, entry$titel, entry$nummer)) {
      next
    }
    u <- be_canonical_url(entry$nummer)
    rec <- tryCatch(
      be_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
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
    if (!be_record_matches(rec, date_range = date_range)) {
      next
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    rec <- be_finalise_record(
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
be_source_portal <- function() "omgeving.vlaanderen.be/merregister"

#' Public landing URL for the portal (where a human would open a dossier).
#' @noRd
be_portal_base <- function() "https://merregister.omgeving.vlaanderen.be"

#' Base URL for the DMVB REST API.
#' @noRd
be_api_base <- function() "https://dmvb.omgeving.vlaanderen.be/"

#' Server-side page-size cap for `GET /api/v1/dossier`.
#'
#' The DMVB backend 400s any `size` > 25. Documented here so the constant is
#' obvious if the cap ever moves.
#' @noRd
be_page_size <- function() 25L

#' Canonical landing URL for a dossier (SPA detail route).
#' @noRd
be_canonical_url <- function(nummer) {
  sprintf("%s/dossier/%s", be_portal_base(), nummer)
}

#' EPSG code of the geometry payloads returned by the DMVB API.
#'
#' Flanders serves Belgian Lambert 72 (EPSG:31370). Recorded on every
#' geojson sidecar and on the record's `geometry_crs` column.
#' @noRd
be_geometry_crs <- function() "EPSG:31370"

#' Known `dossierType` values exposed by the API.
#' @noRd
be_dossier_types <- function() c("PROJECT_MER", "VERZOEK_TOT_ONTHEFFING")

#' Normalise a `dossier_type` argument against the API's vocabulary.
#' @noRd
be_normalise_dossier_type <- function(x) {
  if (is.null(x) || !nzchar(x)) {
    return(NULL)
  }
  valid <- be_dossier_types()
  hit <- valid[toupper(valid) == toupper(x)]
  if (length(hit) == 0L) {
    cli::cli_abort(
      "{.arg dossier_type} must be one of {.val {valid}} (got {.val {x}}).",
      class = "planscanR_error_bad_input"
    )
  }
  hit
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Paginate `GET /api/v1/dossier` and return the full list of search rows.
#'
#' Each row is the small object shown in the search response:
#' `{nummer, dossierType, titel, initiatiefnemer:{naam,kboNummer}}`. Pagination
#' is server-side, capped at 25/page. We early-exit as soon as we have
#' `limit` rows (the caller may filter some out, so we only treat `limit` as
#' a soft stop here — `be_record_matches()` could still drop rows).
#' @noRd
be_fetch_search <- function(nummer = NULL, niscode = NULL, limit = Inf) {
  out <- list()
  page <- 0L
  size <- be_page_size()
  repeat {
    req <- req_planscanr(be_api_base())
    req <- httr2::req_url_path_append(req, "api", "v1", "dossier")
    req <- httr2::req_url_query(req, page = page, size = size)
    if (!is.null(nummer) && nzchar(nummer)) {
      req <- httr2::req_url_query(req, nummer = as.character(nummer))
    }
    if (!is.null(niscode) && nzchar(niscode)) {
      req <- httr2::req_url_query(req, niscode = as.character(niscode))
    }
    payload <- perform_json(req)
    if (!is.list(payload)) {
      break
    }
    content <- payload$content %||% list()
    if (length(content) == 0L) {
      break
    }
    out <- c(out, content)
    total <- as.integer(payload$totalElements %||% length(out))
    if (length(out) >= total) {
      break
    }
    # Soft stop: stop paginating once we've enumerated at least `limit` raw
    # rows. The caller may still filter the list, so this is only a ceiling.
    if (is.finite(limit) && length(out) >= as.integer(limit) * 5L) {
      break
    }
    page <- page + 1L
  }
  out
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch detail.
#'
#' Mirrors the NL / DK pattern. When the sidecar is missing, fetches the
#' detail JSON, parses it into a 1-row tibble, and saves the geometry to a
#' sibling `.geometry.geojson` so subsequent runs can pick it up offline.
#' @noRd
be_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  detail <- be_fetch_detail(entry$nummer)
  rec <- be_parse_detail(url, entry, detail)
  if (write_sidecar && !is.null(detail$locatie)) {
    geo_path <- be_save_geometry_to_geojson(
      country = "be",
      document_id = entry$nummer,
      title = rec$title,
      created_iso = be_record_first_created(detail$documenten),
      geometry = detail$locatie
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- be_geometry_crs()
    }
  }
  rec
}

#' Fetch one dossier detail.
#' @noRd
be_fetch_detail <- function(nummer) {
  req <- req_planscanr(be_api_base())
  req <- httr2::req_url_path_append(req, "api", "v1", "dossier", as.character(nummer))
  perform_json(req)
}

#' Build a 1-row record tibble from one search-row entry + its detail payload.
#'
#' The search row carries `dossierType` + initiatiefnemer; the detail carries
#' everything else (gemeentes, coordinator, domeinen, documenten, locatie).
#' Per-document-type attachment columns are emitted dynamically — see the
#' Attachments section in the function docs.
#' @noRd
be_parse_detail <- function(url, entry, detail) {
  id <- as.character(detail$nummer %||% entry$nummer)
  title <- be_text(detail$titel) %||% be_text(entry$titel) %||% NA_character_

  adm <- detail$administratieveGegevens %||% list()
  dossier_type <- adm$dossierType %||% entry$dossierType %||% NA_character_

  gemeentes <- be_collect_chr(adm$gemeentes, "naam")
  jurisdiction <- if (length(gemeentes) == 0L) {
    NA_character_
  } else {
    paste(gemeentes, collapse = "; ")
  }

  initiatiefnemers <- be_collect_chr(adm$initiatiefnemers, "naam")
  if (length(initiatiefnemers) == 0L && is.list(entry$initiatiefnemer)) {
    iv <- entry$initiatiefnemer$naam
    if (is.character(iv) && nzchar(iv)) {
      initiatiefnemers <- iv
    }
  }
  proponent <- if (length(initiatiefnemers) == 0L) {
    NA_character_
  } else {
    paste(initiatiefnemers, collapse = "; ")
  }

  coordinator <- be_text(detail$coordinator$naam)
  studiebureau <- be_text(detail$coordinator$studiebureau$naam)

  domeinen <- be_collect_chr(detail$domeinen, "naam")
  native_type <- if (length(domeinen) == 0L) {
    dossier_type
  } else {
    paste(c(dossier_type, paste(domeinen, collapse = "; ")), collapse = " | ")
  }

  # The Flemish MER-register does not name a single "Bevoegd gezag" per
  # dossier in the API response; the Departement Omgeving's Dienst Mer is the
  # de-facto authority for every record. Recorded as such for cross-portal
  # alignment, so a downstream `competent_authority` filter doesn't silently
  # exclude every BE row.
  competent_authority <- "Departement Omgeving / Dienst Mer"

  documenten <- detail$documenten %||% list()
  per_section <- be_group_documents_by_type(documenten)
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  date_published <- be_record_earliest_date(documenten)

  rec <- tibble::tibble(
    country = "be",
    source_portal = be_source_portal(),
    document_id = id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    # No narrative abstract in the API; classifier still has title +
    # native_type (the dossierType + per-domein expert labels) to work with.
    summary = NA_character_,
    competent_authority = competent_authority,
    proponent = proponent,
    date_published = date_published,
    date_decision = as.Date(NA),
    native_type = native_type,
    jurisdiction = jurisdiction,
    dossier_type = dossier_type,
    coordinator = coordinator %||% NA_character_,
    coordinator_studiebureau = studiebureau %||% NA_character_,
    expertise_domains = if (length(domeinen) == 0L) {
      NA_character_
    } else {
      paste(domeinen, collapse = "; ")
    },
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

#' Group `documenten[]` by their portal `type`, returning a named list of
#' URL vectors keyed by an auto-slugged type.
#'
#' The Flemish portal exposes an open-ended set of document types
#' (`Aanmelding`, `Ontheffingsaanvraag`, `Verslag toekenning ontheffing`,
#' ...); each one becomes its own sidecar section so downstream consumers can
#' tell the substantive submission from the authority's verdict without
#' parsing filenames. Unknown types are auto-slugged from their label so a
#' new type appears in its own column without a code change.
#' @noRd
be_group_documents_by_type <- function(documenten) {
  if (length(documenten) == 0L) {
    return(list())
  }
  per_section <- list()
  for (d in documenten) {
    url <- d$uri %||% NA_character_
    if (is.null(url) || is.na(url) || !nzchar(url)) {
      next
    }
    slug <- be_section_slug(d$type)
    per_section[[slug]] <- unique(c(per_section[[slug]], url))
  }
  per_section
}

#' Slug a document `type` string to an ASCII column-suffix slug.
#'
#' Lowercases, transliterates Dutch diacritics, and collapses
#' non-alphanumerics to underscores. Empty input gets `"document"` as a
#' deterministic fallback so the sidecar still has a stable section tag.
#' @noRd
be_section_slug <- function(type) {
  if (is.null(type) || !is.character(type) || length(type) != 1L || is.na(type) || !nzchar(type)) {
    return("document")
  }
  s <- type
  # Dutch / French diacritics that show up in document type labels.
  s <- gsub("é|è|ê|ë", "e", s)
  s <- gsub("à|â|ä", "a", s)
  s <- gsub("î|ï", "i", s)
  s <- gsub("ô|ö", "o", s)
  s <- gsub("û|ü", "u", s)
  s <- gsub("ç", "c", s)
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "document" else s
}

#' Earliest `aanmaakdatum` / `ontvangstdatum` across a record's documents.
#'
#' The DMVB API does not expose a `date_published` or `date_decision` at the
#' dossier level. The earliest document creation/receipt date is the best
#' proxy for "when did this dossier become a public record"; we use it as
#' `date_published` so the date_range filter has something to bite on.
#' @noRd
be_record_earliest_date <- function(documenten) {
  if (length(documenten) == 0L) {
    return(as.Date(NA))
  }
  dates <- unlist(
    lapply(documenten, function(d) {
      candidates <- c(
        be_parse_iso_date(d$ontvangstdatum),
        be_parse_iso_date(d$aanmaakdatum)
      )
      candidates[!is.na(candidates)]
    }),
    use.names = FALSE
  )
  if (length(dates) == 0L) {
    return(as.Date(NA))
  }
  min(as.Date(dates))
}

#' First document creation timestamp, ISO-8601 — for the geometry sidecar.
#' @noRd
be_record_first_created <- function(documenten) {
  if (length(documenten) == 0L) {
    return(NULL)
  }
  ts <- vapply(
    documenten,
    function(d) d$aanmaakdatum %||% NA_character_,
    character(1)
  )
  ts <- ts[!is.na(ts) & nzchar(ts)]
  if (length(ts) == 0L) NULL else min(ts)
}

# -----------------------------------------------------------------------------
# Geometry → linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save a dossier's `locatie` GeoJSON geometry next to its sidecar.
#'
#' The DMVB API serves geometries as already-parsed GeoJSON geometry
#' objects (`{"type":"MultiPolygon","coordinates":[[[...]]]}`) embedded in
#' the detail payload, so there is no WKT parsing to do. We wrap the
#' geometry in a `FeatureCollection`, tag the CRS via the GeoJSON-2008
#' `crs` member, and persist it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`.
#'
#' Coordinates are kept in the source EPSG:31370; downstream tools that
#' need WGS84 reproject with `sf`.
#' @noRd
be_save_geometry_to_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  geom_type <- geometry$type
  if (is.null(geom_type) || !nzchar(geom_type)) {
    return(NULL)
  }
  out_path <- be_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", be_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = be_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = be_geometry_crs()
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
be_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed BE record: run downloads (if requested) and write sidecar.
#'
#' Mirrors the NL flow but threads the dynamic per-`type` section list so
#' each `attachment_urls_<slug>` gets a parallel `local_path_<slug>` once
#' the download status is known.
#' @noRd
be_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "be"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "be",
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

#' Apply post-fetch client-side filters to a parsed BE record.
#'
#' `dossier_type` and `query` are checked pre-fetch in the main loop; the
#' only post-fetch filter is `date_range` (against `date_published`).
#' @noRd
be_record_matches <- function(rec, date_range) {
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}

#' Case-insensitive substring match on `query` against `title` + `nummer`.
#' @noRd
be_text_match <- function(query, title, nummer) {
  haystack <- tolower(paste(title %||% "", nummer %||% "", sep = " | "))
  grepl(tolower(query), haystack, fixed = TRUE)
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
be_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Collect a scalar `field` from a list of objects, dropping NA / empty.
#' @noRd
be_collect_chr <- function(items, field) {
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

#' Parse an ISO-8601 timestamp / date string into a Date.
#' @noRd
be_parse_iso_date <- function(x) {
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
