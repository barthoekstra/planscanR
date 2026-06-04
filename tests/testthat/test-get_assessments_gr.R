# Tests for get_assessments_gr(). Offline strategy: stub `gr_fetch_records` (the
# single listing-walk seam) to hand back the recorded EPRM JSON:API fixtures so
# no live HTTP is needed in CI. Fixtures (tests/testthat/fixtures/gr/):
#  - list_page1.json: a JSON:API page envelope with 3 real records:
#      * id 19895 — Φ/Β park: project_location (point) + diavgeia_doc_url.
#      * id 14934 — aepo_creation: project_location + diavgeia_doc_url.
#      * id 44030 — aepo_creation with NO project_location and NO diavgeia_doc_url
#        (covers the no-geometry / no-attachment edge case).
#  - detail_19895.json: the single full-record (`{data:{...}}`) detail shape.

gr_fixture_page <- function(name) {
  jsonlite::fromJSON(fixture_path("gr", name), simplifyVector = FALSE)
}

# Pre-load fixtures at file-load time (before any withr::with_tempdir()).
.gr_page <- gr_fixture_page("list_page1.json")
.gr_records <- .gr_page$data
.gr_rec_geo <- .gr_records[[1]] # 19895, geometry + doc
.gr_rec_nogeo <- .gr_records[[3]] # 44030, no geometry, no doc

mock_fetch_all <- function() {
  function(query = NULL, type = NULL, date_range = NULL, limit = Inf) .gr_records
}
mock_fetch_geo_only <- function() {
  function(query = NULL, type = NULL, date_range = NULL, limit = Inf) list(.gr_rec_geo)
}

# -- Parse unit tests -------------------------------------------------------

test_that("gr_parse_record extracts every conventional column (record with geometry + doc)", {
  url <- planscanR:::gr_canonical_url("19895")
  rec <- planscanR:::gr_parse_record(url, .gr_rec_geo)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "gr")
  expect_identical(rec$source_portal, "eprm.ypen.gr")
  expect_identical(rec$document_id, "19895")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Φ/Β Πάρκο") # "Φ/Β Πάρκο"
  expect_true(is.na(rec$summary))
  # Conventional cross-portal columns.
  expect_match(rec$native_type, "aepo_nonessential_modification")
  expect_match(rec$jurisdiction, "Θεσσαλίας") # Θεσσαλίας
  expect_match(rec$competent_authority, "Τμήμα") # Τμήμα
  expect_match(rec$proponent, "ΧΑΣΙΩΝ") # ΧΑΣΙΩΝ
  expect_identical(rec$status, "positive")
  expect_identical(rec$date_published, as.Date("2026-06-04"))
  expect_identical(rec$date_decision, as.Date("2026-05-28"))
  # Country-specific extras.
  expect_identical(rec$decision_type, "aepo_nonessential_modification")
  expect_identical(rec$project_category, "A1")
  expect_identical(rec$project_pet, "2306963121")
  expect_true(rec$project_natura2000)
  expect_match(rec$doc_ada, "ΨΥΑ") # ΨΥΑ...

  # Attachment: single AEPO decision PDF.
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 1L)
  expect_match(urls[[1]], "^https://diavgeia\\.gov\\.gr/luminapi/api/decisions/")
  expect_match(urls[[1]], "document\\.pdf$")
  expect_true("attachment_urls_aepo" %in% names(rec))
  expect_identical(rec$attachment_urls_aepo[[1]], urls)

  # Geometry is a Point in WGS84.
  geom <- planscanR:::gr_geometry_of(.gr_rec_geo)
  expect_identical(geom$type, "Point")
  expect_length(geom$coordinates, 2L)
  # coordinates are [lon, lat]
  expect_equal(geom$coordinates[[1]], 21.5839469, tolerance = 1e-6)
  expect_equal(geom$coordinates[[2]], 39.8790641, tolerance = 1e-6)
})

test_that("gr_parse_record handles a record without geometry and without a doc", {
  url <- planscanR:::gr_canonical_url("44030")
  rec <- planscanR:::gr_parse_record(url, .gr_rec_nogeo)

  expect_identical(rec$document_id, "44030")
  expect_identical(rec$decision_type, "aepo_creation")
  # No geometry present.
  expect_null(planscanR:::gr_geometry_of(.gr_rec_nogeo))
  expect_true(is.na(rec$geometry_path))
  # No attachments — still schema-valid (zero-length union).
  expect_identical(rec$attachment_urls[[1]], character(0))
  expect_false("attachment_urls_aepo" %in% names(rec))
})

test_that("gr_geometry_of returns NULL on empty / malformed locations", {
  expect_null(planscanR:::gr_geometry_of(list(project_location = NULL)))
  expect_null(planscanR:::gr_geometry_of(list(project_location = list())))
  expect_null(planscanR:::gr_geometry_of(
    list(project_location = list(list(lat = "x", lon = "y")))
  ))
})

# -- End-to-end with sidecar ------------------------------------------------

test_that("get_assessments_gr end-to-end (sidecar-first, point geometry persisted, downloads off)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(gr_fetch_records = mock_fetch_all())

    res <- get_assessments_gr(limit = 5, download = FALSE)
    expect_identical(nrow(res), 3L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("19895", "14934", "44030"))

    # All three sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "gr"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 3L)

    # The geo record has a sibling .geometry.geojson; the no-geo one does not.
    geo_file <- file.path(
      cache,
      "files",
      "gr",
      "19895",
      "19895.geometry.geojson"
    )
    expect_true(file.exists(geo_file))
    geo <- jsonlite::fromJSON(geo_file, simplifyVector = FALSE)
    expect_identical(geo$type, "FeatureCollection")
    expect_match(geo$crs$properties$name, "EPSG::4326")
    expect_identical(geo$features[[1]]$geometry$type, "Point")
    nogeo_file <- file.path(
      cache,
      "files",
      "gr",
      "44030",
      "44030.geometry.geojson"
    )
    expect_false(file.exists(nogeo_file))

    # Second call with refresh = FALSE must NOT re-invoke gr_parse_record.
    local_mocked_bindings(
      gr_parse_record = function(...) {
        stop("gr_parse_record should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_gr(limit = 5, download = FALSE)
    expect_identical(nrow(res2), 3L)
    expect_setequal(res2$document_id, c("19895", "14934", "44030"))
  })
})

test_that("get_assessments_gr honours the date_range filter (client-side guard)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(gr_fetch_records = mock_fetch_all())

    # rec 19895 issued 2026-05-28; recs 14934 / 44030 issued 2026-06-02 / -03.
    # A window ending mid-window selects only 19895.
    res <- get_assessments_gr(
      date_range = c("2026-05-01", "2026-05-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "19895")
  })
})

test_that("get_assessments_gr forwards query + type into the fetch seam", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    seen <- list()
    local_mocked_bindings(
      gr_fetch_records = function(query = NULL, type = NULL, date_range = NULL, limit = Inf) {
        seen <<- list(query = query, type = type)
        list(.gr_rec_geo)
      }
    )
    res <- get_assessments_gr(
      query = "φωτοβολταϊκ", # φωτοβολταικ
      type = "aepo_creation",
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_identical(seen$query, "φωτοβολταϊκ")
    expect_identical(seen$type, "aepo_creation")
  })
})

# -- Sidecar round-trip -----------------------------------------------------

test_that("GR -> sidecar round-trip preserves country-specific extras + geometry", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(gr_fetch_records = mock_fetch_geo_only())

    res <- get_assessments_gr(limit = 5, download = FALSE)
    idx <- index_cache(country = "gr")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "19895")

    # Country-specific extras survive the round-trip.
    expect_identical(idx$decision_type, "aepo_nonessential_modification")
    expect_identical(idx$project_category, "A1")
    expect_identical(idx$doc_ada, res$doc_ada)
    # Geometry sidecar.
    expect_identical(idx$geometry_crs, "EPSG:4326")
    expect_true(file.exists(idx$geometry_path))
    # The single AEPO attachment column survives.
    expect_true("attachment_urls_aepo" %in% names(idx))
    expect_match(idx$attachment_urls_aepo[[1]], "document\\.pdf$")
  })
})

# -- Relevance scoring ------------------------------------------------------

test_that("get_assessments_gr scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(gr_fetch_records = mock_fetch_all())

    res <- get_assessments_gr(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(energy = "energy", water = "water"),
      relevance_model = make_fake_model(languages = c("el", "en"))
    )
    expect_identical(nrow(res), 3L)
    expect_true("relevance_score_energy" %in% names(res))
    expect_true("relevance_score_water" %in% names(res))
    expect_true(is.numeric(res$relevance_score_energy))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('gr') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("gr", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "gr")
    expect_identical(res$source_portal, "eprm.ypen.gr")
    expect_match(res$url, "^https://eprm\\.ypen\\.gr/aepoView/")
  })
})
