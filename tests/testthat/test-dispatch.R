test_that("supported_countries() returns the shipped set", {
  expect_setequal(supported_countries(), c("nl", "de", "at"))
})

test_that("get_assessments() rejects unsupported countries with classed error", {
  expect_error(
    get_assessments("xx"),
    class = "planscanR_error_unsupported_country"
  )
  expect_error(
    get_assessments("fr"),
    class = "planscanR_error_unsupported_country"
  )
})

test_that("get_assessments() rejects malformed country input", {
  expect_error(
    get_assessments(NULL),
    class = "planscanR_error_bad_input"
  )
  expect_error(
    get_assessments(c("nl", "de")),
    class = "planscanR_error_bad_input"
  )
  expect_error(
    get_assessments(""),
    class = "planscanR_error_bad_input"
  )
})

test_that("normalise_country lowercases", {
  expect_identical(planscanR:::normalise_country("NL"), "nl")
  expect_identical(planscanR:::normalise_country("Nl"), "nl")
})

test_that("select_assessments_handler returns the per-country function", {
  expect_identical(planscanR:::select_assessments_handler("nl"), get_assessments_nl)
  expect_identical(planscanR:::select_assessments_handler("de"), get_assessments_de)
  expect_identical(planscanR:::select_assessments_handler("at"), get_assessments_at)
})
