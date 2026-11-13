test_that("the per-host throttle is steady, without an initial burst", {
  skip_if_not("capacity" %in% names(formals(httr2::req_throttle)))
  withr::local_options(planscanR.throttle_rates = list("throttle-test.invalid" = 4))
  httr2:::throttle_reset()
  withr::defer(httr2:::throttle_reset())
  # throttle_delay() takes a token and returns the wait req_perform() would add.
  delays <- vapply(1:5, function(i) {
    httr2:::throttle_delay(req_throttle_planscanr(httr2::request("https://throttle-test.invalid/x")))
  }, numeric(1))
  # httr2's rate = 4 bucket would hold 240 tokens and let all five through at
  # once; a steady 4 req/s makes the later requests wait.
  expect_gt(delays[[5]], 0.5)
})
