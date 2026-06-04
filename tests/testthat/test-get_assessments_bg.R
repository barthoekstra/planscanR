# Tests for get_assessments_bg(). Offline strategy: stub `perform_html` to hand
# back the recorded HTML fixtures so no live HTTP is needed in CI. The fixtures
# cover both МОСВ registers:
#  - ОВОС (EIA): listing-ovos.html, detail-ovos-21617.html  (one terminated
#    EIA dossier with several inline document links, no geometry)
#  - ЕО (SEA): listing-eo.html, detail-eo-44841.html  (one ongoing SEA dossier
#    with two document links)

bg_read_fixture_html <- function(name) {
  rvest::read_html(fixture_path("bg", name))
}

# Pre-load every fixture once, at file-load time, so they're available before
# any test enters `withr::with_tempdir()`.
.bg_fix_ovos_listing <- bg_read_fixture_html("listing-ovos.html")
.bg_fix_eo_listing <- bg_read_fixture_html("listing-eo.html")
.bg_fix_ovos_detail <- bg_read_fixture_html("detail-ovos-21617.html")
.bg_fix_eo_detail <- bg_read_fixture_html("detail-eo-44841.html")

bg_mock_perform_html_two_records <- function() {
  # Cheaper mock: only one record per register. The end-to-end tests stub the
  # index fetcher directly so we don't crawl the listing pages.
  function(req) {
    url <- req$url
    if (grepl("/ovos/lot/21617", url)) {
      return(.bg_fix_ovos_detail)
    }
    if (grepl("/eo/lot/44841", url)) {
      return(.bg_fix_eo_detail)
    }
    stop("Unexpected URL in test: ", url)
  }
}

# Two synthetic search-row entries that line up with the detail fixtures.
.bg_entry_ovos_21617 <- list(
  register = "OVOS",
  id = "21617",
  dossier_number = "БД - ОВОС - 75 - 2017",
  incoming_number = "533",
  title = "Изграждане на терен за загробване на умрели животни",
  proponent = "ОБЩИНА РАЗЛОГ",
  native_type = NA_character_,
  status = "Прекратена"
)
.bg_entry_eo_44841 <- list(
  register = "EO",
  id = "44841",
  dossier_number = "БД-ЕО-70-2923",
  incoming_number = "2972",
  title = "Проект за изменение на Общ устройствен план на община Благоевград",
  proponent = "Община Благоевград",
  native_type = NA_character_,
  status = "Текуща"
)

test_that("bg_parse_index_rows extracts every row from a real OVOS listing page", {
  rows <- planscanR:::bg_parse_index_rows(.bg_fix_ovos_listing, "OVOS")
  expect_gte(length(rows), 1L)
  first <- rows[[1]]
  expect_identical(first$register, "OVOS")
  expect_match(first$id, "^[0-9]+$")
  expect_true(nzchar(first$title))
  expect_true(nzchar(first$proponent))
})

test_that("bg_parse_index_rows extracts every row from a real EO listing page", {
  rows <- planscanR:::bg_parse_index_rows(.bg_fix_eo_listing, "EO")
  expect_gte(length(rows), 1L)
  first <- rows[[1]]
  expect_identical(first$register, "EO")
  expect_match(first$id, "^[0-9]+$")
})

test_that("bg_extract_id pulls the lot id from a portal href", {
  expect_identical(
    planscanR:::bg_extract_id("/ovos/lot/21617", "OVOS"),
    "21617"
  )
  expect_identical(
    planscanR:::bg_extract_id("eo/lot/44841", "EO"),
    "44841"
  )
  expect_true(is.na(planscanR:::bg_extract_id("/something/else", "OVOS")))
  expect_true(is.na(planscanR:::bg_extract_id("ovos/lot/", "OVOS")))
})

test_that("bg_section_slug auto-slugs Bulgarian row labels via transliteration", {
  expect_identical(planscanR:::bg_section_slug("Уведомление"), "uvedomlenie")
  expect_identical(planscanR:::bg_section_slug("Описание"), "opisanie")
  expect_identical(planscanR:::bg_section_slug("Писмо"), "pismo")
  # Edge cases.
  expect_identical(planscanR:::bg_section_slug(NULL), "document")
  expect_identical(planscanR:::bg_section_slug(NA_character_), "document")
  expect_identical(planscanR:::bg_section_slug(""), "document")
})

test_that("bg_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::bg_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::bg_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::bg_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::bg_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::bg_normalise_assessment_type("sea"), "SEA")
  expect_error(planscanR:::bg_normalise_assessment_type("nope"))
})

test_that("bg_parse_dmy extracts DD.MM.YYYY dates", {
  expect_identical(planscanR:::parse_dmy("15.02.2017"), as.Date("2017-02-15"))
  expect_identical(
    planscanR:::parse_dmy("дата: 11.07.2017 г."),
    as.Date("2017-07-11")
  )
  expect_true(is.na(planscanR:::parse_dmy("")))
  expect_true(is.na(planscanR:::parse_dmy(NULL)))
  expect_true(is.na(planscanR:::parse_dmy("no date")))
})

test_that("bg_parse_detail extracts expected OVOS (EIA) fields and attachments", {
  url <- planscanR:::bg_canonical_url("OVOS", "21617")
  rec <- planscanR:::bg_parse_detail(url, .bg_entry_ovos_21617, .bg_fix_ovos_detail)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "bg")
  expect_identical(rec$source_portal, "registers.moew.government.bg")
  expect_identical(rec$document_id, "OVOS-21617")
  expect_identical(rec$url, url)
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "OVOS")
  # title is the investment-proposal name (long Cyrillic string).
  expect_match(rec$title, "Изграждане")
  # proponent comes from the Възложител section.
  expect_match(rec$proponent, "РАЗЛОГ")
  expect_match(rec$competent_authority, "РИОСВ")
  expect_match(rec$native_type, "процедура")
  expect_identical(rec$date_published, as.Date("2017-02-15"))
  expect_identical(rec$date_decision, as.Date("2017-07-11"))
  expect_match(rec$jurisdiction, "Благоевград")
  expect_match(rec$jurisdiction, "Разлог")
  expect_match(rec$dossier_number, "ОВОС")
  # No summary field on this portal.
  expect_true(is.na(rec$summary))
  # Multiple inline documents grouped under several row-label slugs.
  urls <- rec$attachment_urls[[1]]
  expect_gte(length(urls), 3L)
  expect_true(all(grepl("^https?://", urls)))
  expect_true(all(grepl("/ovos/file\\?fileKey=", urls)))
  # fileName is preserved verbatim (required by the server).
  expect_true(all(grepl("fileName=", urls)))
  expect_true("attachment_urls_uvedomlenie" %in% names(rec))
  # No geometry columns are ever emitted for BG.
  expect_false("geometry_path" %in% names(rec))
  expect_false("geometry_crs" %in% names(rec))
})

test_that("bg_parse_detail extracts expected EO (SEA) fields", {
  url <- planscanR:::bg_canonical_url("EO", "44841")
  rec <- planscanR:::bg_parse_detail(url, .bg_entry_eo_44841, .bg_fix_eo_detail)

  expect_identical(rec$register, "EO")
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$document_id, "EO-44841")
  # title is the plan/programme name, disambiguated from proponent via section.
  expect_match(rec$title, "Общ устройствен план")
  expect_match(rec$proponent, "Благоевград")
  expect_match(rec$competent_authority, "РИОСВ")
  expect_identical(rec$date_published, as.Date("2023-07-10"))
  expect_match(rec$dossier_number, "ЕО")
  urls <- rec$attachment_urls[[1]]
  expect_gte(length(urls), 2L)
  expect_true(all(grepl("/eo/file\\?fileKey=", urls)))
})

test_that("bg_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2017-02-15"))
  expect_true(planscanR:::bg_record_matches(rec, NULL))
  expect_true(planscanR:::bg_record_matches(
    rec,
    as.Date(c("2017-01-01", "2017-12-31"))
  ))
  expect_false(planscanR:::bg_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

test_that("get_assessments_bg end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = bg_mock_perform_html_two_records(),
      bg_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "OVOS") {
            list(.bg_entry_ovos_21617)
          } else {
            list(.bg_entry_eo_44841)
          }
        }
      }
    )

    res <- get_assessments_bg(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("OVOS-21617", "EO-44841"))
    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "bg"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT re-invoke bg_parse_detail.
    parse_calls <- 0L
    local_mocked_bindings(
      bg_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("bg_parse_detail should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_bg(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c("OVOS-21617", "EO-44841"))
  })
})

test_that("get_assessments_bg honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = bg_mock_perform_html_two_records(),
      bg_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "OVOS") {
            list(.bg_entry_ovos_21617)
          } else {
            list(.bg_entry_eo_44841)
          }
        }
      }
    )

    # EIA-only -> only the OVOS record.
    res_eia <- get_assessments_bg(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res_eia), 1L)
    expect_identical(res_eia$document_id, "OVOS-21617")

    # SEA-only -> only the EO record.
    res_sea <- get_assessments_bg(assessment_type = "SEA", limit = 5, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$document_id, "EO-44841")
  })
})

test_that("get_assessments_bg respects date_range filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = bg_mock_perform_html_two_records(),
      bg_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "OVOS") {
            list(.bg_entry_ovos_21617)
          } else {
            list(.bg_entry_eo_44841)
          }
        }
      }
    )

    # Only the 2017 OVOS record falls in this window.
    res <- get_assessments_bg(
      date_range = c("2017-01-01", "2017-12-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "OVOS-21617")
  })
})

test_that("BG -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = bg_mock_perform_html_two_records(),
      bg_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "OVOS") {
            list(.bg_entry_ovos_21617)
          } else {
            list(.bg_entry_eo_44841)
          }
        }
      }
    )

    res <- get_assessments_bg(limit = 5, download = FALSE)
    idx <- index_cache(country = "bg")
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c("OVOS-21617", "EO-44841"))

    # Country-specific scalars round-trip through extras{}.
    expect_true("register" %in% names(idx))
    expect_true("assessment_type" %in% names(idx))
    expect_true("dossier_number" %in% names(idx))
    expect_setequal(idx$register, c("OVOS", "EO"))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
    # Per-section attachment URL columns survive too.
    expect_true(any(grepl("^attachment_urls_", names(idx))))
  })
})

test_that("get_assessments_bg scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = bg_mock_perform_html_two_records(),
      bg_fetch_search = function(register, ...) {
        # Page generator: yield the one canned entry once, then signal exhausted.
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "OVOS") {
            list(.bg_entry_ovos_21617)
          } else {
            list(.bg_entry_eo_44841)
          }
        }
      }
    )

    res <- get_assessments_bg(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "wind energy", plan = "устройствен план"),
      relevance_model = make_fake_model(languages = c("bg", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_plan" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('bg') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("bg", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "bg")
    expect_identical(res$source_portal, "registers.moew.government.bg")
    expect_true(grepl(
      "^https://registers\\.moew\\.government\\.bg/(ovos|eo)/lot/",
      res$url
    ))
  })
})
