# Tests for the shared HTTP request builder.

test_that("req_planscanr attaches a throttle only when the option is set", {
  # Default: no throttle policy (DE crawl + AT services stay full-speed).
  withr::local_options(planscanR.throttle_rate = NULL)
  req <- planscanR:::req_planscanr("https://example.org")
  expect_null(req$policies$throttle)

  # Opt-in: a positive rate attaches httr2's throttle policy.
  withr::local_options(planscanR.throttle_rate = 1)
  req <- planscanR:::req_planscanr("https://example.org")
  expect_false(is.null(req$policies$throttle))
})

test_that("req_planscanr ignores a non-positive or non-finite throttle rate", {
  for (bad in list(0, -1, Inf, NA_real_)) {
    withr::local_options(planscanR.throttle_rate = bad)
    req <- planscanR:::req_planscanr("https://example.org")
    expect_null(req$policies$throttle)
  }
})

test_that("get_assessments_nl sets an NL-scoped throttle by default", {
  # The handler should flip the throttle option on for the duration of its
  # call. We stub the URL enumeration to return nothing so no HTTP happens,
  # and capture the option value seen *inside* the handler via the relevance
  # setup hook (which runs after the option is set).
  seen_rate <- NULL
  local_mocked_bindings(
    nl_advice_urls = function() character(0),
    setup_relevance = function(topic, model, country) {
      seen_rate <<- getOption("planscanR.throttle_rate")
      NULL
    }
  )
  withr::local_options(planscanR.nl_facet_warned = TRUE)
  get_assessments_nl(limit = 0, download = FALSE, write_sidecar = FALSE)
  expect_equal(seen_rate, 1)
})

test_that("get_assessments_nl throttle is configurable and disablable", {
  seen_rate <- NULL
  local_mocked_bindings(
    nl_advice_urls = function() character(0),
    setup_relevance = function(topic, model, country) {
      seen_rate <<- getOption("planscanR.throttle_rate")
      NULL
    }
  )
  withr::local_options(planscanR.nl_facet_warned = TRUE)

  # Custom rate flows through.
  withr::with_options(list(planscanR.nl_throttle_rate = 3), {
    get_assessments_nl(limit = 0, download = FALSE, write_sidecar = FALSE)
  })
  expect_equal(seen_rate, 3)

  # A falsy rate disables the throttle entirely (option left unset).
  seen_rate <- "sentinel"
  withr::with_options(list(planscanR.nl_throttle_rate = 0, planscanR.throttle_rate = NULL), {
    get_assessments_nl(limit = 0, download = FALSE, write_sidecar = FALSE)
  })
  expect_null(seen_rate)
})
