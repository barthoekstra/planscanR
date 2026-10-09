test_that("storage guards authorize pending chunks before they are written", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/guard/chunks.bin"
    chunks <- lapply(c("one", "two", "three"), charToRaw)
    calls <- list()
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        for (chunk in chunks) {
          if (!isTRUE(callback(chunk))) break
        }
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) {
        header <- tolower(header)
        if (identical(header, "content-type")) {
          return("application/octet-stream")
        }
        if (identical(header, "content-length")) {
          return("1")
        }
        NA_character_
      },
      .package = "httr2"
    )
    guard <- function(cumulative, advertised, phase = "stream", pending_bytes = 0) {
      calls[[length(calls) + 1L]] <<- list(
        cumulative = cumulative,
        advertised = advertised,
        phase = phase,
        pending_bytes = pending_bytes
      )
      TRUE
    }

    out <- download_to_cache(
      url,
      "nl",
      "guard",
      cache_dir = root,
      max_file_size_mb = Inf,
      storage_guard = guard
    )

    expect_identical(out$status, "downloaded")
    expect_identical(readBin(out$local_path, "raw", n = 11L), charToRaw("onetwothree"))
    stream <- Filter(function(call) identical(call$phase, "stream"), calls)
    expect_gte(length(stream), 4L)
    expect_equal(stream[[1L]]$cumulative, 0)
    expect_equal(stream[[1L]]$pending_bytes, 0)
    expect_equal(stream[[2L]]$cumulative, 0)
    expect_equal(stream[[2L]]$pending_bytes, length(chunks[[1L]]))
    expect_equal(stream[[3L]]$cumulative, length(chunks[[1L]]))
    expect_equal(stream[[3L]]$pending_bytes, length(chunks[[2L]]))
    expect_true(any(vapply(calls, function(call) identical(call$phase, "publish"), logical(1))))
  })
})

test_that("a rejected storage guard leaves no staged or published bytes", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/guard/rejected.bin"
    wrote <- FALSE
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        result <- callback(charToRaw("must not be written"))
        wrote <<- isTRUE(result)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/octet-stream",
      .package = "httr2"
    )
    guard <- function(cumulative, advertised, phase = "stream", pending_bytes = 0) {
      if (identical(phase, "stream") && pending_bytes > 0) FALSE else TRUE
    }

    out <- download_to_cache(
      url,
      "nl",
      "rejected",
      cache_dir = root,
      max_file_size_mb = Inf,
      storage_guard = guard
    )

    expect_identical(out$status, "failed")
    expect_false(wrote)
    expect_true(is.na(out$local_path))
    expect_length(list.files(root, recursive = TRUE, all.files = TRUE), 0L)
  })
})

test_that("guarded content-addressed promotion fences both retained copies", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/guard/object.bin"
    body <- charToRaw("content addressed bytes")
    calls <- list()
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(body)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/octet-stream",
      .package = "httr2"
    )
    guard <- function(cumulative, advertised, phase = "stream", pending_bytes = 0) {
      calls[[length(calls) + 1L]] <<- list(
        cumulative = cumulative,
        phase = phase,
        pending_bytes = pending_bytes
      )
      TRUE
    }

    out <- download_to_cache(
      url,
      "nl",
      "guard-object",
      cache_dir = root,
      max_file_size_mb = Inf,
      content_addressed = TRUE,
      storage_guard = guard
    )

    expect_identical(out$status, "downloaded")
    expect_true(file.exists(out$local_path))
    expect_true(file.exists(out$source_local_path))
    promotions <- Filter(function(call) identical(call$phase, "promotion"), calls)
    expect_gte(length(promotions), 2L)
    expect_true(any(vapply(promotions, function(call) call$pending_bytes == out$size_bytes, logical(1))))
    expect_true(any(vapply(promotions, function(call) call$pending_bytes == 0, logical(1))))
  })
})

test_that("a stale promotion fence removes the staged duplicate before rename", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/guard/stale-object.bin"
    body <- charToRaw("stale promotion bytes")
    local_mocked_bindings(
      head_content_length = function(url) NA_real_,
      req_planscanr = function(base_url, path = NULL) structure(list(), class = "httr2_request"),
      .package = "planscanR"
    )
    local_mocked_bindings(
      req_perform_stream = function(req, callback, ...) {
        callback(body)
        structure(list(), class = "httr2_response")
      },
      resp_header = function(resp, header, ...) "application/octet-stream",
      .package = "httr2"
    )
    guard <- function(cumulative, advertised, phase = "stream", pending_bytes = 0) {
      if (identical(phase, "promotion") && pending_bytes == 0) FALSE else TRUE
    }

    out <- download_to_cache(
      url,
      "nl",
      "stale-object",
      cache_dir = root,
      max_file_size_mb = Inf,
      content_addressed = TRUE,
      storage_guard = guard
    )

    expect_identical(out$status, "failed")
    source <- cache_path(url, "nl", "stale-object", cache_dir = root)
    expect_true(file.exists(source))
    sha <- planscanR:::file_sha256(source)
    target <- planscanR::storage_path(
      root,
      file.path("objects", "sha256", substr(sha, 1L, 2L), substr(sha, 3L, 4L), sha)
    )
    expect_false(file.exists(target))
    expect_length(list.files(root, recursive = TRUE, pattern = "\\.part$"), 0L)
  })
})
