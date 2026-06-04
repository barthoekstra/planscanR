# Tests for get_assessments_hr(). Offline strategy: stub `perform_html` to hand
# back the trimmed HTML fixtures so no live HTTP is needed in CI. Croatia has no
# API: each fixture is a handful of real inlined `<li><strong>` project blocks
# extracted from the live mzozt.gov.hr CMS master pages.
#  - PUO (EIA): puo-listing.html  (a wind farm with a .zip + multi-stage, a
#    fully-decided farm with all four stages, and a single-stage record)
#  - SPUO (SEA): spuo-listing.html  (two flat plans whose documents sit directly
#    under the title with no stage sub-heading)

hr_read_fixture_html <- function(name) {
  rvest::read_html(fixture_path("hr", name))
}

# Pre-load the fixtures once, at file-load time.
.hr_fix_puo <- hr_read_fixture_html("puo-listing.html")
.hr_fix_spuo <- hr_read_fixture_html("spuo-listing.html")

# A perform_html mock that serves the trimmed listing fixtures by register URL.
hr_mock_perform_html <- function() {
  function(req) {
    url <- req$url
    if (grepl("/4014", url)) {
      return(.hr_fix_puo)
    }
    if (grepl("/4037", url)) {
      return(.hr_fix_spuo)
    }
    if (grepl("/4038", url)) {
      # Other-competent SPUO page: empty in the fixture set.
      return(rvest::read_html("<html><body></body></html>"))
    }
    stop("Unexpected URL in test: ", url)
  }
}

# Helper: pull the n-th PUO/SPUO project block as a light index entry.
hr_entry_from_fixture <- function(html, register, i = 1L) {
  blocks <- planscanR:::hr_project_blocks(html)
  block <- blocks[[i]]
  title <- planscanR:::hr_block_title(block)
  document_id <- planscanR:::hr_document_id(register, title)
  page_url <- planscanR:::hr_register_urls(register)[[1]]
  list(
    register = register,
    document_id = document_id,
    url = planscanR:::hr_canonical_url(page_url, document_id),
    title = title,
    assessment_type = if (register == "PUO") "EIA" else "SEA",
    block = block
  )
}

# -- Light enumeration / id derivation --------------------------------------

test_that("hr_project_blocks selects the top-level project blocks", {
  puo <- planscanR:::hr_project_blocks(.hr_fix_puo)
  expect_identical(length(puo), 3L)
  spuo <- planscanR:::hr_project_blocks(.hr_fix_spuo)
  expect_identical(length(spuo), 2L)
})

test_that("hr_document_id is stable, prefixed, and folds in the year", {
  id1 <- planscanR:::hr_document_id("PUO", "Vjetroelektrana X, Grad Y")
  id2 <- planscanR:::hr_document_id("PUO", "Vjetroelektrana X, Grad Y")
  expect_identical(id1, id2) # deterministic
  expect_match(id1, "^HR-PUO-[0-9a-f]{10}$")

  sea <- planscanR:::hr_document_id("SPUO", "Plan upravljanja 2022.-2027.")
  expect_match(sea, "^HR-SPUO-[0-9a-f]{10}-2027$") # latest year folded in

  # Whitespace/casing normalisation makes the hash insensitive to noise.
  a <- planscanR:::hr_document_id("PUO", "  Foo   Bar ")
  b <- planscanR:::hr_document_id("PUO", "Foo Bar")
  expect_identical(a, b)
})

test_that("hr_stage_slug curates known PUO stages and auto-slugs the rest", {
  # Curated, robust to &nbsp; / casing / diacritics.
  expect_identical(
    planscanR:::hr_stage_slug("PUO informacija o zahtjevu"),
    "informacija_o_zahtjevu"
  )
  expect_identical(
    planscanR:::hr_stage_slug("PUO javni uvid"),
    "javni_uvid"
  )
  expect_identical(
    planscanR:::hr_stage_slug("PUO nacrt rješenja"),
    "nacrt_rjesenja"
  )
  expect_identical(planscanR:::hr_stage_slug("PUO RJEŠENJE"), "rjesenje")
  # Auto-slug for an unknown heading (diacritics transliterated).
  expect_identical(
    planscanR:::hr_stage_slug("PUO obavijest o vraćanju"),
    "puo_obavijest_o_vracanju"
  )
  # Empty / missing -> deterministic fallback.
  expect_identical(planscanR:::hr_stage_slug(NULL), "document")
  expect_identical(planscanR:::hr_stage_slug(NA_character_), "document")
  expect_identical(planscanR:::hr_stage_slug(""), "document")
})

test_that("hr_parse_dates extracts DD.MM.YYYY prefixes", {
  d <- planscanR:::hr_parse_dates(c(
    "14.10.2025. - INFORMACIJA",
    "no date here",
    "03.02.2025. - Studija"
  ))
  expect_identical(sort(d), as.Date(c("2025-02-03", "2025-10-14")))
  expect_identical(planscanR:::hr_parse_dates(character(0)), as.Date(character(0)))
})

# -- Parse a full PUO block --------------------------------------------------

test_that("hr_parse_block extracts PUO (EIA) fields, dates, and stage slugs", {
  entry <- hr_entry_from_fixture(.hr_fix_puo, "PUO", 1L) # wind farm w/ .zip
  rec <- planscanR:::hr_parse_block(entry)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "hr")
  expect_identical(rec$source_portal, "mzozt.gov.hr")
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "PUO")
  expect_match(rec$document_id, "^HR-PUO-")
  expect_identical(rec$url, entry$url)
  expect_match(rec$title, "Vjetroelektrana")
  # competent_authority is the Ministry constant for PUO.
  expect_match(rec$competent_authority, "Ministarstvo")
  # date_published = earliest doc date; the wind farm started 29.09.2023.
  expect_identical(rec$date_published, as.Date("2023-09-29"))
  # jurisdiction heuristically pulled from the title.
  expect_match(rec$jurisdiction, "Otočac")
  expect_match(rec$jurisdiction, "županija")
  # No summary / proponent on the CMS page.
  expect_true(is.na(rec$summary))
  expect_true(is.na(rec$proponent))

  # Per-stage attachment columns with curated slugs.
  expect_true("attachment_urls_informacija_o_zahtjevu" %in% names(rec))
  expect_true("attachment_urls_javni_uvid" %in% names(rec))
  # The union holds every document (5 javni_uvid + 1 informacija).
  urls <- rec$attachment_urls[[1]]
  expect_identical(length(urls), 6L)
  expect_true(all(grepl("^https://mzozt\\.gov\\.hr/", urls)))
  # The .zip attachment is captured verbatim (with its diacritics).
  expect_true(any(grepl("\\.zip$", urls)))
  # No geometry columns are ever emitted for HR.
  expect_false("geometry_path" %in% names(rec))
  expect_false("geometry_crs" %in% names(rec))
})

test_that("hr_parse_block detects the decision date + decided status", {
  entry <- hr_entry_from_fixture(.hr_fix_puo, "PUO", 2L) # fully-decided farm
  rec <- planscanR:::hr_parse_block(entry)
  expect_match(rec$title, "farme za intenzivan tov svinja")
  # Has all four PUO stages.
  for (slug in c(
    "informacija_o_zahtjevu",
    "javni_uvid",
    "nacrt_rjesenja",
    "rjesenje"
  )) {
    expect_true(paste0("attachment_urls_", slug) %in% names(rec))
  }
  # The RJEŠENJE document carries the decision date.
  expect_identical(rec$date_decision, as.Date("2026-04-30"))
  expect_identical(rec$status, "decided")
})

# -- Parse a flat SPUO block -------------------------------------------------

test_that("hr_parse_block handles flat SPUO (SEA) blocks with no stage heading", {
  entry <- hr_entry_from_fixture(.hr_fix_spuo, "SPUO", 2L) # flat plan
  rec <- planscanR:::hr_parse_block(entry)
  expect_identical(rec$assessment_type, "SEA")
  expect_identical(rec$register, "SPUO")
  expect_match(rec$title, "Plan upravljanja vodnim područjima")
  # Flat documents fall under the "document" slug.
  expect_true("attachment_urls_document" %in% names(rec))
  expect_false("attachment_urls_javni_uvid" %in% names(rec))
  urls <- rec$attachment_urls[[1]]
  expect_gte(length(urls), 8L)
  expect_true(any(grepl("\\.zip$", urls)))
})

# -- Filters -----------------------------------------------------------------

test_that("hr_title_matches honours the client-side query filter", {
  expect_true(planscanR:::hr_title_matches("Vjetroelektrana X", NULL))
  expect_true(planscanR:::hr_title_matches("Vjetroelektrana X", ""))
  expect_true(planscanR:::hr_title_matches("Vjetroelektrana X", "vjetro"))
  expect_false(planscanR:::hr_title_matches("Vjetroelektrana X", "solarna"))
  expect_false(planscanR:::hr_title_matches(NA_character_, "vjetro"))
})

test_that("hr_record_matches honours the date_range filter", {
  rec <- tibble::tibble(date_published = as.Date("2023-09-29"))
  expect_true(planscanR:::hr_record_matches(rec, NULL))
  expect_true(planscanR:::hr_record_matches(
    rec,
    as.Date(c("2023-01-01", "2023-12-31"))
  ))
  expect_false(planscanR:::hr_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31"))
  ))
})

test_that("hr_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::hr_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::hr_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::hr_normalise_assessment_type("all"), "All")
  expect_identical(planscanR:::hr_normalise_assessment_type("EIA"), "EIA")
  expect_identical(planscanR:::hr_normalise_assessment_type("sea"), "SEA")
  expect_error(planscanR:::hr_normalise_assessment_type("nope"))
})

# -- End-to-end with sidecar -------------------------------------------------

test_that("get_assessments_hr end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_html = hr_mock_perform_html())

    res <- get_assessments_hr(limit = 50, download = FALSE)
    # 3 PUO + 2 SPUO records.
    expect_identical(nrow(res), 5L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$assessment_type, c("EIA", "SEA"))
    expect_true(all(grepl("^HR-(PUO|SPUO)-", res$document_id)))
    expect_true(all(grepl("^https://mzozt\\.gov\\.hr/.*#HR-", res$url)))

    # Every record's sidecar landed on disk.
    sidecars <- list.files(
      file.path(cache, "files", "hr"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 5L)

    # Second call with refresh = FALSE must NOT re-invoke hr_parse_block.
    parse_calls <- 0L
    local_mocked_bindings(
      hr_parse_block = function(...) {
        parse_calls <<- parse_calls + 1L
        stop("hr_parse_block should not have been called on a cached URL")
      }
    )
    res2 <- get_assessments_hr(limit = 50, download = FALSE)
    expect_identical(parse_calls, 0L)
    expect_identical(nrow(res2), 5L)
    expect_setequal(res2$document_id, res$document_id)
  })
})

test_that("get_assessments_hr honours the assessment_type filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_html = hr_mock_perform_html())

    res_eia <- get_assessments_hr(assessment_type = "EIA", download = FALSE)
    expect_identical(nrow(res_eia), 3L)
    expect_true(all(res_eia$assessment_type == "EIA"))

    res_sea <- get_assessments_hr(assessment_type = "SEA", download = FALSE)
    expect_identical(nrow(res_sea), 2L)
    expect_true(all(res_sea$assessment_type == "SEA"))
  })
})

test_that("get_assessments_hr honours the client-side query filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_html = hr_mock_perform_html())

    res <- get_assessments_hr(query = "vjetroelektrana", download = FALSE)
    expect_identical(nrow(res), 1L)
    expect_match(res$title, "Vjetroelektrana")
  })
})

test_that("get_assessments_hr respects the date_range filter", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_html = hr_mock_perform_html())

    # Only the wind farm starts in 2023 (29.09.2023).
    res <- get_assessments_hr(
      assessment_type = "EIA",
      date_range = c("2023-01-01", "2023-12-31"),
      download = FALSE
    )
    expect_identical(nrow(res), 1L)
    expect_match(res$title, "Vjetroelektrana")
  })
})

# -- Sidecar round-trip ------------------------------------------------------

test_that("HR -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_html = hr_mock_perform_html())

    res <- get_assessments_hr(limit = 50, download = FALSE)
    idx <- index_cache(country = "hr")
    expect_identical(nrow(idx), 5L)

    # Country-specific scalars round-trip through extras{}.
    expect_true("register" %in% names(idx))
    expect_true("assessment_type" %in% names(idx))
    expect_true("native_type" %in% names(idx))
    expect_setequal(idx$register, c("PUO", "SPUO"))
    expect_setequal(idx$assessment_type, c("EIA", "SEA"))
    # Per-section attachment URL columns survive too.
    expect_true(any(grepl("^attachment_urls_", names(idx))))
  })
})

# -- Relevance scoring -------------------------------------------------------

test_that("get_assessments_hr scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(perform_html = hr_mock_perform_html())

    res <- get_assessments_hr(
      limit = 50,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(wind = "vjetroelektrana", plan = "plan upravljanja"),
      relevance_model = make_fake_model(languages = c("hr", "en"))
    )
    expect_identical(nrow(res), 5L)
    expect_true("relevance_score_wind" %in% names(res))
    expect_true("relevance_score_plan" %in% names(res))
    expect_true(is.numeric(res$relevance_score_wind))
  })
})

# -- Live integration test ---------------------------------------------------

test_that("get_assessments('hr') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("hr", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "hr")
    expect_identical(res$source_portal, "mzozt.gov.hr")
    expect_true(grepl("^https://mzozt\\.gov\\.hr/", res$url))
  })
})
