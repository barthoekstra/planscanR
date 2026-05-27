test_that("biogain_assessment_topics returns the expected slug set", {
  out <- biogain_assessment_topics()
  expect_type(out, "character")
  expect_setequal(
    names(out),
    c(
      "wind",
      "solar",
      "power_grid",
      "renewable_energy",
      "energy_transition_strategy",
      "renewable_zoning"
    )
  )
  expect_true(all(nzchar(unname(out))))
  # Slugs are unique (so they don't collide as column names).
  expect_identical(anyDuplicated(names(out)), 0L)
})

test_that("biogain_assessment_topics integrates with score_records() multi-topic mode", {
  reset_relevance_warnings()
  m <- make_fake_model() # defined in test-relevance-model.R helpers
  recs <- tibble::tibble(
    country = c("nl", "nl"),
    title = c("Windpark Foo", "Energiecampus Bar"),
    summary = c("wind energy advice", "energy strategy advice")
  )
  out <- score_records(recs, topic = biogain_assessment_topics(), model = m)
  for (slug in names(biogain_assessment_topics())) {
    expect_true(
      paste0("relevance_score_", slug) %in% names(out),
      info = paste("missing column for", slug)
    )
  }
})
