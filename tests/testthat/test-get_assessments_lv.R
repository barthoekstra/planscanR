# Tests for get_assessments_lv(). Offline strategy: stub `perform_html` to hand
# back the recorded HTML fixtures so no live HTTP is needed in CI. The fixtures
# cover both halves of the asymmetric eva.gov.lv portal:
#  - EIA (metadata-only): eia_listing.html + eia_detail.html
#  - SEA (direct PDFs):    sea_atzinumi.html

read_lv_fixture <- function(name) {
  rvest::read_html(fixture_path("lv", name))
}

.lv_fix_eia_listing <- read_lv_fixture("eia_listing.html")
.lv_fix_eia_detail <- read_lv_fixture("eia_detail.html")
.lv_fix_sea_atzinumi <- read_lv_fixture("sea_atzinumi.html")

.lv_detail_url <- paste0(
  "https://www.eva.gov.lv/lv/ietekmes-uz-vidi-novertejumu-projekti/",
  "terauda-un-e-metanola-razosanas-rupnicas-buvnieciba-kundzinsala-riga-rigas-brivostas-parvalde"
)

# -- Parse-fn units ----------------------------------------------------------

test_that("lv_parse_eia_rows extracts listing rows with detail URL + card fields", {
  rows <- planscanR:::lv_parse_eia_rows(.lv_fix_eia_listing)
  expect_gte(length(rows), 3L)
  first <- rows[[1]]
  expect_identical(first$register, "ivn-projekti")
  expect_identical(first$assessment_type, "EIA")
  expect_true(grepl("^https://www\\.eva\\.gov\\.lv/lv/ietekmes-uz-vidi-novertejumu-projekti/", first$url))
  expect_match(first$title, "Daugavpils putni")
  expect_identical(first$status, "Piemērots")
  expect_match(first$proponent, "Balticovo")
})

test_that("lv_extract_media_id pulls the numeric id from a /lv/media/ href", {
  expect_identical(
    planscanR:::lv_extract_media_id("/lv/media/9125/download?attachment"),
    "9125"
  )
  expect_true(is.na(planscanR:::lv_extract_media_id("/lv/atzinumi")))
  expect_true(is.na(planscanR:::lv_extract_media_id(NA_character_)))
})

test_that("lv_media_url absolutises a media id", {
  expect_identical(
    planscanR:::lv_media_url("9125"),
    "https://www.eva.gov.lv/lv/media/9125/download?attachment"
  )
})

test_that("lv_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::lv_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::lv_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::lv_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::lv_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::lv_normalise_assessment_type("sea"), "SEA")
  expect_error(planscanR:::lv_normalise_assessment_type("nope"))
})

test_that("lv_decision_date maps a bare year to Jan 1 and parses a full date", {
  expect_identical(planscanR:::lv_decision_date("2026"), as.Date("2026-01-01"))
  expect_identical(planscanR:::lv_decision_date("06.01.2026."), as.Date("2026-01-06"))
  expect_true(is.na(planscanR:::lv_decision_date(NULL)))
  expect_true(is.na(planscanR:::lv_decision_date("")))
  expect_true(is.na(planscanR:::lv_decision_date("nav")))
})

test_that("lv_parse_eia_detail extracts metadata and leaves attachments EMPTY (metadata-only)", {
  entry <- list(
    register = "ivn-projekti",
    assessment_type = "EIA",
    url = .lv_detail_url,
    title = NULL,
    status = NULL,
    proponent = NULL,
    decision_text = NULL
  )
  rec <- planscanR:::lv_parse_eia_detail(.lv_detail_url, entry, .lv_fix_eia_detail)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "lv")
  expect_identical(rec$source_portal, "eva.gov.lv")
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "ivn-projekti")
  expect_true(startsWith(rec$document_id, "IVN-"))
  expect_match(rec$title, "Tērauda un e-metanola")
  expect_identical(rec$status, "Piemērots")
  expect_match(rec$proponent, "Rīgas Brīvostas Pārvalde")
  expect_identical(rec$competent_authority, "Vides pārraudzības valsts birojs")
  expect_match(rec$location, "Uriekstes ielā")
  expect_match(rec$summary, "elektriskā loka krāsns")
  expect_identical(rec$date_decision, as.Date("2026-01-01"))
  # EIA is metadata-only: NO attachment URLs.
  expect_length(rec$attachment_urls[[1]], 0L)
})

test_that("lv_parse_sea_entries extracts media download URLs + titles from a sub-page", {
  entries <- planscanR:::lv_parse_sea_entries(.lv_fix_sea_atzinumi, "atzinumi")
  expect_gte(length(entries), 2L)
  first <- entries[[1]]
  expect_identical(first$register, "atzinumi")
  expect_identical(first$assessment_type, "SEA")
  expect_identical(first$media_id, "9125")
  expect_identical(
    first$media_url,
    "https://www.eva.gov.lv/lv/media/9125/download?attachment"
  )
  expect_match(first$title, "Cielavas")
  expect_match(first$date_text, "06\\.01\\.2026")
})

test_that("lv_build_sea_record carries the direct PDF as its single attachment", {
  entries <- planscanR:::lv_parse_sea_entries(.lv_fix_sea_atzinumi, "atzinumi")
  rec <- planscanR:::lv_build_sea_record(entries[[1]]$url, entries[[1]])
  expect_identical(rec$country, "lv")
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$register, "atzinumi")
  expect_identical(rec$document_id, "ATZ-9125")
  expect_identical(rec$native_type, "atzinums")
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 1L)
  expect_identical(urls, "https://www.eva.gov.lv/lv/media/9125/download?attachment")
  expect_identical(rec$date_published, as.Date("2026-01-06"))
})

# -- Filters -----------------------------------------------------------------

test_that("lv_record_matches honours the query substring filter", {
  rec <- tibble::tibble(
    title = "Veja parka buvnieciba",
    date_published = as.Date("2026-01-06"),
    date_decision = as.Date(NA)
  )
  expect_true(planscanR:::lv_record_matches(rec, query = NULL))
  expect_true(planscanR:::lv_record_matches(rec, query = "veja"))
  expect_true(planscanR:::lv_record_matches(rec, query = "BUVNIECIBA"))
  expect_false(planscanR:::lv_record_matches(rec, query = "metanols"))
})

test_that("lv_record_matches honours date_range and drops NA-date records only when set", {
  rec <- tibble::tibble(
    title = "x",
    date_published = as.Date("2026-01-06"),
    date_decision = as.Date(NA)
  )
  expect_true(planscanR:::lv_record_matches(rec, date_range = NULL))
  expect_true(planscanR:::lv_record_matches(
    rec,
    date_range = as.Date(c("2026-01-01", "2026-12-31"))
  ))
  expect_false(planscanR:::lv_record_matches(
    rec,
    date_range = as.Date(c("2020-01-01", "2020-12-31"))
  ))
  # NA date is kept when no range is set, dropped when a range is set.
  na_rec <- tibble::tibble(
    title = "x",
    date_published = as.Date(NA),
    date_decision = as.Date(NA)
  )
  expect_true(planscanR:::lv_record_matches(na_rec, date_range = NULL))
  expect_false(planscanR:::lv_record_matches(
    na_rec,
    date_range = as.Date(c("2026-01-01", "2026-12-31"))
  ))
})

# -- End-to-end on fixtures --------------------------------------------------

# Synthetic EIA listing entry matching the detail fixture.
.lv_entry_eia <- list(
  register = "ivn-projekti",
  assessment_type = "EIA",
  url = .lv_detail_url,
  title = "Tērauda un e-metanola ražošanas rūpnīcas būvniecība",
  status = "Piemērots",
  proponent = "Rīgas Brīvostas Pārvalde",
  decision_text = "2026"
)

stub_lv_fetch_eia <- function() {
  function() {
    emitted <- FALSE
    function() {
      if (emitted) {
        return(NULL)
      }
      emitted <<- TRUE
      list(.lv_entry_eia)
    }
  }
}

stub_lv_fetch_sea <- function() {
  function(register) {
    emitted <- FALSE
    function() {
      if (emitted) {
        return(NULL)
      }
      emitted <<- TRUE
      # Only the atzinumi sub-page has entries in this stub; one record.
      if (register == "atzinumi") {
        list(list(
          register = "atzinumi",
          assessment_type = "SEA",
          url = "https://www.eva.gov.lv/lv/atzinumi#media-9125",
          media_url = "https://www.eva.gov.lv/lv/media/9125/download?attachment",
          media_id = "9125",
          title = "Lokālplānojums Cielavas",
          number = "11.15/AP/78/2026",
          date_text = "06.01.2026."
        ))
      } else {
        list()
      }
    }
  }
}

mock_perform_html_lv <- function() {
  function(req) {
    url <- req$url
    if (grepl("terauda-un-e-metanola", url)) {
      return(.lv_fix_eia_detail)
    }
    stop("Unexpected URL in test: ", url)
  }
}

test_that("get_assessments_lv end-to-end on fixtures (both halves; sidecar-first reuse)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_lv(),
      lv_fetch_eia = stub_lv_fetch_eia(),
      lv_fetch_sea = stub_lv_fetch_sea()
    )

    res <- get_assessments_lv(limit = 10, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$assessment_type, c("EIA", "SEA"))
    expect_true(all(c("IVN", "ATZ") %in% sub("-.*$", "", res$document_id)))

    sidecars <- list.files(
      file.path(cache, "files", "lv"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT re-fetch cached EIA detail.
    local_mocked_bindings(
      lv_parse_eia_detail = function(...) {
        stop("lv_parse_eia_detail should not run on a cached URL")
      }
    )
    res2 <- get_assessments_lv(limit = 10, download = FALSE)
    expect_identical(nrow(res2), 2L)
  })
})

test_that("get_assessments_lv honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_lv(),
      lv_fetch_eia = stub_lv_fetch_eia(),
      lv_fetch_sea = stub_lv_fetch_sea()
    )

    res_eia <- get_assessments_lv(assessment_type = "EIA", limit = 10, download = FALSE)
    expect_identical(nrow(res_eia), 1L)
    expect_identical(res_eia$assessment_type, "EIA")
    expect_length(res_eia$attachment_urls[[1]], 0L)

    res_sea <- get_assessments_lv(assessment_type = "SEA", limit = 10, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$assessment_type, "SEA")
    expect_identical(res_sea$document_id, "ATZ-9125")
  })
})

test_that("get_assessments_lv honours query and date_range and caps the global limit", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_lv(),
      lv_fetch_eia = stub_lv_fetch_eia(),
      lv_fetch_sea = stub_lv_fetch_sea()
    )

    # query hits the EIA title only.
    res_q <- get_assessments_lv(query = "metanola", limit = 10, download = FALSE)
    expect_identical(nrow(res_q), 1L)
    expect_identical(res_q$assessment_type, "EIA")

    res_none <- get_assessments_lv(query = "zzz-no-match", limit = 10, download = FALSE)
    expect_identical(nrow(res_none), 0L)

    # Global limit caps across both halves (EIA crawled first).
    res_lim <- get_assessments_lv(limit = 1, download = FALSE)
    expect_identical(nrow(res_lim), 1L)
    expect_identical(res_lim$assessment_type, "EIA")
  })
})

test_that("LV -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_lv(),
      lv_fetch_eia = stub_lv_fetch_eia(),
      lv_fetch_sea = stub_lv_fetch_sea()
    )

    res <- get_assessments_lv(limit = 10, download = FALSE)
    idx <- index_cache(country = "lv")
    expect_identical(nrow(idx), 2L)
    expect_true("register" %in% names(idx))
    expect_true("assessment_type" %in% names(idx))
    expect_true("location" %in% names(idx))
    expect_true("decision" %in% names(idx))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
  })
})

test_that("get_assessments_lv scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_lv(),
      lv_fetch_eia = stub_lv_fetch_eia(),
      lv_fetch_sea = stub_lv_fetch_sea()
    )

    res <- get_assessments_lv(
      limit = 10,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(steel = "metanola", plan = "lokalplanojums"),
      relevance_model = make_fake_model(languages = c("lv", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_steel" %in% names(res))
    expect_true("relevance_score_plan" %in% names(res))
    expect_true(is.numeric(res$relevance_score_steel))
  })
})

# -- Live integration test ---------------------------------------------------

test_that("get_assessments('lv') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("lv", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "lv")
    expect_identical(res$source_portal, "eva.gov.lv")
    expect_true(grepl("^https://www\\.eva\\.gov\\.lv", res$url))
  })
})
