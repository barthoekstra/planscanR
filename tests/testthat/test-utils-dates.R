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

# ---- shared date helpers (Phase 4) ----------------------------------------

test_that("parse_iso_date parses the leading YYYY-MM-DD of an ISO string", {
  expect_identical(planscanR:::parse_iso_date("2024-06-01"), as.Date("2024-06-01"))
  expect_identical(planscanR:::parse_iso_date("2024-06-01T12:30:00Z"), as.Date("2024-06-01"))
  expect_identical(planscanR:::parse_iso_date("2023-12-31T00:00:00.000Z"), as.Date("2023-12-31"))
})

test_that("parse_iso_date returns NA for empty / NA / NULL / non-scalar / junk", {
  expect_true(is.na(planscanR:::parse_iso_date(NA_character_)))
  expect_true(is.na(planscanR:::parse_iso_date("")))
  expect_true(is.na(planscanR:::parse_iso_date(NULL)))
  expect_true(is.na(planscanR:::parse_iso_date(c("2024-01-01", "2024-02-02"))))
  expect_true(is.na(planscanR:::parse_iso_date("not-a-date")))
})

test_that("parse_dmy extracts a DD.MM.YYYY date anywhere in the string", {
  expect_identical(planscanR:::parse_dmy("12.05.2024"), as.Date("2024-05-12"))
  expect_identical(planscanR:::parse_dmy("12.05.2024 (wrapped label)"), as.Date("2024-05-12"))
  # Bulgarian-style embedding: "от 12.05.2024 г."
  expect_identical(planscanR:::parse_dmy("от 12.05.2024 г."), as.Date("2024-05-12"))
})

test_that("parse_dmy returns NA when there is no DD.MM.YYYY date", {
  expect_true(is.na(planscanR:::parse_dmy(NA_character_)))
  expect_true(is.na(planscanR:::parse_dmy("")))
  expect_true(is.na(planscanR:::parse_dmy(NULL)))
  expect_true(is.na(planscanR:::parse_dmy("no date here")))
})

test_that("parse_dutch_date parses Dutch month names and abbreviations", {
  expect_identical(planscanR:::parse_dutch_date("26 mei 2026"), as.Date("2026-05-26"))
  expect_identical(planscanR:::parse_dutch_date("1 januari 2000"), as.Date("2000-01-01"))
  expect_identical(planscanR:::parse_dutch_date("26 mrt 2026"), as.Date("2026-03-26"))
  expect_identical(planscanR:::parse_dutch_date("3 sept 2024"), as.Date("2024-09-03"))
})

test_that("parse_dutch_date returns NA for bad input", {
  expect_true(is.na(planscanR:::parse_dutch_date(NA_character_)))
  expect_true(is.na(planscanR:::parse_dutch_date("")))
  expect_true(is.na(planscanR:::parse_dutch_date("26 fakemonth 2026")))
  expect_true(is.na(planscanR:::parse_dutch_date("not a date")))
})

test_that("parse_german_date parses a leading numeric DD.MM.YYYY date", {
  expect_identical(planscanR:::parse_german_date("12.03.2024"), as.Date("2024-03-12"))
  expect_identical(planscanR:::parse_german_date("1.2.2024"), as.Date("2024-02-01"))
  # Trailing text after a leading date is fine (anchored at start).
  expect_identical(planscanR:::parse_german_date("12.03.2024 Bekanntmachung"), as.Date("2024-03-12"))
})

test_that("parse_german_date is anchored: text before the date yields NA", {
  expect_true(is.na(planscanR:::parse_german_date("vom 12.03.2024")))
  expect_true(is.na(planscanR:::parse_german_date(NA_character_)))
  expect_true(is.na(planscanR:::parse_german_date("")))
  expect_true(is.na(planscanR:::parse_german_date("kein Datum")))
})
