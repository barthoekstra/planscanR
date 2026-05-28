# Tests for the lexical keyword layer.

test_that("biogain_keyword_lexicon has the expected topics", {
  lex <- biogain_keyword_lexicon()
  expect_true(all(
    c("wind", "solar", "power_grid", "other_renewable", "energy_strategy", "renewable_zoning") %in% names(lex)
  ))
  expect_true(all(vapply(lex, is.character, logical(1))))
})

test_that("score_keywords adds kw_<topic> + kw_total counts", {
  recs <- tibble::tibble(
    title = c(
      "Windturbines Amsterdam-Noord", # wind (NL compound)
      "Woningbouw Westergouwe, Gouda", # housing -> no energy terms
      "Neubau einer 380 kV-Hochspannungsfreileitung", # grid (DE)
      "Zonnepark De Kwekerij" # solar (NL compound)
    ),
    summary = c(
      "plaatsing van windturbines, bestemmingsplan aangepast",
      "ontwikkeling van een woonwijk met woningen",
      "Errichtung einer Hoechstspannungsleitung",
      "aanleg van een zonnepark met panelen"
    )
  )
  out <- score_keywords(recs)
  expect_true(all(c("kw_wind", "kw_solar", "kw_power_grid", "kw_total") %in% names(out)))
  # Wind compound matches the `wind` stem (multiple occurrences).
  expect_gt(out$kw_wind[1], 0L)
  expect_gt(out$kw_total[1], 0L)
  # Housing has zero energy keywords — the key discriminator for the zoning
  # overlap.
  expect_identical(out$kw_total[2], 0L)
  # German grid + Dutch solar land on the right topic.
  expect_gt(out$kw_power_grid[3], 0L)
  expect_gt(out$kw_solar[4], 0L)
})

test_that("score_keywords folds in the category (native_type) when present", {
  recs <- tibble::tibble(
    title = "Vorhaben 123",
    summary = "Antrag",
    native_type = "Windkraftanlagen" # category carries the only energy term
  )
  out <- score_keywords(recs)
  expect_gt(out$kw_wind, 0L)
})

test_that("score_keywords matches accented source text via normalisation", {
  # Höchstspannung (umlaut) should match the ASCII 'hoechstspann' term.
  recs <- tibble::tibble(title = "Höchstspannungsfreileitung", summary = NA_character_)
  out <- score_keywords(recs)
  expect_gt(out$kw_power_grid, 0L)
})

test_that("score_keywords preserves a zero-row tibble", {
  recs <- tibble::tibble(title = character(0), summary = character(0))
  out <- score_keywords(recs)
  expect_identical(nrow(out), 0L)
  expect_true("kw_total" %in% names(out))
})
