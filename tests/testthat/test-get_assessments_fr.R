# Tests for get_assessments_fr(). Offline strategy: stub `fr_fetch_records` (the
# single export-call seam) to hand back the recorded OpenDataSoft JSON fixtures
# so no live HTTP is needed in CI. Fixtures:
#  - records-2018108485.json: /records-shape payload, one record WITH geometry +
#    étude d'impact / RNT / avis AE / réponse AE / dossier ZIP attachments.
#  - record-nogeo.json: one éolien record WITHOUT geometry (localisation null),
#    carrying an étude d'impact PDF + dossier ZIP, plus an EXTERNAL HTML
#    préfecture page in dc_relation_decision (must NOT become an attachment).
#  - export.json: the bare-array export shape with both records.

fr_fixture_results <- function(name) {
  jsonlite::fromJSON(fixture_path("fr", name), simplifyVector = FALSE)$results
}
fr_fixture_array <- function(name) {
  jsonlite::fromJSON(fixture_path("fr", name), simplifyVector = FALSE)
}

# Pre-load fixtures at file-load time (before any withr::with_tempdir()).
.fr_rec_geo <- fr_fixture_results("records-2018108485.json")[[1]]
.fr_rec_nogeo <- fr_fixture_results("record-nogeo.json")[[1]]
.fr_export <- fr_fixture_array("export.json")

# `fr_fetch_records` is now a PAGE-GENERATOR FACTORY: it takes `where` and
# returns a zero-arg closure that yields the record list once, then NULL. The
# mock factories mirror that contract -- each returns such a generator factory.
mock_fetch_both <- function() {
  # The export seam ignores the `where` here and returns both records once.
  function(where = NULL) {
    emitted <- FALSE
    function() {
      if (emitted) {
        return(NULL)
      }
      emitted <<- TRUE
      .fr_export
    }
  }
}
mock_fetch_geo_only <- function() {
  function(where = NULL) {
    emitted <- FALSE
    function() {
      if (emitted) {
        return(NULL)
      }
      emitted <<- TRUE
      list(.fr_rec_geo)
    }
  }
}

# -- Parse unit tests -------------------------------------------------------

test_that("fr_parse_record extracts every conventional column (record with geometry)", {
  url <- planscanR:::fr_canonical_url("2018108485")
  rec <- planscanR:::fr_parse_record(url, .fr_rec_geo)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "fr")
  expect_identical(rec$source_portal, "projets-environnement.gouv.fr")
  expect_identical(rec$document_id, "2018108485")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Lyreco")
  expect_match(rec$summary, "photovolta")
  # Conventional cross-portal columns.
  expect_match(rec$native_type, "Autorisation au titre du code")
  expect_match(rec$jurisdiction, "53 - Mayenne")
  expect_identical(rec$status, "clos")
  expect_identical(rec$dc_subject_theme, "ÉNERGIE")
  expect_match(rec$dc_subject_category, "solaire")
  expect_identical(rec$competent_authority, "_sicodei_eco4_")
  expect_identical(rec$date_published, as.Date("2025-06-18"))
  # No préfecture / commissaire decision date on this record.
  expect_true(is.na(rec$date_decision))

  # Attachment union: étude impact + RNT + avis AE + réponse AE + dossier ZIP.
  urls <- rec$attachment_urls[[1]]
  expect_true(any(grepl("108485_FEI\\.pdf$", urls)))
  expect_true(any(grepl("108485_DCZIP\\.zip$", urls)))
  # All real attachments live on the SICODEI blob host.
  expect_true(all(grepl("^https://sicodei\\.projets-environnement\\.gouv\\.fr/", urls)))

  # Per-slug attachment columns.
  expect_true("attachment_urls_etude_impact" %in% names(rec))
  expect_match(rec$attachment_urls_etude_impact[[1]], "108485_FEI\\.pdf$")
  expect_true("attachment_urls_resume_non_technique" %in% names(rec))
  expect_match(rec$attachment_urls_resume_non_technique[[1]], "108485_RNT\\.pdf$")
  expect_true("attachment_urls_avis_ae" %in% names(rec))
  expect_match(rec$attachment_urls_avis_ae[[1]], "108485_AAE\\.pdf$")
  expect_true("attachment_urls_reponse_avis_ae" %in% names(rec))
  expect_true("attachment_urls_dossier" %in% names(rec))
  expect_match(rec$attachment_urls_dossier[[1]], "108485_DCZIP\\.zip$")
  # The étude impact leads the union (curated-first ordering).
  expect_match(urls[[1]], "108485_FEI\\.pdf$")

  # Geometry can be unwrapped from the localisation Feature.
  geom <- planscanR:::fr_geometry_of(.fr_rec_geo)
  expect_identical(geom$type, "MultiPolygon")
})

test_that("fr_parse_record handles a record without geometry and skips external HTML", {
  url <- planscanR:::fr_canonical_url("2026200001")
  rec <- planscanR:::fr_parse_record(url, .fr_rec_nogeo)

  expect_identical(rec$document_id, "2026200001")
  expect_match(rec$title, "ORMES")
  # No geometry present.
  expect_null(planscanR:::fr_geometry_of(.fr_rec_nogeo))
  expect_true(is.na(rec$geometry_path))

  urls <- rec$attachment_urls[[1]]
  # étude impact + dossier ZIP are downloadable; the external HTML décision is not.
  expect_true(any(grepl("200001_FEI\\.pdf$", urls)))
  expect_true(any(grepl("200001_DCZIP\\.zip$", urls)))
  expect_false(any(grepl("prefecture-example", urls)))
  expect_false("attachment_urls_decision" %in% names(rec))
})

test_that("fr_is_downloadable accepts SICODEI host and .pdf/.zip only", {
  expect_true(planscanR:::fr_is_downloadable(
    "https://sicodei.projets-environnement.gouv.fr/2025/06/18/108485/108485_FEI.pdf"
  ))
  expect_true(planscanR:::fr_is_downloadable("https://example.org/a.pdf"))
  expect_true(planscanR:::fr_is_downloadable("https://example.org/a.zip"))
  expect_false(planscanR:::fr_is_downloadable("http://www.mayenne.gouv.fr/page"))
  expect_false(planscanR:::fr_is_downloadable(NA_character_))
  expect_false(planscanR:::fr_is_downloadable(NULL))
  expect_false(planscanR:::fr_is_downloadable(""))
})

test_that("fr_build_where builds ODSQL clauses for each server-side filter", {
  expect_null(planscanR:::fr_build_where())
  expect_identical(
    planscanR:::fr_build_where(query = "éolien"),
    "search(\"éolien\")"
  )
  expect_identical(
    planscanR:::fr_build_where(theme = "ÉNERGIE"),
    "dc_subject_theme = \"ÉNERGIE\""
  )
  expect_identical(
    planscanR:::fr_build_where(status = "ouvert"),
    "vp_status = \"ouvert\""
  )
  expect_identical(
    planscanR:::fr_build_where(native_type = "AENV"),
    "dc_type = \"AENV\""
  )
  w <- planscanR:::fr_build_where(date_range = as.Date(c("2024-01-01", "2024-12-31")))
  expect_match(w, "dc_date >= \"2024-01-01\"")
  expect_match(w, "dc_date <= \"2024-12-31\"")
  # Combined.
  w2 <- planscanR:::fr_build_where(query = "wind", theme = "ÉNERGIE")
  expect_match(w2, "search\\(\"wind\"\\) and dc_subject_theme = \"ÉNERGIE\"")
})

test_that("fr_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2025-06-18"))
  expect_true(planscanR:::fr_record_matches(rec, NULL))
  expect_true(planscanR:::fr_record_matches(rec, as.Date(c("2025-01-01", "2025-12-31"))))
  expect_false(planscanR:::fr_record_matches(rec, as.Date(c("2020-01-01", "2020-12-31"))))
  expect_false(planscanR:::fr_record_matches(
    tibble::tibble(date_published = as.Date(NA)),
    as.Date(c("2025-01-01", "2025-12-31"))
  ))
})

# -- End-to-end with sidecar ------------------------------------------------

test_that("get_assessments_fr end-to-end (sidecar-first, geometry persisted, downloads off)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(fr_fetch_records = mock_fetch_both())

    res <- get_assessments_fr(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("2018108485", "2026200001"))

    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "fr"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # The geo record has a sibling .geometry.geojson; the no-geo one does not.
    geo_file <- file.path(
      cache,
      "files",
      "fr",
      "2018108485",
      "2018108485.geometry.geojson"
    )
    expect_true(file.exists(geo_file))
    geo <- jsonlite::fromJSON(geo_file, simplifyVector = FALSE)
    expect_identical(geo$type, "FeatureCollection")
    expect_match(geo$crs$properties$name, "EPSG::4326")
    expect_identical(geo$features[[1]]$geometry$type, "MultiPolygon")
    nogeo_file <- file.path(
      cache,
      "files",
      "fr",
      "2026200001",
      "2026200001.geometry.geojson"
    )
    expect_false(file.exists(nogeo_file))

    # Second call with refresh = FALSE must NOT re-invoke fr_parse_record.
    local_mocked_bindings(
      fr_parse_record = function(...) {
        stop("fr_parse_record should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_fr(limit = 5, download = FALSE)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c("2018108485", "2026200001"))
  })
})

test_that("get_assessments_fr honours the date_range filter (client-side guard)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(fr_fetch_records = mock_fetch_both())

    # The geo record is dc_date 2025-06-18; the éolien one is 2026-06-03.
    res <- get_assessments_fr(
      date_range = c("2025-01-01", "2025-12-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "2018108485")
  })
})

test_that("get_assessments_fr forwards query into the ODSQL where seam", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    seen_where <- NULL
    local_mocked_bindings(
      fr_fetch_records = function(where = NULL) {
        seen_where <<- where
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          list(.fr_rec_geo)
        }
      }
    )
    res <- get_assessments_fr(query = "éolien", limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_match(seen_where, "search\\(\"éolien\"\\)")
  })
})

# -- Sidecar round-trip -----------------------------------------------------

test_that("FR -> sidecar round-trip preserves country-specific extras + geometry", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(fr_fetch_records = mock_fetch_geo_only())

    res <- get_assessments_fr(limit = 5, download = FALSE)
    idx <- index_cache(country = "fr")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "2018108485")

    # Country-specific extras survive the round-trip.
    expect_identical(idx$native_type, res$native_type)
    expect_identical(idx$dc_subject_theme, "ÉNERGIE")
    expect_identical(idx$status, "clos")
    # Geometry sidecar.
    expect_identical(idx$geometry_crs, "EPSG:4326")
    expect_true(file.exists(idx$geometry_path))
    # Per-slug attachment column survives.
    expect_true("attachment_urls_etude_impact" %in% names(idx))
    expect_match(idx$attachment_urls_etude_impact[[1]], "108485_FEI\\.pdf$")
  })
})

# -- Relevance scoring ------------------------------------------------------

test_that("get_assessments_fr scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(fr_fetch_records = mock_fetch_both())

    res <- get_assessments_fr(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "éolien", solar = "solaire"),
      relevance_model = make_fake_model(languages = c("fr", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_solar" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('fr') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("fr", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "fr")
    expect_identical(res$source_portal, "projets-environnement.gouv.fr")
    expect_true(startsWith(
      res$url,
      "https://www.projets-environnement.gouv.fr/explore/dataset/projets-environnement-diffusion/table"
    ))
  })
})
