# Offline tests for get_assessments_ge(): listing pages (table_1/table_2) and the
# case JSON for 8235a082 (Igoeti) captured from ei.gov.ge; the other cases'
# JSON is derived from it in ge_rec(). Seams: ge_fetch_table(), ge_fetch_record().

ge_read <- function(name) paste(readLines(fixture_path("ge", name), encoding = "UTF-8", warn = FALSE), collapse = "\n")
ge_page <- function(n) xml2::read_html(ge_read(sprintf("table_%d.html", n)), encoding = "UTF-8")
igoeti <- "8235a082-5bda-4e58-bf6b-b513802df00e"
ge_json <- function() jsonlite::fromJSON(ge_read("record_8235a082.json"), simplifyVector = FALSE)

# Igoeti verbatim; any other case gets a distinct project name, and the
# Ternali-like variant drops the implementer and every file flag.
ge_rec <- function(id) {
  j <- ge_json()
  if (id == igoeti) {
    return(j)
  }
  j$res$ProjectName <- paste("Project", substr(id, 1, 8))
  if (startsWith(id, "ea80ad4d")) {
    j$res$ImplementerName <- NULL
    j$res$PermitsPublicPortalInfluenceProjectProcedureGrid <- lapply(
      j$res$PermitsPublicPortalInfluenceProjectProcedureGrid,
      function(g) {
        g$HasDocument <- FALSE
        g$HasAccompanyingDocument <- FALSE
        g$PermitsPublicPortalInfluenceProjectProcedureDocuments <- list()
        g
      }
    )
  }
  j
}

ge_mock <- function(
  table = function(procedure_id, page) ge_page(page),
  record = function(id) ge_rec(id)
) {
  testthat::local_mocked_bindings(
    ge_fetch_table = table,
    ge_fetch_record = record,
    .env = parent.frame()
  )
}

test_that("listing parser keeps native row fields, dedupes nothing itself, reads the last page", {
  p <- planscanR:::ge_parse_table(ge_page(1))
  expect_identical(p$last_page, 2L)
  expect_length(p$entries, 5L) # 35bec21b appears on two rows
  e <- p$entries[[1]]
  expect_identical(e$id, igoeti)
  expect_identical(e$row_id, "bb867595-c0c6-4b1d-ab41-d0cbf26ffcbc")
  expect_identical(e$url, paste0("https://ei.gov.ge/ka/info/", igoeti))
  expect_identical(e$listing_date, "16.11.2026")
  expect_match(e$listing_procedure, "გზშ")
  expect_error(
    planscanR:::ge_parse_table(xml2::read_html("<html><body>oops</body></html>")),
    class = "planscanR_error_bad_response"
  )
  empty <- planscanR:::ge_parse_table(xml2::read_html("<table class='table table-main'><tbody></tbody></table>"))
  expect_length(empty$entries, 0L)
  expect_identical(empty$last_page, 1L)
})

test_that("rows with a detail link but too few cells warn and are skipped", {
  h <- xml2::read_html(paste0(
    "<table class='table table-main'><tbody><tr id='item-x'><td>a</td>",
    "<td><a href='/ka/info/",
    igoeti,
    "'>i</a></td></tr></tbody></table>"
  ))
  expect_warning(p <- planscanR:::ge_parse_table(h), class = "planscanR_warning_partial")
  expect_length(p$entries, 0L)
})

test_that("record builder keeps native fields, full JSON, dates and sectioned attachments", {
  e <- planscanR:::ge_parse_table(ge_page(1))$entries[[1]]
  e$procedure <- "eia"
  rec <- planscanR:::ge_build_record(e, ge_json())
  expect_identical(rec$document_id, paste0("ge_", igoeti))
  expect_identical(rec$country, "ge")
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$native_id, igoeti)
  expect_match(rec$title, "იგოეთის")
  expect_identical(rec$proponent, "შპს აპოთეკო")
  expect_match(rec$jurisdiction, "კასპი")
  expect_identical(rec$date_published, as.Date("2026-05-04")) # earliest PublishDate (UTC+4)
  expect_identical(rec$status, "აქტიური")
  expect_match(rec$status_date, "^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
  expect_true(is.na(rec$competent_authority))
  # procedure bb867595 (HasDocument + accompanying); scoping ccabbc17 with 2 nested docs
  main <- rec$attachment_urls_main_document[[1]]
  bund <- rec$attachment_urls_accompanying_bundle[[1]]
  expect_length(main, 4L) # 2 procedures + 2 nested documents with HasDocument
  expect_length(bund, 3L) # 2 procedures + 1 nested document with HasAccompanyingDocument
  expect_true(all(grepl("accompany=false&type=true$", main)))
  expect_true(all(grepl("accompany=true&type=false$", bund)))
  expect_true(any(grepl("file=bb867595-c0c6-4b1d-ab41-d0cbf26ffcbc&accompany=true", bund, fixed = TRUE)))
  expect_false(any(grepl("file=e1e83751", bund, fixed = TRUE))) # nested doc has no bundle: not guessed
  expect_setequal(rec$attachment_urls[[1]], c(main, bund))
  lab <- jsonlite::fromJSON(rec$attachment_labels_native)
  expect_length(lab, 7L)
  # raw detail JSON survives whole
  raw <- jsonlite::fromJSON(rec$detail_json, simplifyVector = FALSE)
  expect_identical(raw$res$ImplementerName, ge_json()$res$ImplementerName)
  expect_length(raw$res$PermitsPublicPortalInfluenceProjectProcedureGrid, 2L)
  expect_match(rec$procedures_native, ";", fixed = TRUE)
})

test_that("missing implementer / no files are tolerated; a body without the grid errors", {
  e <- planscanR:::ge_parse_table(ge_page(1))$entries[[2]]
  e$procedure <- "sea_scoping"
  rec <- planscanR:::ge_build_record(e, ge_rec(e$id))
  expect_true(is.na(rec$proponent))
  expect_identical(rec$assessment_type, "SEA")
  expect_length(rec$attachment_urls[[1]], 0L)
  expect_false(any(grepl("^attachment_urls_", names(rec)) & names(rec) != "attachment_urls"))
  expect_error(
    planscanR:::ge_build_record(e, list(res = list(ProjectName = "x"))),
    class = "planscanR_error_bad_response"
  )
})

test_that("pagination: pages, cross-page and cross-procedure dedupe, finite stop", {
  calls <- character(0)
  ge_mock(table = function(procedure_id, page) {
    calls <<- c(calls, paste(procedure_id, page))
    ge_page(page)
  })
  gen <- planscanR:::ge_fetch_search(c("eia", "eia_screening"))
  p1 <- gen()
  expect_length(p1, 4L) # 5 rows, 35bec21b twice
  expect_true(all(vapply(p1, `[[`, "", "procedure") == "eia"))
  p2 <- gen()
  expect_length(p2, 3L)
  expect_null(gen()) # second procedure re-lists only already-seen cases
  expect_length(calls, 4L) # 2 pages x 2 procedures, no page past the last
})

test_that("a failed or empty page warns partial; page 1 failure abandons that procedure", {
  ge_mock(table = function(procedure_id, page) {
    if (page == 2) {
      xml2::read_html("<table class='table table-main'><tbody></tbody></table>")
    } else {
      ge_page(1)
    }
  })
  gen <- planscanR:::ge_fetch_search("eia")
  gen()
  expect_warning(r <- gen(), class = "planscanR_warning_partial")
  expect_null(r)
  ge_mock(table = function(procedure_id, page) if (page == 2) stop("boom") else ge_page(1))
  gen <- planscanR:::ge_fetch_search("eia")
  gen()
  expect_warning(r <- gen(), class = "planscanR_warning_partial")
  expect_null(r)
  ge_mock(table = function(procedure_id, page) stop("down"))
  expect_warning(r <- planscanR:::ge_fetch_search("eia")(), class = "planscanR_warning_partial")
  expect_null(r)
})

test_that("a malformed listing envelope is an error, not an empty result", {
  with_temp_cache({
    ge_mock(table = function(procedure_id, page) xml2::read_html("<html><body>{}</body></html>"))
    expect_error(get_assessments_ge(), class = "planscanR_error_bad_response")
  })
})

test_that("end-to-end crawl: sidecars, extras round trip, warm rerun skips detail fetch", {
  with_temp_cache({
    n <- 0L
    ge_mock(record = function(id) {
      n <<- n + 1L
      ge_rec(id)
    })
    res <- get_assessments_ge(procedure = "eia", download = FALSE)
    expect_identical(nrow(res), 7L)
    expect_true(all(grepl("^ge_[0-9a-f-]{36}$", res$document_id)))
    planscanR:::validate_result_schema(res)
    expect_identical(n, 7L)

    back <- index_cache(country = "ge")
    expect_identical(nrow(back), 7L)
    expect_true(all(
      c(
        "procedure",
        "procedure_native",
        "category_native",
        "status",
        "native_id",
        "detail_json",
        "attachment_urls_main_document",
        "attachment_urls_accompanying_bundle",
        "attachment_labels_native"
      ) %in%
        names(back)
    ))
    expect_length(back$attachment_urls_accompanying_bundle[back$native_id == igoeti][[1]], 3L)

    n <- 0L
    again <- get_assessments_ge(procedure = "eia", download = FALSE)
    expect_identical(n, 0L)
    expect_identical(sort(again$document_id), sort(res$document_id))
  })
})

test_that("a failed detail fetch warns, skips the record and is retried next run", {
  with_temp_cache({
    ge_mock(record = function(id) if (startsWith(id, "ea80ad4d")) stop("500") else ge_rec(id))
    expect_warning(res <- get_assessments_ge(procedure = "eia"), class = "planscanR_warning_partial")
    expect_identical(nrow(res), 6L)
    n <- 0L
    ge_mock(record = function(id) {
      n <<- n + 1L
      ge_rec(id)
    })
    res2 <- get_assessments_ge(procedure = "eia")
    expect_identical(n, 1L) # only the failed case is fetched again
    expect_identical(nrow(res2), 7L)
  })
})

test_that("filters have positive and negative cases; empty results are typed", {
  with_temp_cache({
    ge_mock()
    expect_identical(nrow(get_assessments_ge(procedure = "eia", limit = 2, write_sidecar = FALSE)), 2L)
    one <- get_assessments_ge(procedure = "eia", query = "project 4d9b205a", write_sidecar = FALSE)
    expect_identical(one$native_id, "4d9b205a-cd2f-4710-b79e-51f2db4484b7")
    none <- get_assessments_ge(procedure = "eia", query = "zzzz-no-match", write_sidecar = FALSE)
    expect_identical(nrow(none), 0L)
    expect_identical(names(none), names(planscanR:::empty_result_tibble()))
    d <- get_assessments_ge(procedure = "eia", date_range = c("2026-05-01", "2026-05-31"), write_sidecar = FALSE)
    expect_identical(nrow(d), 7L)
    expect_identical(
      nrow(get_assessments_ge(procedure = "eia", date_range = c("2010-01-01", "2010-12-31"), write_sidecar = FALSE)),
      0L
    )
    # procedure: positive = requested GUID reaches the portal; negative = bad key
    seen <- character(0)
    ge_mock(table = function(procedure_id, page) {
      seen <<- c(seen, procedure_id)
      ge_page(page)
    })
    get_assessments_ge(procedure = "sea_report_review", limit = 1, write_sidecar = FALSE)
    expect_identical(unique(seen), "1ba52ee5-cac9-42a3-b5b5-2a0760c3b85d")
    expect_error(get_assessments_ge(procedure = "nope"), class = "planscanR_error_bad_input")
  })
})

test_that("download = TRUE hands every URL (bundles included) to the shared downloader", {
  with_temp_cache({
    ge_mock()
    seen <- list()
    testthat::local_mocked_bindings(
      download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
        seen[[document_id]] <<- urls
        tibble::tibble(
          url = urls,
          local_path = file.path("files", "ge", document_id, seq_along(urls)),
          status = "downloaded",
          size_bytes = 1,
          sha256 = "x",
          reason = NA_character_
        )
      }
    )
    res <- get_assessments_ge(procedure = "eia", limit = 1, download = TRUE)
    expect_length(seen[[paste0("ge_", igoeti)]], 7L)
    expect_length(res$local_path_accompanying_bundle[[1]], 3L)
  })
})

test_that("relevance scoring works with the fake model", {
  with_temp_cache({
    ge_mock()
    res <- get_assessments_ge(
      procedure = "eia",
      write_sidecar = FALSE,
      topic = c(wind = "wind farm"),
      relevance_model = make_fake_model(languages = c("ka", "en"))
    )
    expect_identical(nrow(res), 7L)
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

test_that("ge is dispatched and listed in coverage", {
  expect_true("ge" %in% supported_countries())
  cov <- get_assessments_coverage()
  expect_identical(cov$source_portal[cov$country == "ge"], "ei.gov.ge")
  expect_match(cov$status[cov$country == "ge"], "recent portal only")
})

test_that("get_assessments('ge') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("ge", procedure = "eia", limit = 1, download = FALSE)
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_match(res$document_id, "^ge_")
  })
})
