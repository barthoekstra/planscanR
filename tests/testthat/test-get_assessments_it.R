# Tests for get_assessments_it(). Offline strategy: stub `perform_html` to hand
# back the recorded HTML fixtures so no live HTTP is needed in CI. The fixtures
# cover both registers the MASE portal exposes:
#  - VIA (EIA): via_listing.html + info_detail.html + documentazione.html
#  - VAS (SEA): vas_listing.html (one plan row)

read_it_fixture <- function(name) {
  rvest::read_html(fixture_path("it", name))
}

.it_fix_via_listing <- read_it_fixture("via_listing.html")
.it_fix_vas_listing <- read_it_fixture("vas_listing.html")
.it_fix_info <- read_it_fixture("info_detail.html")
.it_fix_info_vas <- read_it_fixture("info_detail_vas.html")
.it_fix_doc <- read_it_fixture("documentazione.html")

# Synthetic listing entries matching the fixtures.
.it_entry_via <- list(
  register = "VIA",
  id = "7917",
  title = "Autostrada A22 \"del Brennero\" - realizzazione della terza corsia",
  proponent = "Autostrada del Brennero S.p.A.",
  procedura = "Verifica di Ottemperanza",
  doc_url = "https://va.mite.gov.it/it-IT/Oggetti/Documentazione/7917/19017",
  grp = "19017"
)
.it_entry_vas <- list(
  register = "VAS",
  id = "12037",
  title = "PIANO DI GESTIONE DEL RISCHIO ALLUVIONI DEL DISTRETTO DELL'APPENNINO CENTRALE 2028-2033",
  proponent = "Autorità di Bacino del Distretto Idrografico dell'Appennino Centrale",
  procedura = "Verifica di Assoggettabilità a VAS",
  doc_url = "https://va.mite.gov.it/it-IT/Oggetti/Documentazione/12037/18886",
  grp = "18886"
)

mock_perform_html_it <- function() {
  function(req) {
    url <- req$url
    if (grepl("/Oggetti/Info/7917", url)) {
      return(.it_fix_info)
    }
    if (grepl("/Oggetti/Documentazione/7917", url)) {
      return(.it_fix_doc)
    }
    if (grepl("/Oggetti/Info/12037", url)) {
      return(.it_fix_info_vas)
    }
    if (grepl("/Oggetti/Documentazione/12037", url)) {
      return(.it_fix_doc)
    }
    stop("Unexpected URL in test: ", url)
  }
}

# -- Parse-fn units ----------------------------------------------------------

test_that("it_parse_index_rows extracts VIA listing rows with Info id + Doc grp", {
  rows <- planscanR:::it_parse_index_rows(.it_fix_via_listing, "VIA")
  expect_gte(length(rows), 3L)
  first <- rows[[1]]
  expect_identical(first$register, "VIA")
  expect_identical(first$id, "7917")
  expect_match(first$title, "Autostrada A22")
  expect_match(first$proponent, "Autostrada del Brennero")
  expect_match(first$procedura, "Verifica di Ottemperanza")
  expect_match(first$doc_url, "/Oggetti/Documentazione/7917/19017$")
  expect_identical(first$grp, "19017")
})

test_that("it_parse_index_rows extracts VAS listing rows", {
  rows <- planscanR:::it_parse_index_rows(.it_fix_vas_listing, "VAS")
  expect_gte(length(rows), 2L)
  first <- rows[[1]]
  expect_identical(first$register, "VAS")
  expect_identical(first$id, "12037")
  expect_match(first$title, "PIANO DI GESTIONE DEL RISCHIO ALLUVIONI")
})

test_that("it_parse_last_page reads the 'Pagina X di Y' counter", {
  expect_identical(planscanR:::it_parse_last_page(.it_fix_via_listing), 1058L)
  expect_identical(planscanR:::it_parse_last_page(.it_fix_vas_listing), 14L)
  blank <- rvest::read_html("<html><body><p>no counter</p></body></html>")
  expect_true(is.na(planscanR:::it_parse_last_page(blank)))
})

test_that("it_extract_info_id / it_extract_doc_grp pull ids from hrefs", {
  expect_identical(
    planscanR:::it_extract_info_id("https://va.mite.gov.it/it-IT/Oggetti/Info/7917"),
    "7917"
  )
  expect_true(is.na(planscanR:::it_extract_info_id("/it-IT/Ricerca/ViaProcedura")))
  expect_identical(
    planscanR:::it_extract_doc_grp("/it-IT/Oggetti/Documentazione/7917/19017"),
    "19017"
  )
  expect_true(is.na(planscanR:::it_extract_doc_grp(NA_character_)))
})

test_that("it_normalise_assessment_type accepts the API vocabulary case-insensitively", {
  expect_identical(planscanR:::it_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::it_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::it_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::it_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::it_normalise_assessment_type("sea"), "SEA")
  expect_error(planscanR:::it_normalise_assessment_type("nope"))
})

test_that("it_parse_date parses the Italian DD/MM/YYYY format", {
  expect_identical(planscanR:::it_parse_date("03/06/2025"), as.Date("2025-06-03"))
  expect_identical(planscanR:::it_parse_date("avvio 9/9/2024 ok"), as.Date("2024-09-09"))
  expect_true(is.na(planscanR:::it_parse_date(NULL)))
  expect_true(is.na(planscanR:::it_parse_date("")))
  expect_true(is.na(planscanR:::it_parse_date("nessuna data")))
})

test_that("it_section_slug folds Sezione labels to ASCII slugs", {
  expect_identical(planscanR:::it_section_slug("Elenchi Elaborati"), "elenchi_elaborati")
  expect_identical(planscanR:::it_section_slug("Documentazione di ottemperanza"), "documentazione_di_ottemperanza")
  expect_identical(planscanR:::it_section_slug(NULL), "documento")
  expect_identical(planscanR:::it_section_slug(""), "documento")
})

test_that("it_parse_documents groups /File/Documento links by Sezione", {
  per_section <- planscanR:::it_parse_documents(.it_fix_doc)
  expect_true("elenchi_elaborati" %in% names(per_section))
  expect_true("documentazione_di_ottemperanza" %in% names(per_section))
  all_urls <- unique(unlist(per_section, use.names = FALSE))
  expect_length(all_urls, 3L)
  expect_true(all(grepl("^https://va\\.mite\\.gov\\.it/File/Documento/[0-9]+$", all_urls)))
  expect_length(per_section[["documentazione_di_ottemperanza"]], 2L)
})

test_that("it_field_value strips the label and the HTML-comment-leak wrapper", {
  # Proponente in the fixture is wrapped in <!--small -->VALUE<!--/small -->.
  proponent <- planscanR:::it_field_value(.it_fix_info, "Proponente")
  expect_identical(proponent, "Autostrada del Brennero S.p.A.")
  expect_false(grepl("small", proponent, ignore.case = TRUE))
  expect_identical(
    planscanR:::it_field_value(.it_fix_info, "Regioni"),
    "Emilia Romagna, Lombardia, Veneto"
  )
  expect_identical(
    planscanR:::it_field_value(.it_fix_info, "Comuni"),
    "Mantova, Roverbella, Villafranca di Verona, Verona, Vigasio"
  )
  expect_null(planscanR:::it_field_value(.it_fix_info, "Inesistente"))
})

test_that("it_parse_detail extracts conventional columns, extras, and section attachments", {
  url <- planscanR:::it_canonical_url("7917")
  documents <- planscanR:::it_parse_documents(.it_fix_doc)
  parsed <- planscanR:::it_parse_detail(url, .it_entry_via, .it_fix_info, documents)
  rec <- parsed$record

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "it")
  expect_identical(rec$source_portal, "va.mite.gov.it")
  expect_identical(rec$document_id, "VIA-7917")
  expect_identical(rec$url, url)
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "VIA")
  expect_match(rec$title, "Autostrada A22")
  expect_match(rec$proponent, "Autostrada del Brennero")
  expect_identical(
    rec$competent_authority,
    "Ministero dell'Ambiente e della Sicurezza Energetica"
  )
  # Procedure timeline: first row's Data avvio + Stato, plus decree + esito.
  expect_identical(rec$date_published, as.Date("2025-06-03"))
  expect_identical(rec$date_decision, as.Date("2024-09-09"))
  expect_identical(rec$status, "Conclusa")
  expect_identical(rec$outcome, "Ottemperata")
  # Extras: Italian values verbatim.
  expect_match(rec$regions, "Emilia Romagna")
  expect_match(rec$provinces, "Reggio Emilia")
  expect_match(rec$municipalities, "Mantova")
  expect_identical(rec$procedura, "Verifica di Ottemperanza")
  # Attachments: union + per-section columns.
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 3L)
  expect_true(all(grepl("/File/Documento/", urls)))
  expect_true("attachment_urls_elenchi_elaborati" %in% names(rec))
  expect_true("attachment_urls_documentazione_di_ottemperanza" %in% names(rec))
  # No geometry for IT.
  expect_null(parsed$geometry)
})

test_that("it_parse_detail tags VAS records as SEA with the VAS- prefix", {
  url <- planscanR:::it_canonical_url("12037")
  parsed <- planscanR:::it_parse_detail(url, .it_entry_vas, .it_fix_info, list())
  rec <- parsed$record
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$register, "VAS")
  expect_identical(rec$document_id, "VAS-12037")
})

# -- Filters -----------------------------------------------------------------

test_that("it_record_matches honours the query substring filter", {
  rec <- tibble::tibble(title = "Autostrada A22 del Brennero", date_published = as.Date("2025-06-03"))
  expect_true(planscanR:::it_record_matches(rec, query = NULL))
  expect_true(planscanR:::it_record_matches(rec, query = "autostrada"))
  expect_true(planscanR:::it_record_matches(rec, query = "BRENNERO"))
  expect_false(planscanR:::it_record_matches(rec, query = "centrale termica"))
})

test_that("it_record_matches honours the date_range filter", {
  rec <- tibble::tibble(title = "x", date_published = as.Date("2025-06-03"))
  expect_true(planscanR:::it_record_matches(rec, date_range = NULL))
  expect_true(planscanR:::it_record_matches(
    rec,
    date_range = as.Date(c("2025-01-01", "2025-12-31"))
  ))
  expect_false(planscanR:::it_record_matches(
    rec,
    date_range = as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

# -- End-to-end on fixtures --------------------------------------------------

stub_it_fetch_search <- function() {
  function(register, ...) {
    emitted <- FALSE
    function() {
      if (emitted) {
        return(NULL)
      }
      emitted <<- TRUE
      if (register == "VIA") list(.it_entry_via) else list(.it_entry_vas)
    }
  }
}

test_that("get_assessments_it end-to-end on fixtures (sidecar-first reuse)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_it(),
      it_fetch_search = stub_it_fetch_search()
    )

    res <- get_assessments_it(limit = 5, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("VIA-7917", "VAS-12037"))
    expect_setequal(res$assessment_type, c("EIA", "SEA"))

    sidecars <- list.files(
      file.path(cache, "files", "it"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT re-parse cached URLs.
    parse_calls <- 0L
    local_mocked_bindings(
      it_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("it_parse_detail should not run on a cached URL")
      }
    )
    res2 <- get_assessments_it(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 2L)
  })
})

test_that("get_assessments_it honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_it(),
      it_fetch_search = stub_it_fetch_search()
    )

    res_eia <- get_assessments_it(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res_eia), 1L)
    expect_identical(res_eia$document_id, "VIA-7917")

    res_sea <- get_assessments_it(assessment_type = "SEA", limit = 5, download = FALSE)
    expect_identical(nrow(res_sea), 1L)
    expect_identical(res_sea$document_id, "VAS-12037")
  })
})

test_that("get_assessments_it honours the query and date_range filters", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_it(),
      it_fetch_search = stub_it_fetch_search()
    )

    # query hits the VIA title only.
    res_q <- get_assessments_it(query = "Autostrada", limit = 5, download = FALSE)
    expect_identical(nrow(res_q), 1L)
    expect_identical(res_q$document_id, "VIA-7917")

    # query that matches nothing.
    res_none <- get_assessments_it(query = "zzz-no-match", limit = 5, download = FALSE)
    expect_identical(nrow(res_none), 0L)

    # date_range covering 2025 keeps the VIA record (Data avvio 03/06/2025).
    res_d <- get_assessments_it(
      assessment_type = "EIA",
      date_range = c("2025-01-01", "2025-12-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res_d), 1L)
    res_d0 <- get_assessments_it(
      assessment_type = "EIA",
      date_range = c("2019-01-01", "2019-12-31"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res_d0), 0L)
  })
})

test_that("get_assessments_it caps the global limit across both registers", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_it(),
      it_fetch_search = stub_it_fetch_search()
    )

    res <- get_assessments_it(limit = 1, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "VIA-7917")
  })
})

test_that("IT -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_it(),
      it_fetch_search = stub_it_fetch_search()
    )

    res <- get_assessments_it(limit = 5, download = FALSE)
    idx <- index_cache(country = "it")
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c("VIA-7917", "VAS-12037"))
    expect_true("register" %in% names(idx))
    expect_true("assessment_type" %in% names(idx))
    expect_true("regions" %in% names(idx))
    expect_true("municipalities" %in% names(idx))
    expect_true("outcome" %in% names(idx))
    expect_setequal(idx$register, c("VIA", "VAS"))
    # Per-section attachment URL columns survive.
    expect_true(any(grepl("^attachment_urls_", names(idx))))
  })
})

test_that("get_assessments_it scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = mock_perform_html_it(),
      it_fetch_search = stub_it_fetch_search()
    )

    res <- get_assessments_it(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(road = "autostrada", flood = "rischio alluvioni"),
      relevance_model = make_fake_model(languages = c("it", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_road" %in% names(res))
    expect_true("relevance_score_flood" %in% names(res))
    expect_true(is.numeric(res$relevance_score_road))
  })
})

# -- Live integration test ---------------------------------------------------

test_that("get_assessments('it') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("it", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "it")
    expect_identical(res$source_portal, "va.mite.gov.it")
    expect_true(grepl("^https://va\\.mite\\.gov\\.it/it-IT/Oggetti/Info/", res$url))
  })
})
