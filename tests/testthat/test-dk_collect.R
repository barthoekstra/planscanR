test_that("DK label/field collectors keep multi-valued items instead of failing", {
  items <- list(
    list(name = list("da-DK" = c("Vind", "Sol")), code = c("a", "b")),
    list(name = list("da-DK" = "Vej"), code = "c"),
    list(name = NULL, code = NULL)
  )
  expect_equal(dk_collect_labels(items), c("Vind; Sol", "Vej"))
  expect_equal(dk_collect_chr(items, "code"), c("a; b", "c"))
  expect_equal(dk_collect_chr(list(), "code"), character(0))
})
