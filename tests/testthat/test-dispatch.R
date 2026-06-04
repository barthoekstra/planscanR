test_that("supported_countries() returns the shipped set", {
  expect_setequal(
    supported_countries(),
    c("nl", "de", "fr", "at", "dk", "be", "ee", "fi", "bg", "cz", "hr", "gr", "is", "ie")
  )
})

test_that("get_assessments() rejects unsupported countries with classed error", {
  expect_error(
    get_assessments("xx"),
    class = "planscanR_error_unsupported_country"
  )
  expect_error(
    get_assessments("zz"),
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
  expect_identical(planscanR:::select_assessments_handler("fr"), get_assessments_fr)
  expect_identical(planscanR:::select_assessments_handler("at"), get_assessments_at)
  expect_identical(planscanR:::select_assessments_handler("dk"), get_assessments_dk)
  expect_identical(planscanR:::select_assessments_handler("be"), get_assessments_be)
  expect_identical(planscanR:::select_assessments_handler("ee"), get_assessments_ee)
  expect_identical(planscanR:::select_assessments_handler("fi"), get_assessments_fi)
  expect_identical(planscanR:::select_assessments_handler("bg"), get_assessments_bg)
  expect_identical(planscanR:::select_assessments_handler("cz"), get_assessments_cz)
  expect_identical(planscanR:::select_assessments_handler("hr"), get_assessments_hr)
  expect_identical(planscanR:::select_assessments_handler("gr"), get_assessments_gr)
  expect_identical(planscanR:::select_assessments_handler("is"), get_assessments_is)
  expect_identical(planscanR:::select_assessments_handler("ie"), get_assessments_ie)
})
