# Tests for get_assessments_nl().
#
# These tests parse the detail page via the local fixture, so they do not
# require network access. The live integration test is at the bottom and is
# skipped on CI / offline-mode.

read_fixture_html <- function(name) {
  rvest::read_html(fixture_path("nl", name))
}

test_that("nl_parse_detail extracts expected fields from a real detail page", {
  # Stub out req_planscanr/perform_html so nl_parse_detail uses the fixture.
  local_mocked_bindings(
    perform_html = function(req) {
      read_fixture_html("advice-detail-aromaten-delfzijl.html")
    },
    req_planscanr = function(base_url, path = NULL) base_url
  )
  rec <- planscanR:::nl_parse_detail(
    "https://www.commissiemer.nl/advies/fabriek-voor-de-productie-van-aromaten-uit-niet-herbruikbaar-afvalplastic-in-delfzijl/"
  )
  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "nl")
  expect_identical(rec$source_portal, "commissiemer.nl")
  expect_identical(rec$document_id, "3619")
  expect_match(rec$title, "Fabriek voor de productie van aromaten")
  expect_match(rec$summary, "^Plastics Conversion Plant")
  expect_identical(rec$competent_authority, "Provincie Groningen")
  expect_identical(rec$proponent, "Plastics Conversion Plant B.V.")
  expect_identical(rec$date_decision, as.Date("2026-05-26"))
  expect_gt(length(rec$attachment_urls[[1]]), 10L)
  expect_true(all(grepl("\\.pdf$", rec$attachment_urls[[1]])))

  # Section-scoped attachment columns
  src <- rec$attachment_urls_source[[1]]
  adv <- rec$attachment_urls_advice[[1]]
  expect_true(length(src) > length(adv))
  expect_identical(length(src), 40L)
  expect_identical(length(adv), 7L)
  expect_length(intersect(src, adv), 0L)
  # Union (deduped) equals attachment_urls
  expect_setequal(rec$attachment_urls[[1]], unique(c(src, adv)))
  # local_path_* parallel columns initialised empty when download=FALSE
  expect_identical(rec$local_path_source[[1]], character(0))
  expect_identical(rec$local_path_advice[[1]], character(0))
})

test_that("nl_section_pdfs returns empty character() for a missing section", {
  html <- read_fixture_html("advice-detail-aromaten-delfzijl.html")
  expect_identical(
    planscanR:::nl_section_pdfs(html, "Een sectie die niet bestaat"),
    character(0)
  )
})

test_that("nl_section_pdfs scopes link extraction to the named section", {
  html <- read_fixture_html("advice-detail-aromaten-delfzijl.html")
  src <- planscanR:::nl_section_pdfs(html, "Documenten waarop het advies is gebaseerd")
  adv <- planscanR:::nl_section_pdfs(html, "Adviezen en persberichten")
  expect_length(src, 40L)
  expect_length(adv, 7L)
  expect_length(intersect(src, adv), 0L)
})

test_that("nl_extract_project_id falls back to wp postid when no PDFs", {
  html <- read_fixture_html("advice-detail-aromaten-delfzijl.html")
  expect_identical(
    planscanR:::nl_extract_project_id(character(0), html),
    "wp-5795"
  )
})

test_that("nl_record_matches honours filters", {
  rec <- tibble::tibble(
    title = "Windpark Foo",
    url = "https://www.commissiemer.nl/advies/windpark-foo/",
    date_decision = as.Date("2024-06-15"),
    competent_authority = "Provincie Groningen"
  )
  # query
  expect_true(planscanR:::nl_record_matches(rec, "wind", NULL, NULL))
  expect_false(planscanR:::nl_record_matches(rec, "solar", NULL, NULL))
  # date range
  expect_true(planscanR:::nl_record_matches(rec, NULL, as.Date(c("2024-01-01", "2024-12-31")), NULL))
  expect_false(planscanR:::nl_record_matches(rec, NULL, as.Date(c("2023-01-01", "2023-12-31")), NULL))
  # province
  expect_true(planscanR:::nl_record_matches(rec, NULL, NULL, "Groningen"))
  expect_false(planscanR:::nl_record_matches(rec, NULL, NULL, "Limburg"))
})

test_that("nl_record_matches returns FALSE when date_decision is NA and a range is given", {
  rec <- tibble::tibble(
    title = "Foo",
    url = "https://example.org",
    date_decision = as.Date(NA),
    competent_authority = "X"
  )
  expect_false(planscanR:::nl_record_matches(rec, NULL, as.Date(c("2024-01-01", "2024-12-31")), NULL))
})

test_that("validate_facet_arg rejects unknown values with classed error", {
  expect_error(
    planscanR:::validate_facet_arg("not_real", c("a", "b"), "theme"),
    class = "planscanR_error_bad_input"
  )
  expect_invisible(planscanR:::validate_facet_arg(NULL, c("a", "b"), "theme"))
  expect_invisible(planscanR:::validate_facet_arg("a", c("a", "b"), "theme"))
})

test_that("get_assessments_nl warns when unsupported facets are passed", {
  withr::local_options(planscanR.nl_facet_warned = NULL)
  # Stub the URL enumeration + detail parsing so this stays offline.
  local_mocked_bindings(
    nl_advice_urls = function() character(0)
  )
  expect_warning(
    get_assessments_nl(theme = "energie", limit = 0, download = FALSE),
    class = "planscanR_warning_partial"
  )
})

test_that("get_assessments_nl returns the empty result when no URLs match", {
  withr::local_options(planscanR.nl_facet_warned = TRUE)
  local_mocked_bindings(
    nl_advice_urls = function() character(0)
  )
  res <- get_assessments_nl(limit = 0, download = FALSE)
  expect_s3_class(res, "tbl_df")
  expect_identical(nrow(res), 0L)
  expect_true(all(planscanR:::required_columns() %in% names(res)))
})

test_that("sidecar-first: existing sidecars short-circuit detail-page fetches", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    # Pre-populate one sidecar for a URL we'll request.
    target_url <- "https://www.commissiemer.nl/advies/already-cached/"
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "commissiemer.nl",
      document_id = "9001",
      url = target_url,
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      attachment_urls_source = list(character(0)),
      attachment_urls_advice = list(character(0)),
      local_path = list(character(0)),
      local_path_source = list(character(0)),
      local_path_advice = list(character(0)),
      title = "Cached advice",
      summary = "wind energy planning",
      competent_authority = NA_character_,
      proponent = NA_character_,
      date_decision = as.Date(NA)
    )
    planscanR:::write_record_sidecar(rec)
    # Now run get_assessments_nl: nl_parse_detail must NOT be invoked.
    parse_calls <- 0L
    local_mocked_bindings(
      nl_advice_urls = function() target_url,
      nl_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("nl_parse_detail should not have been called when a sidecar exists")
      }
    )
    out <- get_assessments_nl(limit = 5, download = FALSE, write_sidecar = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(out$document_id, "9001")
    expect_identical(out$title, "Cached advice")
  })
})

test_that("refresh = TRUE forces a detail-page fetch even when a sidecar exists", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    target_url <- "https://www.commissiemer.nl/advies/refresh-test/"
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "commissiemer.nl",
      document_id = "9002",
      url = target_url,
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      attachment_urls_source = list(character(0)),
      attachment_urls_advice = list(character(0)),
      local_path = list(character(0)),
      local_path_source = list(character(0)),
      local_path_advice = list(character(0)),
      title = "Old (cached)",
      summary = "stale",
      competent_authority = NA_character_,
      proponent = NA_character_,
      date_decision = as.Date(NA)
    )
    planscanR:::write_record_sidecar(rec)
    parse_calls <- 0L
    local_mocked_bindings(
      nl_advice_urls = function() target_url,
      nl_parse_detail = function(url) {
        parse_calls <<- parse_calls + 1L
        rec$title <- "Fresh from network"
        rec
      }
    )
    out <- get_assessments_nl(limit = 5, download = FALSE, write_sidecar = FALSE, refresh = TRUE)
    expect_identical(parse_calls, 1L)
    expect_identical(out$title, "Fresh from network")
  })
})

test_that("sidecar merge: a new run on one topic preserves prior multi-topic scores", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    base <- tibble::tibble(
      country = "nl",
      source_portal = "commissiemer.nl",
      document_id = "9003",
      url = "https://www.commissiemer.nl/advies/merge-test/",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      attachment_urls_source = list(character(0)),
      attachment_urls_advice = list(character(0)),
      local_path = list(character(0)),
      local_path_source = list(character(0)),
      local_path_advice = list(character(0)),
      title = "x",
      summary = NA_character_,
      competent_authority = NA_character_,
      proponent = NA_character_,
      date_decision = as.Date(NA),
      relevance_model = "fake-bow"
    )
    # First write: two topic scores.
    rec1 <- base
    rec1$relevance_score_wind <- 0.7
    rec1$relevance_score_solar <- 0.4
    p <- planscanR:::write_record_sidecar(rec1)
    # Second write: only one of the two topics, with a different model.
    rec2 <- base
    rec2$relevance_score_wind <- 0.99 # overwrite
    rec2$relevance_model <- "other"
    planscanR:::write_record_sidecar(rec2)
    # Read back: wind reflects new value, solar reflects the preserved old one.
    back <- planscanR:::read_record_sidecar(p)
    expect_equal(back$relevance_score_wind, 0.99)
    expect_equal(back$relevance_score_solar, 0.4)
  })
})

test_that("sidecar_url_index reads only valid JSON sidecars", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    # No sidecars yet: empty index.
    idx <- planscanR:::sidecar_url_index("nl")
    expect_length(idx, 0L)
    # Plant a couple.
    for (i in 1:3) {
      rec <- tibble::tibble(
        country = "nl",
        source_portal = "commissiemer.nl",
        document_id = as.character(8000 + i),
        url = paste0("https://www.commissiemer.nl/advies/idx-", i, "/"),
        retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
        attachment_urls = list(character(0)),
        attachment_urls_source = list(character(0)),
        attachment_urls_advice = list(character(0)),
        local_path = list(character(0)),
        local_path_source = list(character(0)),
        local_path_advice = list(character(0)),
        title = paste("rec", i),
        summary = NA_character_,
        competent_authority = NA_character_,
        proponent = NA_character_,
        date_decision = as.Date(NA)
      )
      planscanR:::write_record_sidecar(rec)
    }
    idx <- planscanR:::sidecar_url_index("nl")
    expect_length(idx, 3L)
    expect_setequal(
      unname(idx),
      list.files(file.path(cache, "files", "nl"), pattern = "\\.meta\\.json$", recursive = TRUE, full.names = TRUE)
    )
    expect_true(all(grepl("^https://www\\.commissiemer\\.nl/advies/idx-", names(idx))))
  })
})

# -- Live integration test ---------------------------------------------------

test_that("get_assessments('nl') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("nl", limit = 2, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_true(all(nzchar(res$document_id)))
    expect_true(all(startsWith(res$url, "https://www.commissiemer.nl/advies/")))
  })
})
