# Tests for get_assessments_gb(). Offline strategy: stub the bulk-CSV fetch
# (gb_fetch_search) and the per-record ES-document fetch (gb_fetch_attachments)
# so no live HTTP is needed in CI. Fixtures:
#  - applications.csv : header + 4 trimmed NSIP rows (the real export's columns)
#  - documents.html   : one project's Environmental Statement document list with
#                       published-document PDF links on nsip-documents.*

read_gb_csv <- function() {
  planscanR:::gb_parse_csv(
    paste(readLines(fixture_path("gb", "applications.csv")), collapse = "\n")
  )
}

read_gb_docs_html <- function() {
  rvest::read_html(fixture_path("gb", "documents.html"))
}

.gb_df <- read_gb_csv()
.gb_entries <- planscanR:::gb_map_rows(.gb_df)
.gb_docs <- read_gb_docs_html()

# The first fixture row (Hinkley Point C, EN010001).
.gb_entry_1 <- .gb_entries[[1]]

test_that("gb_parse_csv reads the verbatim header column names", {
  expect_true(all(
    c(
      "Project reference",
      "Project name",
      "Applicant name",
      "Application type",
      "Region",
      "Location",
      "Grid reference - Easting",
      "Grid reference - Northing:",
      "GPS co-ordinates",
      "Stage",
      "Description",
      "Date of decision",
      "Date application accepted",
      "Date withdrawn"
    ) %in%
      names(.gb_df)
  ))
  expect_identical(nrow(.gb_df), 4L)
})

test_that("gb_map_rows builds an entry per row keyed on the Project reference", {
  expect_length(.gb_entries, 4L)
  refs <- vapply(.gb_entries, function(e) e$reference, character(1))
  expect_true("EN010001" %in% refs)
  expect_true(all(grepl("^[A-Z]{2}[0-9]+$", refs)))
})

test_that("gb_parse_attachments collects published-document PDF urls", {
  urls <- planscanR:::gb_parse_attachments(.gb_docs)
  expect_gte(length(urls), 1L)
  expect_true(all(startsWith(
    urls,
    "https://nsip-documents.planninginspectorate.gov.uk/published-documents/"
  )))
  expect_true(all(grepl("\\.pdf$", urls)))
  # No nsip-documents anchors -> empty.
  blank <- rvest::read_html("<html><body><a href='/somewhere'>x</a></body></html>")
  expect_identical(planscanR:::gb_parse_attachments(blank), character(0))
})

test_that("gb_build_record maps a CSV row to a record incl. coords/dates/extras", {
  parsed <- planscanR:::gb_build_record(
    planscanR:::gb_canonical_url(.gb_entry_1$reference),
    .gb_entry_1,
    character(0)
  )
  rec <- parsed$record

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "gb")
  expect_identical(rec$source_portal, "planninginspectorate.gov.uk")
  expect_identical(rec$document_id, "EN010001")
  expect_match(rec$url, "/projects/EN010001$")
  expect_match(rec$title, "Hinkley Point C")
  expect_identical(rec$competent_authority, "Planning Inspectorate")
  expect_match(rec$proponent, "NNB Generation")
  expect_match(rec$native_type, "Generating Stations")
  expect_identical(rec$status, "Post-decision")
  expect_s3_class(rec$date_decision, "Date")
  expect_identical(rec$date_decision, as.Date("2013-03-19"))
  expect_identical(rec$date_published, as.Date("2011-11-24"))

  # Extras (verbatim values).
  expect_identical(rec$region, "South West")
  expect_match(rec$project_location, "Hinkley Point")
  expect_identical(rec$grid_easting, "321217")
  expect_identical(rec$grid_northing, "146033")
  expect_match(rec$gps_coordinates, "51.208")

  # Point geometry built from the grid reference.
  expect_false(is.null(parsed$geometry))
  expect_identical(parsed$geometry$type, "Point")
  expect_identical(parsed$geometry$coordinates, c(321217, 146033))
})

test_that("gb_point_geometry returns NULL when grid reference is missing", {
  expect_null(planscanR:::gb_point_geometry(NA_character_, NA_character_))
  expect_null(planscanR:::gb_point_geometry("", ""))
  expect_null(planscanR:::gb_point_geometry("notnum", "123"))
})

test_that("gb_record_matches honours query / status / date_range filters", {
  rec <- tibble::tibble(
    title = "Cleve Hill Solar Park",
    status = "Post-decision",
    date_decision = as.Date("2020-05-28"),
    date_published = as.Date("2018-12-14")
  )
  # No filters -> match.
  expect_true(planscanR:::gb_record_matches(rec, NULL, NULL, NULL))
  # query: positive + negative.
  expect_true(planscanR:::gb_record_matches(rec, NULL, "solar", NULL))
  expect_false(planscanR:::gb_record_matches(rec, NULL, "nuclear", NULL))
  # status: positive (case-insensitive) + negative.
  expect_true(planscanR:::gb_record_matches(rec, NULL, NULL, "post-decision"))
  expect_false(planscanR:::gb_record_matches(rec, NULL, NULL, "Examination"))
  # date_range against date_decision: positive + negative.
  expect_true(planscanR:::gb_record_matches(
    rec,
    as.Date(c("2020-01-01", "2020-12-31")),
    NULL,
    NULL
  ))
  expect_false(planscanR:::gb_record_matches(
    rec,
    as.Date(c("2019-01-01", "2019-12-31")),
    NULL,
    NULL
  ))
})

test_that("gb_record_matches falls back to date_published when no decision date", {
  rec <- tibble::tibble(
    title = "x",
    status = "Examination",
    date_decision = as.Date(NA),
    date_published = as.Date("2025-11-12")
  )
  expect_true(planscanR:::gb_record_matches(
    rec,
    as.Date(c("2025-01-01", "2025-12-31")),
    NULL,
    NULL
  ))
  expect_false(planscanR:::gb_record_matches(
    rec,
    as.Date(c("2024-01-01", "2024-12-31")),
    NULL,
    NULL
  ))
})

# A reusable mock pair: bulk-export generator yields all fixture rows once; the
# attachment fetch returns the fixture ES PDFs.
gb_mock_bindings <- function() {
  list(
    gb_fetch_search = function() {
      emitted <- FALSE
      function() {
        if (emitted) {
          return(NULL)
        }
        emitted <<- TRUE
        .gb_entries
      }
    },
    gb_fetch_attachments = function(reference) {
      planscanR:::gb_parse_attachments(.gb_docs)
    }
  )
}

test_that("get_assessments_gb end-to-end on fixtures (sidecar-first, geometry persisted)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- gb_mock_bindings()
    local_mocked_bindings(
      gb_fetch_search = mb$gb_fetch_search,
      gb_fetch_attachments = mb$gb_fetch_attachments
    )

    res <- get_assessments_gb(limit = 10, download = FALSE)
    expect_identical(nrow(res), 4L)
    planscanR:::validate_result_schema(res)
    expect_true(all(grepl("^[A-Z]{2}[0-9]+$", res$document_id)))
    # Every fixture row carries a grid reference -> attachments scraped + geometry.
    expect_true(all(lengths(res$attachment_urls) > 0L))

    # All four geometry sidecars on disk.
    for (id in res$document_id) {
      geom_file <- file.path(cache, "files", "gb", id, paste0(id, ".geometry.geojson"))
      expect_true(file.exists(geom_file))
    }

    # Metadata sidecars on disk.
    sidecars <- list.files(
      file.path(cache, "files", "gb"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 4L)

    # Second call with refresh = FALSE must NOT re-fetch attachments.
    local_mocked_bindings(
      gb_fetch_attachments = function(...) {
        stop("gb_fetch_attachments should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_gb(limit = 10, download = FALSE)
    expect_identical(nrow(res2), 4L)
  })
})

test_that("get_assessments_gb honours query, status, date_range and limit", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- gb_mock_bindings()
    local_mocked_bindings(
      gb_fetch_search = mb$gb_fetch_search,
      gb_fetch_attachments = mb$gb_fetch_attachments
    )

    # query: only the solar park matches.
    res_q <- get_assessments_gb(query = "solar", download = FALSE)
    expect_identical(nrow(res_q), 1L)
    expect_match(res_q$title, "Solar")

    # status: only the withdrawn project.
    res_s <- get_assessments_gb(status = "Withdrawn", download = FALSE)
    expect_identical(nrow(res_s), 1L)
    expect_identical(res_s$status, "Withdrawn")

    # date_range: Hinkley decided 2013.
    res_d <- get_assessments_gb(
      date_range = c("2013-01-01", "2013-12-31"),
      download = FALSE
    )
    expect_identical(nrow(res_d), 1L)
    expect_identical(res_d$document_id, "EN010001")

    # limit caps the total.
    res_lim <- get_assessments_gb(limit = 2, download = FALSE)
    expect_identical(nrow(res_lim), 2L)
  })
})

test_that("GB -> sidecar round-trip preserves extras + geometry via index_cache()", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- gb_mock_bindings()
    local_mocked_bindings(
      gb_fetch_search = mb$gb_fetch_search,
      gb_fetch_attachments = mb$gb_fetch_attachments
    )

    res <- get_assessments_gb(limit = 10, download = FALSE)
    idx <- index_cache(country = "gb")
    expect_identical(nrow(idx), 4L)

    expect_true(all(
      c(
        "region",
        "project_location",
        "grid_easting",
        "grid_northing",
        "gps_coordinates"
      ) %in%
        names(idx)
    ))
    expect_true("South West" %in% idx$region)
    expect_true(any(grepl("321217", idx$grid_easting)))

    # Geometry sidecar tag round-trips (relative on disk, absolutised on read).
    expect_setequal(idx$geometry_crs, "EPSG:27700")
    expect_true(all(file.exists(idx$geometry_path)))
  })
})

test_that("get_assessments_gb scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    mb <- gb_mock_bindings()
    local_mocked_bindings(
      gb_fetch_search = mb$gb_fetch_search,
      gb_fetch_attachments = mb$gb_fetch_attachments
    )

    res <- get_assessments_gb(
      limit = 10,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(nuclear = "nuclear power station", solar = "solar park"),
      relevance_model = make_fake_model(languages = c("en"))
    )
    expect_identical(nrow(res), 4L)
    expect_true("relevance_score_nuclear" %in% names(res))
    expect_true("relevance_score_solar" %in% names(res))
    expect_true(is.numeric(res$relevance_score_nuclear))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments('gb') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("gb", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "gb")
    expect_identical(res$source_portal, "planninginspectorate.gov.uk")
    expect_true(grepl(
      "^https://national-infrastructure-consenting\\.planninginspectorate\\.gov\\.uk",
      res$url
    ))
  })
})
