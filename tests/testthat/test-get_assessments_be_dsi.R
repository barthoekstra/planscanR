# Offline tests for the explicit source "be_dsi" (Flanders DSI planning dossiers).
# Fixtures: two real (trimmed) dossiers + one minimal dossier with no documents.

dsi_fix <- function(name) jsonlite::fromJSON(fixture_path("be_dsi", name), simplifyVector = FALSE)
.dsi_pages <- list(dsi_fix("page0.json"), dsi_fix("page1.json"))
.dsi_det <- list(
  "6" = NULL,
  RUP_02000_212_00462_00001 = dsi_fix("detail-RUP_02000_212_00462_00001.json"),
  RUP_24009_214_00004_00001 = dsi_fix("detail-RUP_24009_214_00004_00001.json"),
  BPA_99999_224_00001_00001 = dsi_fix("detail-BPA_99999_224_00001_00001.json")
)
.dsi_det[["6"]] <- NULL
.dsi_calls <- new.env()

mock_dsi <- function(pages = .dsi_pages) {
  function(req) {
    url <- req$url
    .dsi_calls$urls <- c(.dsi_calls$urls, url)
    if (grepl("zoekRsql", url)) {
      pg <- as.integer(sub(".*page=([0-9]+).*", "\\1", url)) + 1L
      return(if (pg <= length(pages)) pages[[pg]] else list(page = list(totalPages = length(pages))))
    }
    for (id in names(.dsi_det)) {
      det <- .dsi_det[[id]]
      if (grepl(det$id, url, fixed = TRUE)) {
        return(det)
      }
    }
    stop("Unexpected URL in test: ", url)
  }
}

with_dsi <- function(code, pages = .dsi_pages) {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    .dsi_calls$urls <- character(0)
    local_mocked_bindings(perform_json = mock_dsi(pages))
    force(code)
  })
}

test_that("be_dsi is registered, and only country 'be' is accepted", {
  expect_true("be_dsi" %in% get_assessments_sources()$source)
  expect_error(
    get_assessments("nl", source = "be_dsi"),
    "Flemish",
    class = "planscanR_error_bad_input"
  )
  expect_false("be_dsi" %in% supported_countries())
})

test_that("parser captures native metadata, documents per code, phases and geometry", {
  with_dsi({
    res <- get_assessments("be", source = "be_dsi", download = FALSE, write_sidecar = FALSE)
    expect_identical(nrow(res), 3L)
    r <- res[res$document_id == "be_dsi_RUP_02000_212_00462_00001", ]
    expect_identical(r$country, "be")
    expect_identical(r$source_portal, "dsi.omgeving.vlaanderen.be")
    expect_match(r$url, "fiche-detail/2ba01672")
    expect_identical(r$native_type, "gewRUP")
    expect_identical(r$competent_authority, "Departement Omgeving")
    expect_identical(r$dossier_status, "DEFINITIEF")
    expect_identical(r$algplanid, "RUP_02000_212_00462_00001")
    expect_true(!is.na(r$date_published))
    # PLNMER grouped per native code; links deduplicated across phases.
    expect_true(all(c("attachment_urls_plnmer", "attachment_urls_bs", "attachment_urls_tnk") %in% names(r)))
    expect_length(r$attachment_urls_plnmer[[1]], length(unique(r$attachment_urls_plnmer[[1]])))
    expect_true(all(grepl("^https://download.dsi.omgeving.vlaanderen.be/", r$attachment_urls[[1]])))
    expect_setequal(r$attachment_urls[[1]], unlist(r[grep("^attachment_urls_.", names(r))]))
    docs <- jsonlite::fromJSON(r$documents_json)
    expect_true(all(c("code", "omschrijving", "phase", "link") %in% names(docs)))
    expect_setequal(unique(docs$phase), c("BG", "VV", "PV"))
    expect_identical(sum(docs$code == "PLNMER"), 9L)
    expect_length(jsonlite::fromJSON(r$phases_json, simplifyVector = FALSE), 3L)
  })
})

test_that("minimal dossier (no phases/documents/optionals) parses with NA fields", {
  with_dsi({
    res <- get_assessments("be", source = "be_dsi", write_sidecar = FALSE)
    r <- res[res$document_id == "be_dsi_BPA_99999_224_00001_00001", ]
    expect_identical(nrow(r), 1L)
    expect_length(r$attachment_urls[[1]], 0L)
    expect_true(is.na(r$summary) && is.na(r$date_published) && is.na(r$authority_nis_code))
  })
})

test_that("pagination: all pages walked, limit stops early, empty terminates", {
  with_dsi({
    res <- get_assessments("be", source = "be_dsi", write_sidecar = FALSE)
    expect_identical(nrow(res), 3L)
    expect_identical(sum(grepl("zoekRsql", .dsi_calls$urls)), 2L)
  })
  with_dsi({
    res <- get_assessments("be", source = "be_dsi", limit = 1, write_sidecar = FALSE)
    expect_identical(nrow(res), 1L)
    expect_identical(sum(grepl("zoekRsql", .dsi_calls$urls)), 1L)
    expect_match(.dsi_calls$urls[1], "size=1")
    expect_identical(sum(!grepl("zoekRsql", .dsi_calls$urls)), 1L) # one detail call only
  })
  with_dsi({
    get_assessments("be", source = "be_dsi", limit = 1, query = "AVR", write_sidecar = FALSE)
    expect_match(.dsi_calls$urls[1], "size=200") # filtered scans keep full pages
  })
  with_dsi(
    {
      res <- get_assessments("be", source = "be_dsi")
      expect_identical(res, empty_result_tibble())
    },
    pages = list(list(page = list(totalPages = 0L, totalElements = 0L)))
  )
})

test_that("repeated page and early end warn instead of looking complete", {
  with_dsi(
    {
      expect_warning(
        res <- get_assessments("be", source = "be_dsi", write_sidecar = FALSE),
        class = "planscanR_warning_partial"
      )
      expect_identical(nrow(res), 2L)
    },
    pages = list(.dsi_pages[[1]], .dsi_pages[[1]], .dsi_pages[[2]])
  )
})

test_that("query and procedure_code filters have positive and negative cases", {
  with_dsi({
    expect_identical(
      get_assessments("be", source = "be_dsi", query = "AVR", write_sidecar = FALSE)$document_id,
      "be_dsi_RUP_02000_212_00462_00001"
    )
    expect_identical(nrow(get_assessments("be", source = "be_dsi", query = "zzz", write_sidecar = FALSE)), 0L)
    expect_identical(
      get_assessments("be", source = "be_dsi", procedure_code = "BPA", write_sidecar = FALSE)$document_id,
      "be_dsi_BPA_99999_224_00001_00001"
    )
    expect_identical(nrow(get_assessments("be", source = "be_dsi", procedure_code = "WOR", write_sidecar = FALSE)), 0L)
    expect_identical(
      nrow(get_assessments("be", source = "be_dsi", date_range = c("2000-01-01", "2000-12-31"), write_sidecar = FALSE)),
      0L
    )
  })
})

test_that("sidecar round trip keeps extras and sections; warm run does not refetch", {
  with_dsi({
    get_assessments("be", source = "be_dsi")
    idx <- index_cache(country = "be")
    expect_identical(nrow(idx), 3L)
    r <- idx[idx$document_id == "be_dsi_RUP_02000_212_00462_00001", ]
    expect_true("attachment_urls_plnmer" %in% names(r))
    expect_identical(r$geometry_crs, "EPSG:31370")
    expect_true(file.exists(r$geometry_path))
    expect_match(r$documents_json, "PLNMER")
    expect_identical(r$dossier_status, "DEFINITIEF")

    .dsi_calls$urls <- character(0)
    get_assessments("be", source = "be_dsi")
    expect_identical(sum(!grepl("zoekRsql", .dsi_calls$urls)), 0L)
  })
})

test_that("default 'be' source ids cannot collide with be_dsi ids", {
  expect_true(startsWith("be_dsi_RUP_1", "be_dsi_"))
  expect_false(grepl("^PR[0-9]+$", "be_dsi_RUP_1"))
})

test_that("be_dsi scores topics with the fake model", {
  skip_if_not_installed("planscanR.screen")
  with_dsi({
    res <- get_assessments(
      "be",
      source = "be_dsi",
      write_sidecar = FALSE,
      topic = c(wind = "wind energy"),
      relevance_model = make_fake_model()
    )
    expect_true(is.numeric(res$relevance_score_wind))
  })
})
