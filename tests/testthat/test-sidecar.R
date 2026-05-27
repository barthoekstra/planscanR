test_that("sidecar round-trip preserves multi-topic relevance scores", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    rec <- tibble::tibble(
      country = "nl", source_portal = "commissiemer.nl",
      document_id = "9988",
      url = "https://www.commissiemer.nl/advies/multi-topic-test/",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      attachment_urls_source = list(character(0)),
      attachment_urls_advice = list(character(0)),
      local_path = list(character(0)),
      local_path_source = list(character(0)),
      local_path_advice = list(character(0)),
      title = "Multi-topic test",
      summary = NA_character_,
      competent_authority = NA_character_,
      proponent = NA_character_,
      date_decision = as.Date(NA),
      relevance_score_wind = 0.65,
      relevance_score_solar = 0.42,
      relevance_model = "fake-bow"
    )
    path <- planscanR:::write_record_sidecar(rec)
    back <- planscanR:::read_record_sidecar(path)
    expect_true("relevance_score_wind" %in% names(back))
    expect_true("relevance_score_solar" %in% names(back))
    expect_equal(back$relevance_score_wind, 0.65)
    expect_equal(back$relevance_score_solar, 0.42)
  })
})

test_that("sidecar round-trip preserves the record schema and metadata", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    rec <- tibble::tibble(
      country = "nl",
      source_portal = "commissiemer.nl",
      document_id = "9999",
      url = "https://www.commissiemer.nl/advies/sidecar-test/",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(c("https://x/a.pdf", "https://x/b.pdf")),
      attachment_urls_source = list("https://x/a.pdf"),
      attachment_urls_advice = list("https://x/b.pdf"),
      local_path = list(c("/tmp/a.pdf", "/tmp/b.pdf")),
      local_path_source = list("/tmp/a.pdf"),
      local_path_advice = list("/tmp/b.pdf"),
      title = "Test record",
      summary = "Korte beschrijving.",
      competent_authority = "Provincie X",
      proponent = "Some B.V.",
      date_decision = as.Date("2024-06-01")
    )
    downloads <- tibble::tibble(
      url = c("https://x/a.pdf", "https://x/b.pdf"),
      local_path = c("/tmp/a.pdf", "/tmp/b.pdf"),
      status = c("downloaded", "cached"),
      size_bytes = c(1234, 5678),
      sha256 = c("aa", "bb"),
      reason = c(NA_character_, NA_character_)
    )
    path <- planscanR:::write_record_sidecar(rec, downloads)
    expect_true(file.exists(path))

    back <- planscanR:::read_record_sidecar(path)
    expect_identical(back$country, "nl")
    expect_identical(back$document_id, "9999")
    expect_identical(back$summary, "Korte beschrijving.")
    expect_identical(back$date_decision, as.Date("2024-06-01"))
    expect_setequal(back$attachment_urls_source[[1]], "https://x/a.pdf")
    expect_setequal(back$attachment_urls_advice[[1]], "https://x/b.pdf")
    expect_identical(back$download_status[[1]]$status, c("downloaded", "cached"))
    expect_identical(back$download_status[[1]]$size_bytes, c(1234, 5678))
  })
})

test_that("index_cache returns the empty schema when the cache is missing", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    out <- index_cache()
    expect_s3_class(out, "tbl_df")
    expect_identical(nrow(out), 0L)
    expect_true(all(planscanR:::required_columns() %in% names(out)))
  })
})

test_that("index_cache reads back every sidecar under the cache root", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mk_record <- function(doc_id) {
      tibble::tibble(
        country = "nl",
        source_portal = "commissiemer.nl",
        document_id = doc_id,
        url = paste0("https://www.commissiemer.nl/advies/", doc_id, "/"),
        retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
        attachment_urls = list(character(0)),
        attachment_urls_source = list(character(0)),
        attachment_urls_advice = list(character(0)),
        local_path = list(character(0)),
        local_path_source = list(character(0)),
        local_path_advice = list(character(0)),
        title = paste("Record", doc_id),
        summary = NA_character_,
        competent_authority = NA_character_,
        proponent = NA_character_,
        date_decision = as.Date(NA)
      )
    }
    planscanR:::write_record_sidecar(mk_record("1001"))
    planscanR:::write_record_sidecar(mk_record("1002"))

    idx <- index_cache()
    expect_identical(nrow(idx), 2L)
    expect_setequal(idx$document_id, c("1001", "1002"))
    expect_setequal(idx$title, c("Record 1001", "Record 1002"))

    # country filter
    idx_nl <- index_cache(country = "nl")
    expect_identical(nrow(idx_nl), 2L)
    idx_de <- index_cache(country = "de")
    expect_identical(nrow(idx_de), 0L)
  })
})
