fake_source <- function(prefix, docs = "1") {
  function(country, ...) {
    if (length(docs) == 0L) {
      return(empty_result_tibble())
    }
    tibble::tibble(
      country = country,
      source_portal = prefix,
      document_id = paste0(prefix, "_", docs),
      url = paste0("https://example.org/", prefix, "/", docs),
      retrieved_at = Sys.time(),
      attachment_urls = rep(list(character(0)), length(docs)),
      local_path = rep(list(character(0)), length(docs))
    )
  }
}
mock_registry <- function(...) {
  reg <- lapply(list(...), function(h) list(handler = h, name = "Fake", granularity = "project"))
  testthat::local_mocked_bindings(assessment_sources = function() reg, .env = parent.frame())
}

test_that("legacy call and positional call reach the national handler unchanged", {
  seen <- NULL
  local_mocked_bindings(
    get_assessments_nl = function(...) {
      seen <<- list(...)
      empty_result_tibble()
    }
  )
  res <- get_assessments("NL", NULL, 3, query = "x")
  expect_identical(res, empty_result_tibble())
  expect_false("country" %in% names(seen))
  expect_identical(seen$query, "x")
  get_assessments("nl", NULL, 3)
  expect_identical(seen$limit, 3)
  expect_named(
    seen,
    c(
      "date_range",
      "limit",
      "download",
      "cache_dir",
      "overwrite",
      "max_file_size_mb",
      "write_sidecar",
      "refresh",
      "topic",
      "relevance_threshold",
      "relevance_model"
    )
  )
})

test_that("explicit source dispatches with the ISO-2 country and same args", {
  seen <- NULL
  mock_registry(fake = function(country, ...) {
    seen <<- list(country = country, ...)
    fake_source("fake")(country)
  })
  res <- get_assessments("AL", source = "fake", limit = 2, query = "x")
  expect_identical(seen$country, "al")
  expect_identical(seen$limit, 2)
  expect_identical(seen$query, "x")
  expect_identical(res$document_id, "fake_1")
})

test_that("invalid source and invalid country format error actionably", {
  mock_registry(fake = fake_source("fake"))
  expect_error(get_assessments("al", source = "nope"), "fake", class = "planscanR_error_bad_input")
  expect_error(get_assessments("al", source = NA_character_), class = "planscanR_error_bad_input")
  expect_error(get_assessments("al", source = c("fake", "fake")), class = "planscanR_error_bad_input")
  expect_error(get_assessments("alb", source = "fake"), class = "planscanR_error_bad_input")
  expect_error(get_assessments("a1", source = "fake"), class = "planscanR_error_bad_input")
  expect_error(get_assessments(c("al", "ke"), source = "fake"), class = "planscanR_error_bad_input")
  expect_error(get_assessments("al"), class = "planscanR_error_unsupported_country")
})

test_that("a source returning no records yields a typed empty result", {
  mock_registry(fake = fake_source("fake", character(0)))
  res <- get_assessments("ke", source = "fake")
  expect_identical(res, empty_result_tibble())
})

test_that("source-prefixed IDs from two sources in one country do not collide in the cache", {
  with_temp_cache({
    mock_registry(a = fake_source("a"), b = fake_source("b"))
    ra <- get_assessments("ke", source = "a")
    rb <- get_assessments("ke", source = "b")
    write_record_sidecar(ra)
    write_record_sidecar(rb)
    expect_false(identical(
      sidecar_path("ke", ra$document_id, create = FALSE),
      sidecar_path("ke", rb$document_id, create = FALSE)
    ))
    expect_true(file.exists(sidecar_path("ke", ra$document_id, create = FALSE)))
    expect_true(file.exists(sidecar_path("ke", rb$document_id, create = FALSE)))
  })
})

test_that("get_assessments_sources() lists registry metadata", {
  expect_identical(nrow(get_assessments_sources()), 0L)
  mock_registry(fake = fake_source("fake"))
  s <- get_assessments_sources()
  expect_identical(s$source, "fake")
  expect_named(s, c("source", "name", "granularity", "geography", "scope", "limitations", "url"))
})

test_that("source calls skip the metadata-only discover hint", {
  local_mocked_bindings(metadata_only_countries = function() "ke")
  withr::local_options(planscanR.nudged_discover_ke = NULL)
  mock_registry(fake = fake_source("fake"))
  get_assessments("ke", source = "fake", download = TRUE)
  expect_null(getOption("planscanR.nudged_discover_ke"))
})

test_that("unnamed extra arguments still flow through ... to national handlers", {
  seen <- NULL
  local_mocked_bindings(
    get_assessments_nl = function(...) {
      seen <<- list(...)
      empty_result_tibble()
    }
  )
  get_assessments("nl", NULL, Inf, FALSE, NULL, FALSE, NULL, TRUE, FALSE, NULL, NULL, NULL, FALSE, NULL, "extra")
  expect_true("extra" %in% unlist(seen))
  expect_false("source" %in% names(seen))
})
