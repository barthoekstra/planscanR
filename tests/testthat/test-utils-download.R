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
    p <- planscanR:::cache_path(
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

test_that("max_file_size_bytes honours the option and arg overrides", {
  withr::with_options(list(planscanR.max_file_size_mb = 50), {
    expect_identical(planscanR:::max_file_size_bytes(), 50 * 1024 * 1024)
    expect_identical(planscanR:::max_file_size_bytes(10), 10 * 1024 * 1024)
    expect_identical(planscanR:::max_file_size_bytes(Inf), Inf)
    expect_identical(planscanR:::max_file_size_bytes(NULL), 50 * 1024 * 1024)
  })
})
