test_that("storage roots resolve to canonical writable directories", {
  root <- file.path(withr::local_tempdir(), "cache with spaces")
  resolved <- planscanR:::storage_root_resolve(root, create = TRUE, writable = TRUE)

  expect_true(dir.exists(resolved))
  expect_identical(normalizePath(resolved), normalizePath(root))
  expect_true(is.finite(planscanR:::storage_free_bytes(resolved)))
  capacity <- planscanR:::storage_capacity(resolved)
  expect_true(capacity$total_bytes >= capacity$free_bytes)
  expect_true(is.finite(planscanR:::storage_transfer_cap_bytes()))
})

test_that("storage paths stay below the registered root", {
  root <- withr::local_tempdir()
  expect_identical(
    planscanR:::storage_relative_path("files/nl/project/report.pdf", root),
    "files/nl/project/report.pdf"
  )
  expect_identical(
    planscanR:::storage_path(root, "files/nl/project/report.pdf"),
    file.path(root, "files", "nl", "project", "report.pdf")
  )
  created <- planscanR:::storage_path(root, "nested/file.pdf", create_parent = TRUE)
  expect_true(dir.exists(dirname(created)))
  expect_error(
    planscanR:::storage_relative_path("../outside.txt", root),
    class = "planscanR_error_storage_path"
  )

  outside <- file.path(dirname(root), "outside")
  dir.create(outside)
  file.symlink(outside, file.path(root, "escape"))
  expect_error(
    planscanR:::storage_path(root, "escape/file.pdf"),
    class = "planscanR_error_storage_path"
  )
  expect_error(
    planscanR:::storage_relative_path("escape/file.pdf", root),
    class = "planscanR_error_storage_path"
  )
  file.symlink(file.path(outside, "missing"), file.path(root, "dangling"))
  expect_error(
    planscanR:::storage_path(root, "dangling/file.pdf"),
    class = "planscanR_error_storage_path"
  )

  dir.create(file.path(root, "files"))
  file.symlink(outside, file.path(root, "files", "nl"))
  expect_error(
    planscanR::cache_path("https://example.test/report.pdf", "nl", "project", cache_dir = root),
    class = "planscanR_error_storage_path"
  )
})

test_that("storage resolver accepts legacy paths and portable root locations", {
  root <- withr::local_tempdir()
  dir.create(file.path(root, "objects"), recursive = TRUE)
  writeLines("pdf", file.path(root, "objects", "sha256.pdf"))

  expect_identical(
    planscanR::storage_resolve_location(
      "files/nl/project/report.pdf", root = root
    ),
    file.path(root, "files", "nl", "project", "report.pdf")
  )
  expect_identical(
    planscanR::storage_resolve_location(
      list(storage_root_id = "cache", relative_path = "objects/sha256.pdf"),
      root = root, must_exist = TRUE
    ),
    file.path(root, "objects", "sha256.pdf")
  )
  expect_identical(
    planscanR::storage_resolve_location(
      list(storage_root_id = "archive", relative_path = "objects/sha256.pdf"),
      root = root, roots = c(archive = root), must_exist = TRUE
    ),
    file.path(root, "objects", "sha256.pdf")
  )
  expect_error(
    planscanR::storage_resolve_location(
      list(storage_root_id = "cache", relative_path = "../escape.pdf"),
      root = root
    ),
    class = "planscanR_error_storage_path"
  )
  expect_error(
    planscanR::storage_resolve_location(
      list(storage_root_id = "missing", relative_path = "objects/sha256.pdf"),
      roots = c(cache = root)
    ),
    class = "planscanR_error_storage_root"
  )
})

test_that("portable external locations do not require a mounted default cache", {
  archive <- withr::local_tempdir()
  withr::local_options(list(planscanR.cache_dir = file.path(archive, "missing-cache")))
  writeLines("portable", file.path(archive, "object"))
  expect_identical(
    planscanR::storage_resolve_location(
      list(storage_root_id = "archive", relative_path = "object"),
      roots = c(archive = archive), must_exist = TRUE
    ),
    file.path(archive, "object")
  )
  expect_identical(
    planscanR::storage_resolve_location(
      file.path(archive, "object"), roots = c(archive = archive), must_exist = TRUE
    ),
    file.path(archive, "object")
  )
})
