test_that("supported_countries() returns the expected v0.1 set", {
  expect_identical(supported_countries(), "nl")
})

test_that("get_assessments() rejects unsupported countries with classed error", {
  expect_error(
    get_assessments("xx"),
    class = "planscanR_error_unsupported_country"
  )
  expect_error(
    get_assessments("de"),
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
  fn <- planscanR:::select_assessments_handler("nl")
  expect_identical(fn, get_assessments_nl)
})
