#' Fetch environmental-assessment records from Estonia.
#'
#' Implementation of [get_assessments()] for Estonia. Backed by the
#' Keskkonnaamet's *KOTKAS* portal (<https://kotkas.envir.ee/>), which
#' publishes two adjacent public registers:
#'
#' * **KMH** — *Keskkonnamõju hindamine* (project-level EIA),
#'   `https://kotkas.envir.ee/kmh/kmh_index?tab=KMH`.
#' * **KSH** — *Keskkonnamõju strateegiline hindamine* (plan/programme SEA),
#'   `https://kotkas.envir.ee/kmh/ksh_index?tab=KSH`.
#'
#' Both registers are merged into a single result tibble; an
#' `assessment_type` column (`"EIA"` for KMH, `"SEA"` for KSH) tags each row
#' and is round-tripped to the sidecar so downstream tooling can tell them
#' apart without re-fetching anything. `document_id` is prefixed with
#' `"KMH-"` / `"KSH-"` (e.g. `"KMH-478"`, `"KSH-319"`) so the two registers
#' never collide on disk.
#'
#' @section URL enumeration:
#' KOTKAS is a server-rendered (jQuery / Bootstrap, not a SPA) Django-style
#' application. Index listings paginate via a numeric offset on the `qs=`
#' query parameter (page size = 40, server-controlled); each page is one HTML
#' GET that lists titles, regions, initiation dates, statuses, and
#' developers/organisers. Detail pages live at
#' `/kmh/kmh_view?kmh_id=<id>` (KMH) and `/kmh/ksh_view?ksh_id=<id>` (KSH);
#' every field a downstream classifier needs (full title, narrative summary,
#' developer/proponent, decider/competent authority, KOV municipality,
#' geometry, attachment URLs) is on that page already.
#'
#' @section Geometry:
#' Every detail record carries its activity area as an inline GeoJSON
#' geometry, embedded in a hidden form input (`#activity_area_geojson`).
#' Coordinates are in **EPSG:3301** (Estonian Coordinate System of 1997 /
#' L-EST97), the standard projected CRS for Estonia. When
#' `write_sidecar = TRUE`, the geometry is saved next to the sidecar as
#' `<document_id>.geometry.geojson`. The sidecar carries `geometry_path`
#' (absolute path to the .geojson) and `geometry_crs` (`"EPSG:3301"`).
#'
#' The GeoJSON is written with the GeoJSON-2008 `crs` member naming
#' `urn:ogc:def:crs:EPSG::3301`; tools like QGIS / `sf::read_sf()` read this
#' fine, even though RFC 7946 deprecated the field. Coordinates are kept in
#' the source CRS — reproject downstream with `sf` if you need WGS84.
#'
#' @section Attachments:
#' Each detail page exposes a *Dokumendid* table whose rows have a direct,
#' public download URL of the form
#' `https://kotkas.envir.ee/kmh/<kmh|ksh>_file_download?<kmh_id|ksh_id>=<id>&attachment_id=<aid>`
#' (no authentication needed). Documents are grouped by their portal *Liik*
#' (type) column — common ones include *Algatamise otsus* (initiation
#' decision), *Programm* (assessment programme), *Programmi otsus*
#' (programme decision), *Aruanne* (report), *Aruande otsus* (report
#' decision). The set is open-ended; the handler discovers whatever types a
#' record has and emits one `attachment_urls_<slug>` / `local_path_<slug>`
#' list-column per discovered type. The slug is the *Liik* string with
#' Estonian diacritics transliterated, lowercased, and non-alphanumerics
#' collapsed to underscores. `attachment_urls` / `local_path` remain the
#' deduplicated union (required by the schema).
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side substring match (forwarded as
#'    `s__search_keyword`, against title / code / related-person).
#' * `proceeding_status` — server-side enum: one of `"INITIATED"`,
#'    `"ONGOING"`, `"SUSPENDED"`, `"FINISHED"`. Forwarded as
#'    `s__proceeding_status`.
#' * `activity_area` — server-side maakond (county) code, e.g. `"0037"`
#'    (Harju) or the special tokens `"ESTONIA"`, `"SEA"`, `"CROSSBORDER"`.
#'    Forwarded as `s__activity_area`.
#' * `activity` — server-side sector code (e.g. `"1300"` =
#'    *Energeetika ja energiakandjate tootmine*). Forwarded as `s__activity`.
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (KMH only), or `"SEA"` (KSH only). Applied here in
#'    R, not server-side.
#' * `date_range` — matched client-side against `date_published` (the
#'    portal's *Algatamise kpv* / initiation date). `date_decision` is always
#'    `NA` because the portal does not expose a separate decision timestamp
#'    on the detail page (only per-document dates inside the *Dokumendid*
#'    table).
#'
#' @section Performance:
#' The two registers are ~500 (KMH) + ~750 (KSH) records, so a cold full
#' crawl is ~30 index-page fetches plus one detail fetch per record. To
#' avoid disrupting other users of the service, EE requests are throttled to
#' 2 requests per second by default — the portal pushes back with a 300 s
#' retry-backoff at 5 req/s under sustained load. Override via
#' `getOption("planscanR.ee_throttle_rate")` (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query forwarded as `s__search_keyword`.
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which register(s) to crawl.
#' @param proceeding_status Optional procedural-status enum (server-side
#'   filter); one of `"INITIATED"`, `"ONGOING"`, `"SUSPENDED"`, `"FINISHED"`.
#' @param activity_area Optional maakond (county) code (server-side filter).
#' @param activity Optional activity-sector code (server-side filter).
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_ee(limit = 3, download = FALSE)
#'
#' # Wind-themed slice
#' get_assessments_ee(query = "tuulepark", limit = 20, download = FALSE)
#'
#' # SEA only
#' get_assessments_ee(assessment_type = "SEA", download = FALSE)
#' }
get_assessments_ee <- function(
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
  proceeding_status = NULL,
  activity_area = NULL,
  activity = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  assessment_type <- ee_normalise_assessment_type(assessment_type)
  proceeding_status <- ee_normalise_status(proceeding_status)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.ee_throttle_rate", 2)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "ee")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("ee")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("KMH", "KSH"),
    EIA = "KMH",
    SEA = "KSH"
  )

  index <- list()
  for (reg in registers) {
    block <- tryCatch(
      ee_fetch_search(
        register = reg,
        query = query,
        proceeding_status = proceeding_status,
        activity_area = activity_area,
        activity = activity,
        limit = limit
      ),
      error = function(e) {
        warn_partial(
          "Failed to enumerate KOTKAS {.val {reg}} index: {conditionMessage(e)}"
        )
        list()
      }
    )
    index <- c(index, block)
  }

  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling EE  ",
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
    u <- ee_canonical_url(entry$register, entry$id)
    rec <- tryCatch(
      ee_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
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
    if (!ee_record_matches(rec, date_range = date_range)) {
      next
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    rec <- ee_finalise_record(
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
ee_source_portal <- function() "kotkas.envir.ee"

#' Public base URL for the portal.
#' @noRd
ee_portal_base <- function() "https://kotkas.envir.ee"

#' Server-side index page size. Hard-coded in the portal's template.
#' @noRd
ee_page_size <- function() 40L

#' EPSG code of the geometry payloads served by KOTKAS.
#'
#' Estonia uses EPSG:3301 (L-EST97) as its standard projected CRS.
#' Recorded on every geojson sidecar and on the record's `geometry_crs`
#' column.
#' @noRd
ee_geometry_crs <- function() "EPSG:3301"

#' Canonical landing URL for a KMH or KSH dossier.
#'
#' The portal's own pagination back-links use `&represented_id=` (empty value),
#' so we mirror that form verbatim. This keeps the URL identical to what a
#' user would copy out of the browser address bar, which is what
#' `sidecar_url_index()` keys on for cache reuse.
#' @noRd
ee_canonical_url <- function(register, id) {
  view <- if (register == "KMH") "kmh_view" else "ksh_view"
  key <- if (register == "KMH") "kmh_id" else "ksh_id"
  sprintf("%s/kmh/%s?%s=%s&represented_id=", ee_portal_base(), view, key, id)
}

#' Document-ID prefix per register so KMH 478 and KSH 478 never collide on disk.
#' @noRd
ee_document_id <- function(register, id) {
  sprintf("%s-%s", register, id)
}

#' Map our `assessment_type` argument to a normalised value.
#' @noRd
ee_normalise_assessment_type <- function(x) {
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

#' Normalise the procedural-status enum.
#' @noRd
ee_normalise_status <- function(x) {
  if (is.null(x) || !nzchar(x)) {
    return(NULL)
  }
  valid <- c("INITIATED", "ONGOING", "SUSPENDED", "FINISHED")
  hit <- valid[toupper(valid) == toupper(x)]
  if (length(hit) == 0L) {
    cli::cli_abort(
      "{.arg proceeding_status} must be one of {.val {valid}} (got {.val {x}}).",
      class = "planscanR_error_bad_input"
    )
  }
  hit
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Paginate one register's index and return a list of search-row entries.
#'
#' Each entry is a small named list:
#' `list(register = "KMH"|"KSH", id = "<n>", title = ..., region = ...,
#'  initiation_date = <Date>, initiation_reason = ..., status = ...,
#'  developer = ...)`. The detail-page parser is sidecar-first, so this is
#' deliberately the minimum needed to build the canonical URL and decide
#' whether to keep going (limit / pre-filter).
#' @noRd
ee_fetch_search <- function(
  register,
  query = NULL,
  proceeding_status = NULL,
  activity_area = NULL,
  activity = NULL,
  limit = Inf
) {
  out <- list()
  offset <- 0L
  size <- ee_page_size()
  index_path <- if (register == "KMH") "kmh/kmh_index" else "kmh/ksh_index"
  tab <- register
  repeat {
    req <- req_planscanr(ee_portal_base())
    req <- httr2::req_url_path_append(req, index_path)
    req <- httr2::req_url_query(
      req,
      tab = tab,
      qs = offset,
      represented_id = "",
      search = "1"
    )
    if (!is.null(query) && nzchar(query)) {
      req <- httr2::req_url_query(req, s__search_keyword = as.character(query))
    }
    if (!is.null(proceeding_status)) {
      req <- httr2::req_url_query(req, s__proceeding_status = proceeding_status)
    }
    if (!is.null(activity_area) && nzchar(activity_area)) {
      req <- httr2::req_url_query(req, s__activity_area = activity_area)
    }
    if (!is.null(activity) && nzchar(activity)) {
      req <- httr2::req_url_query(req, s__activity = activity)
    }
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      break
    }
    rows <- ee_parse_index_rows(html, register)
    if (length(rows) == 0L) {
      break
    }
    out <- c(out, rows)
    # Soft stop: stop paginating once we've enumerated at least `limit * 5` raw
    # rows. Filters / sidecar misses may still drop rows, so we overshoot a bit.
    if (is.finite(limit) && length(out) >= as.integer(limit) * 5L) {
      break
    }
    # Server short-page → we've reached the end.
    if (length(rows) < size) {
      break
    }
    offset <- offset + size
  }
  out
}

#' Parse the rows of one index page.
#' @noRd
ee_parse_index_rows <- function(html, register) {
  trs <- rvest::html_elements(html, "table.table-sorted tbody tr")
  out <- list()
  for (tr in trs) {
    a <- rvest::html_element(tr, "td[data-label='Nimetus'] a")
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    id <- ee_extract_id(href, register)
    if (is.na(id)) {
      next
    }
    title <- ee_text(rvest::html_text2(a))
    region_cell <- ee_text(rvest::html_text2(rvest::html_element(tr, "td[data-label='Piirkond']")))
    init_date <- ee_parse_dmy(ee_text(rvest::html_text2(rvest::html_element(tr, "td[data-label='Algatamise kpv']"))))
    init_reason <- ee_text(rvest::html_text2(rvest::html_element(tr, "td[data-label='Algatamise põhjus']")))
    status_cell <- ee_text(rvest::html_text2(rvest::html_element(tr, "td[data-label='Menetluse seis']")))
    # KMH uses "Arendaja" (developer); KSH uses "Korraldaja" (organiser).
    party_cell <- ee_text(rvest::html_text2(
      rvest::html_element(tr, "td[data-label='Arendaja'], td[data-label='Korraldaja']")
    ))
    # KSH adds a Liik column (planning-document type, e.g. "Detailplaneering");
    # KMH uses Tegevusvaldkond (sector). Capture both when present so the index
    # entry is a useful cheap filter.
    liik_cell <- ee_text(rvest::html_text2(rvest::html_element(tr, "td[data-label='Liik']")))
    sector_cell <- ee_text(rvest::html_text2(rvest::html_element(tr, "td[data-label='Tegevusvaldkond']")))
    out[[length(out) + 1L]] <- list(
      register = register,
      id = id,
      title = title,
      region = region_cell,
      initiation_date = init_date,
      initiation_reason = init_reason,
      status = status_cell,
      developer = party_cell,
      ksh_type = liik_cell,
      activity = sector_cell
    )
  }
  out
}

#' Extract the kmh_id / ksh_id from an `href` attribute.
#' @noRd
ee_extract_id <- function(href, register) {
  key <- if (register == "KMH") "kmh_id" else "ksh_id"
  m <- regmatches(
    href,
    regexec(paste0(key, "=([0-9]+)"), href)
  )[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch detail.
#'
#' Mirrors the BE / NL / DK pattern. When the sidecar is missing, fetches
#' the detail HTML, parses it, and saves the geometry to a sibling
#' `.geometry.geojson` so subsequent runs can pick it up offline.
#' @noRd
ee_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  detail <- ee_fetch_detail(url)
  parsed <- ee_parse_detail(url, entry, detail)
  rec <- parsed$record
  if (write_sidecar && !is.null(parsed$geometry)) {
    geo_path <- ee_save_geometry_to_geojson(
      country = "ee",
      document_id = rec$document_id,
      title = rec$title,
      created_iso = if (is.na(rec$date_published)) NULL else format(rec$date_published, "%Y-%m-%d"),
      geometry = parsed$geometry
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- ee_geometry_crs()
    }
  }
  rec
}

#' Fetch one KMH / KSH detail page as parsed HTML.
#' @noRd
ee_fetch_detail <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Parse one detail page into a 1-row tibble + an inline GeoJSON geometry.
#'
#' Returns `list(record = <tibble>, geometry = <list or NULL>)`. The geometry
#' is the raw GeoJSON value the portal embeds in the hidden form input; the
#' caller persists it next to the sidecar.
#' @noRd
ee_parse_detail <- function(url, entry, html) {
  register <- entry$register
  id <- entry$id
  document_id <- ee_document_id(register, id)

  title <- ee_label_value(html, "registry__name") %||% entry$title %||% NA_character_
  status <- ee_label_value(html, "proceeding_status") %||% entry$status %||% NA_character_
  activity_sector <- ee_label_value(html, "activity") %||% entry$activity %||% NA_character_
  region <- ee_label_value(html, "activity_area") %||% entry$region %||% NA_character_
  kov <- ee_label_value(html, "kov_ehaks")
  init_date <- ee_parse_dmy(ee_label_value(html, "initiation_date")) %||% entry$initiation_date
  if (length(init_date) == 0L || is.null(init_date)) {
    init_date <- as.Date(NA)
  }
  init_reason <- ee_label_value(html, "initiation_reason") %||% entry$initiation_reason
  init_activity <- ee_label_value(html, "initiation_activity")
  summary_text <- ee_label_value(html, "activity_description")

  # KMH-specific actors.
  developer <- ee_label_value(html, "developer")
  decider <- ee_label_value(html, "decider")
  # KSH-specific actors. (KSH detail pages use the same `label_*` ID scheme but
  # with different fields. We collect whichever subset is present.)
  initiator <- ee_label_value(html, "initiator")
  organizer <- ee_label_value(html, "organizer")
  creator <- ee_label_value(html, "creator")
  expert <- ee_label_value(html, "expert")
  supervisor <- ee_label_value(html, "registry__supervisor")

  # Conventional planscanR columns. KMH's Arendaja maps to proponent; for KSH
  # we fall back to SPD koostaja (creator) which is the planner of the planning
  # document. competent_authority is Otsustaja (KMH) or Korraldaja (KSH) — the
  # body that runs the procedure.
  proponent <- developer %||% creator %||% entry$developer %||% NA_character_
  competent_authority <- decider %||% organizer %||% NA_character_

  jurisdiction <- region

  # native_type: the portal's own topic taxonomy. KMH = activity sector;
  # KSH = planning-document type + activity sector (when available).
  ksh_type <- entry$ksh_type
  native_type <- ee_join_labels(c(ksh_type, activity_sector))
  if (is.na(native_type) || !nzchar(native_type)) {
    native_type <- activity_sector
  }

  # Attachments by Liik (document type).
  per_section <- ee_parse_documents(html, register, id)
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  geometry <- ee_parse_inline_geometry(html)

  rec <- tibble::tibble(
    country = "ee",
    source_portal = ee_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = summary_text %||% NA_character_,
    competent_authority = competent_authority %||% NA_character_,
    proponent = proponent,
    date_published = init_date,
    date_decision = as.Date(NA),
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status %||% NA_character_,
    assessment_type = if (register == "KMH") "EIA" else "SEA",
    register = register,
    initiation_reason = init_reason %||% NA_character_,
    initiation_activity = init_activity %||% NA_character_,
    municipality = kov %||% NA_character_,
    activity_sector = activity_sector %||% NA_character_,
    ksh_type = ksh_type %||% NA_character_,
    decider = decider %||% NA_character_,
    developer = developer %||% NA_character_,
    initiator = initiator %||% NA_character_,
    organizer = organizer %||% NA_character_,
    creator = creator %||% NA_character_,
    expert = expert %||% NA_character_,
    supervisor = supervisor %||% NA_character_,
    geometry_path = NA_character_,
    geometry_crs = NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  list(record = rec, geometry = geometry)
}

#' Pull the textual value associated with a `<label id="label_<key>">`.
#'
#' Returns trimmed text from the sibling `.col-md-9` value cell, or `NULL`
#' if the label is absent. The portal's form layout puts the value div
#' immediately after the label in the same `.form-group`.
#' @noRd
ee_label_value <- function(html, key) {
  selector <- sprintf("label#label_%s", key)
  label <- rvest::html_element(html, selector)
  if (length(label) == 0L || inherits(label, "xml_missing")) {
    return(NULL)
  }
  # Walk up to the .form-group and find its value cell.
  group <- rvest::html_element(label, xpath = "ancestor::div[contains(@class,'form-group')][1]")
  if (length(group) == 0L || inherits(group, "xml_missing")) {
    return(NULL)
  }
  value_cell <- rvest::html_element(group, "div.col-md-9, div.col-md-10, div.col-md-11")
  if (length(value_cell) == 0L || inherits(value_cell, "xml_missing")) {
    return(NULL)
  }
  # The portal wraps several fields in `<!--small -->VALUE<!--/small -->`
  # HTML comments. libxml2 renders the *content* of those comments as text,
  # so a value like "AS TREV-2 Grupp" otherwise comes back as
  # "small AS TREV-2 Grupp/small". Strip every comment node before reading
  # the textual value. We re-parse the cell as HTML (the cell may contain
  # unclosed `<br>` tags, so the strict XML parser would refuse it) and
  # then xml_remove() the comment children before extracting text.
  cell <- xml2::read_html(as.character(value_cell))
  comments <- xml2::xml_find_all(cell, ".//comment()")
  if (length(comments) > 0L) {
    xml2::xml_remove(comments)
  }
  ee_text(rvest::html_text2(cell))
}

#' Parse the Dokumendid table into a named list of URL vectors keyed by Liik.
#'
#' The Dokumendid section is the only `<h2>Dokumendid</h2>` heading on the
#' page; we scope to the table immediately following it. Each row carries
#' the document title (with its download URL), size, Liik (type), document
#' date, content excerpt, and date added. Empty types fall back to
#' `"document"` so the sidecar still has a stable section tag.
#' @noRd
ee_parse_documents <- function(html, register, id) {
  heading <- rvest::html_element(html, "a#kmh_attachment, a#ksh_attachment")
  if (length(heading) == 0L || inherits(heading, "xml_missing")) {
    return(list())
  }
  table <- rvest::html_element(heading, xpath = "following::table[1]")
  if (length(table) == 0L || inherits(table, "xml_missing")) {
    return(list())
  }
  trs <- rvest::html_elements(table, "tbody tr")
  per_section <- list()
  for (tr in trs) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) < 3L) {
      next
    }
    a <- rvest::html_element(tds[[1]], "a")
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    url <- ee_absolute_url(href)
    liik <- ee_text(rvest::html_text2(tds[[3]]))
    slug <- ee_section_slug(liik)
    per_section[[slug]] <- unique(c(per_section[[slug]], url))
  }
  per_section
}

#' Resolve a relative portal href to an absolute URL.
#' @noRd
ee_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(ee_portal_base(), href)
}

#' Slug a `Liik` string to an ASCII column-suffix slug.
#'
#' Lowercases, transliterates Estonian diacritics, and collapses
#' non-alphanumerics to underscores. Empty input gets `"document"` as a
#' deterministic fallback.
#' @noRd
ee_section_slug <- function(liik) {
  if (is.null(liik) || !is.character(liik) || length(liik) != 1L || is.na(liik) || !nzchar(liik)) {
    return("document")
  }
  s <- liik
  # Estonian diacritics that show up in document type labels.
  s <- gsub("ä", "a", s)
  s <- gsub("ö", "o", s)
  s <- gsub("õ", "o", s)
  s <- gsub("ü", "u", s)
  s <- gsub("š", "s", s)
  s <- gsub("ž", "z", s)
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "document" else s
}

#' Pull the inline GeoJSON geometry from the hidden form input.
#'
#' The portal embeds the activity area as a JSON string in
#' `<input id="activity_area_geojson" value="{...}">`. Returns the parsed
#' object (a list with `type` and `coordinates`), or NULL if absent /
#' unparseable.
#' @noRd
ee_parse_inline_geometry <- function(html) {
  el <- rvest::html_element(html, "input#activity_area_geojson")
  if (length(el) == 0L || inherits(el, "xml_missing")) {
    return(NULL)
  }
  raw <- rvest::html_attr(el, "value")
  if (is.na(raw) || !nzchar(raw)) {
    return(NULL)
  }
  parsed <- tryCatch(
    jsonlite::fromJSON(raw, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(parsed) || is.null(parsed$type) || is.null(parsed$coordinates)) {
    return(NULL)
  }
  parsed
}

# -----------------------------------------------------------------------------
# Geometry → linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save the inline geometry next to its sidecar as GeoJSON.
#'
#' Wraps the geometry in a `FeatureCollection`, tags the CRS via the
#' GeoJSON-2008 `crs` member, and persists it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`. Coordinates are kept in
#' the source EPSG:3301; downstream tools that need WGS84 reproject with
#' `sf`.
#' @noRd
ee_save_geometry_to_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  if (is.null(geometry$type) || !nzchar(geometry$type)) {
    return(NULL)
  }
  out_path <- ee_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", ee_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = ee_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = ee_geometry_crs()
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
ee_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed EE record: run downloads (if requested) and write sidecar.
#' @noRd
ee_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "ee"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "ee",
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

#' Apply post-fetch client-side filters.
#'
#' Server-side filters (`query`, `proceeding_status`, `activity_area`,
#' `activity`) are honoured by the portal itself, so by the time a record
#' arrives here it has already passed those. Only `date_range` is enforced
#' here, against `date_published`.
#' @noRd
ee_record_matches <- function(rec, date_range) {
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
ee_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  # Collapse internal runs of whitespace (HTML form layout introduces a lot of
  # newlines + indentation). Keep the visible text but lose the indentation.
  s <- gsub("[ \t]*\n[ \t]*", "\n", s)
  s <- gsub("[ \t]{2,}", " ", s)
  s <- gsub("\n{2,}", "\n", s)
  s <- trimws(s)
  if (!nzchar(s)) NULL else s
}

#' Join a vector of category labels into a single "; "-separated scalar.
#' @noRd
ee_join_labels <- function(labels) {
  labels <- labels[!is.na(labels) & nzchar(labels)]
  if (length(labels) == 0L) {
    return(NA_character_)
  }
  paste(unique(labels), collapse = " | ")
}

#' Parse a Estonian DD.MM.YYYY date string into a Date.
#' @noRd
ee_parse_dmy <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  # The portal uses DD.MM.YYYY consistently; the value cell can wrap text so
  # take only the first 10 characters.
  s <- substr(trimws(s), 1L, 10L)
  d <- suppressWarnings(as.Date(s, format = "%d.%m.%Y"))
  if (length(d) == 0L) as.Date(NA) else d
}
