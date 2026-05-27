# Tests for the attachment-discovery pipeline. Uses the mock search backend
# to keep CI offline; uses small synthetic PDFs created on the fly to keep
# the fixture tree small.

# ---- helpers --------------------------------------------------------------

make_at_record <- function(
  document_id = "9999",
  title = "Windpark Testdorf",
  aktenzahl = "02 9999",
  summary = "Die Energie Testdorf GmbH plant Windkraftanlagen in Testdorf.",
  jurisdiction = "Burgenland",
  year = 2024L,
  attachment_urls = list(character(0)),
  local_path = list(character(0))
) {
  tibble::tibble(
    country = "at",
    source_portal = "umweltbundesamt.at/uvpdb",
    document_id = document_id,
    url = sprintf("https://secure.umweltbundesamt.at/uvpdb/maps/?v2id=%s", document_id),
    retrieved_at = as.POSIXct("2026-05-27T12:00:00", tz = "UTC"),
    attachment_urls = attachment_urls,
    local_path = local_path,
    title = title,
    summary = summary,
    competent_authority = NA_character_,
    proponent = NA_character_,
    date_decision = as.Date(NA),
    native_type = "Windkraftanlagen",
    jurisdiction = jurisdiction,
    status = "bewilligt",
    aktenzahl = aktenzahl,
    year = year,
    download_status = list(empty_download_status())
  )
}

# Build a syntactically-valid 1-page PDF containing a single text string,
# small enough to ship through tests without fixtures. Returns a temp path.
make_text_pdf <- function(text) {
  path <- tempfile(fileext = ".pdf")
  esc <- gsub("\\\\", "\\\\\\\\", text)
  esc <- gsub("\\(", "\\\\(", esc)
  esc <- gsub("\\)", "\\\\)", esc)
  content_stream <- sprintf("BT /F1 12 Tf 50 750 Td (%s) Tj ET\n", esc)
  content_len <- nchar(content_stream, type = "bytes")

  pdf <- paste0(
    "%PDF-1.4\n",
    "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
    "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
    "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>\nendobj\n",
    sprintf("4 0 obj\n<< /Length %d >>\nstream\n", content_len),
    content_stream,
    "endstream\nendobj\n",
    "5 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
    "xref\n0 6\n0000000000 65535 f \n",
    "trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n0\n%%EOF\n"
  )
  writeBin(charToRaw(pdf), path)
  path
}

# ---- search_backend S3 ----------------------------------------------------

test_that("search_backend() validates inputs and dispatches via web_search()", {
  expect_error(search_backend(name = NULL, search_fn = function(...) list()))
  expect_error(search_backend(name = "x", search_fn = "not a function"))

  fixed <- list(list(url = "https://x.example/a.pdf", title = "A"))
  b <- search_backend("test", function(query, include_domains, max_results) fixed)
  expect_s3_class(b, "planscanR_search_backend")
  expect_identical(backend_name(b), "test")
  expect_identical(web_search(b, "anything"), fixed)
})

test_that("search_backend_mock matches by exact key, then substring, then default", {
  m <- search_backend_mock(list(
    "windpark parndorf" = list(list(url = "https://x/parndorf.pdf")),
    "kittsee" = list(list(url = "https://x/kittsee.pdf")),
    "_default" = list()
  ))
  expect_identical(web_search(m, "windpark parndorf")[[1]]$url, "https://x/parndorf.pdf")
  # Substring fallback for "...kittsee...".
  expect_identical(web_search(m, "Windpark Kittsee Bescheid")[[1]]$url, "https://x/kittsee.pdf")
  # Default for unmatched.
  expect_identical(web_search(m, "no match here"), list())
})

# ---- at_discovery_config ---------------------------------------------------

test_that("at_discovery_config() exposes the documented contract", {
  cfg <- at_discovery_config()
  expect_true(all(c("query_templates", "state_domains", "aktenzahl_regex",
                    "extract_proponent", "extra_signals") %in% names(cfg)))
  expect_true(length(cfg$query_templates) >= 3L)
  expect_true("Burgenland" %in% names(cfg$state_domains))
  expect_true("_federal" %in% names(cfg$state_domains))
  expect_true("burgenland.at" %in% cfg$state_domains$Burgenland)
})

test_that("at_clean_title strips parenthesised aliases and normalises whitespace", {
  expect_identical(planscanR:::at_clean_title("Windpark Neusiedl-Weiden Repowering (WP NDWE)"),
                   "Windpark Neusiedl-Weiden Repowering")
  expect_identical(planscanR:::at_clean_title("  Spaces   inside  "), "Spaces inside")
  expect_null(planscanR:::at_clean_title(NA))
})

test_that("at_extract_proponent_from_summary pulls the GmbH from the opener", {
  s <- "Die Energie Burgenland Windkraft GmbH plant das Repowering des Windparks."
  expect_identical(planscanR:::at_extract_proponent_from_summary(s),
                   "Energie Burgenland Windkraft GmbH")
  expect_true(is.na(planscanR:::at_extract_proponent_from_summary(NA)))
  expect_true(is.na(planscanR:::at_extract_proponent_from_summary("")))
})

test_that("at_domains_for unions multi-state jurisdictions and adds _federal", {
  cfg <- at_discovery_config()
  rec_bgld <- make_at_record(jurisdiction = "Burgenland")
  d <- planscanR:::at_domains_for(rec_bgld, cfg)
  expect_true("burgenland.at" %in% d)
  expect_true("ris.bka.gv.at" %in% d)

  rec_multi <- make_at_record(jurisdiction = "Niederösterreich, Wien")
  d2 <- planscanR:::at_domains_for(rec_multi, cfg)
  expect_true("noe.gv.at" %in% d2)
  expect_true("wien.gv.at" %in% d2)
  expect_true("ris.bka.gv.at" %in% d2)
})

# ---- discover_validate -----------------------------------------------------

test_that("discover_validate passes on Aktenzahl exact match", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  rec <- make_at_record(aktenzahl = "02 0515")
  pdf <- make_text_pdf("Bescheid betreffend GZ: 02 0515 Windpark Parndorf")
  on.exit(unlink(pdf), add = TRUE)
  v <- discover_validate(rec, pdf, at_discovery_config())
  expect_true(v$passed)
  expect_true(v$signals[["az"]])
})

test_that("discover_validate passes on >=2 distinguishing-token occurrences", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  rec <- make_at_record(
    title = "Windpark Markgrafneusiedl Repowering",
    aktenzahl = "02 0482"
  )
  # Two mentions of the distinguishing token "Markgrafneusiedl" — clears the
  # validator's >=2-occurrence rule that exists to filter 1-mention gazettes.
  pdf <- make_text_pdf(
    "Windpark Markgrafneusiedl Bescheid 2024. Markgrafneusiedl Standort."
  )
  on.exit(unlink(pdf), add = TRUE)
  v <- discover_validate(rec, pdf, at_discovery_config())
  expect_true(v$passed)
  expect_true(v$signals[["title"]])
})

test_that("discover_validate rejects a single-hit gazette-style false positive", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  rec <- make_at_record(
    title = "Windpark Markgrafneusiedl Repowering",
    aktenzahl = "02 0482"
  )
  # Single passing mention of the distinguishing token — should NOT pass.
  pdf <- make_text_pdf(
    "Amtliche Mitteilungen 2024. Bescheid Windpark Markgrafneusiedl genehmigt."
  )
  on.exit(unlink(pdf), add = TRUE)
  v <- discover_validate(rec, pdf, at_discovery_config())
  expect_false(v$passed)
})

test_that("discover_validate rejects a long-but-thin document (Dürnkrut-like)", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  rec <- make_at_record(
    title = "Windpark Spannberg II",
    aktenzahl = "02 0430"
  )
  # Two Spannberg mentions in the extracted text BUT we pretend this PDF is
  # 100 pages long so the density is 2/10 = 0.2. Under the old >=2 rule
  # this passed; under the hybrid rule the density check must catch it.
  pdf <- make_text_pdf(
    "Einreichoperat Windpark Andersdorf. Vorhaben Andersdorf. Andersdorf.
     ... Vergleichbar mit Spannberg-Cluster. ... Spannberg ist nicht Thema."
  )
  on.exit(unlink(pdf), add = TRUE)
  local_mocked_bindings(
    pdf_page_count = function(path) 100L
  )
  v <- discover_validate(rec, pdf, at_discovery_config())
  expect_false(v$passed)
})

test_that("discover_validate keeps a short-but-dense document (Kundmachung-like)", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  rec <- make_at_record(
    title = "Windpark Spannberg II",
    aktenzahl = "02 0430"
  )
  # Three Spannberg mentions in a 1-page Kundmachung => density 3/1 = 3.0.
  # Should pass the hybrid rule's density branch even though absolute < 5.
  pdf <- make_text_pdf(
    "Kundmachung Windpark Spannberg II: Bescheid genehmigt. Standort Spannberg.
     Antragsteller plant Repowering in Spannberg. UVP-G 2000."
  )
  on.exit(unlink(pdf), add = TRUE)
  v <- discover_validate(rec, pdf, at_discovery_config())
  expect_true(v$passed)
})

test_that("discover_validate rejects an unrelated document", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  rec <- make_at_record(title = "Windpark Parndorf", aktenzahl = "02 0132")
  pdf <- make_text_pdf("Autobahn-Westring S31 Streckenfuehrung Klagenfurt-Velden")
  on.exit(unlink(pdf), add = TRUE)
  v <- discover_validate(rec, pdf, at_discovery_config())
  expect_false(v$passed)
})

# ---- discover_attachments end-to-end --------------------------------------

# Tiny embedded HTTP server for the validation step's PDF downloads.
# httr2's mocking layer is fine for this — we install a hook for the duration
# of the test that returns a real bytestream for our fake-PDF URL.
with_fake_pdf_server <- function(url_to_pdf_path, code) {
  # Mock req_perform: when the URL matches a key, write the PDF bytes to the
  # requested path and return a minimal httr2_response stub. Otherwise pass
  # through to the actual implementation.
  real <- httr2::req_perform
  hook <- function(req, path = NULL, ...) {
    if (req$url %in% names(url_to_pdf_path) && !is.null(path)) {
      file.copy(url_to_pdf_path[[req$url]], path, overwrite = TRUE)
      structure(
        list(url = req$url, status_code = 200L, headers = list()),
        class = "httr2_response"
      )
    } else if (req$method == "HEAD") {
      # HEAD probe: synthesise a Content-Length of the file size if known.
      sz <- if (req$url %in% names(url_to_pdf_path)) {
        as.character(file.info(url_to_pdf_path[[req$url]])$size)
      } else {
        ""
      }
      structure(
        list(
          url = req$url,
          status_code = 200L,
          headers = if (nzchar(sz)) list(`Content-Length` = sz) else list()
        ),
        class = "httr2_response"
      )
    } else {
      real(req, path = path, ...)
    }
  }
  testthat::local_mocked_bindings(req_perform = hook, .package = "httr2")
  code
}

test_that("discover_attachments end-to-end: discovers, validates, writes sidecar", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")

  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    good_pdf <- make_text_pdf(
      "Bescheid betreffend Windpark Testdorf GZ: 02 9999 Energie Testdorf GmbH"
    )
    on.exit(unlink(good_pdf), add = TRUE)

    backend <- search_backend_mock(list(
      "_default" = list(
        list(
          url = "https://burgenland.at/uvp/testdorf-bescheid.pdf",
          title = "Bescheid Windpark Testdorf",
          content = "Bescheid betreffend Windpark Testdorf",
          score = 0.9
        )
      )
    ))

    rec <- make_at_record()

    res <- with_fake_pdf_server(
      url_to_pdf_path = list("https://burgenland.at/uvp/testdorf-bescheid.pdf" = good_pdf),
      discover_attachments(
        rec,
        backend = backend,
        queries_per_record = 2L,
        max_pdfs_per_record = 5L
      )
    )

    # The record now has the new URL as an attachment.
    expect_length(res$attachment_urls[[1]], 1L)
    expect_identical(
      res$attachment_urls[[1]],
      "https://burgenland.at/uvp/testdorf-bescheid.pdf"
    )
    # And the PDF landed in the cache.
    cached <- res$local_path[[1]][1]
    expect_true(file.exists(cached))
    expect_true(grepl("/files/at/9999/", cached, fixed = TRUE))
    # The sidecar exists and contains the discovery_log + discovery-source file.
    sidecar <- file.path(cache, "files", "at", "9999", "9999.meta.json")
    expect_true(file.exists(sidecar))
    payload <- jsonlite::fromJSON(sidecar, simplifyVector = FALSE)
    expect_true(length(payload$discovery_log) >= 1L)
    sources <- vapply(payload$files, function(f) f$source %||% "", character(1))
    expect_true("discovery" %in% sources)
  })
})

test_that("discover_attachments respects skip_if_attached", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  backend <- search_backend_mock(list(
    "_default" = list(list(url = "https://x/should-never-be-called.pdf"))
  ))
  rec <- make_at_record(
    attachment_urls = list("https://existing.example/file.pdf"),
    local_path = list("/some/local/path.pdf")
  )
  # No file copies happen, but the function should return without error and
  # without expanding attachment_urls.
  res <- discover_attachments(rec, backend = backend, dry_run = TRUE)
  expect_identical(length(res$attachment_urls[[1]]), 1L)
})

test_that("discover_attachments(dry_run = TRUE) does not touch the cache", {
  skip_if_not(nzchar(Sys.which("pdftotext")), "pdftotext not installed")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    good_pdf <- make_text_pdf(
      "Windpark Testdorf Bescheid Energie Testdorf GmbH Aktenzahl 02 9999"
    )
    on.exit(unlink(good_pdf), add = TRUE)

    backend <- search_backend_mock(list(
      "_default" = list(
        list(url = "https://burgenland.at/uvp/testdorf-2.pdf", title = "")
      )
    ))

    rec <- make_at_record()
    res <- with_fake_pdf_server(
      url_to_pdf_path = list("https://burgenland.at/uvp/testdorf-2.pdf" = good_pdf),
      discover_attachments(rec, backend = backend, dry_run = TRUE,
                           queries_per_record = 1L)
    )
    # No cache files written.
    expect_false(dir.exists(file.path(cache, "files", "at", "9999")))
    # But the discovery_log captured the would-be promotion.
    expect_true(length(res$discovery_log[[1]]) >= 1L)
  })
})
