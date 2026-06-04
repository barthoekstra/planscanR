# Direct unit tests for merge_sidecar_payload() — the non-destructive write
# reconciliation that was previously exercised only indirectly via the sidecar
# round-trip contract. One test per documented branch.

test_that("merge keeps old scalar metadata when the new write omits it (new otherwise wins)", {
  new <- list(country = "nl", document_id = "1", title = "New title")
  old <- list(
    country = "nl",
    document_id = "1",
    source_portal = "commissiemer.nl",
    title = "Old title",
    summary = "Old summary"
  )
  m <- planscanR:::merge_sidecar_payload(new, old)
  expect_identical(m$source_portal, "commissiemer.nl") # new omitted -> keep old
  expect_identical(m$title, "New title") # new present -> new wins
  expect_identical(m$summary, "Old summary") # new omitted -> keep old
})

test_that("merge unions files[] by URL: new supersedes same URL, old-only rows are kept", {
  new <- list(files = list(list(url = "https://x/a.pdf", status = "downloaded")))
  old <- list(
    files = list(
      list(url = "https://x/a.pdf", status = "pending"),
      list(url = "https://x/b.pdf", status = "pending")
    )
  )
  m <- planscanR:::merge_sidecar_payload(new, old)
  urls <- vapply(m$files, function(f) f$url, character(1))
  expect_setequal(urls, c("https://x/a.pdf", "https://x/b.pdf"))
  a <- Filter(function(f) f$url == "https://x/a.pdf", m$files)[[1]]
  expect_identical(a$status, "downloaded") # new wins
  b <- Filter(function(f) f$url == "https://x/b.pdf", m$files)[[1]]
  expect_identical(b$status, "pending") # old kept
})

test_that("merge unions relevance_scores[] by topic (new wins)", {
  new <- list(relevance_scores = list(list(topic = "wind", score = 0.8)))
  old <- list(
    relevance_scores = list(
      list(topic = "wind", score = 0.5),
      list(topic = "solar", score = 0.3)
    )
  )
  m <- planscanR:::merge_sidecar_payload(new, old)
  topics <- vapply(m$relevance_scores, function(e) e$topic, character(1))
  expect_setequal(topics, c("wind", "solar"))
  wind <- Filter(function(e) e$topic == "wind", m$relevance_scores)[[1]]
  expect_equal(wind$score, 0.8) # new wins same topic
})

test_that("merge unions extras{} by key (new wins) and drops stale relevance_score_* duplicates", {
  new <- list(extras = list(a = 9))
  old <- list(extras = list(a = 1, b = 2, relevance_score_wind = 0.5))
  m <- planscanR:::merge_sidecar_payload(new, old)
  expect_equal(m$extras$a, 9) # new wins
  expect_equal(m$extras$b, 2) # old kept
  expect_null(m$extras$relevance_score_wind) # v3: never carry forward a stale dup
})

test_that("merge appends the old discovery_log after the new entries (audit trail)", {
  new <- list(discovery_log = list(list(q = "new")))
  old <- list(discovery_log = list(list(q = "old")))
  m <- planscanR:::merge_sidecar_payload(new, old)
  expect_length(m$discovery_log, 2L)
  expect_identical(m$discovery_log[[1]]$q, "new")
  expect_identical(m$discovery_log[[2]]$q, "old")
})

test_that("merge keeps the old classification when the new write carries none", {
  new <- list(country = "nl")
  old <- list(classification = list(label = "wind", score = 0.9))
  m <- planscanR:::merge_sidecar_payload(new, old)
  expect_identical(m$classification$label, "wind")
})

test_that("merge prefers the new classification when present", {
  new <- list(classification = list(label = "solar"))
  old <- list(classification = list(label = "wind"))
  m <- planscanR:::merge_sidecar_payload(new, old)
  expect_identical(m$classification$label, "solar")
})
