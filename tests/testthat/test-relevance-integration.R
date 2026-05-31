# Fetch-time relevance integration: get_assessments_nl() with a topic +
# threshold scores records during the fetch and gates PDF downloads (not result
# rows) on the score. The scoring itself is delegated to planscanR.screen (a
# soft dependency), so these tests skip when it isn't installed. The portal HTTP
# is mocked to the recorded fixture so the test stays offline.

test_that("get_assessments_nl multi-topic mode: threshold gates downloads, not result rows", {
  skip_if_not_installed("planscanR.screen")
  withr::local_options(planscanR.nl_facet_warned = TRUE)
  m <- make_fake_model()

  local_mocked_bindings(
    nl_advice_urls = function() {
      "https://www.commissiemer.nl/advies/fabriek-voor-de-productie-van-aromaten/"
    },
    perform_html = function(req) {
      rvest::read_html(testthat::test_path("fixtures", "nl", "advice-detail-aromaten-delfzijl.html"))
    }
  )
  # Pass with any-topic-above-0 threshold
  res <- get_assessments_nl(
    limit = 5,
    download = FALSE,
    write_sidecar = FALSE,
    topic = c(plastics = "Plastics Conversion", random = "music"),
    relevance_threshold = 0,
    relevance_model = m
  )
  expect_identical(nrow(res), 1L)
  expect_true(all(c("relevance_score_plastics", "relevance_score_random") %in% names(res)))

  # Per-topic threshold that no topic clears: the record is still returned
  # and still scored — the threshold only blocks PDF downloads. With
  # download = FALSE in this call there's nothing to gate, but we verify the
  # scores are present and the row count is unchanged.
  res2 <- get_assessments_nl(
    limit = 5,
    download = FALSE,
    write_sidecar = FALSE,
    topic = c(plastics = "Plastics Conversion", random = "music"),
    relevance_threshold = c(plastics = 1.1, random = 1.1),
    relevance_model = m
  )
  expect_identical(nrow(res2), 1L)
  expect_true(all(c("relevance_score_plastics", "relevance_score_random") %in% names(res2)))
})

test_that("get_assessments_nl with topic + threshold: threshold gates PDF downloads only", {
  skip_if_not_installed("planscanR.screen")
  # Use the fixture detail page so this test stays offline; mock the URL
  # enumeration to return a single URL, and the perform_html() call to read
  # the fixture instead of going over HTTP.
  withr::local_options(planscanR.nl_facet_warned = TRUE)
  m <- make_fake_model()

  local_mocked_bindings(
    nl_advice_urls = function() {
      "https://www.commissiemer.nl/advies/fabriek-voor-de-productie-van-aromaten/"
    },
    perform_html = function(req) {
      rvest::read_html(testthat::test_path("fixtures", "nl", "advice-detail-aromaten-delfzijl.html"))
    }
  )

  res <- get_assessments_nl(
    limit = 5,
    download = FALSE,
    write_sidecar = FALSE,
    topic = "Plastics Conversion Plant",
    relevance_threshold = 0.0, # 0 keeps it; bumping below would drop it
    relevance_model = m
  )
  expect_identical(nrow(res), 1L)
  expect_true("relevance_score_plastics_conversion_plant" %in% names(res))
  expect_identical(res$relevance_model, "fake-bow")

  # And the inverse: a threshold above 1 means no PDFs would be downloaded,
  # but the record is still returned and scored. (download = FALSE here so
  # there are no real downloads either way; the contract under test is that
  # the result row count is unaffected by the threshold.)
  res2 <- get_assessments_nl(
    limit = 5,
    download = FALSE,
    write_sidecar = FALSE,
    topic = "Completely different",
    relevance_threshold = 1.1,
    relevance_model = m
  )
  expect_identical(nrow(res2), 1L)
  expect_true("relevance_score_completely_different" %in% names(res2))
})
