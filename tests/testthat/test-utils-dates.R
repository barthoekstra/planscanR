test_that("parse_date_range accepts NULL", {
  expect_null(planscanR:::parse_date_range(NULL))
})

test_that("parse_date_range parses character", {
  out <- planscanR:::parse_date_range(c("2024-01-01", "2024-12-31"))
  expect_s3_class(out, "Date")
  expect_identical(out, as.Date(c("2024-01-01", "2024-12-31")))
})

test_that("parse_date_range parses Date objects", {
  d <- as.Date(c("2024-01-01", "2024-12-31"))
  expect_identical(planscanR:::parse_date_range(d), d)
})

test_that("parse_date_range rejects length != 2", {
  expect_error(
    planscanR:::parse_date_range("2024-01-01"),
    class = "planscanR_error_bad_input"
  )
  expect_error(
    planscanR:::parse_date_range(c("2024-01-01", "2024-02-01", "2024-03-01")),
    class = "planscanR_error_bad_input"
  )
})

test_that("parse_date_range rejects reversed order", {
  expect_error(
    planscanR:::parse_date_range(c("2024-12-31", "2024-01-01")),
    class = "planscanR_error_bad_input"
  )
})

test_that("parse_date_range rejects unparseable strings", {
  expect_error(
    planscanR:::parse_date_range(c("yesterday", "tomorrow")),
    class = "planscanR_error_bad_input"
  )
})

test_that("nl_parse_dutch_date parses Dutch month names", {
  expect_identical(planscanR:::nl_parse_dutch_date("26 mei 2026"), as.Date("2026-05-26"))
  expect_identical(planscanR:::nl_parse_dutch_date("1 januari 2000"), as.Date("2000-01-01"))
  expect_identical(planscanR:::nl_parse_dutch_date("15 oktober 1999"), as.Date("1999-10-15"))
})

test_that("nl_parse_dutch_date handles abbreviated months", {
  expect_identical(planscanR:::nl_parse_dutch_date("26 mrt 2026"), as.Date("2026-03-26"))
})

test_that("nl_parse_dutch_date returns NA for bad input", {
  expect_true(is.na(planscanR:::nl_parse_dutch_date(NA_character_)))
  expect_true(is.na(planscanR:::nl_parse_dutch_date("")))
  expect_true(is.na(planscanR:::nl_parse_dutch_date("not a date")))
  expect_true(is.na(planscanR:::nl_parse_dutch_date("26 fakemonth 2026")))
})
