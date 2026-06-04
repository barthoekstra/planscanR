# Tests for get_assessments_si(). Offline strategy: stub the bulk-export JSON
# fetch (si_fetch_search) and the per-record attachment fetch
# (si_fetch_attachments) so no live HTTP is needed in CI. The fixtures cover
# both register shapes gov.si exposes:
#  - screening (EIA): screening.json     (predhodni-postopek field map)
#  - CPVO (SEA):      cpvo_state.json    (drzavni-prostorski-nacrti field map)
#  - one detail page: detail_screening.html (one /assets/seznami/ attachment)

read_si_json <- function(name) {
  jsonlite::fromJSON(fixture_path("si", name), simplifyVector = FALSE)
}

read_si_html <- function(name) {
  rvest::read_html(fixture_path("si", name))
}

.si_screening <- read_si_json("screening.json")
.si_cpvo <- read_si_json("cpvo_state.json")
.si_detail <- read_si_html("detail_screening.html")

# Lightweight listing entries mirroring si_map_entries() output.
si_entry_for <- function(arr, register, i) {
  raw <- arr[[i]]
  list(
    register = register,
    url_segment = raw$URLSegment,
    url = planscanR:::si_canonical_url(register, raw$URLSegment),
    raw = raw
  )
}

.si_entry_screening_1 <- si_entry_for(.si_screening, "predhodni-postopek", 1L)
.si_entry_cpvo_1 <- si_entry_for(.si_cpvo, "cpvo-drzavni", 1L)

test_that("si_parse_date parses the Slovenian date format tolerantly", {
  expect_identical(planscanR:::si_parse_date("29. 09. 2021"), as.Date("2021-09-29"))
  expect_identical(planscanR:::si_parse_date("07.10.2021"), as.Date("2021-10-07"))
  expect_true(is.na(planscanR:::si_parse_date(NULL)))
  expect_true(is.na(planscanR:::si_parse_date(NA_character_)))
  expect_true(is.na(planscanR:::si_parse_date("")))
  expect_true(is.na(planscanR:::si_parse_date("not a date")))
})

test_that("si_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::si_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::si_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::si_normalise_assessment_type("eia"), "EIA")
  expect_identical(planscanR:::si_normalise_assessment_type("SEA"), "SEA")
  expect_error(planscanR:::si_normalise_assessment_type("nope"))
})

test_that("si_parse_attachments collects and absolutises /assets/seznami links", {
  urls <- planscanR:::si_parse_attachments(.si_detail)
  expect_length(urls, 1L)
  expect_identical(
    urls,
    "https://www.gov.si/assets/seznami/predhodni-postopek/01.docx"
  )
  blank <- rvest::read_html("<html><body><a href='/somewhere'>x</a></body></html>")
  expect_identical(planscanR:::si_parse_attachments(blank), character(0))
})

test_that("si_build_record parses screening (EIA) fields and extras", {
  rec <- planscanR:::si_build_record(.si_entry_screening_1, character(0))

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "si")
  expect_identical(rec$source_portal, "gov.si")
  expect_match(rec$document_id, "^PRED-")
  expect_match(rec$title, "INCOM")
  expect_s3_class(rec$date_published, "Date")
  expect_identical(rec$date_published, as.Date("2021-09-29"))
  expect_match(rec$proponent, "INCOM")
  expect_true(nzchar(rec$case_number))
  expect_match(rec$annex_code, "G\\.II")
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "predhodni-postopek")
  expect_identical(rec$competent_authority, "Ministrstvo za okolje, podnebje in energijo")
  expect_true(is.na(rec$date_decision))
})

test_that("si_build_record parses CPVO (SEA) fields and extras", {
  rec <- planscanR:::si_build_record(.si_entry_cpvo_1, character(0))

  expect_match(rec$document_id, "^CPVO-DRZ-")
  expect_match(rec$title, "Državni prostorski načrt")
  expect_identical(rec$date_published, as.Date("2021-07-08"))
  expect_true(is.na(rec$proponent))
  expect_match(rec$decision, "CPVO")
  expect_match(rec$native_type, "CPVO")
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$register, "cpvo-drzavni")
})

test_that("si_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2021-09-29"))
  expect_true(planscanR:::si_record_matches(rec, NULL))
  expect_true(planscanR:::si_record_matches(
    rec,
    as.Date(c("2021-01-01", "2021-12-31"))
  ))
  expect_false(planscanR:::si_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

# A reusable mock pair: bulk-export generator yields the first entry of each
# register once; the attachment fetch returns the one fixture attachment.
si_mock_bindings <- function() {
  list(
    si_fetch_search = function(register) {
      emitted <- FALSE
      function() {
        if (emitted) {
          return(NULL)
        }
        emitted <<- TRUE
        switch(
          register,
          `predhodni-postopek` = list(.si_entry_screening_1),
          `cpvo-drzavni` = list(.si_entry_cpvo_1),
          `cpvo-obcinski` = list()
        )
      }
    },
    si_fetch_attachments = function(url) {
      planscanR:::si_parse_attachments(.si_detail)
    }
  )
}

test_that("get_assessments_si end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- si_mock_bindings()
    local_mocked_bindings(
      si_fetch_search = mb$si_fetch_search,
      si_fetch_attachments = mb$si_fetch_attachments
    )

    res <- get_assessments_si(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_true(all(grepl("^(PRED|CPVO-DRZ)-", res$document_id)))

    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "si"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT re-fetch attachments.
    local_mocked_bindings(
      si_fetch_attachments = function(...) {
        stop("si_fetch_attachments should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_si(limit = 5, download = FALSE)
    expect_identical(nrow(res2), 2L)
  })
})

test_that("get_assessments_si honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- si_mock_bindings()
    local_mocked_bindings(
      si_fetch_search = mb$si_fetch_search,
      si_fetch_attachments = mb$si_fetch_attachments
    )

    # EIA-only -> only the screening register.
    res_eia <- get_assessments_si(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res_eia), 1L)
    expect_identical(res_eia$register, "predhodni-postopek")
    expect_identical(res_eia$assessment_type, "EIA")

    # SEA-only -> only the CPVO register(s).
    res_sea <- get_assessments_si(assessment_type = "SEA", limit = 5, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$register, "cpvo-drzavni")
    expect_identical(res_sea$assessment_type, "SEA")
  })
})

test_that("get_assessments_si honours date_range and limit", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- si_mock_bindings()
    local_mocked_bindings(
      si_fetch_search = mb$si_fetch_search,
      si_fetch_attachments = mb$si_fetch_attachments
    )

    # Positive window: both records fall in 2021.
    res_in <- get_assessments_si(
      date_range = c("2021-01-01", "2021-12-31"),
      download = FALSE
    )
    expect_identical(nrow(res_in), 2L)

    # Negative window: nothing in 2019.
    res_out <- get_assessments_si(
      date_range = c("2019-01-01", "2019-12-31"),
      download = FALSE
    )
    expect_identical(nrow(res_out), 0L)

    # limit caps the total across registers.
    res_lim <- get_assessments_si(limit = 1, download = FALSE)
    expect_identical(nrow(res_lim), 1L)
  })
})

test_that("SI -> sidecar round-trip preserves country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- si_mock_bindings()
    local_mocked_bindings(
      si_fetch_search = mb$si_fetch_search,
      si_fetch_attachments = mb$si_fetch_attachments
    )

    res <- get_assessments_si(limit = 5, download = FALSE)
    idx <- index_cache(country = "si")
    expect_identical(nrow(idx), 2L)

    expect_true(all(c("assessment_type", "register", "case_number", "annex_code", "decision") %in% names(idx)))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
    expect_setequal(idx$register, c("predhodni-postopek", "cpvo-drzavni"))
    # Screening-side extras survive.
    expect_true(any(grepl("G\\.II", idx$annex_code)))
    # CPVO-side decision survives.
    expect_true(any(grepl("CPVO", idx$decision)))
  })
})

test_that("get_assessments_si scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- si_mock_bindings()
    local_mocked_bindings(
      si_fetch_search = mb$si_fetch_search,
      si_fetch_attachments = mb$si_fetch_attachments
    )

    res <- get_assessments_si(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(water = "oskrba s pitno vodo", industry = "INCOM"),
      relevance_model = make_fake_model(languages = c("sl", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_water" %in% names(res))
    expect_true("relevance_score_industry" %in% names(res))
    expect_true(is.numeric(res$relevance_score_water))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('si') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("si", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "si")
    expect_identical(res$source_portal, "gov.si")
    expect_true(grepl("^https://www\\.gov\\.si", res$url))
  })
})
