# Focused ACQ-RUN5a coverage for the opt-in portal inventory refresh.

test_that("refresh resolves NL sections and preserves the persisted identity", {
  url <- "https://www.commissiemer.nl/advies/fabriek-voor-de-productie-van-aromaten-uit-niet-herbruikbaar-afvalplastic-in-delfzijl/"
  records <- tibble::tibble(
    country = "nl",
    source_portal = "commissiemer.nl",
    document_id = "3619",
    url = url,
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_html = function(req) rvest::read_html(fixture_path("nl", "advice-detail-aromaten-delfzijl.html")),
    req_planscanr = function(base_url, path = NULL) base_url,
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "success")
  expect_true(out$authoritative[[1L]])
  expect_true(length(out$attachment_urls[[1L]]) > 10L)
  expect_length(out$attachment_urls_source[[1L]], 40L)
  expect_length(out$attachment_urls_advice[[1L]], 7L)
  expect_identical(out$country, "nl")
  expect_identical(out$document_id, "3619")
})

test_that("refresh rejects a detail page whose persisted identity conflicts", {
  url <- "https://www.commissiemer.nl/advies/fabriek-voor-de-productie-van-aromaten-uit-niet-herbruikbaar-afvalplastic-in-delfzijl/"
  records <- tibble::tibble(
    country = "nl",
    source_portal = "commissiemer.nl",
    document_id = "wrong-project",
    url = url,
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_html = function(req) rvest::read_html(fixture_path("nl", "advice-detail-aromaten-delfzijl.html")),
    req_planscanr = function(base_url, path = NULL) base_url,
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "retryable")
  expect_false(out$authoritative[[1L]])
  expect_match(out$reason, "identity")
  expect_length(out$attachment_urls[[1L]], 0L)
})

test_that("refresh handles DE sections and strict DK inventories", {
  de_url <- "https://www.uvp-verbund.de/trefferanzeige?docuuid=a8837db3-a6e0-4aa9-b13a-c5d2735187cb"
  de_records <- tibble::tibble(
    country = "de",
    source_portal = "uvp-verbund.de",
    document_id = "a8837db3-a6e0-4aa9-b13a-c5d2735187cb",
    url = de_url,
    attachment_urls = list(character(0))
  )
  dk_records <- tibble::tibble(
    country = "dk",
    source_portal = "miljoeportal.dk/eahub",
    document_id = "assess-1",
    url = "https://eahub.miljoeportal.dk/assessment-detail/assess-1",
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_html = function(req) rvest::read_html(fixture_path("de", "detail-walldurn-windpark.html")),
    perform_json = function(req, ...) {
      if (grepl("/documents/[^/]+/links$", req$url)) {
        doc <- sub(".*/documents/([^/]+)/links$", "\\1", req$url)
        return(list(viewUrl = paste0("https://blob.example/", doc, "/file.pdf")))
      }
      list(documents = list(
        list(
          id = "d1",
          documentType = list(name = list(`da-DK` = "Afgørelse"))
        )
      ))
    },
    .package = "planscanR"
  )

  de <- planscanR::resolve_attachment_inventory(de_records, refresh = TRUE)
  dk <- planscanR::resolve_attachment_inventory(dk_records, refresh = TRUE)

  expect_identical(de$status, "success")
  expect_true(de$authoritative[[1L]])
  expect_length(de$attachment_urls_berichte[[1L]], 47L)
  expect_identical(dk$status, "success")
  expect_true(dk$authoritative[[1L]])
  expect_identical(dk$attachment_urls_afgoerelse[[1L]], "https://blob.example/d1/file.pdf")
})

test_that("refresh rejects a DE detail whose response identity conflicts", {
  requested_id <- "b8837db3-a6e0-4aa9-b13a-c5d2735187cb"
  url <- paste0("https://www.uvp-verbund.de/trefferanzeige?docuuid=", requested_id)
  records <- tibble::tibble(
    country = "de",
    source_portal = "uvp-verbund.de",
    document_id = requested_id,
    url = url,
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_html = function(req) rvest::read_html(fixture_path("de", "detail-walldurn-windpark.html")),
    req_planscanr = function(base_url, path = NULL) base_url,
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "retryable")
  expect_false(out$authoritative[[1L]])
  expect_match(out$reason, "response identity")
  expect_length(out$attachment_urls[[1L]], 0L)
})

test_that("refresh accepts a proven DE empty inventory as character empty", {
  document_id <- "a8837db3-a6e0-4aa9-b13a-c5d2735187cb"
  url <- paste0("https://www.uvp-verbund.de/trefferanzeige?docuuid=", document_id)
  records <- tibble::tibble(
    country = "de",
    source_portal = "uvp-verbund.de",
    document_id = document_id,
    url = url,
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_html = function(req) {
      rvest::read_html(paste0(
        "<html><body><h1>Proven project</h1>",
        "<div hx-get=\"rest/createDetailZip?docuuid=", document_id, "\"></div>",
        "</body></html>"
      ))
    },
    req_planscanr = function(base_url, path = NULL) base_url,
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "empty")
  expect_true(out$authoritative[[1L]])
  expect_type(out$attachment_urls[[1L]], "character")
  expect_length(out$attachment_urls[[1L]], 0L)
})

test_that("strict DK empty documents are an authoritative empty inventory", {
  records <- tibble::tibble(
    country = "dk",
    source_portal = "miljoeportal.dk/eahub",
    document_id = "assess-empty",
    url = "https://eahub.miljoeportal.dk/assessment-detail/assess-empty",
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_json = function(req, ...) list(documents = list()),
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "empty")
  expect_true(out$authoritative[[1L]])
  expect_type(out$attachment_urls[[1L]], "character")
  expect_length(out$attachment_urls[[1L]], 0L)
})

test_that("strict DK unnamed nonempty inventory remains retryable", {
  records <- tibble::tibble(
    country = "dk",
    source_portal = "miljoeportal.dk/eahub",
    document_id = "assess-malformed",
    url = "https://eahub.miljoeportal.dk/assessment-detail/assess-malformed",
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    dk_collect_attachments = function(id, strict = TRUE) list(c("https://blob.example/file.pdf")),
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "retryable")
  expect_false(out$authoritative[[1L]])
  expect_match(out$reason, "malformed")
  expect_length(out$attachment_urls[[1L]], 0L)
})

test_that("refresh failures and unsupported adapters are never authoritative empty", {
  records <- tibble::tibble(
    country = c("nl", "fr"),
    source_portal = c("commissiemer.nl", "projets-environnement.gouv.fr"),
    document_id = c("3619", "fr-1"),
    url = c("https://www.commissiemer.nl/advies/failure/", "https://example.test/fr-1"),
    attachment_urls = list(character(0), character(0))
  )
  testthat::local_mocked_bindings(
    nl_parse_detail = function(url) stop("temporary detail outage"),
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, c("retryable", "blocked"))
  expect_false(any(out$authoritative))
  expect_match(out$reason[[1L]], "temporary detail outage")
  expect_match(out$reason[[2L]], "adapter")
})

test_that("malformed DE detail with URL identity cannot become authoritative empty", {
  records <- tibble::tibble(
    country = "de",
    source_portal = "uvp-verbund.de",
    document_id = "a8837db3-a6e0-4aa9-b13a-c5d2735187cb",
    url = paste0(
      "https://www.uvp-verbund.de/trefferanzeige?docuuid=",
      "a8837db3-a6e0-4aa9-b13a-c5d2735187cb"
    ),
    attachment_urls = list(character(0))
  )
  testthat::local_mocked_bindings(
    perform_html = function(req) rvest::read_html("<html><body><h1>Maintenance</h1></body></html>"),
    req_planscanr = function(base_url, path = NULL) base_url,
    .package = "planscanR"
  )

  out <- planscanR::resolve_attachment_inventory(records, refresh = TRUE)

  expect_identical(out$status, "retryable")
  expect_false(out$authoritative[[1L]])
  expect_match(out$reason, "response identity")
  expect_length(out$attachment_urls[[1L]], 0L)
})
