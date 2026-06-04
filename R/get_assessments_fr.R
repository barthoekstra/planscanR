#' Fetch environmental-assessment records from France.
#'
#' Implementation of [get_assessments()] for France, backed by the national
#' *Projets-Environnement* portal (<https://www.projets-environnement.gouv.fr/>),
#' the public diffusion of project-level environmental files (études d'impact,
#' avis de l'Autorité environnementale, résumés non techniques, etc.) compiled
#' from the préfectures' SICODEI workflow.
#'
#' @section URL enumeration:
#' Unlike the SPA-behind-a-private-API portals elsewhere in the family, this
#' one is an **OpenDataSoft Explore API v2.1** platform — a public, anonymous,
#' documented REST+JSON service. The whole register lives in a single flat
#' dataset (`projets-environnement-diffusion`, ~5,483 records, ~62 fields
#' each). Every field is inline in each record, so there is no separate detail
#' call.
#'
#' Enumeration uses the EXPORT endpoint
#' (`GET <base>/exports/json?limit=-1`), which has no offset cap and returns
#' the full filtered set in one JSON array. Server-side filters are expressed
#' in ODSQL via the `where` parameter: free-text `query` becomes
#' `search("<query>")`, `theme` / `status` / `native_type` become equality
#' clauses, and `date_range` becomes a `dc_date >= ... and dc_date <= ...`
#' window. The stable business key is `recordsid` (used as `document_id`); the
#' ODS internal hash (`record.id`) is deliberately ignored.
#'
#' @section Geometry:
#' About 1,472 of the ~5,483 records carry a `localisation` field — a full
#' GeoJSON **Feature** (typically a `MultiPolygon`) returned inline.
#' OpenDataSoft always serves WGS84, so the CRS is **EPSG:4326**. When
#' `write_sidecar = TRUE` and a record has a geometry, it is saved next to the
#' sidecar as `<document_id>.geometry.geojson` (a `FeatureCollection` wrapping
#' the geometry, with the GeoJSON-2008 `crs` member naming
#' `urn:ogc:def:crs:EPSG::4326`). The sidecar carries `geometry_path` and
#' `geometry_crs` (`"EPSG:4326"`). Records without `localisation` leave the
#' geometry columns `NA`.
#'
#' @section Attachments:
#' Each record exposes a **fixed set of typed document fields**, each holding a
#' single URL. The handler maps the known fields to stable slugs (DE-style
#' curated map) and emits one `attachment_urls_<slug>` / `local_path_<slug>`
#' list-column per field that is populated:
#'
#' * `dc_relation_expertise_etudeimpact` -> `etude_impact` (the EIA study PDF).
#' * `dc_relation_synthesis` -> `resume_non_technique` (résumé non technique).
#' * `dc_relation_expertise_avisae` -> `avis_ae` (avis de l'Autorité environnementale).
#' * `dc_relation_expertise_reponseavisae` -> `reponse_avis_ae` (réponse à l'avis AE).
#' * `dc_relation_officialdocument` -> `dossier` (the `*_DCZIP.zip` dossier).
#' * `dc_relation_decision` -> `decision`.
#' * `dc_relation_assessment` -> `assessment`.
#' * `dc_relation_expertise_autredoc1..3` -> `autre_doc_1..3`.
#' * `dc_relation_expertise_certifbiodiv` -> `certif_biodiv`.
#'
#' Only values whose host is `sicodei.projets-environnement.gouv.fr` (or that
#' end in `.pdf` / `.zip`) are treated as downloadable attachments — many
#' `dc_relation_*` values point at external préfecture web pages (HTML), which
#' are kept in extras columns but never enter the attachment columns.
#' `attachment_urls` / `local_path` are the deduplicated union of the real
#' document URLs, as required by the planscanR schema.
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side full-text (`search("<query>")` in ODSQL).
#' * `theme` — server-side equality on `dc_subject_theme`
#'   (e.g. `"ÉNERGIE"`; see [get_assessments_coverage()]).
#' * `native_type` — server-side equality on `dc_type`
#'   (e.g. `"AENV"`, `"Permis de construire"`).
#' * `status` — server-side equality on `vp_status`
#'   (`"ouvert"`, `"clos"`, `"non defini"`).
#' * `date_range` — server-side window on `dc_date` (publication date).
#'   `date_decision` is `NA` because the dataset exposes no single decision
#'   timestamp.
#'
#' @section Performance:
#' One export call enumerates the whole filtered register, so a cold crawl is
#' cheap. The per-attachment downloads (when `download = TRUE`) hit the SICODEI
#' blob host. Requests are throttled to 5 requests per second by default;
#' override via `getOption("planscanR.fr_throttle_rate")` (requests/sec; falsy
#' disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query; sent server-side as `search("<query>")`.
#' @param theme Optional `dc_subject_theme` value (server-side equality), e.g.
#'   `"ÉNERGIE"`.
#' @param native_type Optional `dc_type` value (server-side equality), e.g.
#'   `"Permis de construire"`.
#' @param status Optional `vp_status` value (server-side equality); one of
#'   `"ouvert"`, `"clos"`, `"non defini"`.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_fr(limit = 3, download = FALSE)
#'
#' # Wind-themed slice (server-side full-text)
#' get_assessments_fr(query = "éolien", limit = 20, download = FALSE)
#'
#' # Energy theme only
#' get_assessments_fr(theme = "ÉNERGIE", limit = 20, download = FALSE)
#' }
get_assessments_fr <- function(
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
  theme = NULL,
  native_type = NULL,
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
  # Politeness throttle. The export call is a single request, but a download
  # run fires one GET per attachment at the SICODEI blob host; cap at 5 req/s
  # by default. Override via `planscanR.fr_throttle_rate`.
  rate <- getOption("planscanR.fr_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "fr")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("fr")
  } else {
    stats::setNames(character(0), character(0))
  }

  where <- fr_build_where(
    query = query,
    theme = theme,
    native_type = native_type,
    status = status,
    date_range = date_range
  )

  # Per-entry processing: sidecar-first parse, client-side date filter,
  # relevance scoring, optional download, and the sidecar write. Returns the
  # 1-row record or NULL to drop the entry. Called once per listing row by
  # stream_crawl().
  process_entry <- function(entry) {
    id <- fr_records_id(entry)
    if (is.null(id)) {
      return(NULL)
    }
    u <- fr_canonical_url(id)
    rec <- tryCatch(
      fr_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!fr_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    fr_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # The whole register comes back in a single export call, so the generator
  # yields that one page and is then exhausted. Streaming it page-by-page still
  # means records are persisted as they are parsed (instead of after the full
  # in-memory pass), with the limit honoured by the driver.
  gen <- tryCatch(
    fr_fetch_records(where = where),
    error = function(e) {
      warn_partial("Failed to enumerate Projets-Environnement: {conditionMessage(e)}")
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "fr")

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
fr_source_portal <- function() "projets-environnement.gouv.fr"

#' Public landing-page base for the portal (where a human would open the data).
#' @noRd
fr_portal_base <- function() "https://www.projets-environnement.gouv.fr"

#' OpenDataSoft Explore API base for the diffusion dataset.
#' @noRd
fr_api_base <- function() {
  paste0(
    "https://www.projets-environnement.gouv.fr",
    "/api/explore/v2.1/catalog/datasets/projets-environnement-diffusion"
  )
}

#' Canonical landing URL for a record (the dataset table filtered to recordsid).
#' @noRd
fr_canonical_url <- function(recordsid) {
  sprintf(
    "%s/explore/dataset/projets-environnement-diffusion/table?q=recordsid:%s",
    fr_portal_base(),
    recordsid
  )
}

#' EPSG code of the geometry payloads. OpenDataSoft always serves WGS84.
#' @noRd
fr_geometry_crs <- function() "EPSG:4326"

#' Host that serves the real downloadable SICODEI document blobs.
#' @noRd
fr_attachment_host <- function() "sicodei.projets-environnement.gouv.fr"

#' Curated map from the dataset's typed document fields to stable slugs.
#'
#' This is the fixed set of `dc_relation_*` fields that carry a single document
#' URL each. The order here fixes the canonical ordering of the deduplicated
#' `attachment_urls` union (substantive documents first). Slugs become column
#' suffixes (`attachment_urls_<slug>` / `local_path_<slug>`) and the per-file
#' `section` tag inside the sidecar JSON.
#' @noRd
fr_attachment_fields <- function() {
  c(
    dc_relation_expertise_etudeimpact = "etude_impact",
    dc_relation_synthesis = "resume_non_technique",
    dc_relation_expertise_avisae = "avis_ae",
    dc_relation_expertise_reponseavisae = "reponse_avis_ae",
    dc_relation_officialdocument = "dossier",
    dc_relation_decision = "decision",
    dc_relation_assessment = "assessment",
    dc_relation_expertise_autredoc1 = "autre_doc_1",
    dc_relation_expertise_autredoc2 = "autre_doc_2",
    dc_relation_expertise_autredoc3 = "autre_doc_3",
    dc_relation_expertise_certifbiodiv = "certif_biodiv"
  )
}

# -----------------------------------------------------------------------------
# ODSQL `where` clause
# -----------------------------------------------------------------------------

#' Build the server-side ODSQL `where` clause from the active filters.
#'
#' Returns a single ODSQL string (joined with ` and `), or NULL when no
#' server-side filter is active. `query` becomes a `search(...)` predicate;
#' `theme` / `native_type` / `status` become equality predicates; `date_range`
#' becomes a `dc_date` window.
#' @noRd
fr_build_where <- function(query = NULL, theme = NULL, native_type = NULL, status = NULL, date_range = NULL) {
  clauses <- character(0)
  if (!is.null(query) && nzchar(query)) {
    clauses <- c(clauses, sprintf("search(%s)", fr_odsql_quote(query)))
  }
  if (!is.null(theme) && nzchar(theme)) {
    clauses <- c(clauses, sprintf("dc_subject_theme = %s", fr_odsql_quote(theme)))
  }
  if (!is.null(native_type) && nzchar(native_type)) {
    clauses <- c(clauses, sprintf("dc_type = %s", fr_odsql_quote(native_type)))
  }
  if (!is.null(status) && nzchar(status)) {
    clauses <- c(clauses, sprintf("vp_status = %s", fr_odsql_quote(status)))
  }
  if (!is.null(date_range)) {
    clauses <- c(
      clauses,
      sprintf("dc_date >= %s", fr_odsql_quote(format(date_range[1], "%Y-%m-%d"))),
      sprintf("dc_date <= %s", fr_odsql_quote(format(date_range[2], "%Y-%m-%d")))
    )
  }
  if (length(clauses) == 0L) {
    return(NULL)
  }
  paste(clauses, collapse = " and ")
}

#' Quote a string literal for an ODSQL clause (double quotes, escaped inner).
#' @noRd
fr_odsql_quote <- function(x) {
  paste0("\"", gsub("\"", "\\\\\"", x), "\"")
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Build a page generator for the (optionally filtered) register.
#'
#' Returns a zero-arg closure (the [stream_crawl()] `next_page` contract). The
#' OpenDataSoft EXPORT endpoint (`/exports/json?limit=-1`) has no offset cap and
#' returns the full filtered result set as a bare JSON array in a single call,
#' so the register is not actually paginated: the generator performs the export
#' on first call, yields the whole record list once, and returns `NULL` on every
#' subsequent call (exhausted). Each record is a named list of the dataset's
#' flat fields. An empty / non-list payload yields nothing.
#' @noRd
fr_fetch_records <- function(where = NULL) {
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    req <- req_planscanr(fr_api_base())
    req <- httr2::req_url_path_append(req, "exports", "json")
    req <- httr2::req_url_query(req, limit = -1L)
    if (!is.null(where) && nzchar(where)) {
      req <- httr2::req_url_query(req, where = where)
    }
    payload <- perform_json(req)
    if (!is.list(payload)) {
      return(NULL)
    }
    # The export endpoint returns a bare array. Some deployments wrap it in a
    # `results` object (the /records shape); tolerate both.
    if (!is.null(payload$results) && is.list(payload$results)) {
      return(payload$results)
    }
    payload
  }
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else parse the record.
#'
#' When the sidecar is missing, parses the inline record into a 1-row tibble
#' and (when the record carries a `localisation` geometry) saves it to a
#' sibling `.geometry.geojson` so subsequent runs pick it up offline.
#' @noRd
fr_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  rec <- fr_parse_record(url, entry)
  geometry <- fr_geometry_of(entry)
  if (write_sidecar && !is.null(geometry)) {
    geo_path <- fr_save_geometry_to_geojson(
      country = "fr",
      document_id = rec$document_id,
      title = rec$title,
      created_iso = fr_text(entry$dc_date),
      geometry = geometry
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- fr_geometry_crs()
    }
  }
  rec
}

#' Build a 1-row record tibble from one inline OpenDataSoft record object.
#'
#' Maps the dataset's flat fields onto the conventional planscanR columns,
#' keeps the source vocabulary verbatim (no normalisation at fetch time), and
#' emits one `attachment_urls_<slug>` / `local_path_<slug>` pair per populated
#' typed document field (see `fr_attachment_fields()`).
#' @noRd
fr_parse_record <- function(url, entry) {
  id <- fr_records_id(entry)
  title <- fr_text(entry$dc_title) %||% NA_character_
  summary <- fr_text(entry$descriptif_du_projet) %||%
    fr_text(entry$dc_description_abstract) %||%
    NA_character_

  native_type <- fr_join(entry$dc_type)
  theme <- fr_join(entry$dc_subject_theme)
  category <- fr_join(entry$dc_subject_category)

  proponent <- fr_text(entry$vp_creator_corporatename) %||%
    fr_text(entry$dc_contributor_corporatename) %||%
    NA_character_
  # The dataset uses "-" as a placeholder for an unknown corporate name.
  if (!is.na(proponent) && identical(proponent, "-")) {
    proponent <- NA_character_
  }

  jurisdiction <- fr_join_present(c(
    fr_text(entry$dc_location),
    fr_text(entry$location_ville),
    fr_text(entry$codepostal)
  ))

  competent_authority <- fr_text(entry$diffuseur) %||% NA_character_
  status <- fr_text(entry$vp_status) %||% NA_character_

  date_published <- fr_parse_iso_date(entry$dc_date)
  # Candidate decision dates: préfecture date, then commissaire report date.
  date_decision <- fr_parse_iso_date(entry$date_de_la_prefecture)
  if (is.na(date_decision)) {
    date_decision <- fr_parse_iso_date(entry$dc_date_rapportcommissaire)
  }

  per_section <- fr_collect_attachments(entry)
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "fr",
    source_portal = fr_source_portal(),
    document_id = id %||% NA_character_,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = summary,
    competent_authority = competent_authority,
    proponent = proponent,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status,
    dc_subject_theme = theme %||% NA_character_,
    dc_subject_category = category %||% NA_character_,
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

#' Extract the stable `recordsid` business key from a record object.
#' @noRd
fr_records_id <- function(entry) {
  fr_text(entry$recordsid)
}

#' Pull the inline GeoJSON geometry from a record's `localisation` Feature.
#'
#' The dataset returns `localisation` as a full GeoJSON `Feature`; we unwrap it
#' to the bare geometry object (`{type, coordinates}`). Returns NULL when the
#' record carries no usable geometry.
#' @noRd
fr_geometry_of <- function(entry) {
  loc <- entry$localisation
  if (is.null(loc) || !is.list(loc)) {
    return(NULL)
  }
  geometry <- if (!is.null(loc$geometry)) loc$geometry else loc
  if (!is.list(geometry) || is.null(geometry$type) || is.null(geometry$coordinates)) {
    return(NULL)
  }
  geometry
}

#' Collect a record's typed document fields into a per-section list of URLs.
#'
#' Walks `fr_attachment_fields()` in its canonical order; for each populated
#' field whose value is a real downloadable document (SICODEI host or a
#' .pdf/.zip URL), records it under the field's slug. External préfecture HTML
#' pages are skipped (they are kept only in the extras columns). Returns a
#' named list `slug -> character(urls)`.
#' @noRd
fr_collect_attachments <- function(entry) {
  fields <- fr_attachment_fields()
  per_section <- list()
  for (field in names(fields)) {
    val <- fr_text(entry[[field]])
    if (is.null(val) || !fr_is_downloadable(val)) {
      next
    }
    slug <- unname(fields[[field]])
    per_section[[slug]] <- unique(c(per_section[[slug]], val))
  }
  per_section
}

#' Is a `dc_relation_*` value a real downloadable document URL?
#'
#' Only values served by the SICODEI blob host, or that end in `.pdf` / `.zip`,
#' count. Everything else (external préfecture web pages, naturefrance deposit
#' landing pages) is HTML and must not enter the attachment columns.
#' @noRd
fr_is_downloadable <- function(url) {
  if (is.null(url) || !is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    return(FALSE)
  }
  host <- tryCatch(
    {
      m <- regmatches(url, regexpr("^https?://[^/]+", url))
      if (length(m) == 0L) "" else sub("^https?://", "", m)
    },
    error = function(e) ""
  )
  if (identical(host, fr_attachment_host())) {
    return(TRUE)
  }
  grepl("\\.(pdf|zip)$", url, ignore.case = TRUE)
}

# -----------------------------------------------------------------------------
# Geometry -> linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save a record's inline geometry next to its sidecar as GeoJSON.
#'
#' Wraps the geometry in a `FeatureCollection`, tags the CRS via the
#' GeoJSON-2008 `crs` member (`urn:ogc:def:crs:EPSG::4326`), and persists it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`. Coordinates are kept in the
#' source EPSG:4326 (OpenDataSoft always serves WGS84).
#' @noRd
fr_save_geometry_to_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  if (is.null(geometry$type) || !nzchar(geometry$type)) {
    return(NULL)
  }
  out_path <- fr_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", fr_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = fr_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = fr_geometry_crs()
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
fr_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed FR record: run downloads (if requested) and write sidecar.
#'
#' Threads the per-field section list so each `attachment_urls_<slug>` gets a
#' parallel `local_path_<slug>` once the download status is known.
#' @noRd
fr_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "fr"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "fr",
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

#' Apply post-fetch client-side filters to a parsed FR record.
#'
#' `query` / `theme` / `native_type` / `status` are handled server-side via the
#' ODSQL `where` clause; `date_range` is enforced server-side too, but we
#' re-check it client-side here as a belt-and-braces guard (and so the
#' sidecar-first path, which never sees the `where`, still honours the window).
#' @noRd
fr_record_matches <- function(rec, date_range) {
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

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
fr_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Join an array-or-scalar field into a single "; "-separated scalar, or NULL.
#'
#' The dataset stores several fields as arrays (`dc_type`, `dc_subject_theme`,
#' ...). We keep the raw values and join them with "; " — no normalisation.
#' @noRd
fr_join <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (is.list(x)) {
    x <- unlist(x, use.names = FALSE)
  }
  if (length(x) == 0L) {
    return(NULL)
  }
  vals <- trimws(as.character(x))
  vals <- vals[!is.na(vals) & nzchar(vals)]
  if (length(vals) == 0L) {
    return(NULL)
  }
  paste(unique(vals), collapse = "; ")
}

#' Join already-coerced present scalars with "; ", or NULL if none.
#' @noRd
fr_join_present <- function(parts) {
  parts <- parts[!vapply(parts, is.null, logical(1))]
  parts <- unlist(parts, use.names = FALSE)
  parts <- parts[!is.na(parts) & nzchar(parts)]
  if (length(parts) == 0L) {
    return(NULL)
  }
  paste(unique(parts), collapse = "; ")
}

#' Parse an ISO-8601 timestamp / date string into a Date.
#' @noRd
fr_parse_iso_date <- function(x) {
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
