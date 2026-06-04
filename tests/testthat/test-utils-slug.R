# Shared ascii_slug() — the lowercase / collapse / trim / fallback tail used by
# every per-handler *_section_slug() and by slugify_topic(). Transliteration of
# non-ASCII is the CALLER's responsibility (the handler maps are deliberately
# language-specific: German ä->ae vs Estonian ä->a, Danish æ->ae, ...), so
# ascii_slug() itself does not transliterate.

test_that("ascii_slug lowercases, collapses non-alphanumerics, and trims", {
  expect_identical(planscanR:::ascii_slug("Aanmelding"), "aanmelding")
  expect_identical(planscanR:::ascii_slug("Plan Type 2"), "plan_type_2")
  expect_identical(planscanR:::ascii_slug("Foo / Bar & Baz"), "foo_bar_baz")
  expect_identical(planscanR:::ascii_slug("  --Foo__Bar--  "), "foo_bar")
  expect_identical(planscanR:::ascii_slug("ABC123"), "abc123")
})

test_that("ascii_slug returns the fallback for empty / NA / non-string input", {
  expect_identical(planscanR:::ascii_slug("", fallback = "document"), "document")
  expect_identical(planscanR:::ascii_slug("///", fallback = "document"), "document")
  expect_identical(planscanR:::ascii_slug(NA_character_, fallback = "x"), "x")
  expect_identical(planscanR:::ascii_slug(NULL, fallback = "x"), "x")
  expect_identical(planscanR:::ascii_slug(c("a", "b"), fallback = "x"), "x")
})

test_that("ascii_slug default fallback is a stable token", {
  # Non-ASCII with no caller-side transliteration collapses away; the fallback
  # keeps the slug non-empty rather than producing "".
  expect_true(nzchar(planscanR:::ascii_slug("Щ")))
})
