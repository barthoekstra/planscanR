# Tests for get_assessments_de(). Mirrors the NL handler's offline test
# strategy: parse a real detail page from a captured fixture, mock URL
# enumeration so no live HTTP is needed in CI.

read_de_fixture <- function(name) {
  rvest::read_html(fixture_path("de", name))
}

test_that("de_parse_detail extracts expected fields from a real UVP detail page", {
  local_mocked_bindings(
    perform_html = function(req) read_de_fixture("detail-walldurn-windpark.html"),
    req_planscanr = function(base_url, path = NULL) base_url
  )
  url <- "https://www.uvp-verbund.de/trefferanzeige?docuuid=a8837db3-a6e0-4aa9-b13a-c5d2735187cb"
  rec <- planscanR:::de_parse_detail(url)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "de")
  expect_identical(rec$source_portal, "uvp-verbund.de")
  expect_identical(rec$document_id, "a8837db3-a6e0-4aa9-b13a-c5d2735187cb")
  expect_match(rec$title, "Windpark Walld")
  expect_match(rec$summary, "^Die Firma WINDENERGIE")
  expect_match(rec$competent_authority, "Neckar-Odenwald")
  expect_identical(rec$jurisdiction, "Baden-Württemberg")
  expect_match(rec$native_type, "Bergbau und Energie")
  expect_identical(rec$date_decision, as.Date("2026-02-24"))

  # Per-section attachment split — counts taken from the captured fixture.
  expect_length(rec$attachment_urls_uvp_bericht[[1]], 1L)
  expect_length(rec$attachment_urls_berichte[[1]], 47L)
  expect_length(rec$attachment_urls_auslegung[[1]], 1L)
  expect_length(rec$attachment_urls_weitere[[1]], 78L)
  expect_length(rec$attachment_urls[[1]], 127L)
  # No URL appears in more than one section.
  by_section <- list(
    rec$attachment_urls_uvp_bericht[[1]],
    rec$attachment_urls_berichte[[1]],
    rec$attachment_urls_auslegung[[1]],
    rec$attachment_urls_weitere[[1]]
  )
  expect_identical(sum(lengths(by_section)), 127L)
  # All attachment URLs are absolute under the portal.
  expect_true(all(startsWith(rec$attachment_urls[[1]], "https://www.uvp-verbund.de/")))
})

test_that("de_section_pdfs returns empty character() for an unknown section", {
  html <- read_de_fixture("detail-walldurn-windpark.html")
  expect_identical(
    planscanR:::de_section_pdfs(html, "Diese Sektion existiert nicht"),
    character(0)
  )
})

test_that("de_section_slug curates known titles and auto-slugs the rest", {
  # Curated titles get their stable slug.
  expect_identical(
    planscanR:::de_section_slug("UVP-Bericht, ggf. Antragsunterlagen"),
    "uvp_bericht"
  )
  expect_identical(planscanR:::de_section_slug("Entscheidung"), "entscheidung")
  # Unknown titles are auto-slugged: German digraphs transliterated to ASCII,
  # lowercased, non-alphanumerics collapsed to single underscores.
  expect_identical(
    planscanR:::de_section_slug("Öffentliche Bekanntmachung"),
    "oeffentliche_bekanntmachung"
  )
  expect_identical(
    planscanR:::de_section_slug("Ergänzende Unterlagen / Nachträge"),
    "ergaenzende_unterlagen_nachtraege"
  )
})

test_that("de_document_section_titles lists distinct headings on a page", {
  html <- read_de_fixture("detail-walldurn-windpark.html")
  titles <- planscanR:::de_document_section_titles(html)
  expect_true(all(
    c(
      "UVP-Bericht, ggf. Antragsunterlagen",
      "Berichte und Empfehlungen",
      "Auslegungsinformationen",
      "Weitere Unterlagen"
    ) %in%
      titles
  ))
  expect_identical(titles, unique(titles))
})

test_that("de_parse_detail dynamically captures a non-curated section (Entscheidung)", {
  # Minimal synthetic page: one curated section + one previously-uncaptured
  # "Entscheidung" section. Confirms the parser discovers headings rather than
  # assuming a fixed set.
  synthetic <- paste0(
    "<html><body>",
    "<h1>Synthetischer Windpark Testvorhaben</h1>",
    "<h4 class='title-font'>UVP-Bericht, ggf. Antragsunterlagen</h4>",
    "<div><a class='link download' ",
    "href='/documents-ige-ng/igc_xx/aaaaaaaa-1111-2222-3333-444444444444/uvp_bericht.pdf'>UVP</a></div>",
    "<h4 class='title-font'>Entscheidung</h4>",
    "<div><a class='link download' ",
    "href='/documents-ige-ng/igc_xx/aaaaaaaa-1111-2222-3333-444444444444/bescheid.pdf'>Bescheid</a></div>",
    "</body></html>"
  )
  local_mocked_bindings(
    perform_html = function(req) rvest::read_html(synthetic),
    req_planscanr = function(base_url, path = NULL) base_url
  )
  rec <- planscanR:::de_parse_detail(
    "https://www.uvp-verbund.de/trefferanzeige?docuuid=aaaaaaaa-1111-2222-3333-444444444444"
  )
  # The non-curated section landed in its own column.
  expect_true("attachment_urls_entscheidung" %in% names(rec))
  expect_match(rec$attachment_urls_entscheidung[[1]], "bescheid\\.pdf$")
  expect_match(rec$attachment_urls_uvp_bericht[[1]], "uvp_bericht\\.pdf$")
  # Both URLs are in the deduplicated union, substantive (uvp_bericht) first.
  expect_length(rec$attachment_urls[[1]], 2L)
  expect_match(rec$attachment_urls[[1]][1], "uvp_bericht\\.pdf$")
})

test_that("de_parse_detail -> sidecar round-trip preserves a non-curated section tag", {
  fixture_synth <- paste0(
    "<html><body>",
    "<h1>Round-trip Test</h1>",
    "<h4 class='title-font'>Entscheidung</h4>",
    "<div><a class='link download' ",
    "href='/documents-ige-ng/igc_xx/aaaaaaaa-1111-2222-3333-444444444444/bescheid.pdf'>Bescheid</a></div>",
    "</body></html>"
  )
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    local_mocked_bindings(
      perform_html = function(req) rvest::read_html(fixture_synth),
      req_planscanr = function(base_url, path = NULL) base_url
    )
    rec <- planscanR:::de_parse_detail(
      "https://www.uvp-verbund.de/trefferanzeige?docuuid=bbbbbbbb-1111-2222-3333-444444444444"
    )
    rec <- planscanR:::de_finalise_record(
      rec,
      download = FALSE,
      overwrite = FALSE,
      max_file_size_mb = NULL,
      write_sidecar = TRUE
    )
    # index_cache fans the section tag back out into its own column.
    back <- index_cache(country = "de")
    expect_true("attachment_urls_entscheidung" %in% names(back))
    expect_match(back$attachment_urls_entscheidung[[1]], "bescheid\\.pdf$")
    # And the raw sidecar JSON carries the per-file section tag.
    sc <- list.files(
      file.path(getwd(), "cache", "files", "de"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE,
      full.names = TRUE
    )
    payload <- jsonlite::fromJSON(sc[[1]], simplifyVector = FALSE)
    sections <- vapply(
      payload$files,
      function(f) if (is.null(f$section)) NA_character_ else f$section,
      character(1)
    )
    expect_true("entscheidung" %in% sections)
  })
})

test_that("de_extract_uuids dedupes anchor pairs on the same record card", {
  html <- read_de_fixture("search-windenergie-page1.html")
  uuids <- planscanR:::de_extract_uuids(html)
  # Each result card has both a title and image anchor pointing to the same
  # docuuid. The dedupe pass collapses those to one per record.
  expect_gt(length(uuids), 1L)
  expect_lte(length(uuids), 10L)
  expect_identical(uuids, unique(uuids))
  expect_true(all(grepl("^[A-Fa-f0-9-]+$", uuids)))
})

test_that("de_docuuid_from_url extracts the uuid from a canonical URL", {
  expect_identical(
    planscanR:::de_docuuid_from_url(
      "https://www.uvp-verbund.de/trefferanzeige?docuuid=abc-123-def-456"
    ),
    "abc-123-def-456"
  )
  expect_identical(
    planscanR:::de_docuuid_from_url(
      "/trefferanzeige?docuuid=507710&q=foo&page=1"
    ),
    "507710"
  )
})

test_that("de_parse_german_date handles DD.MM.YYYY and rejects junk", {
  expect_identical(planscanR:::de_parse_german_date("24.02.2026"), as.Date("2026-02-24"))
  expect_identical(planscanR:::de_parse_german_date("1.1.2024"), as.Date("2024-01-01"))
  expect_true(is.na(planscanR:::de_parse_german_date(NA)))
  expect_true(is.na(planscanR:::de_parse_german_date("")))
  expect_true(is.na(planscanR:::de_parse_german_date("not a date")))
})

test_that("de_absolutise prefixes the portal host onto root-relative URLs", {
  expect_identical(
    planscanR:::de_absolutise("/documents-ige-ng/igc_bw/abc/foo.pdf"),
    "https://www.uvp-verbund.de/documents-ige-ng/igc_bw/abc/foo.pdf"
  )
  expect_identical(
    planscanR:::de_absolutise("https://example.org/foo.pdf"),
    "https://example.org/foo.pdf"
  )
})

test_that("de_record_matches honours date_range and jurisdiction filters", {
  rec <- tibble::tibble(
    title = "Windpark Foo",
    date_decision = as.Date("2024-06-15"),
    jurisdiction = "Baden-Württemberg"
  )
  expect_true(planscanR:::de_record_matches(rec, NULL, NULL))
  expect_true(planscanR:::de_record_matches(
    rec,
    as.Date(c("2024-01-01", "2024-12-31")),
    NULL
  ))
  expect_false(planscanR:::de_record_matches(
    rec,
    as.Date(c("2023-01-01", "2023-12-31")),
    NULL
  ))
  expect_true(planscanR:::de_record_matches(rec, NULL, "Baden"))
  expect_false(planscanR:::de_record_matches(rec, NULL, "Bayern"))
})

test_that("get_assessments_de end-to-end on the fixture (sidecar-first, no downloads)", {
  fixture_html_path <- normalizePath(fixture_path("de", "detail-walldurn-windpark.html"))
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    target_uuid <- "a8837db3-a6e0-4aa9-b13a-c5d2735187cb"

    local_mocked_bindings(
      # Returning the same uuid every page makes the streaming loop see it
      # once on page 1, then dedup-out on page 2 and terminate.
      de_search_page = function(query, page) target_uuid,
      perform_html = function(req) rvest::read_html(fixture_html_path)
    )

    res <- get_assessments_de(limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$document_id, target_uuid)

    # Sidecar was written during the first call.
    sidecars <- list.files(
      file.path(cache, "files", "de"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 1L)

    # Re-running with refresh = FALSE should now skip the network entirely —
    # the parse function must not be invoked.
    parse_calls <- 0L
    local_mocked_bindings(
      de_parse_detail = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("de_parse_detail should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_de(limit = 5, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 1L)
    expect_identical(res2$document_id, res$document_id)
    expect_length(res2$attachment_urls[[1]], 127L)
  })
})

test_that("get_assessments_de's relevance threshold gates PDFs only — not the result row", {
  fixture_html_path <- normalizePath(fixture_path("de", "detail-walldurn-windpark.html"))
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    reset_relevance_warnings()
    target_uuid <- "a8837db3-a6e0-4aa9-b13a-c5d2735187cb"

    local_mocked_bindings(
      de_search_page = function(query, page) target_uuid,
      perform_html = function(req) rvest::read_html(fixture_html_path)
    )

    res <- get_assessments_de(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = "Erntemaschine völlig anderer Stoff",
      relevance_threshold = 1.1, # impossible: still keeps the row
      relevance_model = make_fake_model()
    )
    expect_identical(nrow(res), 1L)
    expect_true("relevance_score_erntemaschine_v_llig_anderer_stoff" %in% names(res))
  })
})

test_that("DE -> sidecar round-trip preserves all four section list-columns", {
  fixture_html_path <- normalizePath(fixture_path("de", "detail-walldurn-windpark.html"))
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      perform_html = function(req) rvest::read_html(fixture_html_path),
      req_planscanr = function(base_url, path = NULL) base_url
    )

    rec <- planscanR:::de_parse_detail(
      "https://www.uvp-verbund.de/trefferanzeige?docuuid=a8837db3-a6e0-4aa9-b13a-c5d2735187cb"
    )
    rec <- planscanR:::de_finalise_record(
      rec,
      download = FALSE,
      overwrite = FALSE,
      max_file_size_mb = NULL,
      write_sidecar = TRUE
    )
    idx <- index_cache(country = "de")
    expect_identical(nrow(idx), 1L)
    # All four sections are restored from the sidecar JSON.
    expect_length(idx$attachment_urls_uvp_bericht[[1]], 1L)
    expect_length(idx$attachment_urls_berichte[[1]], 47L)
    expect_length(idx$attachment_urls_auslegung[[1]], 1L)
    expect_length(idx$attachment_urls_weitere[[1]], 78L)
    expect_length(idx$attachment_urls[[1]], 127L)
    # Extras carried through.
    expect_identical(idx$jurisdiction, "Baden-Württemberg")
    expect_match(idx$native_type, "Bergbau und Energie")
    # And the download_status is pending for every URL (no fetches yet).
    ds <- idx$download_status[[1]]
    expect_true(all(ds$status == "pending"))
    expect_length(ds$status, 127L)
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('de') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("de", limit = 1, query = "windenergie", download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "de")
    expect_identical(res$source_portal, "uvp-verbund.de")
    expect_true(startsWith(
      res$url,
      "https://www.uvp-verbund.de/trefferanzeige?docuuid="
    ))
  })
})
