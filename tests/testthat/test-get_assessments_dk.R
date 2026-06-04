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
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

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

# -- Download support --------------------------------------------------------

test_that("dk_section_slug folds Danish diacritics and defaults to 'document'", {
  expect_equal(dk_section_slug("Miljøkonsekvensrapport"), "miljoekonsekvensrapport")
  expect_equal(dk_section_slug("Afgørelse"), "afgoerelse")
  expect_equal(dk_section_slug("Små sager"), "smaa_sager")
  expect_equal(dk_section_slug(NA_character_), "document")
  expect_equal(dk_section_slug(""), "document")
  expect_equal(dk_section_slug(NULL), "document")
})

test_that("dk_collect_attachments groups view URLs by da-DK document type", {
  testthat::local_mocked_bindings(
    perform_json = function(req, ...) {
      url <- req$url
      if (grepl("/documents/[^/]+/links$", url)) {
        doc <- sub(".*/documents/([^/]+)/links$", "\\1", url)
        return(list(viewUrl = paste0("https://blob.example/", doc, "/file.pdf")))
      }
      list(documents = list(
        list(
          id = "d1", title = "a.pdf",
          documentType = list(name = list(`da-DK` = "Miljøkonsekvensrapport", `en-US` = "EIA report"))
        ),
        list(
          id = "d2", title = "b.pdf",
          documentType = list(name = list(`da-DK` = "Afgørelse", `en-US` = "Decision"))
        )
      ))
    }
  )
  per <- dk_collect_attachments("assess-1")
  expect_setequal(names(per), c("miljoekonsekvensrapport", "afgoerelse"))
  expect_equal(per[["miljoekonsekvensrapport"]], "https://blob.example/d1/file.pdf")
  expect_equal(per[["afgoerelse"]], "https://blob.example/d2/file.pdf")
})

test_that("dk_collect_attachments returns list() when there are no documents", {
  testthat::local_mocked_bindings(
    perform_json = function(req, ...) list(documents = list())
  )
  expect_identical(dk_collect_attachments("assess-empty"), list())
})

test_that("dk_finalise_record(download=TRUE) tags file sections in the sidecar", {
  withr::local_options(planscanR.cache_dir = withr::local_tempdir())
  rec <- tibble::tibble(
    country = "dk",
    source_portal = dk_source_portal(),
    document_id = "assess-1",
    url = dk_canonical_url("assess-1"),
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(c("https://blob.example/d1/a.pdf", "https://blob.example/d2/b.pdf")),
    local_path = list(character(0)),
    title = "Test", summary = NA_character_,
    competent_authority = NA_character_, proponent = NA_character_,
    date_published = as.Date(NA), date_decision = as.Date(NA),
    native_type = NA_character_, jurisdiction = NA_character_, status = NA_character_,
    year = NA_integer_, from_year = NA_integer_, to_year = NA_integer_,
    is_project_assessment = TRUE, is_related_to_plan = FALSE, is_draft = FALSE,
    has_geometry = FALSE, geometry_path = NA_character_, geometry_crs = NA_character_,
    annex1 = NA_character_, annex2 = NA_character_,
    plan_types = NA_character_, plan_categories = NA_character_,
    download_status = list(empty_download_status())
  )
  rec[["attachment_urls_miljoekonsekvensrapport"]] <- list("https://blob.example/d1/a.pdf")
  rec[["local_path_miljoekonsekvensrapport"]] <- list(character(0))
  rec[["attachment_urls_afgoerelse"]] <- list("https://blob.example/d2/b.pdf")
  rec[["local_path_afgoerelse"]] <- list(character(0))

  testthat::local_mocked_bindings(
    download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
      tibble::tibble(
        url = urls,
        local_path = file.path("files", "dk", document_id, paste0(seq_along(urls), ".pdf")),
        status = "downloaded",
        size_bytes = 100,
        sha256 = paste0("sha", seq_along(urls)),
        reason = NA_character_
      )
    }
  )
  out <- dk_finalise_record(rec, download = TRUE, overwrite = FALSE, max_file_size_mb = NULL, write_sidecar = TRUE)
  expect_length(out$local_path_miljoekonsekvensrapport[[1]], 1L)

  back <- index_cache(country = "dk")
  expect_true("attachment_urls_miljoekonsekvensrapport" %in% names(back))
  expect_true("attachment_urls_afgoerelse" %in% names(back))

  # The sidecar tags each file with its da-DK document type as `section`.
  # (The reader fans these back out into `attachment_urls_<section>` columns
  # rather than exposing a `section` column, so assert against the JSON.)
  sidecar <- file.path(
    getOption("planscanR.cache_dir"), "files", "dk", "assess-1", "assess-1.meta.json"
  )
  payload <- jsonlite::fromJSON(sidecar, simplifyVector = FALSE)
  sec_by_url <- vapply(payload$files, function(f) {
    paste(f$url, f$section, sep = "\t")
  }, character(1))
  expect_true("https://blob.example/d1/a.pdf\tmiljoekonsekvensrapport" %in% sec_by_url)
  expect_true("https://blob.example/d2/b.pdf\tafgoerelse" %in% sec_by_url)
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
