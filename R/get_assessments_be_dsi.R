#' Fetch Flemish planning dossiers from the DSI portal (explicit source `be_dsi`).
#'
#' Implementation of the explicit source `"be_dsi"` for
#' `get_assessments("be", source = "be_dsi")`: the public *Digitale
#' Stedenbouwkundige Informatie* (DSI) planning-dossier platform of the Flemish
#' Departement Omgeving (<https://dsi.omgeving.vlaanderen.be/>). It is separate
#' from the default `"be"` handler ([get_assessments_be()], the project-MER
#' register), which is unchanged. Only `country = "be"` is accepted; other
#' codes raise an error.
#'
#' @section Coverage and limitations:
#' Flemish spatial-planning dossiers only (gewestelijke, provinciale and
#' gemeentelijke RUP, BPA, verordeningen, ...); Wallonia and Brussels are not
#' covered. The unit is one planning dossier (all phases), not one assessment
#' report. Plan-MER (SEA) reports are only a subset of the documents: the
#' portal's document code `PLNMER` mixes plan-MER reports, screening
#' ("Onderzoek tot milieueffectrapportage") and decision letters. The handler
#' does **not** classify them (no title or page-count heuristics); every
#' document keeps its native `code`, `omschrijving` (description) and phase,
#' and consumers decide what counts as a report. Records are not pre-filtered
#' to dossiers that carry plan-MER material (~9,800 dossiers in total).
#'
#' @section URL enumeration:
#' Anonymous HAL API: `GET /api/fiches/dossiers/zoekRsql?page=&size=` is paged
#' until `page.totalPages`; the stable id is `algplanid`
#' (`document_id = "be_dsi_<algplanid>"`). One
#' `GET /api/fiches/dossiers/{dossierId}` per dossier returns all phases
#' (`fases[]`) with four document arrays per phase (`dossierstukken[]`,
#' `workflow[]`, `geodata[]`, `inspraakstukken[]`), each document with a
#' public download link. The listing's first-publication timestamp of the
#' active phase is used as `date_published`.
#'
#' @section Attachments:
#' Links from all four arrays are grouped per native document code into
#' `attachment_urls_<code>` / `local_path_<code>` columns (`plnmer`, `bs`,
#' `rvr`, ...) and deduplicated (the same file often recurs across phases).
#' Documents from `workflow` (e.g. advice letters), `geodata` and
#' `inspraakstukken` get the array name as slug prefix
#' (`attachment_urls_workflow_adv`, `attachment_urls_geodata_ct`, ...).
#' The extra column `documents_json` keeps every document as its full native
#' object (id, originId, code, type, description, extension, size, version,
#' index, groepering, verordenend, payload, link) plus `phase` and
#' `source_array`; `phases_json` keeps every phase's non-array fields (id, code,
#' volgorde, payload); `dossier_payload_json` the dossier-level payload;
#' `listing_json` the raw listing row; `herinterpretatie` the native flag.
#' Download volume is large: a dossier with all its documents is often about
#' 100 MB, so use `limit` and `max_file_size_mb`.
#'
#' @section Geometry:
#' Only the contour (MultiPolygon, EPSG:31370) of the latest phase (highest
#' `volgorde`) that has one is saved next to the sidecar, as in
#' [get_assessments_be()], because the record schema has a single
#' `geometry_path`; its phase is recorded in `geometry_phase_code`. Earlier
#' phases' contours are not stored.
#'
#' @section Filters:
#' * `query` — case-insensitive substring on dossier name + `algplanid`
#'   (client-side, before the detail call).
#' * `procedure_code` — exact `procedureCode` (e.g. `"gewRUP"`), client-side.
#' * `date_range` — against `date_published` (listing `actieveFaseTijdstipEerstePublicatie`,
#'   the first-publication time of the active phase, else the active phase
#'   date `fasedatum`).
#'
#' @param country Must be `"be"`.
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query,procedure_code See the Filters section.
#' @param ... Unused; unknown arguments are warned about.
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments_sources()], [get_assessments_be()]
#' @keywords internal
#' @noRd
get_assessments_be_dsi <- function(
  country = "be",
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
  procedure_code = NULL,
  ...
) {
  if (!identical(country, "be")) {
    cli::cli_abort(
      c(
        "Source {.val be_dsi} is a Flemish (Belgium) portal and only supports {.code country = \"be\"}, not {.val {country}}.",
        i = "Use {.code get_assessments(\"be\", source = \"be_dsi\")}."
      ),
      class = "planscanR_error_bad_input"
    )
  }
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  if (
    !is.null(procedure_code) && (!is.character(procedure_code) || length(procedure_code) != 1L || is.na(procedure_code))
  ) {
    cli::cli_abort(
      "{.arg procedure_code} must be a single non-NA string.",
      class = "planscanR_error_bad_input"
    )
  }

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
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

  process_entry <- function(entry) {
    if (!is.null(procedure_code) && !identical(entry$procedureCode, procedure_code)) {
      return(NULL)
    }
    if (!is.null(query) && !be_text_match(query, entry$dossierNaam, entry$algplanid)) {
      return(NULL)
    }
    u <- entry$ficheLink %||% be_dsi_fiche_url(entry$dossierId)
    rec <- tryCatch(
      be_dsi_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec) || !be_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    be_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Small pages for cheap scans, only when no client-side filter can skip rows.
  unfiltered <- is.null(query) && is.null(procedure_code) && is.null(date_range)
  gen <- be_dsi_fetch_search(limit = if (unfiltered) limit else Inf)
  records <- stream_crawl(gen, process_entry, limit = limit, label = "be_dsi")
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

be_dsi_source_portal <- function() "dsi.omgeving.vlaanderen.be"
be_dsi_api_base <- function() "https://dsi.omgeving.vlaanderen.be/"
be_dsi_fiche_url <- function(id) paste0(be_dsi_api_base(), "fiche-detail/", id)

#' Page generator over `zoekRsql` (stream_crawl `next_page` contract).
#'
#' Ends after `page.totalPages` pages or an empty page. Rows are deduplicated by
#' `algplanid`; a page that yields only repeats, a failed page, or an early
#' end (fewer rows than `totalElements`) emits `planscanR_warning_partial`
#' instead of looking complete. Page size shrinks to `limit` for cheap scans.
#' @noRd
be_dsi_fetch_search <- function(limit = Inf, max_size = 200L) {
  size <- as.integer(min(max_size, max(1, ceiling(limit)), na.rm = TRUE))
  page <- 0L
  seen <- character(0)
  total_pages <- NA_integer_
  total <- NA_integer_
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    if (!is.na(total_pages) && page >= total_pages) {
      done <<- TRUE
      if (!is.na(total) && length(seen) < total) {
        warn_partial("DSI listing ended with {length(seen)} of {total} dossiers.")
      }
      return(NULL)
    }
    req <- req_planscanr(be_dsi_api_base())
    req <- httr2::req_url_path_append(req, "api", "fiches", "dossiers", "zoekRsql")
    req <- httr2::req_url_query(req, page = page, size = size)
    payload <- tryCatch(
      perform_json(req),
      error = function(e) {
        warn_partial("DSI listing page {page} failed, results are incomplete: {conditionMessage(e)}")
        NULL
      }
    )
    page <<- page + 1L
    if (!is.list(payload)) {
      done <<- TRUE
      if (!is.null(payload)) {
        warn_partial("DSI listing page {page - 1L} returned an unexpected payload; results are incomplete.")
      }
      return(NULL)
    }
    total_pages <<- as.integer(payload$page$totalPages %||% NA_integer_)
    total <<- as.integer(payload$page$totalElements %||% NA_integer_)
    rows <- payload$`_embedded`$ficheOverzichtZoekResultaats %||% list()
    if (length(rows) == 0L) {
      done <<- TRUE
      if (is.na(total) || length(seen) < total) {
        warn_partial(
          "DSI listing page {page - 1L} was empty after {length(seen)} of {total} dossiers; results are incomplete."
        )
      }
      return(NULL)
    }
    ids <- vapply(rows, function(r) as.character(r$algplanid %||% r$dossierId %||% NA_character_), character(1))
    fresh <- !is.na(ids) & !ids %in% seen & !duplicated(ids)
    if (!any(fresh)) {
      done <<- TRUE
      warn_partial("DSI listing page {page - 1L} repeated already-seen dossiers; stopping, results may be incomplete.")
      return(NULL)
    }
    seen <<- c(seen, ids[fresh])
    rows[fresh]
  }
}

#' Sidecar-first detail load; saves the latest contour next to the sidecar.
#' @noRd
be_dsi_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  req <- req_planscanr(be_dsi_api_base())
  req <- httr2::req_url_path_append(req, "api", "fiches", "dossiers", as.character(entry$dossierId))
  detail <- perform_json(req)
  rec <- be_dsi_parse_detail(url, entry, detail)
  geom <- be_dsi_latest_contour(detail$fases)
  if (write_sidecar && !is.null(geom)) {
    geo_path <- be_save_geometry_to_geojson(
      country = "be",
      document_id = rec$document_id,
      title = rec$title,
      geometry = geom,
      source_portal = be_dsi_source_portal()
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- be_geometry_crs()
    }
  }
  rec
}

#' Contour of the phase with the highest `volgorde` that has one.
#' @noRd
be_dsi_latest_contour <- function(fases, field = "contour") {
  fases <- Filter(function(f) is.list(f$contour) && nzchar(f$contour$type %||% ""), fases %||% list())
  if (length(fases) == 0L) {
    return(NULL)
  }
  ord <- vapply(fases, function(f) as.numeric(f$volgorde %||% -Inf), numeric(1))
  fases[[which.max(ord)]][[field]]
}

#' Build the 1-row record from a listing row + detail payload.
#' @noRd
be_dsi_parse_detail <- function(url, entry, detail) {
  algplanid <- as.character(detail$algplanid %||% entry$algplanid)
  fases <- detail$fases %||% list()

  doc_arrays <- c("dossierstukken", "workflow", "geodata", "inspraakstukken")
  docs <- list()
  for (f in fases) {
    for (arr in doc_arrays) {
      for (d in f[[arr]] %||% list()) {
        d$phase <- f$code %||% NA_character_
        d$source_array <- arr
        docs[[length(docs) + 1L]] <- d
      }
    }
  }
  per_section <- list()
  for (d in docs) {
    link <- d$link %||% NA_character_
    if (is.na(link) || !nzchar(link)) {
      next
    }
    slug <- ascii_slug(d$code, "document")
    if (!identical(d$source_array, "dossierstukken")) {
      slug <- paste0(d$source_array, "_", slug)
    }
    per_section[[slug]] <- unique(c(per_section[[slug]], link))
  }
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null"))
  phases <- lapply(fases, function(f) {
    f[setdiff(names(f), c(doc_arrays, "contour"))]
  })
  geom_phase <- be_dsi_latest_contour(fases, field = "code")
  date_published <- parse_iso_date(substr(entry$actieveFaseTijdstipEerstePublicatie %||% NA_character_, 1, 10))
  if (is.na(date_published)) {
    date_published <- parse_iso_date(entry$fasedatum)
  }
  na_chr <- function(...) {
    for (x in list(...)) {
      v <- be_text(x)
      if (!is.null(v)) return(v)
    }
    NA_character_
  }

  rec <- tibble::tibble(
    country = "be",
    source_portal = be_dsi_source_portal(),
    document_id = paste0("be_dsi_", algplanid),
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = na_chr(detail$naam, entry$dossierNaam),
    summary = na_chr(detail$omschrijving, entry$dossierOmschrijving),
    competent_authority = na_chr(detail$plannendeOverheid, entry$plannendeOverheidNaam),
    proponent = NA_character_,
    date_published = date_published,
    date_decision = parse_iso_date(entry$datumBesluitTotGoedkeuring),
    native_type = na_chr(detail$procedureCode, entry$procedureCode),
    jurisdiction = na_chr(entry$plannendeOverheidNaam),
    algplanid = algplanid,
    dossier_id = na_chr(detail$id, entry$dossierId),
    procedure_version = na_chr(entry$procedureVersie),
    dossier_status = na_chr(detail$status, entry$dossierStatus),
    dossier_theme = na_chr(entry$dossierThema),
    authority_nis_code = na_chr(entry$plannendeOverheidNisCode),
    authority_email = na_chr(entry$plannendeOverheidEmail),
    contact = na_chr(detail$contact),
    active_phase_code = na_chr(entry$actieveFaseCode),
    staatsblad_publication_date = na_chr(entry$actieveFaseDatumPublicatieBelgischStaatsblad),
    herinterpretatie = as.logical(detail$herinterpretatie %||% NA),
    listing_json = json(entry),
    dossier_payload_json = json(detail$payload %||% list()),
    phases_json = json(phases),
    documents_json = json(docs),
    geometry_path = NA_character_,
    geometry_crs = NA_character_,
    geometry_phase_code = geom_phase %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}
