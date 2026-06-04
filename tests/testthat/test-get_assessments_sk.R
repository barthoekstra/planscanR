# Tests for get_assessments_sk(). Offline strategy: stub the list-page fetch
# (sk_fetch_search) and the per-record detail fetch (sk_fetch_detail) so no live
# HTTP is needed in CI. The fixtures cover the enviroportal.sk API Platform
# shapes:
#  - list_p1.json:         the `?page=1` payload with the array-of-arrays
#                          `hydra:member` (a 3-record bucket, a pagination
#                          metadata object, and an empty bucket); records mix
#                          SEA + EIA via the `zbierka` law string.
#  - detail_with_docs.json: one full detail record (seoId "usadlost", EIA) whose
#                          `dokumenty$data` carries PDFs under step "Zámer".

read_sk_json <- function(name) {
  jsonlite::fromJSON(fixture_path("sk", name), simplifyVector = FALSE)
}

.sk_list_p1 <- read_sk_json("list_p1.json")
.sk_detail <- read_sk_json("detail_with_docs.json")

# The record bucket inside hydra:member (bucket 0 of the array-of-arrays).
.sk_records <- .sk_list_p1[["hydra:member"]][[1]]

# -- array-of-arrays flatten -------------------------------------------------

test_that("sk_flatten_members flattens array-of-arrays and keeps only records", {
  member <- .sk_list_p1[["hydra:member"]]
  flat <- planscanR:::sk_flatten_members(member)
  # 3 record objects, the pagination-metadata object dropped, empty bucket gone.
  expect_length(flat, 3L)
  expect_true(all(vapply(flat, function(x) !is.null(x[["seoId"]]), logical(1))))
  # A bare record object (not wrapped in a bucket) flattens too.
  expect_length(planscanR:::sk_flatten_members(list(.sk_records[[1]])), 1L)
  # Empty / NULL inputs are safe.
  expect_length(planscanR:::sk_flatten_members(list()), 0L)
  expect_length(planscanR:::sk_flatten_members(NULL), 0L)
})

# -- date / type derivation --------------------------------------------------

test_that("sk_parse_date extracts the date part of the Slovak datetime", {
  expect_identical(planscanR:::sk_parse_date("2026-06-04 13:51:58"), as.Date("2026-06-04"))
  expect_identical(planscanR:::sk_parse_date("2021-01-02"), as.Date("2021-01-02"))
  expect_true(is.na(planscanR:::sk_parse_date(NULL)))
  expect_true(is.na(planscanR:::sk_parse_date(NA_character_)))
  expect_true(is.na(planscanR:::sk_parse_date("")))
  expect_true(is.na(planscanR:::sk_parse_date("not a date")))
})

test_that("sk_assessment_type_of derives EIA/SEA from the zbierka law string", {
  expect_identical(planscanR:::sk_assessment_type_of("24/2006 novela 269/2025 Z.z. časť EIA"), "EIA")
  expect_identical(planscanR:::sk_assessment_type_of("24/2006 novela 350/2024 Z.z. časť SEA"), "SEA")
  expect_true(is.na(planscanR:::sk_assessment_type_of(NULL)))
  expect_true(is.na(planscanR:::sk_assessment_type_of("")))
  expect_true(is.na(planscanR:::sk_assessment_type_of("nejaký iný zákon")))
})

test_that("sk_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::sk_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::sk_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::sk_normalise_assessment_type("eia"), "EIA")
  expect_identical(planscanR:::sk_normalise_assessment_type("SEA"), "SEA")
  expect_error(planscanR:::sk_normalise_assessment_type("nope"))
})

# -- record parsing ----------------------------------------------------------

test_that("sk_build_record parses a SEA list record's fields and extras", {
  sea <- Find(function(r) grepl("SEA", r$zbierka), .sk_records)
  expect_false(is.null(sea))
  url <- planscanR:::sk_canonical_url(sea$seoId)
  rec <- planscanR:::sk_build_record(url, sea)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "sk")
  expect_identical(rec$source_portal, "enviroportal.sk")
  expect_match(rec$document_id, "^SK-")
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$register, "eia_projects")
  expect_match(rec$url, "^https://www\\.enviroportal\\.sk/eia/detail/")
  expect_true(nzchar(rec$title))
  expect_match(rec$law_collection, "SEA")
})

test_that("sk_build_record parses an EIA detail record (proponent, authority, docs)", {
  url <- planscanR:::sk_canonical_url(.sk_detail$seoId)
  rec <- planscanR:::sk_build_record(url, .sk_detail)

  expect_identical(rec$assessment_type, "EIA")
  expect_match(rec$law_collection, "EIA")
  expect_match(rec$title, "Usadlos")
  expect_match(rec$proponent, "Katar")
  # Leading-space padding on the authority name is trimmed.
  expect_identical(rec$competent_authority, "Okresný úrad Myjava")
  expect_match(rec$summary, "usadlost")
  expect_identical(rec$status, "Zámer")
  expect_identical(rec$process, "Zisťovacie konanie")
  expect_match(rec$region, "Tren")
  expect_match(rec$district, "Myjava")
  expect_match(rec$municipality, "Jablonka")
  expect_s3_class(rec$date_published, "Date")
  expect_true(is.na(rec$date_decision))
})

test_that("sk dokumenty parse yields absolute /eia/dokument urls grouped by step", {
  per_section <- planscanR:::sk_parse_documents(.sk_detail$dokumenty)
  expect_true(is.list(per_section))
  all_urls <- unique(unlist(per_section, use.names = FALSE))
  expect_true("https://www.enviroportal.sk/eia/dokument/403635" %in% all_urls)
  expect_true("https://www.enviroportal.sk/eia/dokument/403634" %in% all_urls)
  # Grouped under the "Zámer" step (transliterated slug).
  slug <- planscanR:::sk_section_slug("Zámer")
  expect_identical(slug, "zamer")
  expect_true(slug %in% names(per_section))

  # The per-step section columns land on the record.
  url <- planscanR:::sk_canonical_url(.sk_detail$seoId)
  rec <- planscanR:::sk_build_record(url, .sk_detail)
  expect_true(paste0("attachment_urls_", slug) %in% names(rec))
  expect_true(all(all_urls %in% rec$attachment_urls[[1]]))

  # An empty / missing dokumenty yields no sections (valid).
  expect_length(planscanR:::sk_parse_documents(NULL), 0L)
  expect_length(
    planscanR:::sk_parse_documents(list(available = list(status = FALSE), data = list())),
    0L
  )
})

# -- filters -----------------------------------------------------------------

test_that("sk_record_matches honours assessment_type / query / date_range", {
  rec <- tibble::tibble(
    title = "NOVOSTAVBA SKLADOVEJ HALY",
    assessment_type = "EIA",
    date_published = as.Date("2026-06-04")
  )
  expect_true(planscanR:::sk_record_matches(rec, "All", NULL, NULL))
  # assessment_type
  expect_true(planscanR:::sk_record_matches(rec, "EIA", NULL, NULL))
  expect_false(planscanR:::sk_record_matches(rec, "SEA", NULL, NULL))
  # query (case-insensitive substring)
  expect_true(planscanR:::sk_record_matches(rec, "All", "skladov", NULL))
  expect_false(planscanR:::sk_record_matches(rec, "All", "nemocnica", NULL))
  # date_range
  expect_true(planscanR:::sk_record_matches(rec, "All", NULL, as.Date(c("2026-01-01", "2026-12-31"))))
  expect_false(planscanR:::sk_record_matches(rec, "All", NULL, as.Date(c("2020-01-01", "2020-12-31"))))
})

# -- end-to-end on fixtures (mocked network seams) ---------------------------

# A reusable mock pair: the list-page generator yields the fixture records once;
# the detail fetch returns the matching record object (the detail fixture for
# "usadlost", else the list summary).
sk_mock_bindings <- function() {
  list(
    sk_fetch_search = function() {
      emitted <- FALSE
      function() {
        if (emitted) {
          return(NULL)
        }
        emitted <<- TRUE
        planscanR:::sk_map_entries(.sk_records)
      }
    },
    sk_fetch_detail = function(seo_id) {
      if (identical(seo_id, .sk_detail$seoId)) {
        return(.sk_detail)
      }
      # Echo the matching list summary as the "detail" for other records.
      Find(function(r) identical(r$seoId, seo_id), .sk_records)
    }
  )
}

test_that("get_assessments_sk end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- sk_mock_bindings()
    local_mocked_bindings(
      sk_fetch_search = mb$sk_fetch_search,
      sk_fetch_detail = mb$sk_fetch_detail
    )

    res <- get_assessments_sk(limit = 10, download = FALSE)
    expect_identical(nrow(res), 3L)
    planscanR:::validate_result_schema(res)
    expect_true(all(grepl("^SK-", res$document_id)))
    expect_setequal(res$assessment_type, c("EIA", "SEA"))

    # Sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "sk"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 3L)

    # Second call with refresh = FALSE must NOT re-fetch detail.
    local_mocked_bindings(
      sk_fetch_detail = function(...) {
        stop("sk_fetch_detail should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_sk(limit = 10, download = FALSE)
    expect_identical(nrow(res2), 3L)
  })
})

test_that("get_assessments_sk honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- sk_mock_bindings()
    local_mocked_bindings(
      sk_fetch_search = mb$sk_fetch_search,
      sk_fetch_detail = mb$sk_fetch_detail
    )

    res_sea <- get_assessments_sk(assessment_type = "SEA", limit = 10, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$assessment_type, "SEA")

    res_eia <- get_assessments_sk(assessment_type = "EIA", limit = 10, download = FALSE)
    expect_identical(nrow(res_eia), 2L)
    expect_true(all(res_eia$assessment_type == "EIA"))
  })
})

test_that("get_assessments_sk honours query, date_range and limit", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- sk_mock_bindings()
    local_mocked_bindings(
      sk_fetch_search = mb$sk_fetch_search,
      sk_fetch_detail = mb$sk_fetch_detail
    )

    # query: only the skladová hala EIA record matches "skladov".
    res_q <- get_assessments_sk(query = "skladov", download = FALSE)
    expect_identical(nrow(res_q), 1L)
    expect_match(res_q$title, "SKLADOV")

    # query negative.
    res_qn <- get_assessments_sk(query = "zzz-nemozne", download = FALSE)
    expect_identical(nrow(res_qn), 0L)

    # date_range: nothing in 2010.
    res_dr <- get_assessments_sk(
      date_range = c("2010-01-01", "2010-12-31"),
      download = FALSE
    )
    expect_identical(nrow(res_dr), 0L)

    # limit caps the total.
    res_lim <- get_assessments_sk(limit = 1, download = FALSE)
    expect_identical(nrow(res_lim), 1L)
  })
})

test_that("SK -> sidecar round-trip preserves country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- sk_mock_bindings()
    local_mocked_bindings(
      sk_fetch_search = mb$sk_fetch_search,
      sk_fetch_detail = mb$sk_fetch_detail
    )

    res <- get_assessments_sk(limit = 10, download = FALSE)
    idx <- index_cache(country = "sk")
    expect_identical(nrow(idx), 3L)

    expect_true(all(
      c(
        "assessment_type",
        "register",
        "law_collection",
        "process",
        "region",
        "district",
        "municipality"
      ) %in%
        names(idx)
    ))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
    expect_setequal(idx$register, "eia_projects")
    expect_true(any(grepl("EIA", idx$law_collection)))
    expect_true(any(grepl("SEA", idx$law_collection)))
  })
})

test_that("get_assessments_sk scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- sk_mock_bindings()
    local_mocked_bindings(
      sk_fetch_search = mb$sk_fetch_search,
      sk_fetch_detail = mb$sk_fetch_detail
    )

    res <- get_assessments_sk(
      limit = 10,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(industry = "skladová hala", plan = "program rozvoja"),
      relevance_model = make_fake_model(languages = c("sk", "en"))
    )
    expect_identical(nrow(res), 3L)
    expect_true("relevance_score_industry" %in% names(res))
    expect_true("relevance_score_plan" %in% names(res))
    expect_true(is.numeric(res$relevance_score_industry))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('sk') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("sk", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "sk")
    expect_identical(res$source_portal, "enviroportal.sk")
    expect_true(grepl("^https://www\\.enviroportal\\.sk", res$url))
  })
})
