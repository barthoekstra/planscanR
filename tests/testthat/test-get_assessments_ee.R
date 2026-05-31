# Tests for get_assessments_ee(). Offline strategy: stub `perform_html` to hand
# back the recorded HTML fixtures so no live HTTP is needed in CI. The fixtures
# cover both registers KOTKAS exposes:
#  - KMH (EIA): kmh-index.html, kmh-detail-478.html  (one mining-sector record
#    with 3 documents and a MultiPolygon geometry)
#  - KSH (SEA): ksh-index.html, ksh-detail-319.html  (one Detailplaneering with
#    10 documents and a Polygon geometry)

read_fixture_html <- function(name) {
  rvest::read_html(fixture_path("ee", name))
}

# Pre-load every fixture once, at file-load time, so they're available before
# any test enters `withr::with_tempdir()`.
.ee_fix_kmh_index <- read_fixture_html("kmh-index.html")
.ee_fix_ksh_index <- read_fixture_html("ksh-index.html")
.ee_fix_kmh_detail <- read_fixture_html("kmh-detail-478.html")
.ee_fix_ksh_detail <- read_fixture_html("ksh-detail-319.html")

# An empty index page (no <tr> rows) so paginated search terminates cleanly
# when the test slice has been fully served.
.ee_fix_empty_index <- rvest::read_html(
  '<html><body><table class="table-sorted"><tbody></tbody></table></body></html>'
)

mock_perform_html_full <- function() {
  # Serves: page 0 of both index registers (with all 40 rows each), then
  # an empty page-1 to terminate; both detail pages.
  function(req) {
    url <- req$url
    if (grepl("/kmh/kmh_index", url) && grepl("qs=0", url)) {
      return(.ee_fix_kmh_index)
    }
    if (grepl("/kmh/ksh_index", url) && grepl("qs=0", url)) {
      return(.ee_fix_ksh_index)
    }
    if (grepl("/kmh/k[mh]h_index", url)) {
      # Any later page is empty.
      return(.ee_fix_empty_index)
    }
    if (grepl("kmh_id=478", url)) {
      return(.ee_fix_kmh_detail)
    }
    if (grepl("ksh_id=319", url)) {
      return(.ee_fix_ksh_detail)
    }
    stop("Unexpected URL in test: ", url)
  }
}

mock_perform_html_two_records <- function() {
  # Cheaper mock: only one record per register. The end-to-end tests stub the
  # index fetcher directly so we don't have to parse the 40-row index pages
  # and then make 40 detail calls.
  function(req) {
    url <- req$url
    if (grepl("kmh_id=478", url)) {
      return(.ee_fix_kmh_detail)
    }
    if (grepl("ksh_id=319", url)) {
      return(.ee_fix_ksh_detail)
    }
    stop("Unexpected URL in test: ", url)
  }
}

# Two synthetic search-row entries that line up with the detail fixtures.
.ee_entry_kmh_478 <- list(
  register = "KMH",
  id = "478",
  title = "Aarnamäe II liivakarjääri keskkonnaloa keskkonnamõju hindamine",
  region = "Saare maakond",
  initiation_date = as.Date("2025-01-22"),
  initiation_reason = NA_character_,
  status = "Algatatud",
  developer = "AS TREV-2 Grupp",
  ksh_type = NA_character_,
  activity = "Kaevandamine ja geoloogia"
)
.ee_entry_ksh_319 <- list(
  register = "KSH",
  id = "319",
  title = "Aaspere Agro OÜ Kõldu veisefarmi detailplaneeringu keskkonnamõju strateegiline hindamine",
  region = "Lääne-Viru maakond",
  initiation_date = as.Date("2014-01-01"),
  initiation_reason = NA_character_,
  status = "Lõpetatud",
  developer = "Haljala Vallavolikogu",
  ksh_type = "Detailplaneering",
  activity = NA_character_
)

test_that("ee_parse_index_rows extracts every row from a real KMH index page", {
  rows <- planscanR:::ee_parse_index_rows(.ee_fix_kmh_index, "KMH")
  expect_gte(length(rows), 1L)
  first <- rows[[1]]
  expect_identical(first$register, "KMH")
  expect_match(first$id, "^[0-9]+$")
  expect_true(nzchar(first$title))
  expect_true(inherits(first$initiation_date, "Date") || is.na(first$initiation_date))
})

test_that("ee_parse_index_rows extracts every row from a real KSH index page (with Liik)", {
  rows <- planscanR:::ee_parse_index_rows(.ee_fix_ksh_index, "KSH")
  expect_gte(length(rows), 1L)
  first <- rows[[1]]
  expect_identical(first$register, "KSH")
  expect_match(first$id, "^[0-9]+$")
  # KSH carries a Liik column (planning-document type) that KMH doesn't.
  expect_true(nzchar(first$ksh_type %||% ""))
})

test_that("ee_extract_id pulls kmh_id / ksh_id from a portal href", {
  expect_identical(
    planscanR:::ee_extract_id("/kmh/kmh_view?kmh_id=478&represented_id=", "KMH"),
    "478"
  )
  expect_identical(
    planscanR:::ee_extract_id("kmh/ksh_view?ksh_id=319&represented_id=", "KSH"),
    "319"
  )
  expect_true(is.na(planscanR:::ee_extract_id("/something/else", "KMH")))
  expect_true(is.na(planscanR:::ee_extract_id("kmh_id=", "KMH")))
})

test_that("ee_section_slug auto-slugs document Liik strings including Estonian diacritics", {
  expect_identical(planscanR:::ee_section_slug("Algatamise otsus"), "algatamise_otsus")
  expect_identical(planscanR:::ee_section_slug("Programm"), "programm")
  expect_identical(planscanR:::ee_section_slug("Aruande lisa"), "aruande_lisa")
  # Lowercase Estonian diacritics fold to ASCII. (Real Liik strings from
  # KOTKAS are sentence-cased so the diacritics arrive lowercase.)
  expect_identical(planscanR:::ee_section_slug("eelnõu"), "eelnou")
  expect_identical(planscanR:::ee_section_slug("aruande lisa õige"), "aruande_lisa_oige")
  # Edge cases.
  expect_identical(planscanR:::ee_section_slug(NULL), "document")
  expect_identical(planscanR:::ee_section_slug(NA_character_), "document")
  expect_identical(planscanR:::ee_section_slug(""), "document")
})

test_that("ee_normalise_assessment_type accepts the API vocabulary case-insensitively", {
  expect_identical(planscanR:::ee_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::ee_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::ee_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::ee_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::ee_normalise_assessment_type("sea"), "SEA")
  expect_error(planscanR:::ee_normalise_assessment_type("nope"))
})

test_that("ee_normalise_status accepts the API vocabulary case-insensitively", {
  expect_null(planscanR:::ee_normalise_status(NULL))
  expect_null(planscanR:::ee_normalise_status(""))
  expect_identical(planscanR:::ee_normalise_status("INITIATED"), "INITIATED")
  expect_identical(planscanR:::ee_normalise_status("ongoing"), "ONGOING")
  expect_error(planscanR:::ee_normalise_status("done"))
})

test_that("ee_parse_detail extracts expected KMH fields, attachments, geometry", {
  url <- planscanR:::ee_canonical_url("KMH", "478")
  parsed <- planscanR:::ee_parse_detail(url, .ee_entry_kmh_478, .ee_fix_kmh_detail)
  rec <- parsed$record

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "ee")
  expect_identical(rec$source_portal, "kotkas.envir.ee")
  expect_identical(rec$document_id, "KMH-478")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Aarnam.e")
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "KMH")
  # The comment-stripping path in ee_label_value: developer cell is wrapped in
  # <!--small -->VALUE<!--/small --> on real pages and must come out clean.
  expect_match(rec$developer, "AS TREV-2 Grupp")
  expect_false(grepl("small", rec$developer, ignore.case = TRUE))
  expect_match(rec$decider, "Keskkonnaamet")
  expect_identical(rec$date_published, as.Date("2025-01-22"))
  expect_match(rec$activity_sector, "Kaevandamine")
  # Three documents, three distinct section slugs.
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 3L)
  expect_true(all(grepl("^https?://", urls)))
  expect_true("attachment_urls_algatamise_otsus" %in% names(rec))
  expect_true("attachment_urls_programm" %in% names(rec))
  expect_true("attachment_urls_programmi_otsus" %in% names(rec))
  # Geometry parsed inline as a MultiPolygon GeoJSON object.
  expect_false(is.null(parsed$geometry))
  expect_identical(parsed$geometry$type, "MultiPolygon")
})

test_that("ee_parse_detail extracts expected KSH fields including ksh_type from index", {
  url <- planscanR:::ee_canonical_url("KSH", "319")
  parsed <- planscanR:::ee_parse_detail(url, .ee_entry_ksh_319, .ee_fix_ksh_detail)
  rec <- parsed$record

  expect_identical(rec$register, "KSH")
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$document_id, "KSH-319")
  expect_match(rec$title, "Aaspere Agro")
  # KSH-specific actors: Initiator + Organiser. Decider/Developer are typically NA.
  expect_match(rec$initiator, "Haljala")
  expect_match(rec$organizer, "Haljala")
  # native_type folds ksh_type (from the index row) with activity_sector.
  expect_match(rec$native_type, "Detailplaneering")
  # 10 attachments grouped under several Liik headings.
  urls <- rec$attachment_urls[[1]]
  expect_gte(length(urls), 5L)
  # Geometry parsed as Polygon.
  expect_false(is.null(parsed$geometry))
  expect_identical(parsed$geometry$type, "Polygon")
})

test_that("ee_parse_inline_geometry returns NULL when the hidden input is absent", {
  blank <- rvest::read_html("<html><body><div>no geometry</div></body></html>")
  expect_null(planscanR:::ee_parse_inline_geometry(blank))
})

test_that("ee_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2025-01-22"))
  expect_true(planscanR:::ee_record_matches(rec, NULL))
  expect_true(planscanR:::ee_record_matches(
    rec,
    as.Date(c("2025-01-01", "2025-12-31"))
  ))
  expect_false(planscanR:::ee_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

test_that("get_assessments_ee end-to-end on fixtures (sidecar-first, geometry persisted)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # Cheaper than parsing the 40-row index pages: stub the index fetcher
    # directly with the two synthetic entries.
    local_mocked_bindings(
      perform_html = mock_perform_html_two_records(),
      ee_fetch_search = function(register, ...) {
        if (register == "KMH") list(.ee_entry_kmh_478) else list(.ee_entry_ksh_319)
      }
    )

    res <- get_assessments_ee(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("KMH-478", "KSH-319"))
    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "ee"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)
    # Both records carry geometry → both have a sibling .geometry.geojson.
    for (id in c("KMH-478", "KSH-319")) {
      geom_file <- file.path(cache, "files", "ee", id, paste0(id, ".geometry.geojson"))
      expect_true(file.exists(geom_file))
      geo <- jsonlite::fromJSON(geom_file, simplifyVector = FALSE)
      expect_identical(geo$type, "FeatureCollection")
      expect_match(geo$crs$properties$name, "EPSG::3301")
    }

    # Second call with refresh = FALSE must NOT re-invoke ee_parse_detail.
    parse_calls <- 0L
    local_mocked_bindings(
      ee_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("ee_parse_detail should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_ee(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c("KMH-478", "KSH-319"))
  })
})

test_that("get_assessments_ee honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_two_records(),
      ee_fetch_search = function(register, ...) {
        if (register == "KMH") list(.ee_entry_kmh_478) else list(.ee_entry_ksh_319)
      }
    )

    # EIA-only -> only the KMH record.
    res_eia <- get_assessments_ee(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res_eia), 1L)
    expect_identical(res_eia$document_id, "KMH-478")

    # SEA-only -> only the KSH record.
    res_sea <- get_assessments_ee(assessment_type = "SEA", limit = 5, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$document_id, "KSH-319")
  })
})

test_that("EE -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_two_records(),
      ee_fetch_search = function(register, ...) {
        if (register == "KMH") list(.ee_entry_kmh_478) else list(.ee_entry_ksh_319)
      }
    )

    res <- get_assessments_ee(limit = 5, download = FALSE)
    idx <- index_cache(country = "ee")
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c("KMH-478", "KSH-319"))

    # Country-specific scalars round-trip through extras{}.
    expect_true("register" %in% names(idx))
    expect_true("assessment_type" %in% names(idx))
    expect_true("ksh_type" %in% names(idx))
    expect_true("activity_sector" %in% names(idx))
    expect_setequal(idx$register, c("KMH", "KSH"))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
    # Per-section attachment URL columns survive too.
    expect_true(any(grepl("^attachment_urls_", names(idx))))
    # The geometry sidecar tag.
    expect_setequal(idx$geometry_crs, "EPSG:3301")
    expect_true(all(file.exists(idx$geometry_path)))
  })
})

test_that("get_assessments_ee scores topics and adds relevance_score_<slug> columns", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    reset_relevance_warnings()

    local_mocked_bindings(
      perform_html = mock_perform_html_two_records(),
      ee_fetch_search = function(register, ...) {
        if (register == "KMH") list(.ee_entry_kmh_478) else list(.ee_entry_ksh_319)
      }
    )

    res <- get_assessments_ee(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "wind energy", mining = "kaevandamine"),
      relevance_model = make_fake_model(languages = c("et", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_mining" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('ee') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("ee", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "ee")
    expect_identical(res$source_portal, "kotkas.envir.ee")
    expect_true(grepl("^https://kotkas\\.envir\\.ee/kmh/(kmh_view|ksh_view)", res$url))
  })
})
