# Tests for get_assessments_cz(). Offline strategy: stub `perform_html` to hand
# back the recorded HTML fixtures so no live HTTP is needed in CI. The fixtures
# cover both CENIA registers (domestic CZ only):
#  - EIA (Záměry na území ČR): listing-eia.html, detail-eia-jhc1237.html
#    (one EIA záměr with several stage-grouped attachment links, no geometry)
#  - SEA (Posuzování koncepcí): listing-sea.html, detail-sea-hkk015k.html
#    (one SEA koncepce with two attachment links)

cz_read_fixture_html <- function(name) {
  rvest::read_html(fixture_path("cz", name))
}

# Pre-load every fixture once, at file-load time, so they're available before
# any test enters `withr::with_tempdir()`.
.cz_fix_eia_listing <- cz_read_fixture_html("listing-eia.html")
.cz_fix_sea_listing <- cz_read_fixture_html("listing-sea.html")
.cz_fix_eia_detail <- cz_read_fixture_html("detail-eia-jhc1237.html")
.cz_fix_sea_detail <- cz_read_fixture_html("detail-sea-hkk015k.html")

cz_mock_perform_html_two_records <- function() {
  # Cheaper mock: only one record per register. The end-to-end tests stub the
  # index fetcher directly so we don't crawl the listing pages.
  function(req) {
    url <- req$url
    if (grepl("/detail/EIA_JHC1237", url)) {
      return(.cz_fix_eia_detail)
    }
    if (grepl("/detail/SEA_HKK015K", url)) {
      return(.cz_fix_sea_detail)
    }
    stop("Unexpected URL in test: ", url)
  }
}

# Two synthetic listing-row entries that line up with the detail fixtures.
.cz_entry_eia_jhc1237 <- list(
  register = "EIA",
  code = "JHC1237",
  title = "Županovice – novostavba hal pro výkrm brojlerů",
  competent_authority = "Krajský úřad Jihočeského kraje",
  native_type = "I/68",
  status = "Závěry zjišťovacího řízení",
  last_modified = as.Date("2026-06-04")
)
.cz_entry_sea_hkk015k <- list(
  register = "SEA",
  code = "HKK015K",
  title = "Strategický plán rozvoje města Trutnova na období 2026-2033",
  competent_authority = "Krajský úřad Královéhradeckého kraje",
  native_type = NA_character_,
  status = "Oznámení",
  last_modified = as.Date("2026-05-13")
)

test_that("cz_parse_index_rows extracts every row from a real EIA listing page", {
  rows <- planscanR:::cz_parse_index_rows(.cz_fix_eia_listing, "EIA")
  expect_gte(length(rows), 1L)
  first <- rows[[1]]
  expect_identical(first$register, "EIA")
  expect_match(first$code, "^[A-Z0-9]+$")
  expect_true(nzchar(first$title))
})

test_that("cz_parse_index_rows extracts every row from a real SEA listing page", {
  rows <- planscanR:::cz_parse_index_rows(.cz_fix_sea_listing, "SEA")
  expect_gte(length(rows), 1L)
  codes <- vapply(rows, function(r) r$code, character(1))
  expect_true("HKK015K" %in% codes)
  first <- rows[[1]]
  expect_identical(first$register, "SEA")
})

test_that("cz_extract_code pulls the detail code from a portal href", {
  expect_identical(
    planscanR:::cz_extract_code("/eiasea/detail/EIA_JHC1237?lang=cs", "EIA"),
    "JHC1237"
  )
  expect_identical(
    planscanR:::cz_extract_code("/eiasea/detail/SEA_HKK015K?lang=cs", "SEA"),
    "HKK015K"
  )
  expect_identical(
    planscanR:::cz_extract_code("/eiasea/detail/EIA_MZP535?lang=cs", "EIA"),
    "MZP535"
  )
  expect_true(is.na(planscanR:::cz_extract_code("/something/else", "EIA")))
})

test_that("cz_section_slug auto-slugs Czech stage headings via transliteration", {
  expect_identical(planscanR:::cz_section_slug("OZNÁMENÍ"), "oznameni")
  expect_identical(
    planscanR:::cz_section_slug("ZJIŠŤOVACÍ ŘÍZENÍ"),
    "zjistovaci_rizeni"
  )
  expect_identical(planscanR:::cz_section_slug("Text oznámení"), "text_oznameni")
  # Edge cases.
  expect_identical(planscanR:::cz_section_slug(NULL), "document")
  expect_identical(planscanR:::cz_section_slug(NA_character_), "document")
  expect_identical(planscanR:::cz_section_slug(""), "document")
})

test_that("cz_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::cz_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::cz_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::cz_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::cz_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::cz_normalise_assessment_type("sea"), "SEA")
  expect_error(planscanR:::cz_normalise_assessment_type("nope"))
})

test_that("cz_parse_java_date parses Java Date.toString() and DD.MM.YYYY forms", {
  expect_identical(
    planscanR:::cz_parse_java_date("Thu Jun 04 07:28:50 CEST 2026"),
    as.Date("2026-06-04")
  )
  expect_identical(
    planscanR:::cz_parse_java_date("Tue May 12 00:00:00 CEST 2026"),
    as.Date("2026-05-12")
  )
  expect_identical(
    planscanR:::cz_parse_java_date("16.04.2026 10:50:09"),
    as.Date("2026-04-16")
  )
  expect_true(is.na(planscanR:::cz_parse_java_date("")))
  expect_true(is.na(planscanR:::cz_parse_java_date(NULL)))
  expect_true(is.na(planscanR:::cz_parse_java_date("no date")))
})

test_that("cz_parse_detail extracts expected EIA fields, location, and attachments", {
  url <- planscanR:::cz_canonical_url("EIA", "JHC1237")
  rec <- planscanR:::cz_parse_detail(url, .cz_entry_eia_jhc1237, .cz_fix_eia_detail)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "cz")
  expect_identical(rec$source_portal, "portal.cenia.cz")
  expect_identical(rec$document_id, "EIA_JHC1237")
  expect_identical(rec$url, url)
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "EIA")
  expect_identical(rec$code, "JHC1237")
  expect_match(rec$title, "Županovice")
  expect_match(rec$competent_authority, "Jihočeského")
  expect_match(rec$proponent, "FREDI")
  expect_identical(rec$native_type, "I/68")
  expect_identical(rec$proponent_company_id, "25174568")
  expect_match(rec$status, "zjišťovacího")
  # date_published is the EIA last-modified date.
  expect_identical(rec$date_published, as.Date("2026-06-04"))
  # date_decision is always NA for CZ.
  expect_true(is.na(rec$date_decision))
  # jurisdiction is composed from the Umístění (Kraj / Okres / Obec / Katastr).
  expect_match(rec$jurisdiction, "Jihočeský kraj")
  expect_match(rec$jurisdiction, "Županovice")
  # No summary field on this portal.
  expect_true(is.na(rec$summary))
  # Stage-grouped attachment links (download tokens preserved verbatim).
  urls <- rec$attachment_urls[[1]]
  expect_gte(length(urls), 3L)
  expect_true(all(grepl("^https://portal\\.cenia\\.cz/eiasea/download/", urls)))
  # The OZNÁMENÍ stage column should exist (large oznameni.zip lives there).
  expect_true("attachment_urls_oznameni" %in% names(rec))
  expect_true(any(grepl("oznameni\\.zip$", urls)))
  # No geometry columns are ever emitted for CZ.
  expect_false("geometry_path" %in% names(rec))
  expect_false("geometry_crs" %in% names(rec))
})

test_that("cz_parse_detail extracts expected SEA fields", {
  url <- planscanR:::cz_canonical_url("SEA", "HKK015K")
  rec <- planscanR:::cz_parse_detail(url, .cz_entry_sea_hkk015k, .cz_fix_sea_detail)

  expect_identical(rec$register, "SEA")
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$document_id, "SEA_HKK015K")
  expect_match(rec$title, "Strategický plán")
  expect_match(rec$competent_authority, "Královéhradeckého")
  expect_match(rec$proponent, "Trutnov")
  expect_identical(rec$proponent_company_id, "00278360")
  # SEA uses the dedicated "Datum zveřejnění" publication date.
  expect_identical(rec$date_published, as.Date("2026-05-12"))
  urls <- rec$attachment_urls[[1]]
  expect_gte(length(urls), 2L)
  expect_true(all(grepl("/eiasea/download/", urls)))
})

test_that("cz_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2026-06-04"))
  expect_true(planscanR:::cz_record_matches(rec, NULL))
  expect_true(planscanR:::cz_record_matches(
    rec,
    as.Date(c("2026-01-01", "2026-12-31"))
  ))
  expect_false(planscanR:::cz_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

test_that("get_assessments_cz end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = cz_mock_perform_html_two_records(),
      cz_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "EIA") {
            list(.cz_entry_eia_jhc1237)
          } else {
            list(.cz_entry_sea_hkk015k)
          }
        }
      }
    )

    res <- get_assessments_cz(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("EIA_JHC1237", "SEA_HKK015K"))
    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "cz"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT re-invoke cz_parse_detail.
    parse_calls <- 0L
    local_mocked_bindings(
      cz_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("cz_parse_detail should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_cz(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c("EIA_JHC1237", "SEA_HKK015K"))
  })
})

test_that("get_assessments_cz honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = cz_mock_perform_html_two_records(),
      cz_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "EIA") {
            list(.cz_entry_eia_jhc1237)
          } else {
            list(.cz_entry_sea_hkk015k)
          }
        }
      }
    )

    # EIA-only -> only the EIA record.
    res_eia <- get_assessments_cz(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res_eia), 1L)
    expect_identical(res_eia$document_id, "EIA_JHC1237")

    # SEA-only -> only the SEA record.
    res_sea <- get_assessments_cz(assessment_type = "SEA", limit = 5, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$document_id, "SEA_HKK015K")
  })
})

test_that("get_assessments_cz respects date_range filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = cz_mock_perform_html_two_records(),
      cz_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "EIA") {
            list(.cz_entry_eia_jhc1237)
          } else {
            list(.cz_entry_sea_hkk015k)
          }
        }
      }
    )

    # Only the SEA record (published 2026-05) falls in this window.
    res <- get_assessments_cz(
      date_range = c("2026-05-01", "2026-05-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "SEA_HKK015K")
  })
})

test_that("CZ -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = cz_mock_perform_html_two_records(),
      cz_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "EIA") {
            list(.cz_entry_eia_jhc1237)
          } else {
            list(.cz_entry_sea_hkk015k)
          }
        }
      }
    )

    res <- get_assessments_cz(limit = 5, download = FALSE)
    idx <- index_cache(country = "cz")
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c("EIA_JHC1237", "SEA_HKK015K"))

    # Country-specific scalars round-trip through extras{}.
    expect_true("register" %in% names(idx))
    expect_true("assessment_type" %in% names(idx))
    expect_true("proponent_company_id" %in% names(idx))
    expect_setequal(idx$register, c("EIA", "SEA"))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
    # Per-section attachment URL columns survive too.
    expect_true(any(grepl("^attachment_urls_", names(idx))))
  })
})

test_that("get_assessments_cz scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = cz_mock_perform_html_two_records(),
      cz_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "EIA") {
            list(.cz_entry_eia_jhc1237)
          } else {
            list(.cz_entry_sea_hkk015k)
          }
        }
      }
    )

    res <- get_assessments_cz(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(farm = "výkrm brojlerů", plan = "strategický plán"),
      relevance_model = make_fake_model(languages = c("cs", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_farm" %in% names(res))
    expect_true("relevance_score_plan" %in% names(res))
    expect_true(is.numeric(res$relevance_score_farm))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('cz') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("cz", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "cz")
    expect_identical(res$source_portal, "portal.cenia.cz")
    expect_true(grepl(
      "^https://portal\\.cenia\\.cz/eiasea/detail/(EIA|SEA)_",
      res$url
    ))
  })
})
