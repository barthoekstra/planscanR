# Offline tests for the "eib" explicit source (perform_json mocked).
.eib_list <- jsonlite::fromJSON(fixture_path("eib", "list.json"), simplifyVector = FALSE)
.eib_item <- jsonlite::fromJSON(fixture_path("eib", "item_246230771.json"), simplifyVector = FALSE)

eib_mock <- function(list_payload = .eib_list, calls = NULL) {
  function(req) {
    if (!is.null(calls)) {
      calls$urls <- c(calls$urls, req$url)
    }
    if (grepl("registers/list", req$url)) {
      return(list_payload)
    }
    if (grepl("registers/item/246230771$", req$url)) {
      return(.eib_item)
    }
    list(data = NULL)
  }
}

eib_get <- function(..., country = "de") {
  suppressWarnings(get_assessments(country, source = "eib", ...))
}

test_that("source is registered but not a national country", {
  expect_true("eib" %in% get_assessments_sources()$source)
  expect_false("eib" %in% supported_countries())
})

test_that("country filter keeps tagged rows, drops regional and untagged ones, warns on a count gap", {
  local_mocked_bindings(perform_json = eib_mock())
  with_temp_cache({
    expect_warning(
      res <- get_assessments("de", source = "eib", write_sidecar = FALSE),
      class = "planscanR_warning_partial"
    )
    expect_length(res$document_id, 3L)
    expect_false(any(c("eib_900000001", "eib_900000002") %in% res$document_id))
    expect_true("eib_246230771" %in% res$document_id)
    # multi-country row (DE+IT) is kept for DE with its complete tag list
    multi <- res[res$country_codes == "DE; IT", ]
    expect_identical(nrow(multi), 1L)
    # and also found for IT
    it <- eib_get(country = "it", write_sidecar = FALSE)
    expect_identical(it$country, rep("it", nrow(it)))
    expect_identical(nrow(it), 1L)
  })
})

test_that("a count mismatch warning names both numbers; equal counts do not warn", {
  local_mocked_bindings(perform_json = eib_mock())
  expect_warning(
    get_assessments("de", source = "eib", write_sidecar = FALSE),
    "5 rows.*totalItems = 7"
  )
  ok <- .eib_list
  ok$totalItems <- 5L
  local_mocked_bindings(perform_json = eib_mock(ok))
  expect_no_warning(get_assessments("de", source = "eib", write_sidecar = FALSE))
})

test_that("parsed record keeps native metadata, role, sections and extras", {
  local_mocked_bindings(perform_json = eib_mock())
  res <- eib_get(write_sidecar = FALSE)
  r <- res[res$document_id == "eib_246230771", ]
  expect_identical(r$source_portal, "eib.org/registers")
  expect_identical(r$url, "https://www.eib.org/en/registers/all/246230771")
  expect_identical(r$attachment_urls[[1]], "https://www.eib.org/attachments/registers/246230771.pdf")
  expect_identical(r$role, "Environmental and Social Impact Assessment (ESIA)")
  expect_identical(r$document_type_id, "ESIA")
  expect_identical(r$project_number, "20230138")
  expect_identical(r$language, "German")
  expect_identical(r$title, "BORKUM RIFFGRUND 3 OFFSHORE WIND FARM - UVP-Bericht")
  expect_identical(r$date_published, as.Date("2025-12-08"))
  expect_identical(r$sectors, "Energy")
  expect_identical(r$availability, "Publicly available")
  expect_true(r$detail_fetched)
  expect_identical(
    r$attachment_urls_environmental_and_social_impact_assessment_esia[[1]],
    r$attachment_urls[[1]]
  )
  # a row whose detail fails keeps listing metadata, flagged as such
  other <- res[res$document_id == "eib_900000003", ]
  expect_false(other$detail_fetched)
  expect_identical(other$project_number, "20230138")
})

test_that("document_type filter has positive and negative cases", {
  local_mocked_bindings(perform_json = eib_mock())
  esia <- eib_get(document_type = "esia", write_sidecar = FALSE)
  expect_true(all(grepl("(ESIA)", esia$native_type, fixed = TRUE)))
  expect_gt(nrow(esia), 0L)
  esds <- eib_get(document_type = "ESDS", write_sidecar = FALSE)
  expect_identical(nrow(esds), 1L)
  expect_identical(
    nrow(eib_get(document_type = "NTS", write_sidecar = FALSE)),
    0L
  )
  expect_identical(
    eib_get(document_type = "NTS", write_sidecar = FALSE),
    empty_result_tibble()
  )
})

test_that("date_range filters date_published; empty listing is typed empty", {
  local_mocked_bindings(perform_json = eib_mock())
  expect_identical(
    nrow(eib_get(date_range = c("2025-01-01", "2025-12-31"), write_sidecar = FALSE)),
    2L # Borkum + the cloned link row share a start date
  )
  expect_identical(
    nrow(eib_get(date_range = c("2001-01-01", "2001-12-31"), write_sidecar = FALSE)),
    0L
  )
  local_mocked_bindings(perform_json = eib_mock(list(data = list(), totalItems = 0L)))
  expect_identical(get_assessments("de", source = "eib"), empty_result_tibble())
})

test_that("limit is honoured and the listing is requested once with the upper-case code", {
  calls <- new.env()
  local_mocked_bindings(perform_json = eib_mock(calls = calls))
  res <- eib_get(limit = 1, write_sidecar = FALSE)
  expect_identical(nrow(res), 1L)
  expect_identical(sum(grepl("registers/list", calls$urls)), 1L)
  expect_match(calls$urls[1], "countries=DE")
})

test_that("download records oversized files, sidecar round-trips, warm run does not refetch", {
  local_mocked_bindings(perform_json = eib_mock())
  n_dl <- 0L
  local_mocked_bindings(
    download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
      n_dl <<- n_dl + 1L
      tibble::tibble(
        url = urls,
        local_path = NA_character_,
        status = "skipped_size",
        size_bytes = 107e6,
        sha256 = NA_character_,
        reason = "over cap"
      )
    }
  )
  with_temp_cache({
    res <- eib_get(download = TRUE, document_type = "ESIA", limit = 1)
    expect_identical(res$download_status[[1]]$status, "skipped_size")
    expect_identical(res$attachment_urls[[1]], "https://www.eib.org/attachments/registers/246230771.pdf")
    back <- index_cache(country = "de")
    expect_true("eib_246230771" %in% back$document_id)
    expect_true("project_number" %in% names(back))
    expect_true("attachment_urls_environmental_and_social_impact_assessment_esia" %in% names(back))
    # warm rerun: no detail request for a cached record
    calls <- new.env()
    local_mocked_bindings(perform_json = eib_mock(calls = calls))
    again <- eib_get(download = TRUE, document_type = "ESIA", limit = 1)
    expect_false(any(grepl("registers/item", calls$urls)))
    expect_identical(again$document_id, res$document_id)
    expect_identical(again$project_number, "20230138")
  })
})

test_that("relevance scoring uses the shared helpers", {
  local_mocked_bindings(perform_json = eib_mock())
  res <- eib_get(
    write_sidecar = FALSE,
    topic = c(wind = "offshore wind farm"),
    relevance_model = make_fake_model()
  )
  expect_true("relevance_score_wind" %in% names(res))
  s <- res$relevance_score_wind[res$document_id == "eib_246230771"]
  expect_gt(s, max(res$relevance_score_wind[res$document_id != "eib_246230771"]))
})

test_that("a failing detail call warns and keeps the listing metadata", {
  local_mocked_bindings(perform_json = function(req) {
    if (grepl("registers/list", req$url)) .eib_list else stop("boom")
  })
  w <- testthat::capture_warnings(
    res <- get_assessments("de", source = "eib", write_sidecar = FALSE, limit = 1)
  )
  expect_true(any(grepl("detail failed", w)))
  expect_false(res$detail_fetched)
})
