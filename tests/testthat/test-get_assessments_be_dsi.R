# Offline tests for the explicit source "be_dsi" (Flanders DSI planning dossiers).
# Fixtures: two real (trimmed) dossiers + one minimal dossier with no documents.
# RUP_24009 carries workflow (advice letters) and geodata documents.

dsi_fix <- function(name) jsonlite::fromJSON(fixture_path("be_dsi", name), simplifyVector = FALSE)
.dsi_pages <- list(dsi_fix("page0.json"), dsi_fix("page1.json"))
.dsi_det <- list(
  RUP_02000_212_00462_00001 = dsi_fix("detail-RUP_02000_212_00462_00001.json"),
  RUP_24009_214_00004_00001 = dsi_fix("detail-RUP_24009_214_00004_00001.json"),
  BPA_99999_224_00001_00001 = dsi_fix("detail-BPA_99999_224_00001_00001.json")
)
.dsi_calls <- new.env()

mock_dsi <- function(pages = .dsi_pages) {
  function(req) {
    url <- req$url
    .dsi_calls$urls <- c(.dsi_calls$urls, url)
    if (grepl("zoekRsql", url)) {
      pg <- as.integer(sub(".*page=([0-9]+).*", "\\1", url)) + 1L
      if (pg <= length(pages) && is.character(pages[[pg]])) {
        stop("simulated listing failure")
      }
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
  with_temp_cache({
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
    expect_identical(r$title, "Historisch gegroeid bedrijf 'AVR' te Roeselare")
    expect_match(r$summary, "^Het GRUP heeft betrekking op delen")
    expect_identical(r$date_published, as.Date("2020-04-29"))
    expect_identical(r$date_decision, as.Date("2016-09-16"))
    expect_identical(r$jurisdiction, "Vlaams Gewest")
    expect_false(r$herinterpretatie)
    listing <- jsonlite::fromJSON(r$listing_json, simplifyVector = FALSE)
    expect_identical(listing$actieveFaseTijdstipEerstePublicatie, "2020-04-29T18:08:19.117")
    expect_identical(listing$fasedatum, "2016-09-16")
    expect_true(all(c("actieveFaseCode", "plannendeOverheidId", "dossierRoepnaam") %in% names(listing)))
    phases <- jsonlite::fromJSON(r$phases_json, simplifyVector = FALSE)
    expect_true(all(c("id", "code", "volgorde", "payload") %in% names(phases[[1]])))
    expect_identical(phases[[1]]$id, "825a44f9-0206-4346-b4d1-85aecb8a8d07")
    expect_false(any(c("dossierstukken", "workflow", "contour") %in% names(phases[[1]])))
    expect_identical(r$geometry_phase_code, "BG")
    # PLNMER grouped per native code; links deduplicated across phases.
    expect_true(all(c("attachment_urls_plnmer", "attachment_urls_bs", "attachment_urls_tnk") %in% names(r)))
    expect_length(r$attachment_urls_plnmer[[1]], length(unique(r$attachment_urls_plnmer[[1]])))
    expect_true(all(grepl("^https://download.dsi.omgeving.vlaanderen.be/", r$attachment_urls[[1]])))
    expect_setequal(r$attachment_urls[[1]], unlist(r[grep("^attachment_urls_.", names(r))]))
    docs <- jsonlite::fromJSON(r$documents_json)
    expect_true(all(
      c(
        "id",
        "originId",
        "code",
        "omschrijving",
        "phase",
        "link",
        "index",
        "groepering",
        "verordenend",
        "payload",
        "source_array"
      ) %in%
        names(docs)
    ))
    expect_setequal(unique(docs$source_array), c("dossierstukken", "geodata"))
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
    expect_identical(
      get_assessments(
        "be",
        source = "be_dsi",
        date_range = c("2020-01-01", "2020-12-31"),
        write_sidecar = FALSE
      )$document_id,
      "be_dsi_RUP_02000_212_00462_00001"
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

test_that("workflow, geodata and inspraak documents are captured and grouped by array", {
  with_dsi({
    res <- get_assessments("be", source = "be_dsi", query = "Verona", write_sidecar = FALSE)
    expect_identical(nrow(res), 1L)
    wf_cols <- grep("^attachment_urls_workflow_", names(res), value = TRUE)
    expect_true("attachment_urls_workflow_adv" %in% wf_cols)
    expect_identical(length(unique(unlist(res[wf_cols]))), 37L)
    expect_true(length(res$attachment_urls_geodata_ct[[1]]) > 0L)
    expect_true("attachment_urls_pn" %in% names(res)) # dossierstukken keep unprefixed slugs
    docs <- jsonlite::fromJSON(res$documents_json)
    expect_setequal(unique(docs$source_array), c("dossierstukken", "workflow", "geodata"))
    expect_true(all(c("ADV") %in% docs$code[docs$source_array == "workflow"]))
    expect_true(all(res$attachment_urls[[1]] %in% docs$link))
    expect_identical(length(res$attachment_urls[[1]]), length(unique(docs$link[!is.na(docs$link)])))
  })
  # inspraakstukken (synthetic): prefix + array recorded
  det <- .dsi_det[["RUP_24009_214_00004_00001"]]
  det$fases <- list(list(
    id = "p1",
    code = "VV",
    volgorde = 1L,
    payload = list(),
    inspraakstukken = list(list(
      id = "i1",
      code = "IP",
      type = "INSPRAAKSTUK",
      link = "https://example.org/ip",
      omschrijving = "Folder"
    ))
  ))
  rec <- planscanR:::be_dsi_parse_detail("u", list(algplanid = "X"), det)
  expect_identical(rec$attachment_urls_inspraakstukken_ip[[1]], "https://example.org/ip")
})

test_that("be and be_dsi share one cache without collisions; warm be_dsi makes 0 detail calls", {
  be_fix <- function(n) jsonlite::fromJSON(fixture_path("be", n), simplifyVector = FALSE)
  be_search <- be_fix("search-page0.json")
  be_det <- list(PR4038 = be_fix("dossier-PR4038.json"), PR4037 = be_fix("dossier-PR4037.json"))
  be_empty <- list(content = list(), number = 1L, size = 25L, totalElements = 2L)
  dsi <- mock_dsi()
  calls <- character(0)
  mock_both <- function(req) {
    calls <<- c(calls, req$url)
    if (grepl("dsi.omgeving", req$url, fixed = TRUE)) {
      return(dsi(req))
    }
    if (grepl("/api/v1/dossier\\?", req$url)) {
      return(if (grepl("page=0", req$url)) be_search else be_empty)
    }
    for (n in names(be_det)) {
      if (grepl(paste0("/dossier/", n), req$url, fixed = TRUE)) return(be_det[[n]])
    }
    stop("Unexpected URL in test: ", req$url)
  }
  with_temp_cache({
    local_mocked_bindings(perform_json = mock_both)
    get_assessments("be", limit = 5)
    get_assessments("be", source = "be_dsi")
    idx <- index_cache(country = "be")
    expect_identical(anyDuplicated(idx$document_id), 0L)
    by_portal <- split(idx$document_id, idx$source_portal)
    expect_setequal(names(by_portal), c("omgeving.vlaanderen.be/merregister", "dsi.omgeving.vlaanderen.be"))
    expect_true(all(startsWith(by_portal[["dsi.omgeving.vlaanderen.be"]], "be_dsi_")))
    expect_false(any(startsWith(by_portal[["omgeving.vlaanderen.be/merregister"]], "be_dsi_")))
    expect_length(intersect(by_portal[[1]], by_portal[[2]]), 0L)

    calls <- character(0)
    res <- get_assessments("be", source = "be_dsi")
    expect_identical(nrow(res), 3L)
    detail_calls <- calls[!grepl("zoekRsql", calls)]
    expect_length(detail_calls, 0L)
  })
})

test_that("failed listing page, early end and empty page before totalPages warn", {
  p0 <- .dsi_pages[[1]]
  # failed second page
  with_dsi(
    {
      expect_warning(
        res <- get_assessments("be", source = "be_dsi", write_sidecar = FALSE),
        class = "planscanR_warning_partial"
      )
      expect_identical(nrow(res), 2L)
    },
    pages = list(p0, "fail")
  )
  # early end: totalPages reached but fewer rows than totalElements
  early <- p0
  early$page$totalPages <- 1L
  early$page$totalElements <- 5L
  with_dsi(
    {
      expect_warning(
        res <- get_assessments("be", source = "be_dsi", write_sidecar = FALSE),
        "2 of 5",
        class = "planscanR_warning_partial"
      )
      expect_identical(nrow(res), 2L)
    },
    pages = list(early)
  )
  # empty page before totalPages
  empty <- list(
    `_embedded` = list(ficheOverzichtZoekResultaats = list()),
    page = list(totalPages = 3L, totalElements = 3L)
  )
  with_dsi(
    {
      expect_warning(
        get_assessments("be", source = "be_dsi", write_sidecar = FALSE),
        "incomplete|empty",
        class = "planscanR_warning_partial"
      )
    },
    pages = list(p0, empty)
  )
  # non-list payload
  with_dsi(
    {
      expect_warning(
        res <- get_assessments("be", source = "be_dsi", write_sidecar = FALSE),
        class = "planscanR_warning_partial"
      )
      expect_identical(res, empty_result_tibble())
    },
    pages = list("fail")
  )
})

test_that("procedure_code must be a single string", {
  expect_error(
    get_assessments("be", source = "be_dsi", procedure_code = c("BPA", "gewRUP")),
    class = "planscanR_error_bad_input"
  )
  expect_error(
    get_assessments("be", source = "be_dsi", procedure_code = NA_character_),
    class = "planscanR_error_bad_input"
  )
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
