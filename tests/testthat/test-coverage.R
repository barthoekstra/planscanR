test_that("get_assessments_coverage returns expected shape", {
  c <- get_assessments_coverage()
  expect_s3_class(c, "tbl_df")
  expect_true(all(c("country", "source_portal", "base_url", "requires_auth", "status", "facets") %in% names(c)))
  expect_true("nl" %in% c$country)
})

test_that("NL coverage row exposes the facet vocabularies", {
  c <- get_assessments_coverage()
  nl <- c[c$country == "nl", ]
  expect_identical(nl$source_portal, "commissiemer.nl")
  expect_false(nl$requires_auth)
  expect_identical(nl$status, "supported")
  f <- nl$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("advice_type", "status", "province", "theme"))
  expect_true("energie" %in% f$theme)
  expect_true("windenergie" %in% f$theme)
  expect_true("afgerond" %in% f$status)
  expect_true("toetsing" %in% f$advice_type)
})
