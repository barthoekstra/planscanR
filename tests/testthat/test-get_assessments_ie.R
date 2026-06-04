# Tests for get_assessments_ie(). Offline strategy: stub the single ArcGIS REST
# GET seam `ie_arcgis_get` so it serves the recorded fixtures
# (tests/testthat/fixtures/ie/) for the `query` and `queryAttachments` paths;
# no live HTTP is needed in CI. Fixtures:
#  - query_page1.json: a /query page envelope (wkid 2157) with 3 features:
#      * OBJECTID_1 5427 / Portal_Ref 2024092 — wind farm: point geometry +
#        a portal-hosted notice attachment (in query_attachments.json).
#      * OBJECTID_1 1115 / Portal_Ref 2020010 — flood scheme: point geometry +
#        a notice attachment.
#      * OBJECTID_1 9001 / Portal_Ref 2023500 — NO geometry and NO attachment
#        (covers the no-geometry / no-attachment edge case).
#  - query_attachments.json: a queryAttachments envelope keyed by OBJECTID_1.

ie_fixture <- function(name) {
  jsonlite::fromJSON(fixture_path("ie", name), simplifyVector = FALSE)
}

# Pre-load fixtures at file-load time (before any withr::with_tempdir()).
.ie_page <- ie_fixture("query_page1.json")
.ie_features <- .ie_page$features
.ie_qa <- ie_fixture("query_attachments.json")
.ie_feat_geo <- .ie_features[[1]] # 5427, geometry + attachment
.ie_feat_nogeo <- .ie_features[[3]] # 9001, no geometry, no attachment

# Build the OBJECTID_1 -> notice-URL index once, the way the handler does.
.ie_attach_index <- local({
  out <- list()
  for (grp in .ie_qa$attachmentGroups) {
    parent <- as.character(grp$parentObjectId)
    urls <- vapply(
      grp$attachmentInfos,
      function(i) planscanR:::ie_attachment_url(parent, i$id),
      character(1)
    )
    out[[parent]] <- urls
  }
  out
})

# A mock for the single network seam. Routes on `path`.
mock_arcgis <- function(features = .ie_features, qa = .ie_qa) {
  function(path, query = list()) {
    if (identical(path, "query")) {
      list(
        spatialReference = list(wkid = 2157L),
        exceededTransferLimit = FALSE,
        features = features
      )
    } else if (identical(path, "queryAttachments")) {
      qa
    } else {
      stop(sprintf("unexpected ArcGIS path: %s", path))
    }
  }
}

# -- Parse unit tests -------------------------------------------------------

test_that("ie_parse_feature extracts every conventional column (feature with geometry + notice)", {
  url <- planscanR:::ie_canonical_url("2024092")
  rec <- planscanR:::ie_parse_feature(url, .ie_feat_geo, .ie_attach_index)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "ie")
  expect_identical(rec$source_portal, "services.arcgis.com (gov.ie EIA Portal)")
  expect_identical(rec$document_id, "2024092")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Offshore wind farm")
  expect_true(is.na(rec$summary))
  # Conventional cross-portal columns.
  expect_identical(rec$competent_authority, "An Bord Pleanála")
  expect_identical(rec$proponent, "North Irish Sea Array Windfarm Limited")
  expect_match(rec$jurisdiction, "coast")
  expect_identical(rec$native_type, "Yes")
  # Epoch-milliseconds date conversion (1726531200000 -> 2024-09-17 UTC).
  expect_identical(rec$date_published, as.Date("2024-09-17"))
  expect_true(is.na(rec$date_decision))
  # Country-specific extras.
  expect_identical(rec$portal_ref, "2024092")
  expect_identical(rec$esri_object_id, "5427")
  expect_identical(rec$linear_development, "Yes")
  expect_match(rec$url_link_application, "pleanala\\.ie")
  expect_match(rec$url_link_secondary, "gov\\.ie")

  # Attachment: single portal-hosted newspaper-notice PDF, URL built from
  # OBJECTID_1 (5427) + attachmentId (5448).
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 1L)
  expect_identical(
    urls[[1]],
    paste0(planscanR:::ie_layer_base(), "/5427/attachments/5448")
  )
  expect_true("attachment_urls_notice" %in% names(rec))
  expect_identical(rec$attachment_urls_notice[[1]], urls)
  # The off-portal EIAR links must NOT enter the attachment columns.
  expect_false(rec$url_link_application %in% urls)
})

test_that("ie_geometry_of converts an Esri point {x,y} to a GeoJSON Point (wkid 2157)", {
  geom <- planscanR:::ie_geometry_of(.ie_feat_geo)
  expect_identical(geom$type, "Point")
  expect_length(geom$coordinates, 2L)
  # coordinates kept verbatim in EPSG:2157 [x, y]
  expect_equal(geom$coordinates[[1]], 715871.6292, tolerance = 1e-4)
  expect_equal(geom$coordinates[[2]], 734092.5021, tolerance = 1e-4)
})

test_that("ie_parse_feature handles a feature without geometry and without an attachment", {
  url <- planscanR:::ie_canonical_url("2023500")
  rec <- planscanR:::ie_parse_feature(url, .ie_feat_nogeo, .ie_attach_index)

  expect_identical(rec$document_id, "2023500")
  expect_identical(rec$esri_object_id, "9001")
  # No geometry present.
  expect_null(planscanR:::ie_geometry_of(.ie_feat_nogeo))
  expect_true(is.na(rec$geometry_path))
  # No attachments — still schema-valid (zero-length union).
  expect_identical(rec$attachment_urls[[1]], character(0))
  expect_false("attachment_urls_notice" %in% names(rec))
})

test_that("ie_geometry_of returns NULL on missing / malformed geometry", {
  expect_null(planscanR:::ie_geometry_of(list(geometry = NULL)))
  expect_null(planscanR:::ie_geometry_of(list(geometry = list(x = "a", y = "b"))))
})

# -- Attachment resolution --------------------------------------------------

test_that("ie_fetch_attachments builds notice download URLs from OBJECTID_1 + attachmentId", {
  local_mocked_bindings(ie_arcgis_get = mock_arcgis())
  idx <- planscanR:::ie_fetch_attachments(c("5427", "1115", "9001"))
  expect_setequal(names(idx), c("5427", "1115"))
  expect_identical(
    idx[["5427"]],
    paste0(planscanR:::ie_layer_base(), "/5427/attachments/5448")
  )
  expect_identical(
    idx[["1115"]],
    paste0(planscanR:::ie_layer_base(), "/1115/attachments/992")
  )
  # OBJECTID_1 with no attachment doesn't appear.
  expect_false("9001" %in% names(idx))
})

# -- where-clause + filters -------------------------------------------------

test_that("ie_build_where composes server-side query / authority / date clauses", {
  expect_identical(planscanR:::ie_build_where(), "1=1")
  expect_match(
    planscanR:::ie_build_where(query = "wind"),
    "UPPER\\(Description__Max__256_character\\) LIKE '%WIND%'"
  )
  expect_match(
    planscanR:::ie_build_where(competent_authority = "An Bord Pleanála"),
    "Competent_Authority = 'An Bord Pleanála'"
  )
  w <- planscanR:::ie_build_where(date_range = planscanR:::parse_date_range(c("2024-01-01", "2024-12-31")))
  expect_match(w, "Date_of_receipt_of_application_ BETWEEN")
  # Single-quote escaping.
  expect_match(
    planscanR:::ie_build_where(competent_authority = "O'Brien CC"),
    "'O''Brien CC'"
  )
})

# -- End-to-end with sidecar ------------------------------------------------

test_that("get_assessments_ie end-to-end (sidecar-first, point geometry persisted, downloads off)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(ie_arcgis_get = mock_arcgis())

    res <- get_assessments_ie(limit = 5, download = FALSE)
    expect_identical(nrow(res), 3L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("2024092", "2020010", "2023500"))

    # All three sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "ie"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 3L)

    # The geo records have a sibling .geometry.geojson; the no-geo one does not.
    geo_file <- file.path(cache, "files", "ie", "2024092", "2024092.geometry.geojson")
    expect_true(file.exists(geo_file))
    geo <- jsonlite::fromJSON(geo_file, simplifyVector = FALSE)
    expect_identical(geo$type, "FeatureCollection")
    expect_match(geo$crs$properties$name, "EPSG::2157")
    expect_identical(geo$features[[1]]$geometry$type, "Point")
    nogeo_file <- file.path(cache, "files", "ie", "2023500", "2023500.geometry.geojson")
    expect_false(file.exists(nogeo_file))

    # Second call with refresh = FALSE must NOT re-invoke ie_parse_feature.
    local_mocked_bindings(
      ie_parse_feature = function(...) {
        stop("ie_parse_feature should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_ie(limit = 5, download = FALSE)
    expect_identical(nrow(res2), 3L)
    expect_setequal(res2$document_id, c("2024092", "2020010", "2023500"))
  })
})

test_that("get_assessments_ie honours the date_range filter (client-side guard)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(ie_arcgis_get = mock_arcgis())

    # 2024092 received 2024-09-17; 2020010 on 2020-02-13; 2023500 on 2023-08-01.
    # A 2024 window selects only 2024092.
    res <- get_assessments_ie(
      date_range = c("2024-01-01", "2024-12-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "2024092")
  })
})

test_that("get_assessments_ie forwards query + competent_authority into the where clause", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    seen <- new.env()
    local_mocked_bindings(
      ie_arcgis_get = function(path, query = list()) {
        if (identical(path, "query")) {
          seen$where <- query$where
          list(exceededTransferLimit = FALSE, features = list(.ie_feat_geo))
        } else {
          .ie_qa
        }
      }
    )
    res <- get_assessments_ie(
      query = "wind",
      competent_authority = "An Bord Pleanála",
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_match(seen$where, "LIKE '%WIND%'")
    expect_match(seen$where, "Competent_Authority = 'An Bord Pleanála'")
  })
})

# -- Sidecar round-trip -----------------------------------------------------

test_that("IE -> sidecar round-trip preserves country-specific extras + geometry", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      ie_arcgis_get = function(path, query = list()) {
        if (identical(path, "query")) {
          list(exceededTransferLimit = FALSE, features = list(.ie_feat_geo))
        } else {
          .ie_qa
        }
      }
    )

    res <- get_assessments_ie(limit = 5, download = FALSE)
    idx <- index_cache(country = "ie")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "2024092")

    # Country-specific extras survive the round-trip.
    expect_identical(idx$esri_object_id, "5427")
    expect_identical(idx$linear_development, "Yes")
    expect_match(idx$url_link_application, "pleanala\\.ie")
    # Geometry sidecar.
    expect_identical(idx$geometry_crs, "EPSG:2157")
    expect_true(file.exists(idx$geometry_path))
    # The single notice attachment column survives.
    expect_true("attachment_urls_notice" %in% names(idx))
    expect_match(idx$attachment_urls_notice[[1]], "/attachments/5448$")
  })
})

# -- Relevance scoring ------------------------------------------------------

test_that("get_assessments_ie scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(ie_arcgis_get = mock_arcgis())

    res <- get_assessments_ie(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "wind", flood = "flood"),
      relevance_model = make_fake_model(languages = c("en"))
    )
    expect_identical(nrow(res), 3L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_flood" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('ie') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("ie", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "ie")
    expect_identical(res$source_portal, "services.arcgis.com (gov.ie EIA Portal)")
    expect_match(res$url, "^https://services\\.arcgis\\.com/.*/query\\?where=Portal_Ref=")
    expect_identical(res$geometry_crs, "EPSG:2157")
  })
})
