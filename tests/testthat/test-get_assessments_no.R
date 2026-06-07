# Tests for get_assessments_no(). Offline strategy: stub the getall list-page
# fetch (no_fetch_search) and the per-record detail fetch (no_fetch_detail) so
# no live HTTP is needed in CI. The fixtures cover the NVE shapes:
#  - getall_p1.json: the `?pageNumber=1` getall payload (3-record `Licenses`
#                    array + a couple of facet entries + TotalCount).
#  - detail.html:    one case detail page with a `div.n-filelist` section
#                    ("Konsesjon") of webfileservice.nve.no PDF links.

read_no_json <- function(name) {
  jsonlite::fromJSON(fixture_path("no", name), simplifyVector = FALSE)
}

.no_getall_p1 <- read_no_json("getall_p1.json")
.no_licenses <- .no_getall_p1[["Licenses"]]
.no_detail_html <- rvest::read_html(fixture_path("no", "detail.html"))

# -- list mapping ------------------------------------------------------------

test_that("no_map_entries maps Licenses into listing entries with id + type", {
  entries <- planscanR:::no_map_entries(.no_licenses)
  expect_length(entries, 3L)
  expect_true(all(vapply(entries, function(e) !is.null(e$soknad_id), logical(1))))
  e1 <- entries[[1]]
  expect_identical(e1$soknad_id, "8934")
  expect_identical(e1$type, "V-1")
  expect_match(e1$url, "^https://www\\.nve\\.no/konsesjon/konsesjonssaker/konsesjonssak\\?id=8934&type=V-1$")
  # Empty / NULL inputs are safe.
  expect_length(planscanR:::no_map_entries(list()), 0L)
})

# -- canonical url -----------------------------------------------------------

test_that("no_canonical_url builds the detail page URL", {
  expect_identical(
    planscanR:::no_canonical_url("8934", "V-1"),
    "https://www.nve.no/konsesjon/konsesjonssaker/konsesjonssak?id=8934&type=V-1"
  )
})

# -- record parsing ----------------------------------------------------------

test_that("no_build_record parses a license record's conventional columns + extras", {
  raw <- .no_licenses[[1]]
  url <- planscanR:::no_canonical_url(raw$SoknadId, raw$Type)
  rec <- planscanR:::no_build_record(url, raw)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "no")
  expect_identical(rec$source_portal, "nve.no")
  expect_identical(rec$document_id, "NVE-8934")
  expect_identical(rec$competent_authority, "Norges vassdrags- og energidirektorat (NVE)")
  expect_match(rec$title, "Harpefoss")
  expect_identical(rec$proponent, "OPPLANDSKRAFT DA")
  expect_identical(rec$county, "Innlandet")
  expect_identical(rec$municipality, "Sør-Fron")
  expect_identical(rec$case_type, "Endring i vilkår")
  expect_identical(rec$case_type_id, "C-28")
  expect_identical(rec$case_type_code, "V-1")
  expect_identical(rec$hearing_deadline, "04.06.2026")
  # date_published parsed from the ISO `Dato`.
  expect_identical(rec$date_published, as.Date("2022-09-28"))
  expect_true(is.na(rec$date_decision))
  expect_true(is.na(rec$summary))
})

test_that("no_parse_documents scrapes webfileservice PDF urls grouped by section", {
  per_section <- planscanR:::no_parse_documents(.no_detail_html)
  expect_true(is.list(per_section))
  # The detail fixture groups documents under the "Konsesjon" section.
  expect_true("konsesjon" %in% names(per_section))
  all_urls <- unique(unlist(per_section, use.names = FALSE))
  expect_length(all_urls, 14L)
  expect_true(all(grepl(
    "^https://webfileservice\\.nve\\.no/API/PublishedFiles/Download/",
    all_urls
  )))
  expect_true(
    "https://webfileservice.nve.no/API/PublishedFiles/Download/73384329-e277-4ec1-85da-dae8472ce68f/202218289/3451657" %in%
      all_urls
  )

  # The per-section columns land on the record, plus the union.
  raw <- .no_licenses[[1]]
  url <- planscanR:::no_canonical_url(raw$SoknadId, raw$Type)
  rec <- planscanR:::no_build_record(url, raw, per_section)
  expect_true("attachment_urls_konsesjon" %in% names(rec))
  expect_true(all(all_urls %in% rec$attachment_urls[[1]]))

  # An empty / missing filelist yields no sections (valid).
  expect_length(
    planscanR:::no_parse_documents(rvest::read_html("<html><body></body></html>")),
    0L
  )
})

# -- summary parsing ---------------------------------------------------------

test_that("no_parse_summary extracts the main-column summary, whitespace-collapsed", {
  summary <- planscanR:::no_parse_summary(.no_detail_html)
  expect_type(summary, "character")
  expect_length(summary, 1L)
  expect_false(is.na(summary))
  # The summary spans two main-column blocks: the bold lead (div.n-mb-5) and
  # the rich-text body (div.n-rte); both are captured, in document order.
  expect_match(summary, "Opplandskraft DA har søkt om endring")
  expect_match(summary, "vassdragsreguleringsloven § 28")
  expect_match(summary, "Harpefoss kraftverk ligger i Gudbrandsdalslågen")
  # Lead precedes body in the joined text.
  expect_lt(
    regexpr("Opplandskraft DA", summary, fixed = TRUE),
    regexpr("Harpefoss kraftverk ligger", summary, fixed = TRUE)
  )
  # Whitespace is collapsed: no runs of spaces, no stray non-breaking spaces,
  # no leading/trailing whitespace, and the trailing empty <p>&nbsp;</p> nodes
  # are squeezed away rather than appended as blank lines.
  expect_false(grepl(" ", summary, fixed = TRUE))
  expect_false(grepl("  ", summary, fixed = TRUE))
  expect_false(grepl("\n", summary, fixed = TRUE))
  expect_identical(summary, trimws(summary))
})

test_that("no_parse_summary returns NA when there is no main-column summary block", {
  # The sidebar/file-list n-mb-5 blocks live in div.n-col-5, so a page with no
  # div.n-col-7 summary must yield NA rather than picking those up.
  no_summary <- rvest::read_html(
    "<html><body><div class=\"n-col-5\"><div class=\"n-mb-5\">sidebar</div></div></body></html>"
  )
  expect_identical(planscanR:::no_parse_summary(no_summary), NA_character_)
  # Empty document is safe too.
  expect_identical(
    planscanR:::no_parse_summary(rvest::read_html("<html><body></body></html>")),
    NA_character_
  )
})

test_that("no_build_record sets summary from the parsed value (default NA)", {
  raw <- .no_licenses[[1]]
  url <- planscanR:::no_canonical_url(raw$SoknadId, raw$Type)
  # Default (no summary supplied) stays NA.
  expect_true(is.na(planscanR:::no_build_record(url, raw)$summary))
  # A supplied summary lands on the record.
  rec <- planscanR:::no_build_record(url, raw, summary = "Sammendrag av saken.")
  expect_identical(rec$summary, "Sammendrag av saken.")
})

# -- filters -----------------------------------------------------------------

test_that("no_record_matches honours date_range", {
  rec <- tibble::tibble(date_published = as.Date("2022-09-28"))
  expect_true(planscanR:::no_record_matches(rec, NULL))
  expect_true(planscanR:::no_record_matches(rec, as.Date(c("2022-01-01", "2022-12-31"))))
  expect_false(planscanR:::no_record_matches(rec, as.Date(c("2010-01-01", "2010-12-31"))))
})

test_that("no_fetch_search forwards query as the getall filterText param", {
  captured <- new.env()
  local_mocked_bindings(
    perform_json = function(req) {
      captured$url <- req$url
      # Return a single empty-Licenses page so the generator stops at once.
      list(Licenses = list())
    }
  )
  gen <- planscanR:::no_fetch_search(query = "vind")
  invisible(gen())
  expect_match(captured$url, "filterText=vind")
  expect_match(captured$url, "pageNumber=1")
  expect_match(captured$url, "getall")
})

# -- end-to-end on fixtures (mocked network seams) ---------------------------

# A reusable mock pair: the list-page generator yields the fixture licenses
# once; the detail fetch returns the parsed detail HTML for every record.
no_mock_bindings <- function() {
  list(
    no_fetch_search = function(query = NULL) {
      emitted <- FALSE
      function() {
        if (emitted) {
          return(NULL)
        }
        emitted <<- TRUE
        planscanR:::no_map_entries(.no_licenses)
      }
    },
    no_fetch_detail = function(url) .no_detail_html
  )
}

test_that("get_assessments_no end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- no_mock_bindings()
    local_mocked_bindings(
      no_fetch_search = mb$no_fetch_search,
      no_fetch_detail = mb$no_fetch_detail
    )

    res <- get_assessments_no(limit = 10, download = FALSE)
    expect_identical(nrow(res), 3L)
    planscanR:::validate_result_schema(res)
    expect_true(all(grepl("^NVE-", res$document_id)))
    expect_true(all(res$country == "no"))
    # Every record picked up the 14 webfileservice PDFs from the detail fixture.
    expect_true(all(vapply(res$attachment_urls, length, integer(1)) == 14L))
    # Every record incorporates the detail-page summary (issue #5).
    expect_true(all(!is.na(res$summary)))
    expect_true(all(grepl("Opplandskraft DA har søkt om endring", res$summary)))

    # Sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "no"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 3L)

    # Second call with refresh = FALSE must NOT re-fetch detail.
    local_mocked_bindings(
      no_fetch_detail = function(...) {
        stop("no_fetch_detail should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_no(limit = 10, download = FALSE)
    expect_identical(nrow(res2), 3L)
  })
})

test_that("get_assessments_no honours date_range and limit", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- no_mock_bindings()
    local_mocked_bindings(
      no_fetch_search = mb$no_fetch_search,
      no_fetch_detail = mb$no_fetch_detail
    )

    # date_range: nothing in 2010.
    res_dr <- get_assessments_no(
      date_range = c("2010-01-01", "2010-12-31"),
      download = FALSE
    )
    expect_identical(nrow(res_dr), 0L)

    # limit caps the total.
    res_lim <- get_assessments_no(limit = 1, download = FALSE)
    expect_identical(nrow(res_lim), 1L)
  })
})

test_that("NO -> sidecar round-trip preserves country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- no_mock_bindings()
    local_mocked_bindings(
      no_fetch_search = mb$no_fetch_search,
      no_fetch_detail = mb$no_fetch_detail
    )

    res <- get_assessments_no(limit = 10, download = FALSE)
    idx <- index_cache(country = "no")
    expect_identical(nrow(idx), 3L)

    expect_true(all(
      c(
        "county",
        "municipality",
        "case_type",
        "case_type_id",
        "case_type_code",
        "stage",
        "hearing_deadline"
      ) %in%
        names(idx)
    ))
    expect_true("Innlandet" %in% idx$county)
    expect_true("C-28" %in% idx$case_type_id)
  })
})

test_that("get_assessments_no scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- no_mock_bindings()
    local_mocked_bindings(
      no_fetch_search = mb$no_fetch_search,
      no_fetch_detail = mb$no_fetch_detail
    )

    res <- get_assessments_no(
      limit = 10,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(hydro = "kraftverk vassdrag", wind = "vindkraft"),
      relevance_model = make_fake_model(languages = c("no", "en"))
    )
    expect_identical(nrow(res), 3L)
    expect_true("relevance_score_hydro" %in% names(res))
    expect_true("relevance_score_wind" %in% names(res))
    expect_true(is.numeric(res$relevance_score_hydro))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('no') fetches a real record end-to-end", {
  skip_if_offline_tests()
  withr::local_options(list(planscanR.no_throttle_rate = 5))
  with_temp_cache({
    res <- get_assessments("no", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "no")
    expect_identical(res$source_portal, "nve.no")
    expect_true(grepl("^https://www\\.nve\\.no", res$url))
  })
})
