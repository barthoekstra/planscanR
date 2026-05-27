test_that("empty_result_tibble has all required columns and zero rows", {
  e <- planscanR:::empty_result_tibble()
  expect_s3_class(e, "tbl_df")
  expect_identical(nrow(e), 0L)
  expect_true(all(planscanR:::required_columns() %in% names(e)))
})

test_that("validate_result_schema accepts a conformant tibble", {
  e <- planscanR:::empty_result_tibble()
  expect_invisible(planscanR:::validate_result_schema(e))
})

test_that("validate_result_schema rejects missing required columns", {
  e <- planscanR:::empty_result_tibble()
  e$retrieved_at <- NULL
  expect_error(
    planscanR:::validate_result_schema(e),
    class = "planscanR_error_bad_schema"
  )
})

test_that("validate_result_schema rejects wrong column type", {
  e <- planscanR:::empty_result_tibble()
  e <- tibble::add_row(
    e,
    country = "nl",
    source_portal = "x",
    document_id = "1",
    url = "https://example.org",
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0))
  )
  e$retrieved_at <- as.character(e$retrieved_at)
  expect_error(
    planscanR:::validate_result_schema(e),
    class = "planscanR_error_bad_schema"
  )
})

test_that("validate_result_schema accepts extra columns", {
  e <- planscanR:::empty_result_tibble()
  e <- tibble::add_row(
    e,
    country = "nl",
    source_portal = "x",
    document_id = "1",
    url = "https://example.org",
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0))
  )
  e$extra_field <- "anything"
  e$another <- 42
  expect_invisible(planscanR:::validate_result_schema(e))
})

test_that("bind_results unions differing column sets", {
  a <- tibble::tibble(
    country = "nl",
    source_portal = "a",
    document_id = "1",
    url = "https://example.org/a",
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0)),
    title = "A"
  )
  b <- tibble::tibble(
    country = "nl",
    source_portal = "b",
    document_id = "2",
    url = "https://example.org/b",
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0)),
    competent_authority = "X"
  )
  out <- bind_results(a, b)
  expect_identical(nrow(out), 2L)
  expect_true(all(c("title", "competent_authority") %in% names(out)))
  expect_true(is.na(out$title[2]))
  expect_true(is.na(out$competent_authority[1]))
})
