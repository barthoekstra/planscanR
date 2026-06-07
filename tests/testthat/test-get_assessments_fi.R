# Tests for get_assessments_fi(). Offline strategy: this handler is a hybrid —
# an Elasticsearch (JSON) listing call gives all metadata, then a per-record
# HTML landing-page fetch harvests the attachment URLs (they are NOT in the
# index). We mock the two seams independently:
#   - fi_es_search(body)  -> recorded ES listing JSON (listing-yva-page0.json)
#   - perform_html(req)    -> recorded landing-page HTML (detail-<id>.html)
#
# Fixtures:
#   listing-yva-page0.json : 3 YVA hits — 1498 (Konnunsuo, peat), 1600
#     (Varpusuo, peat), 1004 (Purmon tuulivoimapuisto, a wind project used for
#     the query filter). Only 1498 + 1600 have detail-page fixtures.
#   detail-1498.html / detail-1600.html : trimmed landing pages with the
#     /sites/default/files/ document anchors.

fi_read_listing <- function() {
  jsonlite::fromJSON(fixture_path("fi", "listing-yva-page0.json"), simplifyVector = FALSE)
}
fi_read_detail <- function(name) {
  rvest::read_html(fixture_path("fi", name))
}

# Pre-load fixtures at file-load time so they resolve before any with_tempdir().
.fi_fix_listing <- fi_read_listing()
.fi_fix_detail_1498 <- fi_read_detail("detail-1498.html")
.fi_fix_detail_1600 <- fi_read_detail("detail-1600.html")
# Landing page that renders a project description in `.page-content__content
# .text-long`, plus a decoy `.text-long` in the footer (issue #11).
.fi_fix_detail_summary <- fi_read_detail("detail-summary.html")

# Empty ES envelope to terminate from-paging cleanly.
.fi_fix_listing_empty <- list(
  took = 0L,
  hits = list(total = list(value = 3L, relation = "eq"), hits = list())
)

# The three _source objects, keyed by id, for synthetic single-record mocks.
.fi_src_by_id <- local({
  out <- list()
  for (h in .fi_fix_listing$hits$hits) {
    out[[h$`_source`$id]] <- h$`_source`
  }
  out
})

mock_fi_es_search_full <- function() {
  # Page 0 returns all 3 hits; any later from returns the empty envelope.
  function(body) {
    if (identical(as.integer(body$from %||% 0L), 0L)) {
      return(.fi_fix_listing)
    }
    .fi_fix_listing_empty
  }
}

mock_fi_perform_html <- function() {
  function(req) {
    url <- req$url
    if (grepl("konnunsuon-turvetuotantoalue", url)) {
      return(.fi_fix_detail_1498)
    }
    if (grepl("varpusuon-turvetuotantohanke", url)) {
      return(.fi_fix_detail_1600)
    }
    # The third listing row (Purmon, 1004) has no detail fixture; a date_range
    # filter that drops the first two records still walks to it, so serve an
    # attachment-less landing page rather than erroring.
    rvest::read_html(
      "<html><head><meta charset=\"utf-8\"></head><body>no documents</body></html>"
    )
  }
}

# ---------------------------------------------------------------------------
# Parse / build unit tests
# ---------------------------------------------------------------------------

test_that("fi_build_record maps ES _source fields onto record columns", {
  src <- .fi_src_by_id[["1498"]]
  url <- planscanR:::fi_canonical_url(src$link)
  per_section <- planscanR:::fi_parse_detail(.fi_fix_detail_1498)
  rec <- planscanR:::fi_build_record(url, src, per_section)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "fi")
  expect_identical(rec$source_portal, "ymparisto.fi")
  expect_identical(rec$document_id, "YVA-1498")
  expect_identical(rec$url, url)
  expect_match(rec$url, "^https://www\\.ymparisto\\.fi/")
  expect_match(rec$title, "Konnunsuon")
  # EIA/YVA-only register.
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$type_label, "YVA-hanke")
  # No structured proponent / decision in the index.
  expect_true(is.na(rec$proponent))
  expect_true(is.na(rec$date_decision))
  # competent_authority + jurisdiction composed from the index arrays.
  expect_true(nzchar(rec$competent_authority))
  expect_true(nzchar(rec$jurisdiction))
  expect_true(nzchar(rec$status))
})

test_that("fi_parse_detail scrapes /sites/default/files/ anchors and types them", {
  per_section <- planscanR:::fi_parse_detail(.fi_fix_detail_1498)
  union <- unique(unlist(per_section, use.names = FALSE))
  # 5 document anchors in the fixture.
  expect_length(union, 5L)
  # All resolve to absolute ymparisto.fi /sites/default/files/ URLs.
  expect_true(all(grepl(
    "^https://www\\.ymparisto\\.fi/sites/default/files/",
    union
  )))
  # CSS asset under /files/css/ (in <head>, a <link> not an <a>) is excluded.
  expect_false(any(grepl("/files/css/", union)))
  # Curated slugs from anchor text: tiivistelmä->summary, kuulutus->notice,
  # lausunto->statement, arviointiselostus->report.
  expect_true("summary" %in% names(per_section))
  expect_true("notice" %in% names(per_section))
  expect_true("statement" %in% names(per_section))
  expect_true("report" %in% names(per_section))
})

test_that("fi_build_record exposes per-section attachment columns", {
  src <- .fi_src_by_id[["1498"]]
  url <- planscanR:::fi_canonical_url(src$link)
  per_section <- planscanR:::fi_parse_detail(.fi_fix_detail_1498)
  rec <- planscanR:::fi_build_record(url, src, per_section)

  expect_true("attachment_urls_report" %in% names(rec))
  expect_true("attachment_urls_summary" %in% names(rec))
  expect_true("attachment_urls_statement" %in% names(rec))
  # The union equals the deduped concatenation of all per-section columns.
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)
  pieces <- unlist(lapply(section_cols, function(cn) rec[[cn]][[1]]), use.names = FALSE)
  expect_setequal(rec$attachment_urls[[1]], unique(pieces))
})

# ---------------------------------------------------------------------------
# Detail-page summary fallback (issue #11)
# ---------------------------------------------------------------------------

test_that("fi_parse_summary extracts the content-region prose, not the footer", {
  summary <- planscanR:::fi_parse_summary(.fi_fix_detail_summary)
  expect_match(summary, "^Australialaisyhtiö Critical Metals Ltd")
  # Multiple <p> are joined and runs of whitespace (incl. newlines) collapsed.
  expect_match(summary, "Hankkeen tarkoituksena on vanadiinipentoksidin")
  expect_false(grepl("\n", summary))
  expect_false(grepl("  ", summary))
  # The footer .text-long boilerplate must NOT leak into the summary.
  expect_false(grepl("Julkaisemme ymparisto", summary))
})

test_that("fi_parse_summary returns NA when the content region has no text-long", {
  # The 1498 fixture has document anchors but no `.page-content__content
  # .text-long` block.
  expect_true(is.na(planscanR:::fi_parse_summary(.fi_fix_detail_1498)))
})

test_that("fi_build_record falls back to the detail summary only when the index description is empty", {
  src <- .fi_src_by_id[["1498"]]
  url <- planscanR:::fi_canonical_url(src$link)
  per_section <- planscanR:::fi_parse_detail(.fi_fix_detail_1498)
  detail_summary <- "Detail-page project description."

  # Index description present -> it wins; detail summary is ignored.
  rec_idx <- planscanR:::fi_build_record(url, src, per_section, detail_summary = detail_summary)
  expect_match(rec_idx$summary, "Tarkoituksena on aloittaa tuotanto")

  # Index description empty -> fall back to the detail-page summary.
  src_empty <- src
  src_empty$description <- ""
  rec_fb <- planscanR:::fi_build_record(url, src_empty, per_section, detail_summary = detail_summary)
  expect_identical(rec_fb$summary, detail_summary)

  # Neither index description nor detail summary -> NA (valid).
  rec_na <- planscanR:::fi_build_record(url, src_empty, per_section, detail_summary = NA_character_)
  expect_true(is.na(rec_na$summary))
})

test_that("get_assessments_fi backfills summary from the detail page when the index omits it", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # One record whose ES index `description` is empty; the detail page renders
    # the project prose in `.page-content__content .text-long`.
    src_empty <- .fi_src_by_id[["1498"]]
    src_empty$description <- ""
    local_mocked_bindings(
      fi_es_search = function(body) {
        if (identical(as.integer(body$from %||% 0L), 0L)) {
          hit <- list(`_index` = "search-fi", `_id` = "1498", `_source` = src_empty)
          return(list(
            took = 0L,
            hits = list(total = list(value = 1L, relation = "eq"), hits = list(hit))
          ))
        }
        .fi_fix_listing_empty
      },
      perform_html = function(req) .fi_fix_detail_summary
    )

    res <- get_assessments_fi(limit = 1, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_match(res$summary, "^Australialaisyhtiö Critical Metals Ltd")
  })
})

test_that("fi_section_slug uses the curated keyword map + auto-slug fallback", {
  expect_identical(planscanR:::fi_section_slug("Arviointiohjelma"), "programme")
  expect_identical(planscanR:::fi_section_slug("Arviointiselostus"), "report")
  expect_identical(planscanR:::fi_section_slug("Yhteysviranomaisen lausunto"), "statement")
  expect_identical(planscanR:::fi_section_slug("Kuulutus"), "notice")
  expect_identical(planscanR:::fi_section_slug("Arviointiohjelman Tiivistelmä"), "summary")
  # Auto-slug fallback for an unknown anchor text (diacritics folded).
  expect_identical(planscanR:::fi_section_slug("Liite 1 Kartta"), "liite_1_kartta")
  # Edge cases.
  expect_identical(planscanR:::fi_section_slug(NULL), "document")
  expect_identical(planscanR:::fi_section_slug(NA_character_), "document")
  expect_identical(planscanR:::fi_section_slug(""), "document")
})

test_that("fi_normalise_assessment_type accepts only All/EIA (no SEA)", {
  expect_identical(planscanR:::fi_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::fi_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::fi_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::fi_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::fi_normalise_assessment_type("eia"), "EIA")
  # No SEA in the Finnish register.
  expect_error(
    planscanR:::fi_normalise_assessment_type("SEA"),
    class = "planscanR_error_bad_input"
  )
})

test_that("fi_epoch_to_date converts unix seconds to a Date", {
  expect_identical(
    planscanR:::fi_epoch_to_date(1721813845),
    as.Date(as.POSIXct(1721813845, origin = "1970-01-01", tz = "UTC"))
  )
  expect_true(is.na(planscanR:::fi_epoch_to_date(NULL)))
  expect_true(is.na(planscanR:::fi_epoch_to_date(NA)))
})

test_that("fi_canonical_url resolves relative links against the portal base", {
  expect_identical(
    planscanR:::fi_canonical_url("/fi/x/y"),
    "https://www.ymparisto.fi/fi/x/y"
  )
  expect_identical(
    planscanR:::fi_canonical_url("https://www.ymparisto.fi/fi/x/y"),
    "https://www.ymparisto.fi/fi/x/y"
  )
  expect_true(is.na(planscanR:::fi_canonical_url(NULL)))
  expect_true(is.na(planscanR:::fi_canonical_url(NA_character_)))
})

test_that("fi_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2011-01-11"))
  expect_true(planscanR:::fi_record_matches(rec, NULL))
  expect_true(planscanR:::fi_record_matches(rec, as.Date(c("2011-01-01", "2011-12-31"))))
  expect_false(planscanR:::fi_record_matches(rec, as.Date(c("2020-01-01", "2020-12-31"))))
  expect_false(planscanR:::fi_record_matches(
    tibble::tibble(date_published = as.Date(NA)),
    as.Date(c("2011-01-01", "2011-12-31"))
  ))
})

# ---------------------------------------------------------------------------
# End-to-end (both seams mocked)
# ---------------------------------------------------------------------------

test_that("get_assessments_fi end-to-end on fixtures (sidecar-first, no geometry)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # Only 1498 + 1600 have detail fixtures; cap at 2 so we never reach the
    # detail-less Purmon (1004) row.
    local_mocked_bindings(
      fi_es_search = mock_fi_es_search_full(),
      perform_html = mock_fi_perform_html()
    )

    res <- get_assessments_fi(limit = 2, download = FALSE)
    expect_identical(nrow(res), 2L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("YVA-1498", "YVA-1600"))
    expect_true(all(startsWith(res$url, "https://www.ymparisto.fi/")))
    # Attachment URLs were populated from the HTML even with download = FALSE.
    expect_true(all(vapply(res$attachment_urls, length, integer(1)) > 0L))
    # No geometry columns are emitted.
    expect_false("geometry_path" %in% names(res))

    # Both sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "fi"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 2L)

    # Second call with refresh = FALSE must NOT re-fetch / re-parse the detail
    # page (sidecar-first). Stub both the detail fetch + the parse to prove it.
    detail_calls <- 0L
    local_mocked_bindings(
      fi_fetch_detail = function(...) {
        detail_calls <<- detail_calls + 1L
        stop("fi_fetch_detail should not be called on a cached URL")
      },
      fi_parse_detail = function(...) {
        detail_calls <<- detail_calls + 1L
        stop("fi_parse_detail should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_fi(limit = 2, download = FALSE)
    expect_identical(detail_calls, 0L)
    expect_identical(nrow(res2), 2L)
    expect_setequal(res2$document_id, c("YVA-1498", "YVA-1600"))
  })
})

test_that("get_assessments_fi honours the query filter (server-side ES match)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # The query is server-side: the ES seam decides what comes back. Return
    # only the wind project (Purmon, 1004) when the query mentions tuulivoima.
    captured_body <- NULL
    local_mocked_bindings(
      fi_es_search = function(body) {
        captured_body <<- body
        if (identical(as.integer(body$from %||% 0L), 0L)) {
          hit <- list(`_index` = "search-fi", `_id` = "1004", `_source` = .fi_src_by_id[["1004"]])
          return(list(
            took = 0L,
            hits = list(total = list(value = 1L, relation = "eq"), hits = list(hit))
          ))
        }
        .fi_fix_listing_empty
      },
      perform_html = function(req) {
        # Purmon has no detail fixture; return an attachment-less landing page.
        rvest::read_html("<html><body><div>no documents</div></body></html>")
      }
    )

    res <- get_assessments_fi(query = "tuulivoima", limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_identical(res$document_id, "YVA-1004")
    # The query was threaded into the ES body as a multi_match.
    expect_false(is.null(captured_body$query$bool$must))
  })
})

test_that("get_assessments_fi honours the date_range filter (client-side)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      fi_es_search = mock_fi_es_search_full(),
      perform_html = mock_fi_perform_html()
    )

    # 1498 (Konnunsuo) publishTime is 2015-11; 1600 (Varpusuo) is 2009-12. A
    # 2009-2016 window keeps both; a 2020 window drops everything.
    res_in <- get_assessments_fi(
      date_range = c("2009-01-01", "2016-12-31"),
      limit = 2,
      download = FALSE
    )
    expect_identical(nrow(res_in), 2L)

    res_out <- get_assessments_fi(
      date_range = c("2020-01-01", "2020-12-31"),
      limit = 2,
      download = FALSE
    )
    expect_identical(nrow(res_out), 0L)
  })
})

test_that("FI -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      fi_es_search = mock_fi_es_search_full(),
      perform_html = mock_fi_perform_html()
    )

    res <- get_assessments_fi(limit = 2, download = FALSE)
    idx <- index_cache(country = "fi")
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c("YVA-1498", "YVA-1600"))

    # The per-section attachment columns survive the round-trip.
    expect_true("attachment_urls_report" %in% names(idx))
    expect_true("attachment_urls_summary" %in% names(idx))
    # Country-specific extras (typeLabel, subjectArea) round-trip via extras{}.
    expect_true(all(idx$type_label == "YVA-hanke"))
    expect_true("subject_area" %in% names(idx))
    expect_true(all(idx$assessment_type == "EIA"))
  })
})

test_that("get_assessments_fi scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      fi_es_search = mock_fi_es_search_full(),
      perform_html = mock_fi_perform_html()
    )

    res <- get_assessments_fi(
      limit = 2,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "wind energy", peat = "peat extraction"),
      relevance_model = make_fake_model(languages = c("fi", "en"))
    )
    expect_identical(nrow(res), 2L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_peat" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('fi') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("fi", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "fi")
    expect_identical(res$source_portal, "ymparisto.fi")
    expect_true(startsWith(res$url, "https://www.ymparisto.fi/"))
  })
})
