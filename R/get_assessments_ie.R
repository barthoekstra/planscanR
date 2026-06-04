#' Fetch environmental-assessment records from Ireland.
#'
#' Implementation of [get_assessments()] for Ireland's **EIA Portal**
#' (<https://experience.arcgis.com/experience/a1a85d92623147b191dd25a14b2571da/>),
#' the gov.ie public map of Environmental Impact Assessment applications,
#' served by a public anonymous **Esri ArcGIS REST FeatureServer**
#' (`services.arcgis.com`, the `EIA_Location_Point` master layer, ≈5,100
#' records). This is the package's first ArcGIS REST handler: transport is
#' plain `GET` with `f=json`, pagination is `resultOffset` / `resultRecordCount`,
#' and Esri point geometry is converted to GeoJSON in-house.
#'
#' @section What this handler returns (IMPORTANT — EIA only, notices only):
#' The portal covers **EIA applications only** — there is **no SEA register**
#' here. For each application the portal hosts (at most) the statutory
#' **newspaper / public-notice PDF**; the full EIAR (Environmental Impact
#' Assessment Report) itself is **off-portal**, on the relevant
#' competent-authority website (An Bord Pleanála, the local council, the EPA,
#' ...). Those external case pages are surfaced as the extras columns
#' `url_link_application` / `url_link_secondary` (HTML landing pages on
#' heterogeneous third-party sites, *not* direct PDFs) and are deliberately
#' kept out of `attachment_urls`; treat them as a discovery target. So plan for
#' a corpus of public-notice PDFs plus off-portal EIAR links, not the EIARs
#' themselves.
#'
#' @section The OBJECTID_1 gotcha:
#' The layer's unique object-id field is **`OBJECTID_1`**, *not* the plain
#' `OBJECTID` (which is non-unique on this layer and frequently `0`). All
#' attachment lookups and the internal id fallback key off `OBJECTID_1`.
#'
#' @section URL enumeration:
#' Listing is `GET <layer>/query`, paginated with `resultOffset` /
#' `resultRecordCount` (page size 1000, the server's `maxRecordCount`), looping
#' while `exceededTransferLimit` is true. A stable `orderByFields=OBJECTID_1 ASC`
#' fixes the page ordering. Each feature carries all its metadata inline in
#' `attributes` (there is no separate detail endpoint), plus an Esri point
#' `geometry` requested in `outSR=2157`. Enumeration is **streaming**: a page
#' generator yields one `resultOffset` page at a time (and resolves that page's
#' notice attachments in a single batched `queryAttachments` call) so records
#' are parsed and persisted page-by-page rather than after a full register scan.
#'
#' The portal has **no per-record permalink**, so a unique, deterministic `url`
#' is synthesised per record: the record-specific query URL
#' `<layer>/query?where=Portal_Ref='<ref>'&outFields=*&f=json` (stable and
#' meaningful — it is the record's landing query). This keeps the sidecar-first
#' path keyed on a stable url.
#'
#' Server-side `where` filters honoured here:
#' * `query` -> `UPPER(Description__Max__256_character) LIKE '%<QUERY>%'`
#'   (free-text over the description).
#' * `competent_authority` -> `Competent_Authority = '<value>'`.
#' * `date_range` -> a `Date_of_receipt_of_application_` BETWEEN window
#'   (epoch-milliseconds), re-checked client-side as a guard.
#'
#' @section Geometry:
#' Each record carries an Esri point `geometry` (`{x, y}`) in **Irish Transverse
#' Mercator (IRENET95 ITM / EPSG:2157)** — requested via `outSR=2157`. It is
#' converted in-house to a GeoJSON **Point** (`{type:"Point", coordinates:[x,y]}`)
#' and, when `write_sidecar = TRUE`, written next to the sidecar as
#' `<document_id>.geometry.geojson` in the family FeatureCollection layout with
#' the GeoJSON-2008 `crs` member naming `urn:ogc:def:crs:EPSG::2157`. No
#' reprojection happens — coordinates stay in EPSG:2157. The sidecar carries
#' `geometry_path` and `geometry_crs` (`"EPSG:2157"`). Records with a null
#' geometry leave the geometry columns `NA`.
#'
#' @section Attachments:
#' Portal-hosted attachments are ArcGIS feature attachments — the statutory
#' newspaper / public-notice PDF. Because the download URL needs both the
#' `OBJECTID_1` and the per-attachment id (`<layer>/<OBJECTID_1>/attachments/<id>`),
#' attachment metadata is resolved in a batched **per-page** `queryAttachments`
#' call (keyed by `OBJECTID_1`) — even when `download = FALSE`, this is needed
#' to populate `attachment_urls`. The single slug is `notice`
#' (`attachment_urls_notice` / `local_path_notice`); the deduplicated union goes
#' to `attachment_urls` / `local_path` (required by the schema). A record may
#' carry **0** attachments (still schema-valid).
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side description substring
#'   (`UPPER(Description__Max__256_character) LIKE`).
#' * `competent_authority` — server-side equality on `Competent_Authority`
#'   (see [get_assessments_coverage()] / `eia_portal_ie_facets()`).
#' * `date_range` — server-side window on `Date_of_receipt_of_application_`
#'   (the application-receipt date), re-checked client-side against
#'   `date_published`. `date_decision` is `NA` (the layer exposes no
#'   decision-date field).
#'
#' @section Performance:
#' Enumeration is ≈6 paginated `query` calls (page size 1000) plus one batched
#' `queryAttachments` lookup per page (many `OBJECTID_1`s per call). IE requests
#' are throttled to 5 requests per second by default; override via
#' `getOption("planscanR.ie_throttle_rate")` (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query; sent server-side as a description `LIKE`.
#' @param competent_authority Optional competent-authority name (server-side
#'   equality on `Competent_Authority`), e.g. `"An Bord Pleanála"`. See
#'   `eia_portal_ie_facets()`.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test (EIA applications; portal hosts the notice PDF only)
#' get_assessments_ie(limit = 3, download = FALSE)
#'
#' # Wind-themed slice (server-side description LIKE)
#' get_assessments_ie(query = "wind", limit = 20, download = FALSE)
#'
#' # An Bord Pleanála applications only
#' get_assessments_ie(
#'   competent_authority = "An Bord Pleanála",
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_ie <- function(
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
  competent_authority = NULL,
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
  # Politeness throttle. Enumeration is ~6 page calls plus a batched attachment
  # lookup per page and one download per attachment; cap at 5 req/s by default.
  # Override via `planscanR.ie_throttle_rate`.
  rate <- getOption("planscanR.ie_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "ie")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("ie")
  } else {
    stats::setNames(character(0), character(0))
  }

  where <- ie_build_where(
    query = query,
    competent_authority = competent_authority,
    date_range = date_range
  )

  # Per-entry processing: sidecar-first detail parse, client-side date guard,
  # relevance scoring, optional download, and the sidecar write. Returns the
  # 1-row record or NULL to drop the entry. Each entry carries its inline
  # feature plus the page's resolved OBJECTID_1 -> notice-URL index. Called once
  # per listing row by stream_crawl().
  process_entry <- function(entry) {
    feature <- entry$feature
    attach_index <- entry$attach_index %||% list()
    ref <- ie_portal_ref(feature)
    if (is.null(ref)) {
      return(NULL)
    }
    u <- ie_canonical_url(ref)
    rec <- tryCatch(
      ie_load_or_fetch(
        u,
        feature,
        attach_index,
        sidecar_index,
        write_sidecar = write_sidecar
      ),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!ie_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    ie_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream the register page-by-page, persisting records as they are parsed
  # instead of enumerating the whole layer first. The generator owns the
  # resultOffset pagination state and resolves each page's notice attachments.
  gen <- tryCatch(
    ie_fetch_features(where = where),
    error = function(e) {
      warn_partial("Failed to enumerate the EIA Portal: {conditionMessage(e)}")
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "ie")

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
ie_source_portal <- function() "services.arcgis.com (gov.ie EIA Portal)"

#' ArcGIS REST FeatureServer layer base for the EIA master point layer.
#'
#' The full 5,104-record master layer. (NOT the 2025+ `*_view` slice nor the
#' superseded archive layer.)
#' @noRd
ie_layer_base <- function() {
  paste0(
    "https://services.arcgis.com/NzlPQPKn5QF9v2US/arcgis/rest/services/",
    "EIA_Location_Point/FeatureServer/0"
  )
}

#' Server `maxRecordCount` / our enumeration page size.
#' @noRd
ie_page_size <- function() 1000L

#' EPSG code of the geometry payloads (Irish Transverse Mercator, IRENET95 ITM).
#'
#' We request `outSR=2157`, so geometry comes back in EPSG:2157 and is stored
#' verbatim (no reprojection).
#' @noRd
ie_geometry_crs <- function() "EPSG:2157"

#' Numeric `outSR` / `inSR` wkid for the geometry payloads.
#' @noRd
ie_out_sr <- function() 2157L

#' Canonical landing URL for a record (the record-specific query URL).
#'
#' The portal has no per-record permalink, so we synthesise a unique,
#' deterministic, record-specific query URL on `Portal_Ref`. This is stable and
#' meaningful (it returns exactly the record), and keys the sidecar-first path.
#' @noRd
ie_canonical_url <- function(portal_ref) {
  sprintf(
    "%s/query?where=Portal_Ref='%s'&outFields=*&f=json",
    ie_layer_base(),
    portal_ref
  )
}

#' Build the download URL for a single ArcGIS feature attachment.
#'
#' Anonymous; form `<layer>/<OBJECTID_1>/attachments/<attachmentId>`.
#' @noRd
ie_attachment_url <- function(oid, attachment_id) {
  sprintf("%s/%s/attachments/%s", ie_layer_base(), oid, attachment_id)
}

# -----------------------------------------------------------------------------
# Network seam (the single ArcGIS REST GET wrapper tests mock)
# -----------------------------------------------------------------------------

#' Thin ArcGIS REST GET seam: `GET <layer>/<path>?<query>&f=json`.
#'
#' All network access in this handler funnels through here so tests can mock a
#' single binding. `path` is appended to the layer base (e.g. `"query"` or
#' `"queryAttachments"`); `query` is a named list of query parameters (`f=json`
#' is always added). Returns the parsed JSON (a named list).
#' @noRd
ie_arcgis_get <- function(path, query = list()) {
  req <- req_planscanr(ie_layer_base())
  if (!is.null(path) && nzchar(path)) {
    req <- httr2::req_url_path_append(req, path)
  }
  query$f <- "json"
  req <- do.call(httr2::req_url_query, c(list(req), query))
  perform_json(req)
}

# -----------------------------------------------------------------------------
# Server-side `where` clause
# -----------------------------------------------------------------------------

#' Build the server-side ArcGIS `where` clause from the active filters.
#'
#' Returns a single SQL-ish string (joined with ` AND `), or `"1=1"` when no
#' filter is active (the layer requires a `where`). `query` becomes an
#' `UPPER(Description...) LIKE` predicate; `competent_authority` an equality;
#' `date_range` a `Date_of_receipt_of_application_` BETWEEN window in epoch ms.
#' @noRd
ie_build_where <- function(query = NULL, competent_authority = NULL, date_range = NULL) {
  clauses <- character(0)
  if (!is.null(query) && nzchar(query)) {
    clauses <- c(
      clauses,
      sprintf(
        "UPPER(Description__Max__256_character) LIKE '%%%s%%'",
        ie_sql_escape(toupper(query))
      )
    )
  }
  if (!is.null(competent_authority) && nzchar(competent_authority)) {
    clauses <- c(
      clauses,
      sprintf("Competent_Authority = '%s'", ie_sql_escape(competent_authority))
    )
  }
  if (!is.null(date_range)) {
    from_ms <- ie_date_to_epoch_ms(date_range[1])
    to_ms <- ie_date_to_epoch_ms(date_range[2])
    clauses <- c(
      clauses,
      sprintf(
        "Date_of_receipt_of_application_ BETWEEN %s AND %s",
        format(from_ms, scientific = FALSE),
        format(to_ms, scientific = FALSE)
      )
    )
  }
  if (length(clauses) == 0L) {
    return("1=1")
  }
  paste(clauses, collapse = " AND ")
}

#' Escape single quotes for an ArcGIS SQL string literal.
#' @noRd
ie_sql_escape <- function(x) {
  gsub("'", "''", x)
}

#' Convert a Date to epoch milliseconds (UTC midnight).
#' @noRd
ie_date_to_epoch_ms <- function(d) {
  as.numeric(as.POSIXct(as.Date(d), tz = "UTC")) * 1000
}

# -----------------------------------------------------------------------------
# Index enumeration (streaming, paginated /query)
# -----------------------------------------------------------------------------

#' Build a page generator for the EIA Portal `/query` listing.
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call fetches the next `resultOffset` page (page size = server
#' `maxRecordCount`), resolves that page's notice attachments in one batched
#' `queryAttachments` call, and returns the page's listing entries as a list, or
#' `NULL` once the layer is exhausted. The `resultOffset` / done state lives in
#' the closure via `<<-`, so the streaming driver pulls only as many pages as
#' the limit needs and records are persisted page-by-page.
#'
#' Each entry is a small named list `list(feature = <inline feature>,
#' attach_index = <OBJECTID_1 -> notice URLs>)`. Pagination requests geometry in
#' `outSR=2157` and a stable `orderByFields`, and ends when `exceededTransferLimit`
#' is false/absent and a short (sub-page-size) page comes back (or an empty page).
#' @noRd
ie_fetch_features <- function(where = "1=1") {
  offset <- 0L
  size <- ie_page_size()
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    payload <- ie_arcgis_get(
      "query",
      list(
        where = where,
        outFields = "*",
        returnGeometry = "true",
        outSR = ie_out_sr(),
        resultRecordCount = size,
        resultOffset = offset,
        orderByFields = "OBJECTID_1 ASC"
      )
    )
    if (!is.list(payload)) {
      done <<- TRUE
      return(NULL)
    }
    feats <- payload$features %||% list()
    if (length(feats) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    # Termination: a short page (fewer than the page size) with no further
    # transfer-limit overflow is the last page.
    exceeded <- isTRUE(payload$exceededTransferLimit)
    if (!exceeded && length(feats) < size) {
      done <<- TRUE
    }
    offset <<- offset + length(feats)

    # Resolve this page's notice attachments in one batched queryAttachments
    # call so each emitted entry carries its OBJECTID_1 -> notice-URL index.
    oids <- ie_feature_oids(feats)
    attach_index <- tryCatch(
      ie_fetch_attachments(oids),
      error = function(e) {
        warn_partial("Failed to resolve EIA Portal attachments: {conditionMessage(e)}")
        list()
      }
    )
    lapply(feats, function(f) list(feature = f, attach_index = attach_index))
  }
}

# -----------------------------------------------------------------------------
# Phase 2: batched attachment resolution
# -----------------------------------------------------------------------------

#' Collect the distinct OBJECTID_1 ids of a feature set.
#'
#' Returns a character vector of distinct OBJECTID_1 values.
#' @noRd
ie_feature_oids <- function(features) {
  if (length(features) == 0L) {
    return(character(0))
  }
  oids <- vapply(
    features,
    function(f) ie_oid(f) %||% NA_character_,
    character(1)
  )
  unique(oids[!is.na(oids)])
}

#' Batched `queryAttachments` -> a named list `OBJECTID_1 -> attachment URLs`.
#'
#' Sends `objectIds` (comma-separated OBJECTID_1 list) in batches and walks the
#' `attachmentGroups` envelope, building the download URL for each attachment
#' from `parentObjectId` (== OBJECTID_1) + `attachmentInfos[].id`. Returns a
#' named list keyed by OBJECTID_1 (character) of character vectors of URLs;
#' OBJECTID_1s with no attachments simply don't appear.
#' @noRd
ie_fetch_attachments <- function(oids, batch_size = 100L) {
  if (length(oids) == 0L) {
    return(list())
  }
  out <- list()
  batches <- split(oids, ceiling(seq_along(oids) / batch_size))
  for (batch in batches) {
    payload <- ie_arcgis_get(
      "queryAttachments",
      list(objectIds = paste(batch, collapse = ","))
    )
    if (!is.list(payload)) {
      next
    }
    groups <- payload$attachmentGroups %||% list()
    for (grp in groups) {
      parent <- ie_text(grp$parentObjectId)
      if (is.null(parent)) {
        next
      }
      infos <- grp$attachmentInfos %||% list()
      urls <- character(0)
      for (info in infos) {
        aid <- ie_text(info$id)
        if (is.null(aid)) {
          next
        }
        urls <- c(urls, ie_attachment_url(parent, aid))
      }
      if (length(urls) > 0L) {
        out[[parent]] <- unique(c(out[[parent]], urls))
      }
    }
  }
  out
}

# -----------------------------------------------------------------------------
# Record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else parse the feature.
#'
#' When the sidecar is missing, parses the inline feature into a 1-row tibble
#' (resolving its notice-PDF attachment URLs from `attach_index`) and, when the
#' feature carries a point geometry, saves it to a sibling `.geometry.geojson`
#' so subsequent runs pick it up offline.
#' @noRd
ie_load_or_fetch <- function(url, feature, attach_index, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  rec <- ie_parse_feature(url, feature, attach_index)
  geometry <- ie_geometry_of(feature)
  if (write_sidecar && !is.null(geometry)) {
    geo_path <- ie_save_geometry_to_geojson(
      country = "ie",
      document_id = rec$document_id,
      title = rec$title,
      created_iso = ie_epoch_ms_to_iso(ie_attr(feature, "Date_of_receipt_of_application_")),
      geometry = geometry
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- ie_geometry_crs()
    }
  }
  rec
}

#' Build a 1-row record tibble from one inline ArcGIS feature.
#'
#' Maps the layer's `attributes` onto the conventional planscanR columns, keeps
#' the source vocabulary verbatim (no normalisation at fetch time), and emits
#' the single `attachment_urls_notice` / `local_path_notice` pair when the
#' feature has portal-hosted attachments (resolved via `attach_index`).
#' @noRd
ie_parse_feature <- function(url, feature, attach_index) {
  ref <- ie_portal_ref(feature)
  oid <- ie_oid(feature)

  title <- ie_attr(feature, "Description__Max__256_character") %||% NA_character_
  proponent <- ie_attr(feature, "Applicant_name") %||% NA_character_
  competent_authority <- ie_attr(feature, "Competent_Authority") %||% NA_character_
  jurisdiction <- ie_attr(feature, "Location") %||% NA_character_
  native_type <- ie_attr(feature, "Linear_Development") %||% NA_character_

  date_published <- ie_epoch_ms_to_date(ie_attr(feature, "Date_of_receipt_of_application_"))

  url_link_application <- ie_attr(feature, "URL_link_to_application_appeal_") %||% NA_character_
  url_link_secondary <- ie_attr(feature, "URL_link_2__if_any_") %||% NA_character_

  per_section <- list()
  notice_urls <- if (!is.null(oid)) attach_index[[oid]] else NULL
  if (!is.null(notice_urls) && length(notice_urls) > 0L) {
    per_section[["notice"]] <- unique(notice_urls)
  }
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "ie",
    source_portal = ie_source_portal(),
    document_id = ref %||% oid %||% NA_character_,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    # No narrative abstract in the layer; the classifier works off title +
    # native_type + jurisdiction.
    summary = NA_character_,
    competent_authority = competent_authority,
    proponent = proponent,
    date_published = date_published,
    # The layer exposes no decision-date field.
    date_decision = as.Date(NA),
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction,
    # Country-specific extras.
    portal_ref = ref %||% NA_character_,
    esri_object_id = oid %||% NA_character_,
    linear_development = native_type %||% NA_character_,
    url_link_application = url_link_application,
    url_link_secondary = url_link_secondary,
    competent_authority_application = ie_attr(feature, "Competent_Authority_Application") %||%
      NA_character_,
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

#' Extract the stable `Portal_Ref` business key from a feature (-> document_id).
#' @noRd
ie_portal_ref <- function(feature) {
  ie_attr(feature, "Portal_Ref")
}

#' Extract the OBJECTID_1 (NOT plain OBJECTID) as a character, or NULL.
#'
#' The plain `OBJECTID` is non-unique on this layer (often 0); `OBJECTID_1` is
#' the unique id field, used for attachment lookups + as a fallback id.
#' @noRd
ie_oid <- function(feature) {
  ie_attr(feature, "OBJECTID_1")
}

#' Read a single attribute off a feature as a trimmed non-empty character.
#' @noRd
ie_attr <- function(feature, name) {
  attrs <- feature$attributes %||% list()
  ie_text(attrs[[name]])
}

#' Convert an Esri point `{x, y}` geometry to a bare GeoJSON Point geometry.
#'
#' Returns `{type:"Point", coordinates:[x, y]}` (coordinates kept in the source
#' EPSG:2157), or NULL when the feature has no usable point geometry.
#' @noRd
ie_geometry_of <- function(feature) {
  geom <- feature$geometry
  if (is.null(geom) || !is.list(geom)) {
    return(NULL)
  }
  x <- suppressWarnings(as.numeric(geom$x))
  y <- suppressWarnings(as.numeric(geom$y))
  if (length(x) != 1L || length(y) != 1L || is.na(x) || is.na(y)) {
    return(NULL)
  }
  list(type = "Point", coordinates = c(x, y))
}

# -----------------------------------------------------------------------------
# Geometry -> linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save a record's Point geometry next to its sidecar as GeoJSON.
#'
#' Wraps the geometry in a `FeatureCollection`, tags the CRS via the
#' GeoJSON-2008 `crs` member (`urn:ogc:def:crs:EPSG::2157`), and persists it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`. Coordinates are kept in the
#' source EPSG:2157 (Irish Transverse Mercator).
#' @noRd
ie_save_geometry_to_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  if (is.null(geometry$type) || !nzchar(geometry$type)) {
    return(NULL)
  }
  out_path <- ie_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", ie_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = ie_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = ie_geometry_crs()
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
ie_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed IE record: run downloads (if requested) and write sidecar.
#'
#' Threads the single `notice` section so `attachment_urls_notice` gets a
#' parallel `local_path_notice` once the download status is known.
#' @noRd
ie_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "ie"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "ie",
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

#' Apply post-fetch client-side filters to a parsed IE record.
#'
#' `query` / `competent_authority` / `date_range` are handled server-side via
#' the `where` clause; `date_range` is re-checked client-side here as a
#' belt-and-braces guard (and so the sidecar-first path, which never sees the
#' `where`, still honours the window). The window is matched against
#' `date_published` (the application-receipt date the server filters on).
#' @noRd
ie_record_matches <- function(rec, date_range) {
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
ie_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Convert an epoch-milliseconds value to a Date (UTC), or NA.
#' @noRd
ie_epoch_ms_to_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  n <- suppressWarnings(as.numeric(x))
  if (is.na(n)) {
    return(as.Date(NA))
  }
  as.Date(as.POSIXct(n / 1000, origin = "1970-01-01", tz = "UTC"))
}

#' Convert an epoch-milliseconds value to an ISO date string, or NULL.
#' @noRd
ie_epoch_ms_to_iso <- function(x) {
  d <- ie_epoch_ms_to_date(x)
  if (is.na(d)) NULL else format(d, "%Y-%m-%d")
}
