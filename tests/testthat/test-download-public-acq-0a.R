# Failure fixtures for ACQ-0a reliable download publication.

ACQ0A_PDF_MAGIC <- as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3))

test_that("an interrupted nonempty transfer preserves the verified copy", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    writeBin(charToRaw("verified copy"), dest)

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(charToRaw("partial response"))
        stop("simulated transfer interruption")
      },
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root, overwrite = TRUE)

    expect_identical(out$status, "failed")
    expect_match(out$reason, "simulated transfer interruption")
    expect_identical(readBin(dest, "raw", n = file.info(dest)$size), charToRaw("verified copy"))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})

test_that("a nonempty file without a publication receipt is not a cache hit", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    writeBin(ACQ0A_PDF_MAGIC, dest)
    fetched <- FALSE

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        fetched <<- TRUE
        callback(ACQ0A_PDF_MAGIC)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root)

    expect_true(fetched)
    expect_identical(out$status, "downloaded")
    expect_true(file.exists(planscanR:::download_receipt_path(dest)))
  })
})

test_that("HTML login/error bodies are rejected before publication", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(charToRaw("<html><body>login required</body></html>"))
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "text/html" else NA_character_
      },
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root)

    expect_identical(out$status, "failed")
    expect_match(out$reason, "HTML|attachment|content", ignore.case = TRUE)
    expect_true(is.na(out$local_path))
    expect_false(file.exists(dest))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})

test_that("pretty-printed JSON error bodies are rejected for extensionless URLs", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/error"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(charToRaw('{\n  "error": "Unauthorized"\n}'))
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/json" else NA_character_
      },
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root)

    expect_identical(out$status, "failed")
    expect_match(out$reason, "error|response|attachment", ignore.case = TRUE)
    expect_true(is.na(out$local_path))
    expect_false(file.exists(dest))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})

test_that("a mismatched GET length is rejected without publishing bytes", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(ACQ0A_PDF_MAGIC)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) return("application/pdf")
        if (identical(tolower(header), "content-length")) return("999")
        NA_character_
      },
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root)

    expect_identical(out$status, "failed")
    expect_match(out$reason, "length|Content-Length", ignore.case = TRUE)
    expect_false(file.exists(dest))
  })
})

test_that("compressed response lengths are not treated as decoded byte proofs", {
  local_mocked_bindings(
    resp_header = function(resp, header, ...) {
      if (identical(tolower(header), "content-encoding")) return("gzip")
      if (identical(tolower(header), "content-length")) return("12")
      NA_character_
    },
    .package = "httr2"
  )

  expect_true(is.na(planscanR:::response_content_length(structure(list(), class = "httr2_response"))))
})

test_that("streamed bytes exceeding the cap remain only in staging and are cleaned", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/big.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    chunks_sent <- 0L
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        for (chunk in list(as.raw(rep(0L, 80L)), as.raw(rep(0L, 80L)), as.raw(rep(0L, 80L)))) {
          chunks_sent <<- chunks_sent + 1L
          if (!isTRUE(callback(chunk))) {
            break
          }
        }
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root, max_file_size_mb = 0.0001)

    expect_identical(out$status, "skipped_size")
    expect_true(is.na(out$local_path))
    expect_identical(chunks_sent, 2L)
    expect_false(file.exists(dest))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})

test_that("publication failure preserves the previous verified copy", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    writeBin(ACQ0A_PDF_MAGIC, dest)
    planscanR:::write_download_receipt(
      dest,
      url,
      "application/pdf",
      file.info(dest)$size,
      planscanR:::file_sha256(dest)
    )
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(ACQ0A_PDF_MAGIC)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )
    local_mocked_bindings(
      rename_download_file = function(from, to) FALSE,
      .package = "planscanR"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root, overwrite = TRUE)

    expect_identical(out$status, "failed")
    expect_match(out$reason, "publish|rename|atomic", ignore.case = TRUE)
    expect_identical(readBin(dest, "raw", n = file.info(dest)$size), ACQ0A_PDF_MAGIC)
    expect_true(planscanR:::is_verified_download(dest))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})

test_that("receipt publication precedes data replacement and preserves the old proof", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    writeBin(ACQ0A_PDF_MAGIC, dest)
    new_pdf <- as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37))
    planscanR:::write_download_receipt(
      dest,
      url,
      "application/pdf",
      file.info(dest)$size,
      planscanR:::file_sha256(dest)
    )
    rename_calls <- 0L
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(new_pdf)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )
    local_mocked_bindings(
      rename_download_file = function(from, to) {
        rename_calls <<- rename_calls + 1L
        rename_calls == 1L
      },
      .package = "planscanR"
    )

    out <- download_to_cache(url, "nl", "1234", cache_dir = root, overwrite = TRUE)

    expect_identical(out$status, "failed")
    expect_match(out$reason, "publish|rename|atomic", ignore.case = TRUE)
    expect_identical(rename_calls, 2L)
    expect_identical(readBin(dest, "raw", n = file.info(dest)$size), ACQ0A_PDF_MAGIC)
    expect_true(planscanR:::is_verified_download(dest))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})

test_that("long attachment names publish bounded receipts and remain cacheable", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    long_name <- paste0(strrep("a", 192L), ".pdf")
    url <- paste0("https://example.org/files/n/1/", long_name)
    dest <- cache_path(url, "n", "1", cache_dir = root)
    expect_identical(nchar(basename(dest), type = "bytes"), 200L)
    network_calls <- 0L
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        network_calls <<- network_calls + 1L
        callback(ACQ0A_PDF_MAGIC)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )

    first <- download_to_cache(url, "n", "1", cache_dir = root)
    receipt <- planscanR:::download_receipt_path(dest, first$sha256)
    expect_identical(first$status, "downloaded")
    expect_true(file.exists(receipt))
    expect_lt(nchar(basename(receipt), type = "bytes"), 255L)
    expect_true(grepl(first$sha256, basename(receipt), fixed = TRUE))

    second <- download_to_cache(url, "n", "1", cache_dir = root)
    expect_identical(second$status, "exists")
    expect_identical(normalizePath(second$local_path), normalizePath(dest))
    expect_identical(network_calls, 1L)
  })
})

test_that("successful explicit-extension downloads preserve distinct same-stem files", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    pdf_url <- "https://example.org/files/nl/1234/report.pdf"
    docx_url <- "https://example.org/files/nl/1234/report.docx"
    pdf_dest <- cache_path(pdf_url, "nl", "1234", cache_dir = root)
    docx_dest <- cache_path(docx_url, "nl", "1234", cache_dir = root)
    network_calls <- 0L
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        network_calls <<- network_calls + 1L
        if (network_calls == 1L) {
          callback(ACQ0A_PDF_MAGIC)
        } else {
          callback(as.raw(c(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00)))
        }
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (!identical(tolower(header), "content-type")) return(NA_character_)
        if (network_calls == 1L) "application/pdf" else "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
      },
      .package = "httr2"
    )

    first <- download_to_cache(pdf_url, "nl", "1234", cache_dir = root)
    second <- download_to_cache(docx_url, "nl", "1234", cache_dir = root)

    expect_identical(first$status, "downloaded")
    expect_identical(second$status, "downloaded")
    expect_true(file.exists(pdf_dest))
    expect_true(file.exists(docx_dest))
    expect_true(planscanR:::is_verified_download(pdf_dest))
    expect_true(planscanR:::is_verified_download(docx_dest))
    expect_identical(download_to_cache(pdf_url, "nl", "1234", cache_dir = root)$status, "exists")
    expect_identical(download_to_cache(docx_url, "nl", "1234", cache_dir = root)$status, "exists")
    expect_identical(network_calls, 2L)
  })
})

test_that("content-addressed downloads deduplicate bytes without sharing URL receipts", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    urls <- c("https://example.org/files/nl/1234/report-a.pdf",
      "https://example.org/files/nl/1234/report-b.pdf")
    calls <- 0L
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        calls <<- calls + 1L
        callback(ACQ0A_PDF_MAGIC)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )

    first <- download_to_cache(urls[[1L]], "nl", "1234", cache_dir = root,
      content_addressed = TRUE)
    second <- download_to_cache(urls[[2L]], "nl", "1234", cache_dir = root,
      content_addressed = TRUE)
    expect_identical(first$status, "downloaded")
    expect_identical(second$status, "downloaded")
    expect_identical(first$local_path, second$local_path)
    expect_identical(first$location[[1L]]$relative_path, second$location[[1L]]$relative_path)
    expect_true(file.exists(first$source_local_path))
    expect_true(file.exists(second$source_local_path))
    expect_identical(jsonlite::read_json(planscanR:::download_receipt_path(first$source_local_path),
      simplifyVector = TRUE)$url, urls[[1L]])
    expect_identical(jsonlite::read_json(planscanR:::download_receipt_path(second$source_local_path),
      simplifyVector = TRUE)$url, urls[[2L]])
    object_receipt <- jsonlite::read_json(planscanR:::download_receipt_path(first$local_path),
      simplifyVector = TRUE)
    expect_true(is.na(object_receipt$url) || is.null(object_receipt$url))
    expect_identical(calls, 2L)
  })
})

test_that("content-addressed publication refuses insufficient duplicate space", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(ACQ0A_PDF_MAGIC)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        if (identical(tolower(header), "content-type")) "application/pdf" else NA_character_
      },
      .package = "httr2"
    )
    local_mocked_bindings(storage_capacity = function(root) {
      list(total_bytes = 100, free_bytes = 0)
    }, .package = "planscanR")
    out <- download_to_cache(url, "nl", "1234", cache_dir = root,
      content_addressed = TRUE)
    expect_identical(out$status, "failed")
    expect_match(out$reason, "Insufficient free space")
    expect_length(list.files(file.path(root, "objects"), recursive = TRUE), 0L)
  })
})

test_that("content-addressed promotion enforces the current cap on cached files", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    source <- cache_path(url, "nl", "1234", cache_dir = root)
    writeBin(ACQ0A_PDF_MAGIC, source)
    sha <- planscanR:::file_sha256(source)
    planscanR:::write_download_receipt(source, url, "application/pdf", file.info(source)$size, sha)

    out <- download_to_cache(url, "nl", "1234", cache_dir = root,
      max_file_size_mb = 0.000001, content_addressed = TRUE)
    expect_identical(out$status, "failed")
    expect_match(out$reason, "exceeds the size cap")
    expect_false(dir.exists(file.path(root, "objects")))
  })
})

test_that("batch downloads also preserve a verified copy after interruption", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- planscanR:::cache_path_internal(url, "nl", "1234", root = root)
    writeBin(charToRaw("verified copy"), dest)

    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(charToRaw("partial response"))
        stop("simulated batch interruption")
      },
      .package = "httr2"
    )

    out <- planscanR:::download_attachments(
      url,
      country = "nl",
      document_id = "1234",
      root = root,
      overwrite = TRUE
    )

    expect_identical(out$status, "failed")
    expect_match(out$reason, "simulated batch interruption")
    expect_identical(readBin(dest, "raw", n = file.info(dest)$size), charToRaw("verified copy"))
    expect_length(list.files(dirname(dest), pattern = "\\.part$", all.files = TRUE), 0L)
  })
})
