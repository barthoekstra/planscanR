# Schema v3 contract (docs/spec/contract.md §2):
#   1. on-disk paths (files[].local_path, geometry_path) stored RELATIVE to the
#      cache root and absolutised on read;
#   2. extras{} no longer duplicates relevance_score_* (relevance_scores[] is
#      canonical);
#   3. datetime fields carry a trailing Z, and legacy non-Z values still read;
#   4. v1 (no version field) and v2 sidecars still read (back-compat).

read_raw_sidecar <- function(path) jsonlite::fromJSON(path, simplifyVector = FALSE)

test_that("files[].local_path is stored relative to the cache root, absolutised on read", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    root <- getwd()
    abs_pdf <- file.path(root, "files", "nl", "relpath1", "a.pdf")

    rec <- tibble::tibble(
      country = "nl",
      source_portal = "x",
      document_id = "relpath1",
      url = "https://x/relpath1",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list("https://x/a.pdf"),
      local_path = list(abs_pdf)
    )
    downloads <- tibble::tibble(
      url = "https://x/a.pdf",
      local_path = abs_pdf,
      status = "downloaded",
      size_bytes = 1,
      sha256 = "aa",
      reason = NA_character_
    )
    path <- planscanR:::write_record_sidecar(rec, downloads)

    raw <- read_raw_sidecar(path)
    json_lp <- raw$files[[1]]$local_path
    expect_false(startsWith(json_lp, "/")) # not absolute
    expect_identical(json_lp, file.path("files", "nl", "relpath1", "a.pdf"))

    back <- planscanR:::read_record_sidecar(path)
    bp <- back$download_status[[1]]$local_path
    expect_true(startsWith(bp, "/")) # absolutised back to a working path
    expect_match(bp, "files/nl/relpath1/a\\.pdf$")
    expect_match(back$local_path[[1]], "files/nl/relpath1/a\\.pdf$")
  })
})

test_that("geometry_path is stored relative to the cache root, absolutised on read", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    root <- getwd()
    abs_geo <- file.path(root, "files", "ie", "geo1", "geo1.geometry.geojson")

    rec <- tibble::tibble(
      country = "ie",
      source_portal = "x",
      document_id = "geo1",
      url = "https://x/geo1",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      geometry_path = abs_geo,
      geometry_crs = "EPSG:2157"
    )
    path <- planscanR:::write_record_sidecar(rec)

    raw <- read_raw_sidecar(path)
    expect_identical(
      raw$extras$geometry_path,
      file.path("files", "ie", "geo1", "geo1.geometry.geojson")
    )

    back <- planscanR:::read_record_sidecar(path)
    expect_true(startsWith(back$geometry_path, "/"))
    expect_match(back$geometry_path, "files/ie/geo1/geo1\\.geometry\\.geojson$")
  })
})

test_that("extras{} no longer duplicates relevance_score_* (relevance_scores[] is canonical)", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "x",
      document_id = "score1",
      url = "https://x/score1",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      relevance_score_wind = 0.65,
      relevance_score_solar = 0.42,
      relevance_model = "fake-bow"
    )
    path <- planscanR:::write_record_sidecar(rec)

    raw <- read_raw_sidecar(path)
    # canonical array carries the scores
    topics <- vapply(raw$relevance_scores, function(e) e$topic, character(1))
    expect_setequal(topics, c("wind", "solar"))
    # ...but extras must NOT carry them as duplicate keys
    expect_null(raw$extras$relevance_score_wind)
    expect_null(raw$extras$relevance_score_solar)

    # round-trip still reconstructs the per-topic columns
    back <- planscanR:::read_record_sidecar(path)
    expect_equal(back$relevance_score_wind, 0.65)
    expect_equal(back$relevance_score_solar, 0.42)
  })
})

test_that("re-scoring a v2 sidecar drops its stale extras relevance_score_* duplicate", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    path <- planscanR:::sidecar_path("nl", "rescore1")
    # Legacy v2 sidecar carrying the v2 duplication bug: the score lives BOTH in
    # the canonical array and (stale) in extras.
    v2 <- list(
      schema_version = 2L,
      country = "nl",
      source_portal = "x",
      document_id = "rescore1",
      url = "https://x/rescore1",
      retrieved_at = "2024-01-01T00:00:00Z",
      relevance_model = "old",
      relevance_scores = list(list(
        topic = "wind",
        score = 0.5,
        model = "old",
        scored_at = "2024-01-01T00:00:00Z"
      )),
      extras = list(relevance_score_wind = 0.5),
      files = list()
    )
    writeLines(jsonlite::toJSON(v2, auto_unbox = TRUE, null = "null"), path)

    # Re-score under v3 with a NEW value; merge must not resurrect the stale 0.5.
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "x",
      document_id = "rescore1",
      url = "https://x/rescore1",
      retrieved_at = as.POSIXct("2026-01-01", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      relevance_score_wind = 0.8,
      relevance_model = "new"
    )
    planscanR:::write_record_sidecar(rec)

    raw <- read_raw_sidecar(path)
    expect_null(raw$extras$relevance_score_wind) # stale duplicate gone on disk
    back <- planscanR:::read_record_sidecar(path)
    expect_equal(back$relevance_score_wind, 0.8) # canonical value wins
  })
})

test_that("datetime fields are written with a trailing Z", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "x",
      document_id = "ts1",
      url = "https://x/ts1",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      relevance_score_wind = 0.5,
      relevance_model = "m",
      class_label = "wind",
      class_relevant = TRUE,
      class_score = 0.9,
      class_score_wind = 0.9,
      class_model = "clf"
    )
    path <- planscanR:::write_record_sidecar(rec)
    raw <- read_raw_sidecar(path)
    expect_match(raw$retrieved_at, "Z$")
    expect_match(raw$relevance_scores[[1]]$scored_at, "Z$")
    expect_match(raw$classification$classified_at, "Z$")
  })
})

test_that("legacy v2 sidecar with a non-Z timestamp and absolute path still reads", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    path <- planscanR:::sidecar_path("nl", "legacy2")
    payload <- list(
      schema_version = 2L,
      country = "nl",
      source_portal = "x",
      document_id = "legacy2",
      url = "https://x/legacy2",
      retrieved_at = "2024-01-02T03:04:05", # legacy, no trailing Z
      files = list(list(
        url = "https://x/a.pdf",
        local_path = "/abs/legacy/a.pdf", # legacy absolute path
        status = "downloaded"
      ))
    )
    writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"), path)

    back <- planscanR:::read_record_sidecar(path)
    expect_s3_class(back$retrieved_at, "POSIXct")
    expect_false(is.na(back$retrieved_at)) # tolerant parse of non-Z value
    # an already-absolute legacy path is returned unchanged
    expect_identical(back$download_status[[1]]$local_path, "/abs/legacy/a.pdf")
  })
})

test_that("legacy v1 sidecar (no schema_version field) still reads", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    path <- planscanR:::sidecar_path("nl", "legacyv1")
    payload <- list(
      country = "nl",
      source_portal = "x",
      document_id = "legacyv1",
      url = "https://x/legacyv1",
      retrieved_at = "2024-01-02T03:04:05Z",
      files = list()
    )
    writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"), path)

    back <- planscanR:::read_record_sidecar(path)
    expect_identical(back$country, "nl")
    expect_identical(nrow(back), 1L)
  })
})
