# Tests for get_assessments_be(). Offline strategy: stub `perform_json` to hand
# back the recorded JSON fixtures so no live HTTP is needed in CI. The fixtures
# include a single search-page response plus three detail records:
#  - PR4038 / PR4037: PROJECT_MER, each with a Locatie geometry + 1 Aanmelding
#  - PR2574: VERZOEK_TOT_ONTHEFFING with 2 document types (exercises the
#            per-document-type section slugging).

be_fixture <- function(name) {
  jsonlite::fromJSON(fixture_path("be", name), simplifyVector = FALSE)
}

# Pre-load every fixture once, at file-load time, so the JSON contents are
# captured before any test enters `withr::with_tempdir()`. Inside the tempdir
# the relative path that `fixture_path()` returns would no longer resolve.
.be_fix_search <- be_fixture("search-page0.json")
.be_fix_pr4038 <- be_fixture("dossier-PR4038.json")
.be_fix_pr4037 <- be_fixture("dossier-PR4037.json")
.be_fix_pr2574 <- be_fixture("dossier-PR2574.json")

# A second-page "empty" payload so paginated search terminates cleanly.
.be_fix_search_empty <- list(content = list(), number = 1L, size = 25L, totalElements = 2L)

mock_perform_json_search_2 <- function() {
  # Mock for tests that only need the two PROJECT_MER records (PR4038, PR4037).
  function(req) {
    url <- req$url
    if (grepl("/api/v1/dossier\\?", url) || grepl("/api/v1/dossier$", url)) {
      if (grepl("page=0", url)) {
        return(.be_fix_search)
      }
      return(.be_fix_search_empty)
    }
    if (grepl("/api/v1/dossier/PR4038", url)) {
      return(.be_fix_pr4038)
    }
    if (grepl("/api/v1/dossier/PR4037", url)) {
      return(.be_fix_pr4037)
    }
    stop("Unexpected URL in test: ", url)
  }
}

mock_perform_json_with_pr2574 <- function() {
  # Search returns only PR2574; detail returns the VERZOEK_TOT_ONTHEFFING.
  function(req) {
    url <- req$url
    if (grepl("/api/v1/dossier\\?", url)) {
      if (grepl("page=0", url)) {
        return(list(
          content = list(list(
            nummer = "PR2574",
            dossierType = "VERZOEK_TOT_ONTHEFFING",
            titel = .be_fix_pr2574$titel,
            initiatiefnemer = list(naam = "Tuincentrum Van Uytsel,", kboNummer = NULL)
          )),
          number = 1L,
          size = 25L,
          totalElements = 1L
        ))
      }
      return(.be_fix_search_empty)
    }
    if (grepl("/api/v1/dossier/PR2574", url)) {
      return(.be_fix_pr2574)
    }
    stop("Unexpected URL in test: ", url)
  }
}

test_that("be_parse_detail extracts expected fields from a real dossier payload", {
  url <- planscanR:::be_canonical_url("PR4037")
  entry <- list(
    nummer = "PR4037",
    dossierType = "PROJECT_MER",
    titel = "Windturbineproject Overhaem",
    initiatiefnemer = list(naam = "Spark Power", kboNummer = "1002476390")
  )
  rec <- planscanR:::be_parse_detail(url, entry, .be_fix_pr4037)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "be")
  expect_identical(rec$source_portal, "omgeving.vlaanderen.be/merregister")
  expect_identical(rec$document_id, "PR4037")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Windturbineproject")
  # No narrative abstract on the API.
  expect_true(is.na(rec$summary))
  # Conventional cross-portal columns
  expect_match(rec$native_type, "PROJECT_MER")
  expect_identical(rec$jurisdiction, "Borgloon; Tongeren")
  expect_identical(rec$proponent, "Spark Power")
  # No decision timestamp on the API.
  expect_true(is.na(rec$date_decision))
  # Attachment union + the per-section column.
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 1L)
  expect_match(urls, "^https://dmvb\\.omgeving\\.vlaanderen\\.be/api/v1/dossier/PR4037/document/")
  expect_true("attachment_urls_aanmelding" %in% names(rec))
  expect_identical(rec$attachment_urls_aanmelding[[1]], urls)
})

test_that("be_parse_detail handles a VERZOEK_TOT_ONTHEFFING record with two doc types", {
  url <- planscanR:::be_canonical_url("PR2574")
  entry <- list(
    nummer = "PR2574",
    dossierType = "VERZOEK_TOT_ONTHEFFING",
    titel = "Project Tuincentrum Van Uytsel BVBA",
    initiatiefnemer = list(naam = "Tuincentrum Van Uytsel,", kboNummer = NULL)
  )
  rec <- planscanR:::be_parse_detail(url, entry, .be_fix_pr2574)

  expect_match(rec$native_type, "VERZOEK_TOT_ONTHEFFING")
  # Two documents -> two distinct per-type section columns + a 2-URL union.
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 2L)
  expect_true("attachment_urls_ontheffingsaanvraag" %in% names(rec))
  expect_true("attachment_urls_verslag_toekenning_ontheffing" %in% names(rec))
  expect_length(rec$attachment_urls_ontheffingsaanvraag[[1]], 1L)
  expect_length(rec$attachment_urls_verslag_toekenning_ontheffing[[1]], 1L)
  # No section overlap.
  expect_length(
    intersect(
      rec$attachment_urls_ontheffingsaanvraag[[1]],
      rec$attachment_urls_verslag_toekenning_ontheffing[[1]]
    ),
    0L
  )
})

test_that("be_section_slug auto-slugs document types including diacritics", {
  expect_identical(planscanR:::be_section_slug("Aanmelding"), "aanmelding")
  expect_identical(planscanR:::be_section_slug("Ontheffingsaanvraag"), "ontheffingsaanvraag")
  expect_identical(
    planscanR:::be_section_slug("Verslag toekenning ontheffing"),
    "verslag_toekenning_ontheffing"
  )
  # Diacritics get folded back to ASCII before slug-collapsing.
  expect_identical(planscanR:::be_section_slug("Décision préliminaire"), "decision_preliminaire")
  expect_identical(planscanR:::be_section_slug("Aanmelding (versie 2)"), "aanmelding_versie_2")
  # Edge cases.
  expect_identical(planscanR:::be_section_slug(NULL), "document")
  expect_identical(planscanR:::be_section_slug(NA_character_), "document")
  expect_identical(planscanR:::be_section_slug(""), "document")
  expect_identical(planscanR:::be_section_slug("   "), "document")
})

test_that("be_normalise_dossier_type accepts the API vocabulary case-insensitively", {
  expect_null(planscanR:::be_normalise_dossier_type(NULL))
  expect_null(planscanR:::be_normalise_dossier_type(""))
  expect_identical(planscanR:::be_normalise_dossier_type("PROJECT_MER"), "PROJECT_MER")
  expect_identical(planscanR:::be_normalise_dossier_type("project_mer"), "PROJECT_MER")
  expect_identical(
    planscanR:::be_normalise_dossier_type("verzoek_tot_ontheffing"),
    "VERZOEK_TOT_ONTHEFFING"
  )
  expect_error(
    planscanR:::be_normalise_dossier_type("NOPE"),
    class = "planscanR_error_bad_input"
  )
})

test_that("be_text_match handles case-insensitive substring matches on title + nummer", {
  expect_true(planscanR:::be_text_match("wind", "Windturbineproject Overhaem", "PR4037"))
  expect_true(planscanR:::be_text_match("WIND", "Windturbineproject Overhaem", "PR4037"))
  expect_true(planscanR:::be_text_match("PR4037", "Windturbineproject Overhaem", "PR4037"))
  expect_false(planscanR:::be_text_match("kohlekraftwerk", "Windturbineproject Overhaem", "PR4037"))
  # NULL title is tolerated.
  expect_true(planscanR:::be_text_match("PR40", NULL, "PR4037"))
})

test_that("be_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2024-06-15"))
  expect_true(planscanR:::be_record_matches(rec, NULL))
  expect_true(planscanR:::be_record_matches(rec, as.Date(c("2024-01-01", "2024-12-31"))))
  expect_false(planscanR:::be_record_matches(rec, as.Date(c("2020-01-01", "2020-12-31"))))
  # NA date in the rec falls out of any window.
  expect_false(planscanR:::be_record_matches(
    tibble::tibble(date_published = as.Date(NA)),
    as.Date(c("2024-01-01", "2024-12-31"))
  ))
})

test_that("get_assessments_be end-to-end on fixtures (sidecar-first, geometry persisted, downloads off)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json_search_2())

    res <- get_assessments_be(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("PR4037", "PR4038"))
    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "be"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)
    # Both records carry geometry → both have a sibling .geometry.geojson.
    for (id in c("PR4037", "PR4038")) {
      geom_file <- file.path(cache, "files", "be", id, paste0(id, ".geometry.geojson"))
      expect_true(file.exists(geom_file))
      geo <- jsonlite::fromJSON(geom_file, simplifyVector = FALSE)
      expect_identical(geo$type, "FeatureCollection")
      expect_match(geo$crs$properties$name, "EPSG::31370")
      expect_identical(geo$features[[1]]$geometry$type, "MultiPolygon")
    }

    # Second call with refresh = FALSE must NOT re-invoke be_parse_detail.
    parse_calls <- 0L
    local_mocked_bindings(
      be_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("be_parse_detail should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_be(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c("PR4037", "PR4038"))
  })
})

test_that("get_assessments_be honours the dossier_type filter (client-side)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json_search_2())

    # Only PROJECT_MER fixtures exist; asking for VERZOEK_TOT_ONTHEFFING drops them all.
    res <- get_assessments_be(
      dossier_type = "VERZOEK_TOT_ONTHEFFING",
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 0L)

    # Asking for PROJECT_MER keeps both.
    res2 <- get_assessments_be(
      dossier_type = "PROJECT_MER",
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res2), 2L)
  })
})

test_that("get_assessments_be honours the query filter (substring on title + nummer)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json_search_2())

    # Only PR4037 has "wind" in the title.
    res <- get_assessments_be(query = "wind", limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "PR4037")
  })
})

test_that("BE -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json_with_pr2574())

    res <- get_assessments_be(limit = 5, download = FALSE)
    idx <- index_cache(country = "be")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "PR2574")

    # The per-type section columns survive the round-trip.
    expect_true("attachment_urls_ontheffingsaanvraag" %in% names(idx))
    expect_true("attachment_urls_verslag_toekenning_ontheffing" %in% names(idx))
    expect_length(idx$attachment_urls_ontheffingsaanvraag[[1]], 1L)
    expect_length(idx$attachment_urls_verslag_toekenning_ontheffing[[1]], 1L)
    # And the geometry sidecar.
    expect_identical(idx$geometry_crs, "EPSG:31370")
    expect_true(file.exists(idx$geometry_path))
    # Country-specific scalars round-trip through extras{}.
    expect_match(idx$native_type, "VERZOEK_TOT_ONTHEFFING")
  })
})

test_that("get_assessments_be scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_json = mock_perform_json_search_2())

    res <- get_assessments_be(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "wind energy", solar = "solar energy"),
      relevance_model = make_fake_model(languages = c("nl", "en", "de"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_solar" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('be') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("be", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "be")
    expect_identical(res$source_portal, "omgeving.vlaanderen.be/merregister")
    expect_true(startsWith(
      res$url,
      "https://merregister.omgeving.vlaanderen.be/dossier/"
    ))
  })
})
