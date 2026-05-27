# Tests for get_assessments_at(). Offline strategy: hand back the recorded
# JSON fixtures from `perform_json()` so no live HTTP is needed in CI.

at_fixture <- function(name) {
  jsonlite::fromJSON(fixture_path("at", name), simplifyVector = FALSE)
}

# Pre-load every fixture once, at file-load time, so the JSON contents are
# captured before any test enters `withr::with_tempdir()`. Inside the tempdir
# the relative path that `fixture_path()` returns would no longer resolve.
.at_fix_mapsdata <- at_fixture("mapsdata.json")
.at_fix_v449 <- at_fixture("vorhabeninfo-449.json")
.at_fix_v450 <- at_fixture("vorhabeninfo-450.json")

mock_perform_json <- function() {
  function(req) {
    url <- req$url
    if (grepl("servicehandler=mapsdata", url, fixed = TRUE)) {
      return(.at_fix_mapsdata)
    }
    if (grepl("v2id=449", url, fixed = TRUE)) {
      return(.at_fix_v449)
    }
    if (grepl("v2id=450", url, fixed = TRUE)) {
      return(.at_fix_v450)
    }
    stop("Unexpected URL in test: ", url)
  }
}

test_that("at_parse_detail extracts expected fields from a real vorhabenInfo response", {
  local_mocked_bindings(perform_json = mock_perform_json())
  url <- planscanR:::at_canonical_url(449)
  entry <- list(az = "02 0514", v2id = 449L, title = "x", year = 2016L, province = "O", type = 1L)
  rec <- planscanR:::at_parse_detail(url, entry)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "at")
  expect_identical(rec$source_portal, "umweltbundesamt.at/uvpdb")
  expect_identical(rec$document_id, "449")
  expect_match(rec$title, "Reststoffdeponie Unterhart")
  expect_match(rec$summary, "Energie AG Ober")
  expect_identical(rec$jurisdiction, "Oberösterreich")
  expect_identical(rec$status, "bewilligt")
  expect_identical(rec$art, "Neues Vorhaben")
  expect_identical(rec$year, 2016L)
  expect_identical(rec$aktenzahl, "02 0514")
  # Typology lookup: type 1 -> "Abfallwirtschaft ..." in legend.
  expect_match(rec$native_type, "^Abfallwirtschaft")
  expect_identical(rec$type_group, "Industrie")
  # No attachments are reachable anonymously.
  expect_identical(rec$attachment_urls[[1]], character(0))
  expect_identical(rec$local_path[[1]], character(0))
  expect_true(is.na(rec$date_decision))
  expect_match(rec$rechtsgrundlagen, "UVP-G")
})

test_that("at_parse_detail of a Windkraft record places it in the Energie typegroup", {
  local_mocked_bindings(perform_json = mock_perform_json())
  url <- planscanR:::at_canonical_url(450)
  entry <- list(az = "02 0515", v2id = 450L, title = "x", year = 2016L, province = "B", type = 23L)
  rec <- planscanR:::at_parse_detail(url, entry)

  expect_match(rec$title, "Windpark Parndorf")
  expect_identical(rec$jurisdiction, "Burgenland")
  expect_identical(rec$native_type, "Windkraftanlagen")
  expect_identical(rec$type_group, "Energie")
  expect_identical(rec$art, "Änderungsvorhaben")
  expect_identical(rec$year, 2016L)
})

test_that("at_type_legend / at_type_group cover the documented vocabulary", {
  expect_identical(planscanR:::at_type_legend(1L), "Abfallwirtschaft (Abfallbehandlung und -verwertung)")
  expect_identical(planscanR:::at_type_legend(23L), "Windkraftanlagen")
  expect_true(is.na(planscanR:::at_type_legend(0L)))
  expect_true(is.na(planscanR:::at_type_legend(NA_integer_)))
  expect_true(is.na(planscanR:::at_type_legend(NULL)))

  expect_identical(planscanR:::at_type_group(23L), "Energie")
  expect_identical(planscanR:::at_type_group(19L), "Infrastruktur")
  expect_identical(planscanR:::at_type_group(1L), "Industrie")
  expect_true(is.na(planscanR:::at_type_group(NA_integer_)))
})

test_that("at_year_in_range correctly intersects a date window", {
  drng <- as.Date(c("2016-01-01", "2018-12-31"))
  expect_true(planscanR:::at_year_in_range(2016, drng))
  expect_true(planscanR:::at_year_in_range(2018, drng))
  expect_true(planscanR:::at_year_in_range(2017L, drng))
  expect_false(planscanR:::at_year_in_range(2015, drng))
  expect_false(planscanR:::at_year_in_range(2019, drng))
  expect_false(planscanR:::at_year_in_range(NA, drng))
  expect_false(planscanR:::at_year_in_range(NULL, drng))
})

test_that("at_record_matches honours query / date_range / jurisdiction filters", {
  rec <- tibble::tibble(
    title = "Windpark Parndorf",
    summary = "Errichtung von Windkraftanlagen",
    year = 2016L,
    jurisdiction = "Burgenland"
  )
  expect_true(planscanR:::at_record_matches(rec, NULL, NULL, NULL))
  expect_true(planscanR:::at_record_matches(rec, "windpark", NULL, NULL))
  expect_false(planscanR:::at_record_matches(rec, "kohlekraftwerk", NULL, NULL))
  expect_true(planscanR:::at_record_matches(
    rec,
    NULL,
    as.Date(c("2016-01-01", "2016-12-31")),
    NULL
  ))
  expect_false(planscanR:::at_record_matches(
    rec,
    NULL,
    as.Date(c("2020-01-01", "2020-12-31")),
    NULL
  ))
  expect_true(planscanR:::at_record_matches(rec, NULL, NULL, "Burgenland"))
  expect_false(planscanR:::at_record_matches(rec, NULL, NULL, "Tirol"))
})

test_that("get_assessments_at end-to-end on fixtures (sidecar-first, no downloads)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # Trim the index to just the two records we have fixtures for, otherwise
    # the streaming loop would try to fetch vorhabenInfo for hundreds of v2ids.
    short_index <- list(
      list(az = "02 0514", v2id = 449L, title = "x", year = 2016L, province = "O", type = 1L),
      list(az = "02 0515", v2id = 450L, title = "x", year = 2016L, province = "B", type = 23L)
    )

    local_mocked_bindings(
      perform_json = mock_perform_json(),
      at_fetch_mapsdata = function() short_index
    )

    res <- get_assessments_at(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_identical(sort(res$document_id), c("449", "450"))
    # Two sidecars on disk now.
    sidecars <- list.files(
      file.path(cache, "files", "at"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT hit at_parse_detail again.
    parse_calls <- 0L
    local_mocked_bindings(
      at_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("at_parse_detail should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_at(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_identical(sort(res2$document_id), c("449", "450"))
    expect_identical(res2$attachment_urls[[1]], character(0))
  })
})

test_that("get_assessments_at honours the query filter (substring on title + summary)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    short_index <- list(
      list(az = "02 0514", v2id = 449L, title = "x", year = 2016L, province = "O", type = 1L),
      list(az = "02 0515", v2id = 450L, title = "x", year = 2016L, province = "B", type = 23L)
    )

    local_mocked_bindings(
      perform_json = mock_perform_json(),
      at_fetch_mapsdata = function() short_index
    )

    # Only the Windpark Parndorf record matches.
    res <- get_assessments_at(query = "windpark", limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "450")
  })
})

test_that("get_assessments_at honours the jurisdiction filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    short_index <- list(
      list(az = "02 0514", v2id = 449L, title = "x", year = 2016L, province = "O", type = 1L),
      list(az = "02 0515", v2id = 450L, title = "x", year = 2016L, province = "B", type = 23L)
    )

    local_mocked_bindings(
      perform_json = mock_perform_json(),
      at_fetch_mapsdata = function() short_index
    )

    res <- get_assessments_at(jurisdiction = "Burgenland", limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "450")
  })
})

test_that("get_assessments_at scores topics and adds relevance_score_<slug> columns", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    reset_relevance_warnings()

    short_index <- list(
      list(az = "02 0515", v2id = 450L, title = "x", year = 2016L, province = "B", type = 23L)
    )

    local_mocked_bindings(
      perform_json = mock_perform_json(),
      at_fetch_mapsdata = function() short_index
    )

    res <- get_assessments_at(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "Windkraftanlagen", abfall = "Abfallwirtschaft"),
      relevance_model = make_fake_model()
    )
    expect_identical(nrow(res), 1L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_abfall" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

test_that("AT -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json())

    url <- planscanR:::at_canonical_url(450)
    entry <- list(az = "02 0515", v2id = 450L, title = "x", year = 2016L, province = "B", type = 23L)
    rec <- planscanR:::at_parse_detail(url, entry)
    rec <- planscanR:::at_finalise_record(rec, write_sidecar = TRUE)

    idx <- index_cache(country = "at")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "450")
    expect_match(idx$title, "Windpark Parndorf")
    expect_identical(idx$jurisdiction, "Burgenland")
    expect_identical(idx$native_type, "Windkraftanlagen")
    expect_identical(idx$type_group, "Energie")
    expect_identical(idx$aktenzahl, "02 0515")
    # And no attachments survived (because none exist).
    expect_identical(idx$attachment_urls[[1]], character(0))
    expect_identical(nrow(idx$download_status[[1]]), 0L)
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('at') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("at", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "at")
    expect_identical(res$source_portal, "umweltbundesamt.at/uvpdb")
    expect_true(startsWith(
      res$url,
      "https://secure.umweltbundesamt.at/uvpdb/maps/?v2id="
    ))
    # AT is metadata-only: no attachments should ever surface.
    expect_identical(res$attachment_urls[[1]], character(0))
  })
})
