test_that("sidecar round-trip preserves multi-topic relevance scores", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "commissiemer.nl",
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

test_that("index_cache row transforms run before bounded binding and default output is unchanged", {
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
        attachment_urls = list(c("https://fixture/", doc_id, ".pdf")),
        attachment_urls_source = list(c("https://fixture/source/", doc_id, ".pdf")),
        local_path = list(NA_character_),
        local_path_source = list(NA_character_),
        title = paste("Record", doc_id),
        summary = "Fixture",
        competent_authority = NA_character_,
        proponent = NA_character_,
        date_decision = as.Date(NA)
      )
    }
    planscanR:::write_record_sidecar(mk_record("1001"))
    planscanR:::write_record_sidecar(mk_record("1002"))
    planscanR:::write_record_sidecar(mk_record("1003"))

    baseline <- index_cache(batch_size = 1L)
    default <- index_cache()
    sidecars <- list.files(
      file.path(getwd(), "files"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE,
      full.names = TRUE
    )
    prior_path <- do.call(
      planscanR:::bind_results,
      lapply(sidecars, planscanR:::read_record_sidecar)
    )
    expect_identical(default, baseline)
    expect_identical(default, prior_path)
    expect_identical(baseline, prior_path)

    seen <- character(0)
    projected <- index_cache(
      row_transform = function(record) {
        seen <<- c(seen, record$document_id[[1L]])
        record$transformed <- TRUE
        record
      },
      batch_size = 2L
    )
    expect_identical(seen, baseline$document_id)
    expect_true(all(projected$transformed))
    expect_identical(projected$document_id, baseline$document_id)
    expect_identical(projected$attachment_urls, baseline$attachment_urls)
  })
})

test_that("index_cache projects heterogeneous section rows in bounded batches", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    for (i in seq_len(1000L)) {
      record <- tibble::tibble(
        country = if (i %% 2L == 0L) "nl" else "de",
        source_portal = "commissiemer.nl",
        document_id = sprintf("stress-%04d", i),
        url = paste0("https://fixture/", i),
        retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
        attachment_urls = list(character(0)),
        local_path = list(character(0)),
        title = paste("Record", i),
        summary = "heterogeneous section fixture",
        competent_authority = NA_character_,
        proponent = NA_character_,
        date_decision = as.Date(NA)
      )
      section <- paste0("attachment_urls_section_", i)
      record[[section]] <- list(paste0("https://fixture/section/", i, ".pdf"))
      planscanR:::write_record_sidecar(record)
    }

    seen <- 0L
    original_bind <- planscanR:::bind_results
    bind_widths <- list()
    bind_seen <- integer(0)
    bind_names <- list()
    bind_spy <- function(...) {
      args <- rlang::list2(...)
      bind_widths[[length(bind_widths) + 1L]] <<-
        vapply(args, ncol, integer(1))
      bind_seen <<- c(bind_seen, seen)
      bind_names[[length(bind_names) + 1L]] <<-
        unique(unlist(lapply(args, names), use.names = FALSE))
      do.call(original_bind, args)
    }
    local_mocked_bindings(bind_results = bind_spy, .package = "planscanR")
    projected <- index_cache(
      batch_size = 64L,
      row_transform = function(record) {
        seen <<- seen + 1L
        record$projected_id <- record$document_id
        record[c(
          "country", "source_portal", "document_id", "url", "retrieved_at",
          "attachment_urls", "local_path", "projected_id"
        )]
      }
    )
    expect_identical(seen, 1000L)
    expect_identical(nrow(projected), 1000L)
    expect_true(all(projected$projected_id == projected$document_id))
    expect_identical(length(names(projected)), 8L)
    expect_identical(length(bind_widths), 17L)
    expect_identical(bind_seen[[1L]], 64L)
    expect_true(all(vapply(bind_widths, function(widths) all(widths <= 8L), logical(1))))
    expect_false(any(grepl("^attachment_urls_section_", unlist(bind_names))))
  })
})

test_that("index_cache rejects malformed row transforms outside read warnings", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    record <- tibble::tibble(
      country = "nl",
      source_portal = "commissiemer.nl",
      document_id = "1001",
      url = "https://fixture/1001",
      retrieved_at = as.POSIXct("2026-05-26 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      title = "Record 1001",
      summary = "Fixture",
      competent_authority = NA_character_,
      proponent = NA_character_,
      date_decision = as.Date(NA)
    )
    planscanR:::write_record_sidecar(record)
    record$document_id <- "1002"
    planscanR:::write_record_sidecar(record)

    expect_error(
      index_cache(row_transform = function(x) x[rep(1L, 2L), , drop = FALSE]),
      class = "planscanR_error_bad_input"
    )
    expect_error(
      index_cache(row_transform = function(x) stop("transform failed")),
      "transform failed"
    )
    expect_error(
      index_cache(
        batch_size = 2L,
        row_transform = function(x) {
          if (identical(x$document_id[[1L]], "1002")) {
            x$country <- NULL
          }
          x
        }
      ),
      class = "planscanR_error_bad_schema"
    )
    expect_error(
      index_cache(row_transform = 1L),
      class = "planscanR_error_bad_input"
    )
    expect_error(
      index_cache(batch_size = 0L),
      class = "planscanR_error_bad_input"
    )
  })
})

test_that("write_record_sidecar never drops on-disk data it isn't given", {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    urls <- c("https://h/x/a.pdf", "https://h/x/b.pdf")

    # 1. Scan-shaped write: attachment URLs (pending) + metadata.
    rec1 <- tibble::tibble(
      country = "de",
      source_portal = "uvp-verbund.de",
      document_id = "keep-1",
      url = "https://h/trefferanzeige?docuuid=keep-1",
      retrieved_at = as.POSIXct("2026-05-28 12:00:00", tz = "UTC"),
      attachment_urls = list(urls),
      attachment_urls_uvp_bericht = list(urls),
      local_path = list(rep(NA_character_, 2)),
      title = "Windpark X",
      summary = "WEA",
      native_type = "Windkraftanlagen",
      download_status = list(planscanR:::pending_download_status(urls))
    )
    planscanR:::write_record_sidecar(rec1, downloads = rec1$download_status[[1]])

    # 2. Classify-shaped write: a record with NO file/title/summary info,
    #    only a classification verdict. Must NOT wipe the attachment URLs.
    rec2 <- tibble::tibble(
      country = "de",
      source_portal = "uvp-verbund.de",
      document_id = "keep-1",
      url = "https://h/trefferanzeige?docuuid=keep-1",
      retrieved_at = as.POSIXct("2026-05-28 13:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      class_label = "wind",
      class_relevant = TRUE,
      class_score = 0.9,
      class_score_wind = 0.9,
      download_status = list(planscanR:::empty_download_status())
    )
    planscanR:::write_record_sidecar(rec2)

    back <- index_cache(country = "de")
    # Attachments survive the classify-shaped write...
    expect_length(back$attachment_urls[[1]], 2L)
    expect_true("attachment_urls_uvp_bericht" %in% names(back))
    # ...the title/summary/category survive (rec2 didn't carry them)...
    expect_identical(back$title, "Windpark X")
    expect_identical(back$summary, "WEA")
    expect_identical(back$native_type, "Windkraftanlagen")
    # ...and the new classification verdict is added.
    expect_identical(back$class_label, "wind")
    expect_true(back$class_relevant)
  })
})

test_that("write_record_sidecar updates same-URL file rows in place (new wins)", {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    urls <- c("https://h/x/a.pdf", "https://h/x/b.pdf")
    rec <- tibble::tibble(
      country = "de",
      source_portal = "uvp-verbund.de",
      document_id = "upd-1",
      url = "https://h/trefferanzeige?docuuid=upd-1",
      retrieved_at = as.POSIXct("2026-05-28 12:00:00", tz = "UTC"),
      attachment_urls = list(urls),
      attachment_urls_uvp_bericht = list(urls),
      local_path = list(rep(NA_character_, 2)),
      title = "X",
      summary = NA_character_,
      download_status = list(planscanR:::pending_download_status(urls))
    )
    planscanR:::write_record_sidecar(rec, downloads = rec$download_status[[1]])

    # "Download" the first file: a row for url a.pdf now downloaded.
    ds <- tibble::tibble(
      url = urls[1],
      local_path = "/tmp/a.pdf",
      status = "downloaded",
      size_bytes = 123,
      sha256 = "abc",
      reason = NA_character_
    )
    rec$download_status <- list(ds)
    planscanR:::write_record_sidecar(rec, downloads = ds)

    back <- index_cache(country = "de")
    dl <- back$download_status[[1]]
    # Both URLs still present; a.pdf is now downloaded, b.pdf still pending.
    expect_length(back$attachment_urls[[1]], 2L)
    expect_identical(dl$status[dl$url == urls[1]], "downloaded")
    expect_identical(dl$status[dl$url == urls[2]], "pending")
  })
})

test_that("sidecar schema assertion accepts current/legacy and rejects newer", {
  # v3 (current), v2, and v1 (no version field) read without warning.
  expect_no_warning(planscanR:::assert_sidecar_schema(list(schema_version = 3L)))
  expect_no_warning(planscanR:::assert_sidecar_schema(list(schema_version = 2L)))
  expect_no_warning(planscanR:::assert_sidecar_schema(list()))
  # A newer sidecar than this planscanR understands fails loudly.
  expect_error(
    planscanR:::assert_sidecar_schema(list(schema_version = 4L), "/tmp/x.meta.json"),
    class = "planscanR_error_sidecar_schema"
  )
  # read_record_sidecar applies the assertion on a real file.
  withr::with_tempdir({
    p <- file.path(getwd(), "rec.meta.json")
    writeLines(jsonlite::toJSON(list(schema_version = 99L, files = list()), auto_unbox = TRUE), p)
    expect_error(
      planscanR:::read_record_sidecar(p),
      class = "planscanR_error_sidecar_schema"
    )
  })
})

test_that("date_published round-trips as Date (type-stable across cached + fresh)", {
  # date_published is the one conventional date column that travels through
  # extras{} rather than a first-class sidecar field. Without coercion on read
  # it comes back as character, so a bind_rows() over a mix of cached and
  # freshly-parsed records aborts with a Date-vs-character class mismatch.
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    mk <- function(id, dp) {
      tibble::tibble(
        country = "zz",
        source_portal = "x",
        document_id = id,
        url = paste0("http://x/", id),
        retrieved_at = as.POSIXct("2025-01-01", tz = "UTC"),
        attachment_urls = list(character(0)),
        local_path = list(character(0)),
        title = id,
        date_published = dp,
        date_decision = as.Date(NA),
        download_status = list(planscanR:::empty_download_status())
      )
    }
    planscanR:::write_record_sidecar(mk("A", as.Date("2025-01-22")))
    planscanR:::write_record_sidecar(mk("B", as.Date(NA)))

    back_a <- planscanR:::read_record_sidecar(planscanR:::sidecar_path("zz", "A"))
    back_b <- planscanR:::read_record_sidecar(planscanR:::sidecar_path("zz", "B"))
    expect_s3_class(back_a$date_published, "Date")
    expect_identical(back_a$date_published, as.Date("2025-01-22"))
    expect_s3_class(back_b$date_published, "Date")
    expect_true(is.na(back_b$date_published))

    # The actual failure mode: binding a cached record (read back) with a
    # freshly-parsed one must not abort.
    fresh <- mk("C", as.Date("2025-03-15"))
    expect_no_error(dplyr::bind_rows(back_a, fresh))
  })
})
