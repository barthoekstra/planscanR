# ACQ-1c: per-record coordination and offline download reconciliation.

test_that("independent sidecar writers retain download, classification, and translation outcomes", {
  skip_if(.Platform$OS.type == "windows", "forked process coordination test is Unix-only")

  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    path <- file.path(root, "files", "nl", "1234", "nl_1234_report.pdf")
    pending <- planscanR:::pending_download_status(url)
    base <- tibble::tibble(
      country = "nl",
      source_portal = "example.org",
      document_id = "1234",
      url = "https://example.org/record/1234",
      retrieved_at = as.POSIXct("2026-10-03 12:00:00", tz = "UTC"),
      attachment_urls = list(url),
      local_path = list(NA_character_),
      title = "Wind project",
      summary = "A project",
      download_status = list(pending)
    )
    planscanR::write_record_sidecar(base, root = root)

    downloaded <- tibble::tibble(
      url = url,
      local_path = path,
      status = "downloaded",
      size_bytes = 9,
      sha256 = paste(rep("a", 64), collapse = ""),
      reason = NA_character_
    )
    jobs <- list(
      parallel::mcparallel({
        rec <- base
        rec$download_status <- list(downloaded)
        planscanR::write_record_sidecar(rec, downloads = downloaded, root = root)
      }, mc.interactive = FALSE),
      parallel::mcparallel({
        rec <- base
        rec$class_label <- "wind"
        rec$class_score <- 0.91
        rec$class_relevant <- TRUE
        rec$class_model <- "test-model"
        rec$class_score_wind <- 0.91
        # Mirrors planscanR.screen::classify_assessments(), which passes the
        # (possibly stale) download_status row it received with the record.
        planscanR::write_record_sidecar(rec, downloads = pending, root = root)
      }, mc.interactive = FALSE),
      parallel::mcparallel({
        rec <- base
        rec$translation_text <- "translated title"
        rec$translation_language <- "en"
        planscanR::write_record_sidecar(rec, downloads = pending, root = root)
      }, mc.interactive = FALSE)
    )
    results <- parallel::mccollect(jobs)
    expect_length(results, 3L)
    expect_true(all(vapply(results, function(x) !inherits(x, "try-error"), logical(1))))

    sidecar <- planscanR:::sidecar_path("nl", "1234", root = root)
    out <- planscanR::read_record_sidecar(sidecar)
    expect_identical(out$class_label, "wind")
    expect_identical(out$translation_text, "translated title")
    expect_identical(out$download_status[[1]]$status, "downloaded")
    expect_identical(out$download_status[[1]]$url, url)

    planscanR::update_record_sidecar("nl", "1234", function(current) {
      current$translation_text <- "updated atomically"
      current
    }, root = root)
    updated <- planscanR::read_record_sidecar(sidecar)
    expect_identical(updated$translation_text, "updated atomically")
    expect_identical(updated$class_label, "wind")
    expect_identical(updated$download_status[[1]]$status, "downloaded")
  })
})

test_that("a sidecar lock held by an exited process is released by the OS", {
  skip_if(.Platform$OS.type == "windows", "forked process coordination test is Unix-only")

  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "example.org",
      document_id = "lock-owner",
      url = "https://example.org/record/lock-owner",
      retrieved_at = as.POSIXct("2026-10-03 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      download_status = list(planscanR:::empty_download_status())
    )
    planscanR::write_record_sidecar(rec, root = root)
    sidecar <- planscanR:::sidecar_path("nl", "lock-owner", root = root)
    lock_path <- planscanR:::sidecar_lock_path(sidecar)

    child <- parallel::mcparallel({
      lock <- filelock::lock(lock_path, timeout = 0)
      if (is.null(lock)) {
        stop("child could not acquire the lock")
      }
      # A hard exit exercises filelock's OS-level owner cleanup without
      # running the parent's with_tempdir() cleanup handlers in the fork.
      tools::pskill(Sys.getpid(), signal = get("SIGKILL", envir = asNamespace("tools")))
    }, mc.interactive = FALSE)
    suppressWarnings(parallel::mccollect(child))

    rec$title <- "written after owner exit"
    expect_silent(planscanR::write_record_sidecar(rec, root = root))
    expect_identical(planscanR::read_record_sidecar(sidecar)$title, "written after owner exit")
  })
})

test_that("standalone sidecar reads do not require a writable cache directory", {
  skip_if(.Platform$OS.type == "windows", "POSIX directory permissions are Unix-only")

  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "example.org",
      document_id = "readonly",
      url = "https://example.org/record/readonly",
      retrieved_at = as.POSIXct("2026-10-03 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      download_status = list(planscanR:::empty_download_status())
    )
    planscanR::write_record_sidecar(rec, root = root)
    path <- planscanR:::sidecar_path("nl", "readonly", root = root)
    lock_path <- planscanR:::sidecar_lock_path(path)
    unlink(lock_path)
    parent <- dirname(path)
    on.exit(Sys.chmod(parent, mode = "0755"), add = TRUE)
    Sys.chmod(parent, mode = "0555")

    expect_identical(planscanR::read_record_sidecar(path)$document_id, "readonly")
    expect_identical(planscanR:::sidecar_url_index("nl", cache_dir = root), setNames(path, rec$url))
    expect_false(file.exists(lock_path))
  })
})

test_that("repeated unchanged sidecar updates retain discovery history once", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "example.org",
      document_id = "history",
      url = "https://example.org/record/history",
      retrieved_at = as.POSIXct("2026-10-03 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      download_status = list(planscanR:::empty_download_status()),
      discovery_log = list(list(list(query = "old")))
    )
    path <- planscanR::write_record_sidecar(rec, root = root)

    for (i in seq_len(10L)) {
      planscanR::update_record_sidecar("nl", "history", function(current) {
        current$title <- paste("update", i)
        current
      }, root = root)
    }

    back <- planscanR::read_record_sidecar(path)
    expect_length(back$discovery_log[[1]], 1L)
    expect_identical(back$discovery_log[[1]][[1]]$query, "old")
  })
})

test_that("sidecar callbacks can append or prepend discovery history", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "example.org",
      document_id = "history-order",
      url = "https://example.org/record/history-order",
      retrieved_at = as.POSIXct("2026-10-03 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      download_status = list(planscanR:::empty_download_status()),
      discovery_log = list(list(list(query = "old")))
    )
    path <- planscanR::write_record_sidecar(rec, root = root)

    planscanR::update_record_sidecar("nl", "history-order", function(current) {
      current$discovery_log <- list(c(
        current$discovery_log[[1]],
        list(list(query = "appended"))
      ))
      current
    }, root = root)
    planscanR::update_record_sidecar("nl", "history-order", function(current) {
      current$discovery_log <- list(c(
        list(list(query = "prepended")),
        current$discovery_log[[1]]
      ))
      current
    }, root = root)

    back <- planscanR::read_record_sidecar(path)
    expect_identical(
      vapply(back$discovery_log[[1]], function(entry) entry$query, character(1)),
      c("prepended", "old", "appended")
    )
  })
})

test_that("HTML response bodies cannot be published as verified downloads", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    part <- file.path(getwd(), "response.part")
    writeLines("<html><body>login required</body></html>", part)
    dest <- planscanR::cache_path(
      "https://example.org/files/nl/1234/response.pdf",
      "nl",
      "1234",
      cache_dir = root
    )

    expect_error(
      planscanR:::publish_verified_download_copy(
        part,
        dest,
        url = "https://example.org/files/nl/1234/response.pdf",
        content_type = "application/pdf"
      ),
      "HTML|attachment MIME type"
    )
    expect_false(file.exists(dest))
    expect_false(planscanR:::is_verified_download(dest))
    expect_length(list.files(dirname(dest), pattern = "\\.verified\\.json$"), 0L)
  })
})

test_that("trusted publication metadata repairs a receipt without refetching", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- planscanR::cache_path(url, "nl", "1234", cache_dir = root)
    bytes <- charToRaw("already published bytes")
    writeBin(bytes, dest)

    before <- planscanR::reconcile_cached_download(dest)
    expect_identical(before$status, "unverified")
    expect_false(planscanR:::is_verified_download(dest))

    digest <- planscanR:::file_sha256(dest)
    repaired <- planscanR::reconcile_cached_download(
      dest,
      expected_size_bytes = length(bytes),
      expected_sha256 = digest,
      url = url,
      content_type = "application/pdf",
      repair = TRUE
    )
    expect_identical(repaired$status, "repaired")
    expect_true(planscanR:::is_verified_download(dest))

    local_mocked_bindings(
      head_content_length = function(...) stop("network should not be called"),
      .package = "planscanR"
    )
    out <- planscanR::download_to_cache(url, "nl", "1234", cache_dir = root)
    expect_identical(out$status, "exists")
    expect_identical(out$sha256, digest)
  })
})

test_that("a corrupt sidecar is never silently replaced", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    rec <- tibble::tibble(
      country = "nl",
      source_portal = "example.org",
      document_id = "corrupt",
      url = "https://example.org/record/corrupt",
      retrieved_at = as.POSIXct("2026-10-03 12:00:00", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0)),
      download_status = list(planscanR:::empty_download_status())
    )
    path <- planscanR::write_record_sidecar(rec, root = root)
    writeLines("{not-json", path)
    expect_error(
      planscanR::write_record_sidecar(rec, root = root),
      class = "planscanR_error_sidecar_corrupt"
    )
    expect_identical(readLines(path), "{not-json")
  })
})

test_that("cache audit identifies unverified legacy files and interrupted parts", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    verified_url <- "https://example.org/files/nl/1234/verified.pdf"
    verified <- planscanR::cache_path(verified_url, "nl", "1234", cache_dir = root)
    writeBin(charToRaw("verified"), verified)
    planscanR:::write_download_receipt(
      verified,
      verified_url,
      "application/pdf",
      file.info(verified)$size,
      planscanR:::file_sha256(verified)
    )

    unverified <- file.path(dirname(verified), "nl_1234_legacy.pdf")
    writeBin(charToRaw("legacy partial"), unverified)
    partial <- file.path(dirname(verified), "nl_1234_new.pdf.planscanR-123.part")
    writeBin(charToRaw("interrupted"), partial)

    audit <- planscanR::audit_cache_downloads(cache_dir = root)
    expect_identical(audit$status[audit$path == verified], "verified")
    expect_identical(audit$status[audit$path == unverified], "unverified")
    expect_identical(audit$status[audit$path == partial], "partial")
  })
})
