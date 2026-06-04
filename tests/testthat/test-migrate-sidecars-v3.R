# Task 2.4: migrate_sidecars_v3() upgrades a v2 cache in place to v3
# (relative paths, schema_version 3, no relevance_score_* extras dup) while
# index_cache() keeps returning identical tibble values.

test_that("migrate_sidecars_v3 upgrades v2 sidecars to v3, preserving index_cache values", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    root <- getwd()

    # Hand-write a legacy v2 sidecar: absolute local_path + the v2 extras
    # relevance_score duplication.
    write_v2 <- function(country, id, score) {
      p <- planscanR:::sidecar_path(country, id)
      abs_pdf <- file.path(root, "files", country, id, "a.pdf")
      payload <- list(
        schema_version = 2L,
        country = country,
        source_portal = "x",
        document_id = id,
        url = paste0("https://x/", id),
        retrieved_at = "2024-01-02T03:04:05Z",
        title = paste("Rec", id),
        relevance_model = "old",
        relevance_scores = list(list(
          topic = "wind", score = score, model = "old",
          scored_at = "2024-01-02T03:04:05Z"
        )),
        extras = list(relevance_score_wind = score, native_type = "T"),
        files = list(list(
          url = "https://x/a.pdf", local_path = abs_pdf,
          status = "downloaded", size_bytes = 10, sha256 = "aa"
        ))
      )
      writeLines(jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"), p)
      p
    }
    p1 <- write_v2("nl", "m1", 0.5)
    write_v2("nl", "m2", 0.7)

    before <- planscanR::index_cache()
    before <- before[order(before$document_id), ]

    n <- planscanR::migrate_sidecars_v3()
    expect_identical(n, 2L)

    # On disk: v3, relative path, no extras relevance dup, other extras kept.
    raw1 <- jsonlite::fromJSON(p1, simplifyVector = FALSE)
    expect_equal(as.integer(raw1$schema_version), 3L)
    expect_identical(raw1$files[[1]]$local_path, file.path("files", "nl", "m1", "a.pdf"))
    expect_null(raw1$extras$relevance_score_wind)
    expect_identical(raw1$extras$native_type, "T")

    # index_cache() returns identical tibble VALUES (paths absolutised on read
    # both before and after, so local_path is the same absolute path).
    after <- planscanR::index_cache()
    after <- after[order(after$document_id), ]
    expect_identical(after$document_id, before$document_id)
    expect_identical(after$local_path, before$local_path)
    expect_identical(after$relevance_score_wind, before$relevance_score_wind)
    expect_identical(after$title, before$title)
    expect_identical(after$native_type, before$native_type)

    # Idempotent: a second pass rewrites the same count and changes no values.
    expect_identical(planscanR::migrate_sidecars_v3(), 2L)
    again <- planscanR::index_cache()
    again <- again[order(again$document_id), ]
    expect_identical(again$local_path, after$local_path)
    expect_identical(again$relevance_score_wind, after$relevance_score_wind)
  })
})

test_that("migrate_sidecars_v3 is a no-op count on an empty/missing cache", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    expect_identical(planscanR::migrate_sidecars_v3(), 0L)
  })
})
