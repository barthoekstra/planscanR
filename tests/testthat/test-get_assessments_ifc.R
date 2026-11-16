# Offline tests for the "ifc" explicit source (perform_json / perform_html mocked).
.ifc_list <- jsonlite::fromJSON(fixture_path("ifc", "list.json"), simplifyVector = FALSE)
.ifc_html <- function(f) rvest::read_html(fixture_path("ifc", f))

# perform_json mock serving `.ifc_list` in top/skip slices; records bodies in `calls`.
ifc_json_mock <- function(payload = .ifc_list, calls = NULL) {
  function(req) {
    body <- req$body$data
    if (!is.null(calls)) {
      calls$bodies <- c(calls$bodies, list(body))
      calls$keys <- c(calls$keys, req$headers[["Ocp-Apim-Subscription-Key"]])
    }
    rows <- payload$value
    from <- body$skip + 1L
    to <- min(length(rows), body$skip + body$top)
    out <- payload
    out$value <- if (from <= length(rows)) rows[from:to] else list()
    out
  }
}

ifc_html_mock <- function(calls = NULL) {
  function(req) {
    if (!is.null(calls)) {
      calls$urls <- c(calls$urls, req$url)
    }
    f <- if (grepl("46568", req$url)) {
      "key_page.html"
    } else if (grepl("/49251/", req$url)) {
      "detail_49251.html"
    } else if (grepl("/50775/", req$url)) {
      "detail_empty.html"
    } else {
      "detail_notable.html"
    }
    .ifc_html(f)
  }
}

ifc_setup <- function(json = ifc_json_mock(), html = ifc_html_mock(), .env = parent.frame()) {
  ifc_state$key <- NULL
  local_mocked_bindings(perform_json = json, perform_html = html, .env = .env)
}

ifc_get <- function(..., country = "eg") {
  suppressWarnings(get_assessments(country, source = "ifc", ...))
}

test_that("source is registered but not a national country", {
  expect_true("ifc" %in% get_assessments_sources()$source)
  expect_false("ifc" %in% supported_countries())
})

test_that("geography: unmapped code errors, bad format errors, mapped country with no rows is typed empty", {
  with_temp_cache({
    ifc_setup()
    expect_error(get_assessments("nl", source = "ifc"), class = "planscanR_error_bad_input")
    expect_error(get_assessments("egypt", source = "ifc"), class = "planscanR_error_bad_input")
    ifc_setup(json = function(req) list(`@odata.count` = 0L, value = list()))
    expect_identical(get_assessments("in", source = "ifc"), empty_result_tibble())
  })
})

test_that("country table has no regional names, unique codes, quotes escaped in the filter", {
  nm <- ifc_country_names()
  expect_false(any(grepl("Region$|Subregion$", nm)))
  expect_false(anyDuplicated(names(nm)) > 0L)
  expect_true(all(grepl("^[a-z]{2}$", names(nm))))
  with_temp_cache({
    calls <- new.env()
    ifc_setup(json = ifc_json_mock(list(`@odata.count` = 0L, value = list()), calls))
    get_assessments("ci", source = "ifc")
    expect_match(
      calls$bodies[[1]]$filter,
      "Project_Type eq 'ESRS' and Country_Description eq 'Cote D''Ivoire'",
      fixed = FALSE
    )
  })
})

test_that("records keep native metadata, summary, extras, documents and one section", {
  with_temp_cache({
    ifc_setup()
    res <- ifc_get(write_sidecar = FALSE)
    expect_identical(nrow(res), 3L)
    expect_identical(unique(res$country), "eg")
    r <- res[res$document_id == "ifc_49251", ]
    expect_identical(r$source_portal, "disclosures.ifc.org")
    expect_identical(r$url, "https://disclosures.ifc.org/project-detail/ESRS/49251/aysha-wind-power")
    expect_identical(r$title, "Aysha Wind Power")
    expect_identical(r$date_published, as.Date("2026-06-10"))
    expect_identical(r$Country_Description, "Egypt, Arab Republic of")
    expect_identical(r$Project_Number, "49251")
    expect_match(r$summary, "Wind farm & grid", fixed = TRUE)
    expect_match(r$summary, "E&S review scope.", fixed = TRUE)
    expect_identical(length(r$attachment_urls[[1]]), 2L)
    expect_identical(r$attachment_urls[[1]], r$attachment_urls_document[[1]])
    expect_match(r$attachment_urls[[1]][1], "^https://disclosuresservice\\.ifc\\.org/api/File/downloadfile\\?id=")
    docs <- jsonlite::fromJSON(r$documents_json, simplifyVector = FALSE)
    expect_length(docs, 2L)
    expect_identical(docs[[1]]$file_name, "ESIA - Aysha Wind Power Project-June 2026.pdf")
    expect_identical(docs[[1]]$role, docs[[1]]$file_name)
    expect_identical(jsonlite::fromJSON(r$listing_json)$Project_Number, "49251")
    expect_true(r$detail_fetched)
  })
})

test_that("pending project with an empty table is complete; a page without the table is not", {
  with_temp_cache({
    ifc_setup()
    w <- testthat::capture_warnings(res <- get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    pend <- res[res$document_id == "ifc_50775", ]
    expect_true(pend$detail_fetched)
    expect_length(pend$attachment_urls[[1]], 0L)
    bad <- res[res$document_id == "ifc_48684", ]
    expect_false(bad$detail_fetched)
    expect_true(any(grepl("48684", w) & grepl("documents table", w)))
  })
})

test_that("a failed detail is retried on a warm run; a complete one is served from the sidecar", {
  with_temp_cache({
    ifc_setup()
    first <- ifc_get()
    expect_false(first$detail_fetched[first$document_id == "ifc_48684"])
    calls <- new.env()
    ifc_setup(html = ifc_html_mock(calls))
    second <- ifc_get()
    expect_true(any(grepl("/48684/", calls$urls)))
    expect_false(any(grepl("/49251/", calls$urls)))
    expect_false(any(grepl("/50775/", calls$urls)))
    expect_identical(second$title[second$document_id == "ifc_49251"], "Aysha Wind Power")
    expect_identical(length(second$attachment_urls[second$document_id == "ifc_49251"][[1]]), 2L)
  })
})

test_that("a thrown detail error warns and keeps listing metadata", {
  with_temp_cache({
    ifc_setup(html = function(req) if (grepl("46568", req$url)) .ifc_html("key_page.html") else stop("boom"))
    w <- testthat::capture_warnings(res <- get_assessments("eg", source = "ifc", write_sidecar = FALSE, limit = 1))
    expect_true(any(grepl("boom", w)))
    expect_false(res$detail_fetched)
  })
})

test_that("key is read from a detail page once, sent as header, and a missing key errors", {
  with_temp_cache({
    calls <- new.env()
    hcalls <- new.env()
    ifc_setup(json = ifc_json_mock(calls = calls), html = ifc_html_mock(hcalls))
    options(planscanR.ifc_page_size = 1L)
    withr::defer(options(planscanR.ifc_page_size = NULL))
    ifc_get(write_sidecar = FALSE)
    expect_true(all(calls$keys == "testkey123"))
    expect_identical(sum(grepl("46568", hcalls$urls)), 1L)
    ifc_setup(html = function(req) .ifc_html("detail_notable.html"))
    expect_error(get_assessments("eg", source = "ifc"), class = "planscanR_error_bad_response")
  })
})

test_that("pagination: multiple pages, skip advances, limit shrinks page size", {
  with_temp_cache({
    calls <- new.env()
    ifc_setup(json = ifc_json_mock(calls = calls))
    withr::local_options(planscanR.ifc_page_size = 2L)
    w <- testthat::capture_warnings(res <- get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    expect_false(any(grepl("IFC listing|count", w)))
    expect_identical(sapply(calls$bodies, `[[`, "skip"), c(0L, 2L))
    expect_identical(calls$bodies[[1]]$orderby, "Project_Number asc")
    expect_identical(nrow(res), 3L)
    calls$bodies <- NULL
    res1 <- ifc_get(limit = 1, write_sidecar = FALSE)
    expect_identical(nrow(res1), 1L)
    expect_identical(calls$bodies[[1]]$top, 1L)
  })
})

test_that("short, failed, repeated, growing pages and malformed envelopes are not silent", {
  with_temp_cache({
    withr::local_options(planscanR.ifc_page_size = 2L)
    # listing ends early (empty page before the count)
    short <- .ifc_list
    short$`@odata.count` <- 5L
    ifc_setup(json = ifc_json_mock(short))
    w <- testthat::capture_warnings(get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    expect_true(any(grepl("3 of 5", w)))
    # repeated page
    ifc_setup(json = function(req) {
      out <- .ifc_list
      out$`@odata.count` <- 6L
      out
    })
    w <- testthat::capture_warnings(get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    expect_true(any(grepl("repeated", w)))
    # growing count
    n <- 0L
    ifc_setup(json = function(req) {
      n <<- n + 1L
      out <- ifc_json_mock()(req)
      out$`@odata.count` <- 3L + n
      out
    })
    w <- testthat::capture_warnings(get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    expect_true(any(grepl("count changed", w)))
    # page failure after the first
    k <- 0L
    ifc_setup(json = function(req) {
      k <<- k + 1L
      if (k > 1L) stop("503") else ifc_json_mock()(req)
    })
    w <- testthat::capture_warnings(res <- get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    expect_true(any(grepl("incomplete", w)))
    expect_identical(nrow(res), 2L)
    # first page failure and malformed envelope error
    ifc_setup(json = function(req) stop("503"))
    expect_error(get_assessments("eg", source = "ifc"), class = "planscanR_error_http")
    ifc_setup(json = function(req) list(message = "x"))
    expect_error(get_assessments("eg", source = "ifc"), class = "planscanR_error_bad_response")
    ifc_setup(json = function(req) list(`@odata.count` = 3L, value = "x"))
    expect_error(get_assessments("eg", source = "ifc"), class = "planscanR_error_bad_response")
  })
})

test_that("rows of another country are dropped with a warning naming them", {
  with_temp_cache({
    odd <- .ifc_list
    odd$value[[2]]$Country_Description <- "Africa Region"
    ifc_setup(json = ifc_json_mock(odd))
    w <- testthat::capture_warnings(res <- get_assessments("eg", source = "ifc", write_sidecar = FALSE))
    expect_true(any(grepl("Africa Region", w)))
    expect_identical(nrow(res), 2L)
  })
})

test_that("date_range filters Disclosed_Date with positive and negative cases", {
  with_temp_cache({
    ifc_setup()
    expect_identical(nrow(ifc_get(date_range = c("2026-01-01", "2026-12-31"), write_sidecar = FALSE)), 2L)
    expect_identical(
      ifc_get(date_range = c("2001-01-01", "2001-12-31"), write_sidecar = FALSE),
      empty_result_tibble()
    )
  })
})

test_that("download, sidecar round trip and warm rerun keep extras and sections", {
  with_temp_cache({
    ifc_setup()
    n_dl <- 0L
    local_mocked_bindings(
      download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
        n_dl <<- n_dl + 1L
        tibble::tibble(
          url = urls,
          local_path = NA_character_,
          status = c("skipped_size", "failed")[seq_along(urls)],
          size_bytes = NA_real_,
          sha256 = NA_character_,
          reason = c("over cap", "HTTP 404")[seq_along(urls)]
        )
      }
    )
    res <- ifc_get(download = TRUE, limit = 1)
    expect_identical(res$download_status[[1]]$status, c("skipped_size", "failed"))
    back <- index_cache(country = "eg")
    expect_true("ifc_49251" %in% back$document_id)
    expect_true(all(c("Country_Description", "documents_json", "attachment_urls_document") %in% names(back)))
    calls <- new.env()
    ifc_setup(html = ifc_html_mock(calls))
    again <- ifc_get(limit = 1)
    expect_false(any(grepl("/49251/", calls$urls)))
    expect_identical(again$document_id, "ifc_49251")
  })
})

test_that("relevance scoring uses the shared helpers", {
  skip_if_not_installed("planscanR.screen")
  with_temp_cache({
    ifc_setup()
    res <- ifc_get(write_sidecar = FALSE, topic = c(wind = "wind farm"), relevance_model = make_fake_model())
    expect_true("relevance_score_wind" %in% names(res))
  })
})
