# Offline tests for download_to_cache()'s network branches.
#
# The HTTP seam is mocked: planscanR internals (head_content_length,
# req_planscanr) via .package = "planscanR", and the httr2 calls
# (req_perform, resp_header) via .package = "httr2". A mocked req_perform
# writes synthetic bytes to its `path` argument so the rest of the function
# (size cap, finalize_extension, file_sha256) runs against a real file.

PDF_MAGIC <- as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34)) # %PDF-1.4

test_that("download_to_cache downloads, finalizes, and checksums", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform = function(req, path = NULL, ...) {
        writeBin(PDF_MAGIC, path)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/pdf",
      .package = "httr2"
    )

    out <- download_to_cache(
      "https://example.org/files/nl/1234/report.pdf",
      "nl",
      "1234"
    )
    expect_identical(out$status, "downloaded")
    expect_false(is.na(out$local_path))
    expect_true(file.exists(out$local_path))
    expect_gt(out$size_bytes, 0)
    expect_match(out$sha256, "^[0-9a-f]{64}$")
    expect_identical(out$sha256, planscanR:::file_sha256(out$local_path))
  })
})

test_that("download_to_cache skips via the HEAD size cap before fetching", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    perform_called <- FALSE
    local_mocked_bindings(
      head_content_length = function(url) 999999999,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform = function(req, path = NULL, ...) {
        perform_called <<- TRUE
        writeBin(PDF_MAGIC, path)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/pdf",
      .package = "httr2"
    )

    url <- "https://example.org/files/nl/1234/big.pdf"
    dest <- cache_path(url, "nl", "1234")
    out <- download_to_cache(url, "nl", "1234", max_file_size_mb = 0.0001)

    expect_identical(out$status, "skipped_size")
    expect_true(is.na(out$local_path))
    expect_false(perform_called)
    expect_false(file.exists(dest))
  })
})

test_that("download_to_cache discards an over-cap file after download", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # cap of 0.0001 MiB ~= 104 bytes; write well over that.
    big_n <- 4096L
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform = function(req, path = NULL, ...) {
        writeBin(as.raw(rep(0L, big_n)), path)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/pdf",
      .package = "httr2"
    )

    url <- "https://example.org/files/nl/1234/big.pdf"
    dest <- cache_path(url, "nl", "1234")
    out <- download_to_cache(url, "nl", "1234", max_file_size_mb = 0.0001)

    expect_identical(out$status, "skipped_size")
    expect_true(is.na(out$local_path))
    expect_false(file.exists(dest))
  })
})

test_that("download_to_cache reports failure and leaves no 0-byte file", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform = function(req, path = NULL, ...) stop("boom"),
      resp_header = function(resp, header, ...) "application/pdf",
      .package = "httr2"
    )

    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234")
    out <- download_to_cache(url, "nl", "1234")

    expect_identical(out$status, "failed")
    expect_match(out$reason, "boom")
    expect_true(is.na(out$local_path))
    expect_false(file.exists(dest))
  })
})

test_that("download_to_cache with overwrite re-fetches an existing file", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234")
    # Pre-existing finalized file.
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D, 0x31)), dest)

    perform_called <- FALSE
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform = function(req, path = NULL, ...) {
        perform_called <<- TRUE
        writeBin(PDF_MAGIC, path)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/pdf",
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", overwrite = TRUE)
    expect_identical(out$status, "downloaded")
    expect_true(perform_called)
  })
})

test_that("download_to_cache finalizes the extension for a no-extension URL", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform = function(req, path = NULL, ...) {
        writeBin(PDF_MAGIC, path)
        structure(list(), class = "httr2_response")
      },
      # NULL Content-Type forces the magic-byte sniff path.
      resp_header = function(resp, header, ...) NULL,
      .package = "httr2"
    )

    # No file extension in the path -> cache_path yields a `.x` placeholder.
    url <- "https://kotkas.envir.ee/kmh/kmh_file_download?kmh_id=44&attachment_id=12345"
    dest <- cache_path(url, "ee", "KMH-44")
    expect_identical(tools::file_ext(dest), "x")

    out <- download_to_cache(url, "ee", "KMH-44")
    expect_identical(out$status, "downloaded")
    expect_match(out$local_path, "\\.pdf$")
    expect_true(file.exists(out$local_path))
  })
})
