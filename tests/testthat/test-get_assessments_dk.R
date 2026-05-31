# Tests for get_assessments_dk(). Offline strategy: stub `perform_json` to hand
# back the recorded JSON fixtures (one /assessments/search response, one
# /assessments/{id}/geometry response) so no live HTTP is needed in CI.

dk_fixture <- function(name) {
  jsonlite::fromJSON(fixture_path("dk", name), simplifyVector = FALSE)
}

# Pre-load every fixture once, at file-load time, so the JSON contents are
# captured before any test enters `withr::with_tempdir()`. Inside the tempdir
# the relative path that `fixture_path()` returns would no longer resolve.
.dk_fix_search <- dk_fixture("search.json")
.dk_fix_geometry <- dk_fixture("geometry.json")

# IDs of the two records in the search fixture (in order). The first has
# geometry; the second does not.
.dk_with_geom_id <- .dk_fix_search[[1]]$id
.dk_no_geom_id <- .dk_fix_search[[2]]$id

mock_perform_json <- function() {
  function(req) {
    url <- req$url
    if (grepl("/assessments/search$", url)) {
      return(.dk_fix_search)
    }
    if (grepl(paste0("/assessments/", .dk_with_geom_id, "/geometry$"), url)) {
      return(.dk_fix_geometry)
    }
    stop("Unexpected URL in test: ", url)
  }
}

test_that("dk_parse_entry extracts expected fields from a real search-row payload", {
  entry <- .dk_fix_search[[1]]
  url <- planscanR:::dk_canonical_url(entry$id)
  rec <- planscanR:::dk_parse_entry(url, entry)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "dk")
  expect_identical(rec$source_portal, "miljoeportal.dk/eahub")
  expect_identical(rec$document_id, as.character(entry$id))
  expect_identical(rec$url, url)
  # The fixture is a vindmølle/wind record; both records carry "vindmølle".
  expect_match(rec$title, "indm", fixed = FALSE)
  # EA-Hub has no narrative abstract.
  expect_true(is.na(rec$summary))
  # date_decision is structurally always NA on the DK handler — the API only
  # exposes year ranges, no decision timestamp.
  expect_true(is.na(rec$date_decision))
  # has_geometry flag reflects the entry.
  expect_true(rec$has_geometry)
  # No attachment URLs at scan time (deferred to a future download phase).
  expect_identical(rec$attachment_urls[[1]], character(0))
  expect_identical(rec$local_path[[1]], character(0))
  # Country-specific extras the schema doesn't enforce but the handler emits.
  expect_true("from_year" %in% names(rec))
  expect_true("to_year" %in% names(rec))
  expect_true("annex1" %in% names(rec) || "annex2" %in% names(rec))
})

test_that("dk_parse_entry handles a record without geometry", {
  entry <- .dk_fix_search[[2]]
  url <- planscanR:::dk_canonical_url(entry$id)
  rec <- planscanR:::dk_parse_entry(url, entry)
  expect_false(rec$has_geometry)
  expect_true(is.na(rec$geometry_path))
  expect_true(is.na(rec$geometry_crs))
})

test_that("dk_year_in_range correctly intersects a date window", {
  drng <- as.Date(c("2016-01-01", "2018-12-31"))
  expect_true(planscanR:::dk_year_in_range(2017L, 2017L, drng))
  expect_true(planscanR:::dk_year_in_range(2015L, 2017L, drng))
  expect_true(planscanR:::dk_year_in_range(2018L, 2020L, drng))
  expect_false(planscanR:::dk_year_in_range(2020L, 2021L, drng))
  expect_false(planscanR:::dk_year_in_range(2010L, 2014L, drng))
  # A single end of the range still anchors the test.
  expect_true(planscanR:::dk_year_in_range(NA, 2017L, drng))
  expect_true(planscanR:::dk_year_in_range(2017L, NA, drng))
  # Both NA -> no overlap possible.
  expect_false(planscanR:::dk_year_in_range(NA, NA, drng))
})

test_that("dk_normalise_assessment_type accepts the API vocabulary case-insensitively", {
  expect_identical(planscanR:::dk_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::dk_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::dk_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::dk_normalise_assessment_type("Plans"), "Plans")
  expect_identical(planscanR:::dk_normalise_assessment_type("project"), "Project")
  expect_error(planscanR:::dk_normalise_assessment_type("nope"))
})

test_that("dk_record_matches honours the date_range filter", {
  rec <- tibble::tibble(from_year = 2017L, to_year = 2018L)
  expect_true(planscanR:::dk_record_matches(rec, NULL))
  expect_true(planscanR:::dk_record_matches(
    rec,
    as.Date(c("2018-01-01", "2018-12-31"))
  ))
  expect_false(planscanR:::dk_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

test_that("get_assessments_dk end-to-end on fixtures (sidecar-first, geometry persisted)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json())

    res <- get_assessments_dk(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c(.dk_with_geom_id, .dk_no_geom_id))
    # Two sidecars on disk now.
    sidecars <- list.files(
      file.path(cache, "files", "dk"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)
    # The with-geometry record has a sibling .geometry.geojson on disk.
    geom_file <- file.path(
      cache,
      "files",
      "dk",
      .dk_with_geom_id,
      paste0(.dk_with_geom_id, ".geometry.geojson")
    )
    expect_true(file.exists(geom_file))
    # GeoJSON is self-describing with the source CRS.
    geo <- jsonlite::fromJSON(geom_file, simplifyVector = FALSE)
    expect_identical(geo$type, "FeatureCollection")
    expect_match(geo$crs$properties$name, "EPSG::25832")
    expect_identical(geo$features[[1]]$geometry$type, "MultiPolygon")
    # And the no-geometry record has none.
    geom_file_2 <- file.path(
      cache,
      "files",
      "dk",
      .dk_no_geom_id,
      paste0(.dk_no_geom_id, ".geometry.geojson")
    )
    expect_false(file.exists(geom_file_2))

    # Second call with refresh = FALSE must NOT re-invoke dk_parse_entry.
    parse_calls <- 0L
    local_mocked_bindings(
      dk_parse_entry = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("dk_parse_entry should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_dk(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c(.dk_with_geom_id, .dk_no_geom_id))
  })
})

test_that("get_assessments_dk applies the date_range filter client-side", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json())

    # An unreachable date window — both fixtures fall outside.
    res <- get_assessments_dk(
      date_range = c("1900-01-01", "1900-12-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 0L)
  })
})

test_that("DK -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json())

    res <- get_assessments_dk(limit = 5, download = FALSE)
    idx <- index_cache(country = "dk")
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c(.dk_with_geom_id, .dk_no_geom_id))

    # The handler's country-specific scalar columns survive the round-trip
    # via the sidecar's `extras{}` channel.
    with_geom <- idx[idx$document_id == .dk_with_geom_id, , drop = FALSE]
    expect_true("from_year" %in% names(idx))
    expect_true("has_geometry" %in% names(idx))
    expect_true(isTRUE(with_geom$has_geometry))
    expect_identical(with_geom$geometry_crs, "EPSG:25832")
    expect_true(file.exists(with_geom$geometry_path))
  })
})

test_that("get_assessments_dk scores topics and adds relevance_score_<slug> columns", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    reset_relevance_warnings()

    local_mocked_bindings(perform_json = mock_perform_json())

    res <- get_assessments_dk(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "vindmølle", solar = "solenergi"),
      relevance_model = make_fake_model(languages = c("da", "en", "nl"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_solar" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('dk') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("dk", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "dk")
    expect_identical(res$source_portal, "miljoeportal.dk/eahub")
    expect_true(startsWith(
      res$url,
      "https://eahub.miljoeportal.dk/assessment-detail/"
    ))
    # DK is metadata-only: no portal-side attachments should surface.
    expect_identical(res$attachment_urls[[1]], character(0))
  })
})
