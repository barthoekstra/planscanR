# Offline tests for get_assessments_cy(): HTML fixtures captured from
# eia.moa.gov.cy (listing trimmed to 3 distinct rows + 1 repeated row; detail
# pages for a Screening row (4173), a MEEP with one zip (3958) and a MEEP with
# several Melete rows incl. a zip (3792)). Network seams: cy_fetch_listing(),
# cy_fetch_detail().

cy_html <- function(name) xml2::read_html(fixture_path("cy", name), encoding = "UTF-8")
cy_mock <- function(
  detail = function(no) cy_html(sprintf("detail_%s.html", no)),
  listing = function() cy_html("list.html")
) {
  testthat::local_mocked_bindings(
    cy_fetch_listing = listing,
    cy_fetch_detail = detail,
    .env = parent.frame()
  )
}
meep <- "ΜΕΕΠ"

test_that("listing parser keeps native labels, absolutises hrefs and dedupes repeats", {
  e <- planscanR:::cy_parse_listing(cy_html("list.html"))
  expect_length(e, 3L) # 4 rows, 4173 repeated
  expect_identical(vapply(e, `[[`, "", "no"), c("4173", "3792", "3958"))
  expect_identical(e[[1]]$url, "https://eia.moa.gov.cy/public/eiaview.html?no=4173")
  expect_identical(e[[1]]$listing_type, "Screening")
  expect_identical(e[[2]]$listing_type, meep)
  expect_identical(e[[1]]$listing_number, "2026-152-1")
  expect_length(planscanR:::cy_parse_listing(xml2::read_html("<html><body></body></html>")), 0L)
})

test_that("detail parser captures every key/value and every file entry, grouped by folder", {
  e <- planscanR:::cy_parse_listing(cy_html("list.html"))
  rec <- planscanR:::cy_build_record(e[[2]], cy_html("detail_3792.html"))
  expect_identical(rec$document_id, "cy_3792")
  expect_identical(rec$country, "cy")
  expect_identical(rec$project_number, "2024-164-1")
  expect_identical(rec$file_number, "ΛΕΥ/00053/2024")
  expect_identical(rec$native_type, "Μελέτη Επιπτώσεων")
  expect_identical(rec$listing_type, meep)
  expect_identical(rec$date_published, as.Date("2024-03-05"))
  expect_identical(rec$date_decision, as.Date("2025-08-04"))
  expect_identical(rec$district, "Λευκωσία")
  expect_true(is.na(rec$proponent))
  # all 4 file rows kept; the two Melete rows (pdf + zip) share the meep section
  expect_length(rec$attachment_urls[[1]], 4L)
  expect_length(rec$attachment_urls_meep[[1]], 2L)
  expect_true(any(grepl("\\.zip$", rec$attachment_urls_meep[[1]])))
  expect_length(rec$attachment_urls_gnomatevseis[[1]], 1L)
  expect_length(rec$attachment_urls_oikologiki_axiologisi[[1]], 1L)
  expect_match(rec$attachment_labels_native, "meep=Μελέτη", fixed = TRUE)
  # every native key survives in native_fields (incl. unmapped coordinates row)
  nf <- jsonlite::fromJSON(rec$native_fields)
  expect_length(nf, 11L)
  expect_true("Συντεταγμένες(E,N,H)" %in% names(nf))
})

test_that("screening rows are kept with their native label and a different folder", {
  e <- planscanR:::cy_parse_listing(cy_html("list.html"))
  rec <- planscanR:::cy_build_record(e[[1]], cy_html("detail_4173.html"))
  expect_identical(rec$listing_type, "Screening")
  expect_identical(rec$native_type, "Έκθεση Πληροφοριών")
  expect_true("attachment_urls_ekthesis_pliroforion" %in% names(rec))
  expect_true("attachment_urls_aitiologimeni_diapistosi" %in% names(rec))
})

test_that("missing optional fields and no attachments are tolerated; empty detail errors", {
  e <- planscanR:::cy_parse_listing(cy_html("list.html"))[[1]]
  h <- paste(readLines(fixture_path("cy", "detail_4173.html"), encoding = "UTF-8", warn = FALSE), collapse = "\n")
  h <- sub("(?s)<table class=\"table no-margin table-hover\"><tbody>\\s*.*?</tbody></table>", "", h, perl = TRUE)
  h <- gsub("<td>31-12-2025</td>", "<td></td>", h, fixed = TRUE)
  rec <- planscanR:::cy_build_record(e, xml2::read_html(h))
  expect_length(rec$attachment_urls[[1]], 0L)
  expect_false(any(grepl("^attachment_urls_", names(rec)) & names(rec) != "attachment_urls"))
  expect_true(is.na(rec$date_published))
  expect_error(planscanR:::cy_parse_detail(xml2::read_html("<html><body><p>x</p></body></html>")))

  # blank description / area / category / project number on the detail page:
  # the listing values must survive
  blank <- function(h, key) {
    sub(sprintf("(?s)(<strong>%s:? ?</strong></td>\\s*<td>).*?(</td>)", key), "\\1\\2", h, perl = TRUE)
  }
  h2 <- paste(readLines(fixture_path("cy", "detail_4173.html"), encoding = "UTF-8", warn = FALSE), collapse = "\n")
  for (k in c(
    "\u03a0\u03b5\u03c1\u03b9\u03b3\u03c1\u03b1\u03c6\u03ae",
    "\u03a0\u03b5\u03c1\u03b9\u03bf\u03c7\u03ae",
    "\u039a\u03b1\u03c4\u03b7\u03b3\u03bf\u03c1\u03af\u03b1",
    "\u0391\u03c1\u03b9\u03b8\u03bc\u03cc\u03c2 \u0388\u03c1\u03b3\u03bf\u03c5"
  )) {
    h2 <- blank(h2, k)
  }
  rec2 <- planscanR:::cy_build_record(e, xml2::read_html(h2))
  expect_identical(rec2$title, e$listing_title)
  expect_identical(rec2$area, e$listing_area)
  expect_identical(rec2$category, e$listing_category)
  expect_identical(rec2$project_number, e$listing_number)
  expect_false(is.na(rec2$title))
})

test_that("listing rows with a detail link but too few cells warn and are skipped", {
  h <- xml2::read_html(paste0(
    "<table id='example1'><tbody><tr><td>x</td><td>y</td>",
    "<td><a href='eiaview.html?no=9'>i</a></td></tr></tbody></table>"
  ))
  expect_warning(e <- planscanR:::cy_parse_listing(h), class = "planscanR_warning_partial")
  expect_length(e, 0L)
})

test_that("end-to-end crawl: dedupe, sidecars, extras round trip, warm rerun skips detail fetch", {
  with_temp_cache({
    n <- 0L
    cy_mock(detail = function(no) {
      n <<- n + 1L
      cy_html(sprintf("detail_%s.html", no))
    })
    res <- get_assessments_cy(download = FALSE)
    expect_identical(nrow(res), 3L)
    expect_true(all(grepl("^cy_[0-9]+$", res$document_id)))
    planscanR:::validate_result_schema(res)
    expect_identical(n, 3L)

    back <- index_cache(country = "cy")
    expect_identical(nrow(back), 3L)
    expect_true(all(c("listing_type", "project_number", "native_fields", "attachment_urls_meep") %in% names(back)))
    expect_length(back$attachment_urls_meep[back$document_id == "cy_3792"][[1]], 2L)
    expect_true(all(
      c(
        "attachment_urls_gnomatevseis",
        "attachment_urls_oikologiki_axiologisi",
        "attachment_urls_ekthesis_pliroforion",
        "attachment_urls_aitiologimeni_diapistosi",
        "native_no",
        "file_number",
        "category",
        "district",
        "area",
        "town",
        "attachment_labels_native"
      ) %in%
        names(back)
    ))
    expect_identical(back$native_no[back$document_id == "cy_3792"], "3792")

    n <- 0L
    again <- get_assessments_cy(download = FALSE)
    expect_identical(n, 0L)
    expect_identical(sort(again$document_id), sort(res$document_id))
  })
})

test_that("filters have positive and negative cases; empty results are typed", {
  with_temp_cache({
    cy_mock()
    expect_identical(nrow(get_assessments_cy(limit = 2, write_sidecar = FALSE)), 2L)
    pv <- get_assessments_cy(query = "φωτοβολταϊκού", write_sidecar = FALSE)
    expect_identical(nrow(pv), 2L)
    none <- get_assessments_cy(query = "zzzz-no-match", write_sidecar = FALSE)
    expect_identical(nrow(none), 0L)
    expect_identical(names(none), names(planscanR:::empty_result_tibble()))
    d <- get_assessments_cy(date_range = c("2025-01-01", "2025-12-01"), write_sidecar = FALSE)
    expect_identical(sort(d$document_id), "cy_3958")
    expect_identical(nrow(get_assessments_cy(date_range = c("2010-01-01", "2010-12-31"), write_sidecar = FALSE)), 0L)
  })
})

test_that("listing failure or empty listing warns and returns a typed empty result", {
  with_temp_cache({
    cy_mock(listing = function() stop("boom"))
    expect_warning(res <- get_assessments_cy(), class = "planscanR_warning_partial")
    expect_identical(nrow(res), 0L)
  })
  with_temp_cache({
    cy_mock(listing = function() xml2::read_html("<html><body></body></html>"))
    expect_warning(res <- get_assessments_cy(), class = "planscanR_warning_partial")
    expect_identical(nrow(res), 0L)
  })
})

test_that("a failing detail fetch warns and skips only that record", {
  with_temp_cache({
    cy_mock(detail = function(no) if (no == "3792") stop("500") else cy_html(sprintf("detail_%s.html", no)))
    expect_warning(res <- get_assessments_cy(write_sidecar = FALSE), class = "planscanR_warning_partial")
    expect_identical(sort(res$document_id), c("cy_3958", "cy_4173"))
  })
})

test_that("download = TRUE hands every URL (zip included) to the shared downloader", {
  with_temp_cache({
    cy_mock()
    seen <- list()
    testthat::local_mocked_bindings(
      download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
        seen[[document_id]] <<- urls
        tibble::tibble(
          url = urls,
          local_path = file.path("files", "cy", document_id, basename(urls)),
          status = "downloaded",
          size_bytes = 1,
          sha256 = "x",
          reason = NA_character_
        )
      }
    )
    res <- get_assessments_cy(download = TRUE)
    expect_true(any(grepl("%2F.*\\.zip$", seen[["cy_3958"]])))
    expect_length(seen[["cy_3792"]], 4L)
    expect_length(res$local_path_meep[res$document_id == "cy_3792"][[1]], 2L)
  })
})

test_that("relevance scoring works with the fake model", {
  with_temp_cache({
    cy_mock()
    res <- get_assessments_cy(
      write_sidecar = FALSE,
      topic = c(solar = "φωτοβολταϊκό πάρκο"),
      relevance_model = make_fake_model(languages = c("el", "en"))
    )
    expect_identical(nrow(res), 3L)
    expect_true(is.numeric(res$relevance_score_solar))
  })
})

test_that("get_assessments('cy') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("cy", limit = 1, download = FALSE)
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_match(res$document_id, "^cy_")
  })
})
