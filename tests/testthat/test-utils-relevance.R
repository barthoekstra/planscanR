# Unit tests for the pure relevance helpers in utils_relevance.R. These need no
# planscanR.screen / embedding model — they exercise the maths and argument
# handling directly.

# ---- cosine_similarity_matrix ---------------------------------------------

test_that("cosine_similarity_matrix: 1 for identical, 0 for orthogonal rows", {
  m <- matrix(c(1, 0, 0, 1), nrow = 2, byrow = TRUE) # (1,0), (0,1)
  topics <- matrix(c(1, 0), nrow = 1) # (1,0)
  out <- planscanR:::cosine_similarity_matrix(m, topics)
  expect_identical(dim(out), c(2L, 1L))
  expect_equal(out[1, 1], 1)
  expect_equal(out[2, 1], 0)
})

test_that("cosine_similarity_matrix: zero-norm rows/cols become NA, others defined", {
  m <- matrix(c(0, 0, 1, 1), nrow = 2, byrow = TRUE) # row1 is zero
  topics <- matrix(c(1, 1, 0, 0), nrow = 2, byrow = TRUE) # topic2 is zero
  out <- planscanR:::cosine_similarity_matrix(m, topics)
  expect_true(all(is.na(out[1, ]))) # zero doc vector -> NA row
  expect_true(all(is.na(out[, 2]))) # zero topic vector -> NA column
  expect_false(is.na(out[2, 1])) # non-zero / non-zero is defined
})

test_that("cosine_similarity_matrix aborts on non-matrix input", {
  expect_error(planscanR:::cosine_similarity_matrix(1:3, matrix(1)), "matrix")
})

# ---- normalise_topics ------------------------------------------------------

test_that("normalise_topics handles NULL / single / named / unnamed", {
  expect_null(planscanR:::normalise_topics(NULL))
  expect_identical(names(planscanR:::normalise_topics("wind energy")), "wind_energy")
  expect_identical(names(planscanR:::normalise_topics(c(w = "wind", s = "solar"))), c("w", "s"))
  expect_identical(
    names(planscanR:::normalise_topics(c("wind energy", "solar power"))),
    c("wind_energy", "solar_power")
  )
})

test_that("normalise_topics aborts on bad input and duplicate slugs", {
  expect_error(planscanR:::normalise_topics(1:3), class = "planscanR_error_bad_input")
  expect_error(planscanR:::normalise_topics(character(0)), class = "planscanR_error_bad_input")
  expect_error(planscanR:::normalise_topics(c("a", "")), class = "planscanR_error_bad_input")
  expect_error(
    planscanR:::normalise_topics(c(x = "wind", x = "solar")),
    class = "planscanR_error_bad_input"
  )
})

# ---- slugify_topic ---------------------------------------------------------

test_that("slugify_topic lowercases, underscores, and falls back to 'topic'", {
  expect_identical(planscanR:::slugify_topic("Wind Energy"), "wind_energy")
  expect_identical(planscanR:::slugify_topic("solar/PV power"), "solar_pv_power")
  expect_identical(planscanR:::slugify_topic("!!!"), "topic")
})

# ---- passes_download_gate (the download threshold gate) ---------------------

test_that("passes_download_gate passes when threshold or rel is NULL", {
  expect_true(planscanR:::passes_download_gate(list(), rel = NULL, threshold = 0.5))
  expect_true(planscanR:::passes_download_gate(
    list(),
    rel = list(topics = c(w = "wind")),
    threshold = NULL
  ))
})

test_that("passes_download_gate scalar threshold: pass iff any score >= threshold (boundary inclusive)", {
  rel <- list(topics = c(wind = "wind", solar = "solar"))
  expect_true(planscanR:::passes_download_gate(
    list(relevance_score_wind = 0.6, relevance_score_solar = 0.1),
    rel,
    0.5
  ))
  expect_false(planscanR:::passes_download_gate(
    list(relevance_score_wind = 0.2, relevance_score_solar = 0.1),
    rel,
    0.5
  ))
  expect_true(planscanR:::passes_download_gate(
    # exact boundary
    list(relevance_score_wind = 0.5, relevance_score_solar = 0.1),
    rel,
    0.5
  ))
})

test_that("passes_download_gate named threshold: any named topic clearing its own cutoff passes", {
  rel <- list(topics = c(wind = "wind", solar = "solar"))
  rec <- list(relevance_score_wind = 0.4, relevance_score_solar = 0.9)
  expect_true(planscanR:::passes_download_gate(rec, rel, c(solar = 0.8)))
  expect_false(planscanR:::passes_download_gate(rec, rel, c(wind = 0.8)))
})

test_that("passes_download_gate ignores NA scores", {
  rel <- list(topics = c(wind = "wind"))
  expect_false(planscanR:::passes_download_gate(
    list(relevance_score_wind = NA_real_),
    rel,
    0.5
  ))
})
