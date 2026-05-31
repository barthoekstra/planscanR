test_that("cache_dir resolves under user option override", {
  d <- tempfile("planscanR-cache-")
  withr::with_options(list(planscanR.cache_dir = d), {
    p <- planscanR:::cache_dir("http")
    expect_true(dir.exists(p))
    expect_identical(normalizePath(p), normalizePath(file.path(d, "http")))
  })
})

test_that("cache_path builds the country/document_id layout with a flatten-safe basename", {
  withr::with_tempdir({
    p <- planscanR:::cache_path_internal(
      "https://pas.commissiemer.nl/files/nl/3619/a3619ts.pdf",
      country = "nl",
      document_id = "3619",
      root = getwd()
    )
    expect_true(grepl("files/nl/3619/", p))
    expect_identical(basename(p), "nl_3619_a3619ts.pdf")
    expect_true(dir.exists(dirname(p)))
  })
})

test_that("slugify_filename produces flatten-safe lowercase ASCII names", {
  expect_identical(
    planscanR:::slugify_filename(
      "https://pas.commissiemer.nl/files/nl/3619/Some File With Spaces.PDF",
      "nl",
      "3619"
    ),
    "nl_3619_some-file-with-spaces.pdf"
  )
  expect_identical(
    planscanR:::slugify_filename(
      "https://example.org/x/y/voorbeeld_tekening_aanzicht.pdf",
      "nl",
      "3619"
    ),
    "nl_3619_voorbeeld_tekening_aanzicht.pdf"
  )
})

test_that("slugify_filename disambiguates extension-less URLs by attachment_id", {
  # Kotkas (EE) URLs share an identical path; identity lives in the query
  # string. Without the URL-hash suffix, every attachment for one record
  # would collide on the same basename and overwrite each other on disk.
  a <- planscanR:::slugify_filename(
    "https://kotkas.envir.ee/kmh/kmh_file_download?kmh_id=44&attachment_id=12345",
    "ee",
    "KMH-44"
  )
  b <- planscanR:::slugify_filename(
    "https://kotkas.envir.ee/kmh/kmh_file_download?kmh_id=44&attachment_id=12346",
    "ee",
    "KMH-44"
  )
  expect_false(identical(a, b))
  expect_match(a, "^ee_kmh-44_kmh_file_download-[0-9a-f]{8}\\.x$")
  expect_match(b, "^ee_kmh-44_kmh_file_download-[0-9a-f]{8}\\.x$")
  # Stable for the same URL across calls.
  expect_identical(
    a,
    planscanR:::slugify_filename(
      "https://kotkas.envir.ee/kmh/kmh_file_download?kmh_id=44&attachment_id=12345",
      "ee",
      "KMH-44"
    )
  )
})

test_that("content_type_to_ext maps the common MIME types and ignores parameters", {
  expect_identical(planscanR:::content_type_to_ext("application/pdf"), "pdf")
  expect_identical(planscanR:::content_type_to_ext("application/pdf; charset=binary"), "pdf")
  expect_identical(planscanR:::content_type_to_ext("APPLICATION/PDF"), "pdf")
  expect_identical(planscanR:::content_type_to_ext("image/jpeg"), "jpg")
  expect_identical(
    planscanR:::content_type_to_ext(
      "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    ),
    "docx"
  )
  expect_true(is.na(planscanR:::content_type_to_ext("application/octet-stream")))
  expect_true(is.na(planscanR:::content_type_to_ext(NA_character_)))
  expect_true(is.na(planscanR:::content_type_to_ext("")))
  expect_true(is.na(planscanR:::content_type_to_ext(NULL)))
})

test_that("sniff_magic_ext recognises PDF / PNG / JPEG / ZIP byte signatures", {
  withr::with_tempdir({
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34)), "doc")
    writeBin(as.raw(c(0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10)), "img")
    writeBin(as.raw(c(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)), "pic")
    writeBin(as.raw(c(0x50, 0x4B, 0x03, 0x04, 0x14, 0x00)), "bundle")
    writeBin(as.raw(rep(0x00, 16L)), "blank")
    expect_identical(planscanR:::sniff_magic_ext("doc"), "pdf")
    expect_identical(planscanR:::sniff_magic_ext("img"), "jpg")
    expect_identical(planscanR:::sniff_magic_ext("pic"), "png")
    expect_identical(planscanR:::sniff_magic_ext("bundle"), "zip")
    expect_true(is.na(planscanR:::sniff_magic_ext("blank")))
    expect_true(is.na(planscanR:::sniff_magic_ext("nonexistent-file")))
  })
})

test_that("finalize_extension renames .x placeholders using Content-Type or magic bytes", {
  withr::with_tempdir({
    # Header wins.
    writeBin(as.raw(c(0x00, 0x00, 0x00, 0x00)), "a.x")
    out <- planscanR:::finalize_extension("a.x", "application/pdf; charset=binary")
    expect_identical(basename(out), "a.pdf")
    expect_true(file.exists("a.pdf"))
    expect_false(file.exists("a.x"))

    # No header → fall back to magic bytes.
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D)), "b.x")
    out <- planscanR:::finalize_extension("b.x", "application/octet-stream")
    expect_identical(basename(out), "b.pdf")

    # Unknown type / unknown bytes: leave the placeholder in place.
    writeBin(as.raw(rep(0xAB, 8L)), "c.x")
    out <- planscanR:::finalize_extension("c.x", "application/x-weird")
    expect_identical(basename(out), "c.x")
    expect_true(file.exists("c.x"))

    # Not a placeholder: no-op even when Content-Type disagrees.
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46)), "d.pdf")
    out <- planscanR:::finalize_extension("d.pdf", "image/png")
    expect_identical(basename(out), "d.pdf")
  })
})

test_that("resolve_cached_path finds the finalized file when only the placeholder is known", {
  withr::with_tempdir({
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46)), "ee_kmh-44_kmh_file_download-deadbeef.pdf")
    out <- planscanR:::resolve_cached_path_internal("ee_kmh-44_kmh_file_download-deadbeef.x")
    expect_identical(basename(out), "ee_kmh-44_kmh_file_download-deadbeef.pdf")
  })
  withr::with_tempdir({
    # Two finalized files for the same stem is ambiguous — refuse to guess.
    writeBin(as.raw(1L), "stem.pdf")
    writeBin(as.raw(1L), "stem.zip")
    expect_true(is.na(planscanR:::resolve_cached_path_internal("stem.x")))
  })
  withr::with_tempdir({
    # Nothing yet on disk → NA, so callers know to proceed with the download.
    expect_true(is.na(planscanR:::resolve_cached_path_internal("missing.x")))
  })
})

test_that("slugify_filename truncates very long names with a URL-hash suffix", {
  long_name <- paste0(strrep("a", 250), ".pdf")
  url <- paste0("https://example.org/", long_name)
  out <- planscanR:::slugify_filename(url, "nl", "3619", max_chars = 80L)
  expect_lte(nchar(out), 80L)
  expect_true(grepl("\\.pdf$", out))
  # A second call yields the same name for the same URL
  expect_identical(out, planscanR:::slugify_filename(url, "nl", "3619", max_chars = 80L))
})

test_that("url_encode_safe escapes unsafe path chars but preserves structure", {
  # Literal space in the filename (the commissiemer.nl failure mode).
  expect_identical(
    planscanR:::url_encode_safe(
      "https://pas.commissiemer.nl/files/nl/3907/Ontwerp wijzigingsbesluit Omgevingsvisie.pdf"
    ),
    "https://pas.commissiemer.nl/files/nl/3907/Ontwerp%20wijzigingsbesluit%20Omgevingsvisie.pdf"
  )
  # scheme://authority and reserved path/query delimiters are left untouched.
  expect_identical(
    planscanR:::url_encode_safe("https://host.example/a/b?x=1&y=2"),
    "https://host.example/a/b?x=1&y=2"
  )
  # Already-encoded escapes are NOT double-encoded.
  expect_identical(
    planscanR:::url_encode_safe("https://host.example/a%20b/c.pdf"),
    "https://host.example/a%20b/c.pdf"
  )
  # Degenerate inputs pass through.
  expect_identical(planscanR:::url_encode_safe(NA_character_), NA_character_)
  expect_identical(planscanR:::url_encode_safe(""), "")
})

test_that("file_sha256 returns NA for missing path", {
  expect_true(is.na(planscanR:::file_sha256(NA_character_)))
  expect_true(is.na(planscanR:::file_sha256(tempfile("nonexistent"))))
})

test_that("file_sha256 hashes existing files deterministically", {
  withr::with_tempdir({
    writeLines("hello", "x.txt")
    h1 <- planscanR:::file_sha256("x.txt")
    h2 <- planscanR:::file_sha256("x.txt")
    expect_identical(h1, h2)
    expect_match(h1, "^[0-9a-f]{64}$")
  })
})

test_that("download_attachments returns the empty status tibble for empty input", {
  out <- planscanR:::download_attachments(
    character(0),
    country = "nl",
    document_id = "9999"
  )
  expect_s3_class(out, "tbl_df")
  expect_identical(nrow(out), 0L)
  expect_setequal(
    names(out),
    c("url", "local_path", "status", "size_bytes", "sha256", "reason")
  )
})

test_that("clear_cache is a no-op against an empty / missing root", {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "doesntexist"))
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    out <- clear_cache(confirm = FALSE)
    expect_s3_class(out, "tbl_df")
    expect_identical(nrow(out), 0L)
  })
})

test_that("clear_cache wipes the files tree but not anything outside it", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = root)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    dir.create(file.path(root, "files", "nl", "1234"), recursive = TRUE)
    dir.create(file.path(root, "files", "de", "9999"), recursive = TRUE)
    writeLines("b", file.path(root, "files", "nl", "1234", "x.pdf"))
    writeLines("c", file.path(root, "files", "de", "9999", "y.pdf"))
    # A sibling file OUTSIDE the cache root — must NEVER be touched.
    writeLines("d", file.path(getwd(), "sibling.txt"))

    # country = "nl" leaves de in place.
    out <- clear_cache(country = "nl", confirm = FALSE)
    expect_true(out$removed[1])
    expect_false(dir.exists(file.path(root, "files", "nl")))
    expect_true(dir.exists(file.path(root, "files", "de", "9999")))

    # Default (no country) removes the rest of `files/`.
    out <- clear_cache(confirm = FALSE)
    expect_true(all(out$removed))
    expect_false(dir.exists(file.path(root, "files")))

    # Sibling untouched.
    expect_true(file.exists(file.path(getwd(), "sibling.txt")))
  })
})

test_that("clear_cache returns size and file-count info per target", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = root)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    dir.create(file.path(root, "files", "nl", "1"), recursive = TRUE)
    writeLines(strrep("x", 1000L), file.path(root, "files", "nl", "1", "f.txt"))
    out <- clear_cache(confirm = FALSE)
    expect_identical(out$n_files, 1L)
    expect_gt(out$bytes, 0)
  })
})

test_that("format_bytes gives a human-readable size", {
  expect_match(planscanR:::format_bytes(0), "^0\\.0 B")
  expect_match(planscanR:::format_bytes(1500), "^1\\.5 KB")
  expect_match(planscanR:::format_bytes(1024^3), "^1\\.0 GB")
})

test_that("cache_path (public) builds the canonical files/<cc>/<doc>/<slug> layout", {
  withr::with_tempdir({
    p <- cache_path(
      "https://pas.commissiemer.nl/files/nl/3619/a3619ts.pdf",
      country = "nl",
      document_id = "3619",
      cache_dir = getwd()
    )
    expect_true(grepl("files/nl/3619/", p))
    expect_identical(basename(p), "nl_3619_a3619ts.pdf")
    expect_true(dir.exists(dirname(p)))
  })
})

test_that("cache_path (public) defaults to the resolved cache root", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    withr::with_options(list(planscanR.cache_dir = root), {
      p <- cache_path("https://example.org/x/doc.pdf", "de", "9999")
      expect_identical(
        normalizePath(dirname(p), mustWork = FALSE),
        normalizePath(file.path(root, "files", "de", "9999"), mustWork = FALSE)
      )
    })
  })
})

test_that("resolve_cached_path (public) finds the finalized file behind a .x placeholder", {
  withr::with_tempdir({
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46)), "ee_kmh-44_dl-deadbeef.pdf")
    out <- resolve_cached_path("ee_kmh-44_dl-deadbeef.x")
    expect_identical(basename(out), "ee_kmh-44_dl-deadbeef.pdf")
    # Nothing on disk -> NA so a caller knows to download.
    expect_true(is.na(resolve_cached_path("missing.x")))
  })
})

test_that("download_to_cache validates the url argument", {
  expect_error(
    download_to_cache(character(0), "nl", "1"),
    class = "planscanR_error_bad_input"
  )
  expect_error(
    download_to_cache(NA_character_, "nl", "1"),
    class = "planscanR_error_bad_input"
  )
  expect_error(
    download_to_cache(c("a", "b"), "nl", "1"),
    class = "planscanR_error_bad_input"
  )
})

test_that("download_to_cache returns the cached file without a request when one exists", {
  withr::with_tempdir({
    root <- file.path(getwd(), "cache")
    url <- "https://example.org/files/nl/1234/report.pdf"
    dest <- cache_path(url, "nl", "1234", cache_dir = root)
    writeBin(as.raw(c(0x25, 0x50, 0x44, 0x46, 0x2D, 0x31)), dest)
    out <- download_to_cache(url, "nl", "1234", cache_dir = root)
    expect_s3_class(out, "tbl_df")
    expect_identical(nrow(out), 1L)
    expect_identical(out$status, "exists")
    expect_identical(normalizePath(out$local_path), normalizePath(dest))
    expect_match(out$sha256, "^[0-9a-f]{64}$")
    expect_gt(out$size_bytes, 0)
    expect_setequal(
      names(out),
      c("url", "local_path", "size_bytes", "sha256", "status", "reason")
    )
  })
})

test_that("max_file_size_bytes honours the option and arg overrides", {
  withr::with_options(list(planscanR.max_file_size_mb = 50), {
    expect_identical(planscanR:::max_file_size_bytes(), 50 * 1024 * 1024)
    expect_identical(planscanR:::max_file_size_bytes(10), 10 * 1024 * 1024)
    expect_identical(planscanR:::max_file_size_bytes(Inf), Inf)
    expect_identical(planscanR:::max_file_size_bytes(NULL), 50 * 1024 * 1024)
  })
})
