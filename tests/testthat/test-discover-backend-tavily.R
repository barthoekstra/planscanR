# Offline tests for the Tavily search backend: construction + response parsing.
#
# The network is mocked at the httr2 seam: req_perform returns a dummy
# response object, and resp_body_json returns a recorded/synthetic parsed
# list (the shape Tavily's /search endpoint returns).

test_that("search_backend_tavily constructs and reports its name", {
  b <- search_backend_tavily(api_key = "dummy-not-a-real-key")
  expect_identical(backend_name(b), "tavily")
  expect_s3_class(b, "planscanR_search_backend_tavily")
  expect_s3_class(b, "planscanR_search_backend")
})

test_that("search_backend_tavily validates max_results_cap range", {
  expect_error(search_backend_tavily(api_key = "x", max_results_cap = 200))
  expect_error(search_backend_tavily(api_key = "x", max_results_cap = 0))
})

test_that("search_backend_tavily errors when no api_key is available", {
  # The constructor falls back to Sys.getenv("TAVILY_API_KEY"); with the env
  # var unset (and no explicit key) it aborts with a missing-credentials error.
  withr::local_envvar(TAVILY_API_KEY = "")
  expect_error(
    search_backend_tavily(),
    class = "planscanR_error_missing_credentials"
  )
})

test_that("web_search parses results and drops entries without a url", {
  b <- search_backend_tavily(api_key = "dummy-not-a-real-key")

  fixture <- list(
    results = list(
      list(url = "https://a/x.pdf", title = "A", content = "...", score = 0.9),
      list(url = "https://b/y.pdf", title = "B", content = "...", score = 0.5),
      list(title = "no url", content = "...")
    )
  )

  local_mocked_bindings(
    req_perform = function(req, ...) structure(list(), class = "httr2_response"),
    resp_body_json = function(resp, ...) fixture,
    .package = "httr2"
  )

  out <- web_search(b, "wind filetype:pdf")
  expect_length(out, 2L)
  expect_named(out[[1]], c("url", "title", "content", "score", "raw_content"))
  expect_type(out[[1]]$score, "double")
  expect_identical(out[[1]]$url, "https://a/x.pdf")
  expect_identical(out[[2]]$url, "https://b/y.pdf")
})

test_that("web_search returns an empty list when there are no results", {
  b <- search_backend_tavily(api_key = "dummy-not-a-real-key")

  local_mocked_bindings(
    req_perform = function(req, ...) structure(list(), class = "httr2_response"),
    resp_body_json = function(resp, ...) list(results = list()),
    .package = "httr2"
  )
  expect_length(web_search(b, "wind filetype:pdf"), 0L)

  # Missing `results` key entirely also yields an empty list.
  local_mocked_bindings(
    req_perform = function(req, ...) structure(list(), class = "httr2_response"),
    resp_body_json = function(resp, ...) list(),
    .package = "httr2"
  )
  expect_length(web_search(b, "wind filetype:pdf"), 0L)
})
