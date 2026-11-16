# Offline tests for the explicit source "aiib" (AIIB project register).
# Mock seams: aiib_perform_text (the JS data file) and perform_html (detail pages).
.aiib_js <- paste(
  readLines(fixture_path("aiib", "all-projects-data.js"), encoding = "UTF-8", warn = FALSE),
  collapse = "\n"
)
.aiib_js_full <- .aiib_js
.aiib_js <- sub('\n\t\n\t\\{"date":"2020".*?\\},(?=\n)', "", .aiib_js, perl = TRUE) # without the unmapped-economy row
.aiib_calls <- new.env()

aiib_mock_html <- function(bad = character(0)) {
  function(req) {
    u <- req$url
    .aiib_calls$html <- c(.aiib_calls$html, u)
    if (any(vapply(.aiib_calls$fail, grepl, logical(1), x = u, fixed = TRUE))) {
      stop("simulated 503")
    }
    f <- if (any(vapply(bad, grepl, logical(1), x = u, fixed = TRUE))) {
      "detail-bad.html"
    } else if (grepl("Henan-Flood", u, fixed = TRUE)) {
      "detail-henan.html"
    } else {
      "detail-nodocs.html"
    }
    rvest::read_html(fixture_path("aiib", f))
  }
}

with_aiib <- function(code, js = .aiib_js, fail = character(0), bad = character(0)) {
  with_temp_cache({
    .aiib_calls$html <- character(0)
    .aiib_calls$fail <- fail
    local_mocked_bindings(
      aiib_perform_text = function(req) js,
      perform_html = aiib_mock_html(bad)
    )
    force(code)
  })
}

aiib_get <- function(country = "cn", ...) {
  suppressWarnings(get_assessments(country, source = "aiib", write_sidecar = FALSE, ...))
}

test_that("aiib is registered, not national, and rejects codes it cannot map", {
  expect_true("aiib" %in% get_assessments_sources()$source)
  expect_false("aiib" %in% supported_countries())
  with_aiib({
    expect_error(get_assessments("nl", source = "aiib"), "no country name mapped", class = "planscanR_error_bad_input")
    expect_error(get_assessments("china", source = "aiib"), class = "planscanR_error_bad_input")
    expect_length(.aiib_calls$html, 0L)
  })
})

test_that("country filter matches on economy, handles non-ASCII and the typographic apostrophe, excludes Multicountry", {
  with_aiib({
    expect_setequal(
      aiib_get("cn")$document_id,
      c("aiib_details_2021_approved_henan_flood", "aiib_details_2024_proposed_yingkou")
    )
    expect_identical(aiib_get("tr")$economy, "Türkiye")
    ci <- aiib_get("ci")
    expect_identical(nrow(ci), 1L)
    expect_identical(ci$name_prefix, "Côte d’Ivoire")
    expect_identical(ci$country, "ci")
    all_ids <- unlist(lapply(c("cn", "tr", "ci", "bd"), function(k) aiib_get(k)$document_id))
    expect_false(any(grepl("gss|atlantis", all_ids)))
    expect_identical(anyDuplicated(all_ids), 0L)
    expect_true(all(grepl("^aiib_[a-z0-9_]+$", all_ids)))
  })
})

test_that("mapped code with no rows is a typed empty; unmapped economy names are warned", {
  with_aiib({
    expect_identical(get_assessments("in", source = "aiib"), empty_result_tibble())
  })
  with_aiib(
    expect_warning(get_assessments("in", source = "aiib"), "Atlantis", class = "planscanR_warning_partial"),
    js = .aiib_js_full
  )
})

test_that("detail record keeps native metadata, dates, organisations only, extras", {
  with_aiib({
    r <- aiib_get("cn")
    r <- r[r$document_id == "aiib_details_2021_approved_henan_flood", ]
    expect_identical(r$source_portal, "aiib.org")
    expect_identical(r$url, "https://www.aiib.org/en/projects/details/2021/approved/Henan-Flood.html")
    expect_identical(r$title, "China: Henan Flood Emergency Rehabilitation and Recovery Project")
    expect_identical(r$project_number, "000543")
    expect_identical(r$es_category, "Category A")
    expect_identical(r$status, "Approved")
    expect_identical(r$sector, "Water")
    expect_identical(r$economy, "China")
    expect_identical(r$name_prefix, "China")
    expect_identical(r$approval_year, "2021")
    expect_identical(r$date_published, as.Date("2021-11-25"))
    expect_match(r$summary, "^Emergency post-flood recovery")
    expect_match(r$objective, "^The project objectives")
    expect_match(r$proponent, "Ministry of Finance")
    expect_match(r$implementing_entity, "Government of Henan Province")
    all_text <- paste(unlist(r), collapse = " ")
    expect_false(grepl("Zhao|@", all_text))
    flds <- jsonlite::fromJSON(r$detail_fields_json)
    expect_identical(flds[["FINANCING APPROVAL"]], "November 25, 2021")
    expect_identical(flds[["LATEST FIELD VISIT"]], "May 2026")
    expect_identical(jsonlite::fromJSON(r$listing_json)$approved_funding, "USD1,000 million")
    expect_identical(r$listing_pos, "0.1")
    expect_identical(nrow(jsonlite::fromJSON(r$news_json)), 1L)
  })
})

test_that("links are grouped by native heading with full labels; external links are listed, not attached", {
  with_aiib({
    r <- aiib_get("cn")
    r <- r[r$document_id == "aiib_details_2021_approved_henan_flood", ]
    expect_true(all(
      c(
        "attachment_urls_aiib_documents",
        "attachment_urls_client_cofinancing_partner_documents",
        "attachment_urls_procurement_documents"
      ) %in%
        names(r)
    ))
    labs <- r$attachment_labels_aiib_documents[[1]]
    expect_length(labs, 4L)
    expect_identical(labs[1], "Draft final ESIA and ESMP Dengfeng (English)")
    expect_true("Project Implementation Monitoring Report (May 2026)" %in% labs)
    expect_length(r$attachment_urls_aiib_documents[[1]], 4L)
    cl <- r$attachment_labels_client_cofinancing_partner_documents[[1]]
    expect_true("ESIA ESMP Jiaozuo Disease Restoration and Improvement Subproject (Chinese)" %in% cl)
    expect_identical(r$external_urls_client_cofinancing_partner_documents[[1]], "http://idcol.org/home/downloads")
    expect_identical(r$external_labels_client_cofinancing_partner_documents[[1]], "IDCOL downloads")
    expect_false(any(grepl("idcol", r$attachment_urls[[1]])))
    expect_true(all(grepl("^https://www\\.aiib\\.org/", r$attachment_urls[[1]])))
    expect_identical(
      sort(r$attachment_urls[[1]]),
      sort(unlist(r[grep("^attachment_urls_.", names(r))], use.names = FALSE))
    )
    docs <- jsonlite::fromJSON(r$documents_json)
    expect_identical(nrow(docs), 11L)
    expect_identical(sum(docs$external), 1L)
  })
})

test_that("pages without documents are fine; a 200 page without containers is a failure, never cached", {
  with_aiib({
    r <- aiib_get("bd")
    expect_identical(r$detail_status, "ok")
    expect_length(r$attachment_urls[[1]], 0L)
    expect_identical(r$project_number, "000003")
    expect_true(is.na(r$date_published)) # month-only date
  })
  with_aiib(
    {
      w <- testthat::capture_warnings(
        r <- get_assessments("bd", source = "aiib")
      )
      expect_true(any(grepl("listing-only", w)))
      expect_identical(r$detail_status, "failed")
      expect_identical(r$title, "Bangladesh: Distribution System Upgrade")
      expect_identical(nrow(index_cache(country = "bd")), 0L)
    },
    bad = "desco"
  )
})

test_that("a failed detail fetch is retried next run; successful ones are warm hits", {
  with_aiib({
    r <- suppressWarnings(get_assessments("cn", source = "aiib"))
    expect_identical(nrow(r), 2L)
    expect_setequal(index_cache(country = "cn")$document_id, r$document_id)
    n <- length(.aiib_calls$html)
    again <- get_assessments("cn", source = "aiib")
    expect_identical(length(.aiib_calls$html), n) # warm: no detail refetch
    expect_identical(again$project_number[again$document_id == r$document_id[1]], r$project_number[1])
    expect_true("attachment_urls_aiib_documents" %in% names(again))
    expect_true("attachment_labels_aiib_documents" %in% names(again))
  })
  with_aiib(
    {
      w <- testthat::capture_warnings(r1 <- get_assessments("cn", source = "aiib"))
      expect_true(any(grepl("listing-only", w)))
      expect_identical(r1$detail_status[r1$path == "/en/projects/details/2024/proposed/Yingkou.html"], "failed")
      expect_identical(nrow(index_cache(country = "cn")), 1L)
      .aiib_calls$fail <- character(0)
      r2 <- get_assessments("cn", source = "aiib")
      expect_true(all(r2$detail_status == "ok"))
      expect_identical(nrow(index_cache(country = "cn")), 2L)
    },
    fail = "Yingkou"
  )
})

test_that("filters: query, status, date_range, limit have positive and negative cases", {
  with_aiib({
    expect_identical(nrow(aiib_get("cn", query = "yingkou")), 1L)
    expect_identical(nrow(aiib_get("cn", query = "no-such-thing")), 0L)
    expect_identical(aiib_get("cn", status = "proposed")$approval_year, "-")
    expect_identical(nrow(aiib_get("cn", status = "Terminated / Cancelled")), 0L)
    expect_identical(nrow(aiib_get("cn", date_range = c("2021-01-01", "2021-12-31"))), 1L)
    expect_identical(nrow(aiib_get("cn", date_range = c("2010-01-01", "2012-12-31"))), 0L)
    n <- length(.aiib_calls$html)
    expect_identical(nrow(aiib_get("cn", limit = 1)), 1L)
    expect_identical(length(.aiib_calls$html) - n, 1L) # detail only for returned records
    expect_error(get_assessments("cn", source = "aiib", status = c("a", "b")), class = "planscanR_error_bad_input")
  })
})

test_that("an unexpected data file shape errors with bad_response", {
  for (js in c("<html>blocked</html>", "var data=[];", "var data=[{\"x\":1}];", "var data=[{oops}];", "")) {
    with_aiib(
      expect_error(get_assessments("cn", source = "aiib"), class = "planscanR_error_bad_response"),
      js = js
    )
  }
})

test_that("a repeated path in the data file is dropped with a partial warning", {
  row <- '{"name":"A: x","path":"/p/1.html","economy":"China","status":"Approved"}'
  dup <- paste0("var data=[", row, ",", row, ",];")
  expect_warning(rows <- aiib_parse_listing(dup), class = "planscanR_warning_partial")
  expect_length(rows, 1L)
})

test_that("downloads go through the shared downloader per section; sidecar round trip keeps extras", {
  with_aiib({
    got <- new.env()
    local_mocked_bindings(
      download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
        got$n <- c(got$n, length(urls))
        tibble::tibble(
          url = urls,
          local_path = file.path(tempdir(), basename(urls)),
          status = "downloaded",
          size_bytes = 10,
          sha256 = "abc",
          reason = NA_character_
        )
      }
    )
    r <- suppressWarnings(get_assessments("cn", source = "aiib", download = TRUE))
    h <- r[r$document_id == "aiib_details_2021_approved_henan_flood", ]
    expect_length(h$local_path[[1]], length(h$attachment_urls[[1]]))
    expect_length(h$local_path_aiib_documents[[1]], 4L)
    back <- index_cache(country = "cn")
    b <- back[back$document_id == h$document_id, ]
    expect_identical(b$project_number, "000543")
    expect_identical(b$attachment_labels_aiib_documents[[1]][1], "Draft final ESIA and ESMP Dengfeng (English)")
    expect_identical(b$external_urls_client_cofinancing_partner_documents[[1]], "http://idcol.org/home/downloads")
  })
})

test_that("relevance scoring uses the shared helpers", {
  skip_if_not_installed("planscanR.screen")
  with_aiib({
    res <- aiib_get("cn", topic = c(flood = "flood recovery"), relevance_model = make_fake_model())
    expect_true("relevance_score_flood" %in% names(res))
  })
})
