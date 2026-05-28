# Tests for the BIOGAIN selection procedure.

mk <- function(...) {
  base <- tibble::tibble(
    relevance_score_wind = 0,
    relevance_score_solar = 0,
    relevance_score_power_grid = 0,
    relevance_score_renewable_energy = 0,
    relevance_score_energy_transition_strategy = 0,
    relevance_score_renewable_zoning = 0,
    class_label = "other",
    class_relevant = FALSE,
    class_score = 0.3,
    kw_total = 0L,
    title = "x",
    summary = NA_character_
  )
  args <- list(...)
  for (nm in names(args)) {
    base[[nm]] <- args[[nm]]
  }
  base
}

test_that("cosine arm selects (any topic >= threshold)", {
  out <- select_assessments(mk(relevance_score_wind = 0.7))
  expect_true(out$selected)
  expect_true(out$cosine_relevant)
})

test_that("classifier arm selects", {
  out <- select_assessments(mk(class_label = "wind", class_relevant = TRUE, class_score = 0.8))
  expect_true(out$selected)
})

test_that("keyword arm rescues at kw_total >= kw_min", {
  # No cosine, no class relevance, but strong keyword signal.
  out <- select_assessments(mk(kw_total = 3L))
  expect_true(out$selected)
  # Below kw_min -> not selected.
  out2 <- select_assessments(mk(kw_total = 1L))
  expect_false(out2$selected)
})

test_that("confident fossil/nuclear is trimmed even if a signal fires", {
  # cosine relevant, but classifier confidently says nuclear -> excluded.
  out <- select_assessments(mk(
    relevance_score_wind = 0.7,
    class_label = "nuclear",
    class_score = 0.8
  ))
  expect_false(out$selected)
  # Low-confidence nuclear is NOT trimmed (kept via cosine).
  out2 <- select_assessments(mk(
    relevance_score_wind = 0.7,
    class_label = "nuclear",
    class_score = 0.2
  ))
  expect_true(out2$selected)
})

test_that("nothing relevant -> not selected", {
  expect_false(select_assessments(mk())$selected)
})

test_that("kw_total is computed when absent", {
  recs <- tibble::tibble(
    relevance_score_wind = 0,
    class_label = "other",
    class_relevant = FALSE,
    class_score = 0.1,
    title = "Windpark De Test",
    summary = "bouw van windturbines"
  )
  out <- select_assessments(recs)
  expect_true("kw_total" %in% names(out))
  expect_true(out$selected) # wind keywords push it over kw_min
})
