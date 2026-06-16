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

test_that("req_planscanr applies a per-host throttle to the matching host only", {
  # A per-host rate map throttles its hosts; a host with no entry and no
  # scalar fallback stays full-speed. (RO-1b: the de uvp-verbund portal can be
  # capped harder than the rest of the download run.)
  withr::local_options(
    planscanR.throttle_rate = NULL,
    planscanR.throttle_rates = list("www.uvp-verbund.de" = 0.5)
  )
  req_de <- planscanR:::req_planscanr("https://www.uvp-verbund.de/freitextsuche?q=x")
  expect_false(is.null(req_de$policies$throttle)) # throttle_realm (partial match)

  req_other <- planscanR:::req_planscanr("https://example.org/x.pdf")
  expect_null(req_other$policies$throttle)
})

test_that("a scalar throttle rate is the fallback for hosts without a per-host entry", {
  withr::local_options(
    planscanR.throttle_rate = 2,
    planscanR.throttle_rates = list("www.uvp-verbund.de" = 0.5)
  )
  # Both hosts end up throttled: de by its specific rate, others by the scalar.
  expect_false(is.null(
    planscanR:::req_planscanr("https://www.uvp-verbund.de/x")$policies$throttle
  ))
  expect_false(is.null(
    planscanR:::req_planscanr("https://example.org/x.pdf")$policies$throttle
  ))
})

test_that("throttle_rate_for resolves per-host override then scalar default", {
  withr::local_options(
    planscanR.throttle_rate = 2,
    planscanR.throttle_rates = list("www.uvp-verbund.de" = 0.5)
  )
  expect_equal(
    planscanR:::throttle_rate_for("https://www.uvp-verbund.de/freitextsuche"),
    0.5
  )
  expect_equal(
    planscanR:::throttle_rate_for("https://example.org/a.pdf"),
    2
  )
  # No throttle configured at all -> NULL.
  withr::local_options(planscanR.throttle_rate = NULL, planscanR.throttle_rates = NULL)
  expect_null(planscanR:::throttle_rate_for("https://example.org/a.pdf"))
})

test_that("req_retry_planscanr treats 429/503 (and 500/502/504) as transient", {
  # RO-1b: the download path must back off on portal rate-limits (429) and
  # gateway hiccups (503), but never retry a definitive 4xx like 404/403.
  req <- planscanR:::req_planscanr("https://www.uvp-verbund.de/x")
  is_transient <- req$policies$retry_is_transient
  expect_true(is.function(is_transient))
  for (code in c(429L, 500L, 502L, 503L, 504L)) {
    expect_true(
      is_transient(httr2::response(status_code = code)),
      info = sprintf("status %d should be transient", code)
    )
  }
  for (code in c(200L, 400L, 403L, 404L)) {
    expect_false(
      is_transient(httr2::response(status_code = code)),
      info = sprintf("status %d should NOT be transient", code)
    )
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
