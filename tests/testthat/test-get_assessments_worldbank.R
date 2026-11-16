# Offline tests for the World Bank WDS source. The seam is perform_json().

wb_page1 <- jsonlite::fromJSON(fixture_path("worldbank", "page1.json"), simplifyVector = FALSE)

wb_doc <- function(id, docdt = "2024-01-01T05:00:00Z") {
  list(id = as.character(id), docdt = docdt, docty = "Environmental Assessment", display_title = paste("Doc", id))
}
wb_payload <- function(ids, total, ...) {
  docs <- stats::setNames(lapply(ids, wb_doc, ...), if (length(ids)) paste0("D", ids) else NULL)
  docs$facets <- list()
  list(total = total, documents = docs)
}
# Serve scripted payloads (one per call; last repeats) and log each request URL.
mock_wb <- function(payloads, .env = parent.frame()) {
  calls <- new.env()
  calls$urls <- character(0)
  testthat::local_mocked_bindings(
    perform_json = function(req) {
      calls$urls <- c(calls$urls, req$url)
      p <- payloads[[min(length(calls$urls), length(payloads))]]
      if (inherits(p, "error")) {
        stop(p)
      }
      p
    },
    .env = .env
  )
  calls
}

test_that("registered source parses a WDS page into schema columns, extras and sections", {
  with_temp_cache({
    calls <- mock_wb(list(wb_page1))
    res <- get_assessments("ke", source = "worldbank")
    expect_identical(nrow(res), 3L)
    expect_identical(unique(res$country), "ke")
    expect_identical(res$document_id, c("worldbank_40080515", "worldbank_34302187", "worldbank_111"))
    r <- res[1, ]
    expect_identical(r$source_portal, "worldbank.org")
    expect_identical(r$url, "https://documents.worldbank.org/curated/en/099514301092640402")
    expect_identical(
      r$attachment_urls[[1]],
      "https://documents.worldbank.org/curated/en/099514301092640402/pdf/IDU-50b6.pdf"
    )
    expect_identical(r$attachment_urls_document[[1]], r$attachment_urls[[1]])
    expect_identical(r$date_published, as.Date("2025-12-31"))
    expect_identical(r$native_type, "Environmental and Social Assessment")
    expect_identical(r$majdocty, "Project Documents")
    expect_identical(r$projectid, "P156634")
    expect_identical(r$guid, "099514301092640402")
    expect_identical(r$txturl, "http://documents.worldbank.org/curated/en/099514301092640402/text/IDU-50b6.txt")
    expect_identical(r$sectr, "FY17 - Water, Sanitation and Waste Management; FY17 - Other")
    expect_identical(r$lndinstr, "Investment Project Financing")
    expect_identical(r$summary, "The development objective is to remove screenings.")
    expect_identical(r$native_id, "40080515")
    # multi-country raw strings are kept; missing fields become NA, no pdf -> no section
    expect_identical(res$count[2], "World,Kenya")
    expect_identical(res$countrycode[2], "1W,KE")
    expect_identical(res$attachment_urls[[3]], character(0))
    expect_length(res$attachment_urls_document[[3]], 0L)
    expect_true(is.na(res$projectid[3]))
    # request carries the server-side filters
    expect_match(calls$urls[1], "countrycode=KE", fixed = TRUE)
    expect_match(calls$urls[1], "docty_exact=Environmental%20Assessment%5E", fixed = TRUE)
    expect_match(calls$urls[1], "srt=docdt&order=desc", fixed = TRUE)
  })
})

test_that("a valid code with total 0 gives a typed empty result", {
  with_temp_cache({
    mock_wb(list(list(total = 0, documents = list(facets = list()))))
    expect_identical(get_assessments("xx", source = "worldbank"), empty_result_tibble())
  })
})

test_that("pagination spans pages, dedupes repeats and stops at total", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    calls <- mock_wb(list(
      wb_payload(c(1, 2), 5),
      wb_payload(c(2, 3), 5), # repeated id 2 (offset shifted)
      wb_payload(c(4, 5), 5)
    ))
    res <- get_assessments("ke", source = "worldbank", write_sidecar = FALSE)
    expect_identical(res$document_id, paste0("worldbank_", 1:5))
    expect_length(calls$urls, 3L)
    expect_match(calls$urls[2], "os=2", fixed = TRUE)
    expect_match(calls$urls[3], "os=4", fixed = TRUE)
  })
})

test_that("an all-duplicate page is skipped without ending the crawl", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    mock_wb(list(wb_payload(c(1, 2), 6), wb_payload(c(1, 2), 6), wb_payload(c(3, 4), 6), wb_payload(c(5, 6), 6)))
    res <- get_assessments("ke", source = "worldbank", write_sidecar = FALSE)
    expect_identical(res$document_id, paste0("worldbank_", 1:6))
  })
})

test_that("limit stops paging early", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    calls <- mock_wb(list(wb_payload(c(1, 2), 6), wb_payload(c(3, 4), 6)))
    res <- get_assessments("ke", source = "worldbank", limit = 2, write_sidecar = FALSE)
    expect_identical(nrow(res), 2L)
    expect_length(calls$urls, 1L)
  })
})

test_that("an empty page before total warns as partial", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    mock_wb(list(wb_payload(c(1, 2), 6), wb_payload(integer(0), 6)))
    expect_warning(
      res <- get_assessments("ke", source = "worldbank", write_sidecar = FALSE),
      class = "planscanR_warning_partial"
    )
    expect_identical(nrow(res), 2L)
  })
})

test_that("a mid-crawl failure warns as partial; a first-page failure errors", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    mock_wb(list(wb_payload(c(1, 2), 6), simpleError("boom")))
    expect_warning(
      res <- get_assessments("ke", source = "worldbank", write_sidecar = FALSE),
      class = "planscanR_warning_partial"
    )
    expect_identical(nrow(res), 2L)
    mock_wb(list(simpleError("boom")))
    expect_error(get_assessments("ke", source = "worldbank"), "World Bank")
  })
})

test_that("a total that keeps growing terminates finitely with a partial warning", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    n <- 0L
    testthat::local_mocked_bindings(perform_json = function(req) {
      n <<- n + 2L
      wb_payload(c(n - 1L, n), n + 2L)
    })
    expect_warning(
      res <- get_assessments("ke", source = "worldbank", write_sidecar = FALSE),
      class = "planscanR_warning_partial"
    )
    expect_lt(nrow(res), 20L)
  })
})

test_that("a shrinking total ends the crawl without a warning", {
  with_temp_cache({
    withr::local_options(planscanR.wb_page_size = 2L)
    mock_wb(list(wb_payload(c(1, 2), 6), wb_payload(c(3, 4), 4)))
    res <- get_assessments("ke", source = "worldbank", write_sidecar = FALSE)
    expect_identical(nrow(res), 4L)
  })
})

test_that("date_range is sent server-side and enforced client-side", {
  with_temp_cache({
    payload <- list(
      total = 3,
      documents = list(
        D1 = wb_doc(1, "2022-01-01T05:00:00Z"),
        D2 = wb_doc(2, "2020-06-01T04:00:00Z"), # outside, even if the server leaked it
        D3 = wb_doc(3, "2022-12-31T05:00:00Z")
      )
    )
    calls <- mock_wb(list(payload))
    res <- get_assessments(
      "ke",
      source = "worldbank",
      date_range = c("2021-01-01", "2022-12-31"),
      write_sidecar = FALSE
    )
    expect_identical(res$document_id, c("worldbank_1", "worldbank_3"))
    expect_match(calls$urls[1], "strdate=2021-01-01&enddate=2022-12-31", fixed = TRUE)
  })
})

test_that("query is forwarded as qterm only when given", {
  with_temp_cache({
    calls <- mock_wb(list(wb_payload(1, 1)))
    get_assessments("ke", source = "worldbank", query = "bridge", write_sidecar = FALSE)
    get_assessments("ke", source = "worldbank", write_sidecar = FALSE)
    expect_match(calls$urls[1], "qterm=bridge", fixed = TRUE)
    expect_false(grepl("qterm", calls$urls[2]))
  })
})

test_that("sidecar round trip keeps extras and sections; warm run does not re-download", {
  with_temp_cache({
    mock_wb(list(wb_page1))
    n_dl <- 0L
    testthat::local_mocked_bindings(
      download_attachments = function(urls, country, document_id, ...) {
        n_dl <<- n_dl + 1L
        pending_download_status(urls)
      }
    )
    res <- get_assessments("ke", source = "worldbank", download = TRUE)
    side <- read_record_sidecar(sidecar_path("ke", "worldbank_40080515", create = FALSE))
    expect_identical(side$projectid, "P156634")
    expect_identical(side$count, "Kenya")
    expect_identical(side$attachment_urls_document[[1]], res$attachment_urls_document[[1]])
    expect_identical(side$native_type, "Environmental and Social Assessment")
  })
})

test_that("relevance scoring runs through the shared helpers", {
  skip_if_not_installed("planscanR.screen")
  with_temp_cache({
    mock_wb(list(wb_page1))
    res <- get_assessments(
      "ke",
      source = "worldbank",
      topic = c(water = "water and sanitation"),
      relevance_model = make_fake_model(),
      write_sidecar = FALSE
    )
    expect_true(is.numeric(res$relevance_score_water))
  })
})

test_that("worldbank is an explicit source and not a supported country", {
  expect_true("worldbank" %in% get_assessments_sources()$source)
  expect_false("worldbank" %in% supported_countries())
})
