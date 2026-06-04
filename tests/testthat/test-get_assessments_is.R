# Tests for get_assessments_is(). Offline strategy: stub `is_graphql` (the
# single GraphQL network seam) to hand back the recorded Skipulagsgátt
# `{"data":{...}}` envelopes so no live HTTP is needed in CI. The handler
# distinguishes the listing query from the detail query by inspecting the
# GraphQL `variables`. Fixtures (tests/testthat/fixtures/is/):
#  - listing_process16.json: an issueConnection envelope with 3 edges
#      (ids 137, 189 with geography; id 333 without).
#  - single_issue_137.json: a full singleIssue WITH geometry (Point) + phase
#      files across ALMENNT / VIDBROGD / AFGREIDSLA roles (one unpublished).
#  - single_issue_333.json: a singleIssue WITHOUT geometry and with no
#      published files (covers the no-geometry / no-attachment edge case).

is_fixture <- function(name) {
  jsonlite::fromJSON(fixture_path("is", name), simplifyVector = FALSE)
}

# Pre-load fixtures at file-load time (before any withr::with_tempdir()).
.is_listing <- is_fixture("listing_process16.json")
.is_single_137 <- is_fixture("single_issue_137.json")
.is_single_333 <- is_fixture("single_issue_333.json")

.is_listing_edges <- .is_listing$data$issueConnection$edges
.is_node_137 <- .is_listing_edges[[1]]$node
.is_node_333 <- .is_listing_edges[[3]]$node

# An index entry shaped like is_fetch_listing() emits, for process 16.
is_entry_137 <- function() {
  list(
    process_id = "16",
    id = "137",
    issue_number = "0137/2023",
    title = "Kvíslatunguvirkjun í Strandabyggð",
    published_date = "2023-06-01T09:31:55.254Z",
    closed_date = "2024-12-09T00:00:00.000Z",
    lifecycle = "done",
    has_geography = TRUE,
    process_type = "MAT_A_UMHVERFISAHRIFUM",
    current_phase = "Staðfesting með lokagögnum"
  )
}
is_entry_333 <- function() {
  list(
    process_id = "16",
    id = "333",
    issue_number = "0333/2023",
    title = "Vindorkuver að Grímsstöðum 2",
    published_date = "2023-07-03T15:46:31.410Z",
    closed_date = NULL,
    lifecycle = "process_initialized",
    has_geography = FALSE,
    process_type = "MAT_A_UMHVERFISAHRIFUM",
    current_phase = "Staðfesting"
  )
}

# Wrap a listing node into a minimal singleIssue envelope (no phases / geometry)
# so the mock can serve a detail for any edge it lists without a dedicated
# fixture — the publishedDate / lifecycle carry over so the date filter bites.
single_from_node <- function(node) {
  list(
    data = list(
      singleIssue = list(
        id = node$id,
        issueNumber = node$issueNumber,
        title = node$title,
        description = NULL,
        publishedDate = node$publishedDate,
        closedDate = node$closedDate,
        lifecycle = node$lifecycle,
        hasGeography = node$hasGeography,
        process = node$process,
        currentPhase = node$currentPhase,
        communities = node$communities,
        postalCodes = list(),
        geographies = NULL,
        phases = list()
      )
    )
  )
}

# A combined `is_graphql` mock: returns the listing envelope when the query is
# the listing query (variables carry `input$processId`), the matching
# singleIssue envelope when it is the detail query (variables carry
# `input$issueId`).
mock_graphql_all <- function() {
  function(query, variables = NULL) {
    input <- (variables %||% list())$input %||% list()
    if (!is.null(input$issueId)) {
      switch(
        as.character(input$issueId),
        `137` = .is_single_137,
        `189` = single_from_node(.is_listing_edges[[2]]$node),
        `333` = .is_single_333,
        .is_single_333
      )
    } else {
      # Only serve the listing once (process 16); empty for the others so the
      # All-process loop doesn't duplicate.
      if (identical(as.character(input$processId), "16")) {
        .is_listing
      } else {
        list(
          data = list(
            issueConnection = list(
              totalCount = 0L,
              pageInfo = list(hasNextPage = FALSE, endCursor = NULL),
              edges = list()
            )
          )
        )
      }
    }
  }
}

# -- Parse unit tests -------------------------------------------------------

test_that("is_parse_issue extracts every conventional column (record with geometry + phase files)", {
  url <- planscanR:::is_canonical_url("137")
  parsed <- planscanR:::is_parse_issue(url, is_entry_137(), .is_single_137$data$singleIssue)
  rec <- parsed$record

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "is")
  expect_identical(rec$source_portal, "skipulagsgatt.is")
  expect_identical(rec$document_id, "IS-16-137")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Kvíslatunguvirkjun")
  expect_match(rec$summary, "Orkubú Vestfjarða")
  # Conventional cross-portal columns.
  expect_identical(rec$competent_authority, "Skipulagsstofnun")
  expect_true(is.na(rec$proponent))
  expect_match(rec$native_type, "Mat á umhverfisáhrifum")
  expect_match(rec$jurisdiction, "Strandabyggð")
  expect_match(rec$jurisdiction, "Vestfirðir")
  expect_identical(rec$status, "done")
  expect_identical(rec$date_published, as.Date("2023-06-01"))
  expect_identical(rec$date_decision, as.Date("2024-12-09"))
  # Country-specific extras.
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$process_id, "16")
  expect_identical(rec$process_type, "MAT_A_UMHVERFISAHRIFUM")
  expect_identical(rec$lifecycle, "done")
  expect_identical(rec$issue_number, "0137/2023")

  # Attachment sections grouped by phase-file role; unpublished file dropped.
  expect_true("attachment_urls_almennt" %in% names(rec))
  expect_true("attachment_urls_vidbrogd" %in% names(rec))
  expect_true("attachment_urls_afgreidsla" %in% names(rec))
  almennt <- rec$attachment_urls_almennt[[1]]
  vidbrogd <- rec$attachment_urls_vidbrogd[[1]]
  afgreidsla <- rec$attachment_urls_afgreidsla[[1]]
  expect_length(almennt, 1L) # one published ALMENNT
  expect_length(vidbrogd, 1L)
  expect_length(afgreidsla, 2L) # two published AFGREIDSLA (one unpublished dropped)
  expect_match(almennt[[1]], "^https://www\\.skipulagsgatt\\.is/files/")

  # Union of all sections.
  urls <- rec$attachment_urls[[1]]
  expect_length(urls, 4L) # 1 + 1 + 2 published files
  expect_true(all(grepl("^https://www\\.skipulagsgatt\\.is/files/", urls)))

  # Geometry: a Point, double-parsed from the GeoJSON string.
  geom <- parsed$geometry
  expect_identical(geom$type, "Point")
  expect_length(geom$coordinates, 2L)
  expect_equal(geom$coordinates[[1]], -21.815823456903185, tolerance = 1e-9)
  expect_equal(geom$coordinates[[2]], 65.83428262150709, tolerance = 1e-9)
})

test_that("is_parse_issue handles a record without geometry and without published files", {
  url <- planscanR:::is_canonical_url("333")
  parsed <- planscanR:::is_parse_issue(url, is_entry_333(), .is_single_333$data$singleIssue)
  rec <- parsed$record

  expect_identical(rec$document_id, "IS-16-333")
  expect_identical(rec$assessment_type, "EIA")
  # No geometry present (hasGeography = false, geographies = null).
  expect_null(parsed$geometry)
  expect_true(is.na(rec$geometry_path))
  # No published attachments — still schema-valid (zero-length union).
  expect_identical(rec$attachment_urls[[1]], character(0))
  expect_false("attachment_urls_almennt" %in% names(rec))
  # date_decision is NA (closedDate null).
  expect_true(is.na(rec$date_decision))
})

test_that("is_parse_geographies double-parses the GeoJSON string", {
  geos <- .is_single_137$data$singleIssue$geographies
  geom <- planscanR:::is_parse_geographies(geos)
  expect_identical(geom$type, "Point")
  # The raw feature geometry is a JSON *string*, not a list.
  expect_true(is.character(geos$features[[1]]$geometry))
})

test_that("is_parse_geographies returns NULL on empty / null collections", {
  expect_null(planscanR:::is_parse_geographies(NULL))
  expect_null(planscanR:::is_parse_geographies(list(type = "FeatureCollection", features = list())))
})

test_that("is_section_slug transliterates and slugs roles", {
  expect_identical(planscanR:::is_section_slug("ALMENNT"), "almennt")
  expect_identical(planscanR:::is_section_slug("VIDBROGD"), "vidbrogd")
  expect_identical(planscanR:::is_section_slug("AFGREIDSLA"), "afgreidsla")
  expect_identical(planscanR:::is_section_slug(NULL), "document")
  expect_identical(planscanR:::is_section_slug(""), "document")
})

test_that("is_processes_for maps assessment_type to process ids", {
  expect_identical(planscanR:::is_processes_for("All"), c("15", "16", "501"))
  expect_identical(planscanR:::is_processes_for("EIA"), c("15", "16"))
  expect_identical(planscanR:::is_processes_for("SEA"), "501")
})

# -- End-to-end with sidecar ------------------------------------------------

test_that("get_assessments_is end-to-end (sidecar-first, geometry persisted, downloads off)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(is_graphql = mock_graphql_all())

    res <- get_assessments_is(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res), 3L)
    planscanR:::validate_result_schema(res)
    expect_setequal(res$document_id, c("IS-16-137", "IS-16-189", "IS-16-333"))

    # All three sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "is"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 3L)

    # The geo record (137) has a sibling .geometry.geojson; the no-geo one (333)
    # does not.
    geo_file <- file.path(cache, "files", "is", "IS-16-137", "IS-16-137.geometry.geojson")
    expect_true(file.exists(geo_file))
    geo <- jsonlite::fromJSON(geo_file, simplifyVector = FALSE)
    expect_identical(geo$type, "FeatureCollection")
    expect_match(geo$crs$properties$name, "EPSG::4326")
    expect_identical(geo$features[[1]]$geometry$type, "Point")
    nogeo_file <- file.path(cache, "files", "is", "IS-16-333", "IS-16-333.geometry.geojson")
    expect_false(file.exists(nogeo_file))

    # Second call with refresh = FALSE must NOT re-invoke is_parse_issue.
    local_mocked_bindings(
      is_parse_issue = function(...) {
        stop("is_parse_issue should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_is(assessment_type = "EIA", limit = 5, download = FALSE)
    expect_identical(nrow(res2), 3L)
    expect_setequal(res2$document_id, c("IS-16-137", "IS-16-189", "IS-16-333"))
  })
})

test_that("get_assessments_is honours the date_range filter (client-side guard)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(is_graphql = mock_graphql_all())

    # 137 published 2023-06-01, 189 published 2023-06-07, 333 published
    # 2023-07-03. A June window selects only 137 and 189.
    res <- get_assessments_is(
      assessment_type = "EIA",
      date_range = c("2023-06-01", "2023-06-30"),
      limit = 5,
      download = FALSE
    )
    expect_identical(nrow(res), 2L)
    expect_setequal(res$document_id, c("IS-16-137", "IS-16-189"))
  })
})

test_that("get_assessments_is forwards query + processId into the GraphQL seam", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    seen <- list()
    local_mocked_bindings(
      is_graphql = function(query, variables = NULL) {
        input <- (variables %||% list())$input %||% list()
        if (!is.null(input$issueId)) {
          return(.is_single_137)
        }
        seen[[length(seen) + 1L]] <<- list(
          process_id = input$processId,
          search = input$search
        )
        # Serve the listing only for process 501 (SEA), empty otherwise.
        list(
          data = list(
            issueConnection = list(
              totalCount = 0L,
              pageInfo = list(hasNextPage = FALSE, endCursor = NULL),
              edges = list()
            )
          )
        )
      }
    )
    get_assessments_is(
      assessment_type = "SEA",
      query = "vindorku",
      limit = 5,
      download = FALSE
    )
    # SEA -> process 501 only; query forwarded as `search`.
    expect_identical(length(seen), 1L)
    expect_identical(seen[[1]]$process_id, "501")
    expect_identical(seen[[1]]$search, "vindorku")
  })
})

test_that("get_assessments_is rejects a bad assessment_type", {
  expect_error(
    get_assessments_is(assessment_type = "NOPE", download = FALSE),
    class = "planscanR_error_bad_input"
  )
})

# -- Sidecar round-trip -----------------------------------------------------

test_that("IS -> sidecar round-trip preserves country-specific extras + geometry", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    # Serve only record 137 (geometry + files).
    local_mocked_bindings(
      is_graphql = function(query, variables = NULL) {
        input <- (variables %||% list())$input %||% list()
        if (!is.null(input$issueId)) {
          return(.is_single_137)
        }
        if (identical(as.character(input$processId), "16")) {
          envelope <- .is_listing
          envelope$data$issueConnection$edges <- envelope$data$issueConnection$edges[1]
          return(envelope)
        }
        list(
          data = list(
            issueConnection = list(
              totalCount = 0L,
              pageInfo = list(hasNextPage = FALSE, endCursor = NULL),
              edges = list()
            )
          )
        )
      }
    )

    res <- get_assessments_is(assessment_type = "EIA", limit = 5, download = FALSE)
    idx <- index_cache(country = "is")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "IS-16-137")

    # Country-specific extras survive the round-trip.
    expect_identical(idx$assessment_type, "EIA")
    expect_identical(idx$process_type, "MAT_A_UMHVERFISAHRIFUM")
    expect_identical(idx$lifecycle, "done")
    # Geometry sidecar.
    expect_identical(idx$geometry_crs, "EPSG:4326")
    expect_true(file.exists(idx$geometry_path))
    # The phase-file attachment columns survive.
    expect_true("attachment_urls_almennt" %in% names(idx))
    expect_true("attachment_urls_afgreidsla" %in% names(idx))
  })
})

# -- Relevance scoring ------------------------------------------------------

test_that("get_assessments_is scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(is_graphql = mock_graphql_all())

    res <- get_assessments_is(
      assessment_type = "EIA",
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(energy = "orku", water = "virkjun"),
      relevance_model = make_fake_model(languages = c("is", "en"))
    )
    expect_identical(nrow(res), 3L)
    expect_true("relevance_score_energy" %in% names(res))
    expect_true("relevance_score_water" %in% names(res))
    expect_true(is.numeric(res$relevance_score_energy))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('is') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("is", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "is")
    expect_identical(res$source_portal, "skipulagsgatt.is")
    expect_match(res$url, "^https://www\\.skipulagsgatt\\.is/issues/")
  })
})
