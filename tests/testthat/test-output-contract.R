# Output column contract (dev/spec/contract.md §1). Locks the guaranteed core
# columns across ALL 19 country handlers BEFORE Phase 3.2 renames portal-native
# keys, so that work cannot silently drop or retype a core column. Each handler
# is driven to one representative record through its parse seam + existing
# fixtures (no live HTTP); at/de/nl mock the network binding.

# One representative 1-row record per country, built from existing fixtures.
make_record <- list(
  at = function() {
    with_mocked_bindings(
      planscanR:::at_parse_detail(
        planscanR:::at_canonical_url(449),
        list(az = "02 0514", v2id = 449L, title = "x", year = 2016L, province = "O", type = 1L)
      ),
      perform_json = function(req) {
        jsonlite::fromJSON(fixture_path("at", "vorhabeninfo-449.json"), simplifyVector = FALSE)
      },
      .package = "planscanR"
    )
  },
  be = function() {
    planscanR:::be_parse_detail(
      planscanR:::be_canonical_url("PR4037"),
      list(
        nummer = "PR4037",
        dossierType = "PROJECT_MER",
        titel = "Windturbineproject Overhaem",
        initiatiefnemer = list(naam = "Spark Power", kboNummer = "1002476390")
      ),
      jsonlite::fromJSON(fixture_path("be", "dossier-PR4037.json"), simplifyVector = FALSE)
    )
  },
  bg = function() {
    planscanR:::bg_parse_detail(
      planscanR:::bg_canonical_url("OVOS", "21617"),
      list(
        register = "OVOS",
        id = "21617",
        dossier_number = "БД - ОВОС - 75 - 2017",
        incoming_number = "533",
        title = "x",
        proponent = "y",
        native_type = NA_character_,
        status = "z"
      ),
      rvest::read_html(fixture_path("bg", "detail-ovos-21617.html"))
    )
  },
  cz = function() {
    planscanR:::cz_parse_detail(
      planscanR:::cz_canonical_url("EIA", "JHC1237"),
      list(
        register = "EIA",
        code = "JHC1237",
        title = "x",
        competent_authority = "y",
        native_type = "I/68",
        status = "z",
        last_modified = as.Date("2026-06-04")
      ),
      rvest::read_html(fixture_path("cz", "detail-eia-jhc1237.html"))
    )
  },
  de = function() {
    with_mocked_bindings(
      planscanR:::de_parse_detail(
        "https://www.uvp-verbund.de/trefferanzeige?docuuid=a8837db3-a6e0-4aa9-b13a-c5d2735187cb"
      ),
      perform_html = function(req) rvest::read_html(fixture_path("de", "detail-walldurn-windpark.html")),
      req_planscanr = function(base_url, path = NULL) base_url,
      .package = "planscanR"
    )
  },
  dk = function() {
    entry <- jsonlite::fromJSON(fixture_path("dk", "search.json"), simplifyVector = FALSE)[[1]]
    planscanR:::dk_parse_entry(planscanR:::dk_canonical_url(entry$id), entry)
  },
  ee = function() {
    planscanR:::ee_parse_detail(
      planscanR:::ee_canonical_url("KMH", "478"),
      list(
        register = "KMH",
        id = "478",
        title = "x",
        region = "y",
        initiation_date = as.Date("2025-01-22"),
        initiation_reason = NA_character_,
        status = "z",
        developer = "w",
        ksh_type = NA_character_,
        activity = "a"
      ),
      rvest::read_html(fixture_path("ee", "kmh-detail-478.html"))
    )$record
  },
  fi = function() {
    listing <- jsonlite::fromJSON(fixture_path("fi", "listing-yva-page0.json"), simplifyVector = FALSE)
    src <- Filter(
      function(s) identical(s$id, "1498"),
      lapply(listing$hits$hits, `[[`, "_source")
    )[[1]]
    url <- planscanR:::fi_canonical_url(src$link)
    planscanR:::fi_build_record(
      url,
      src,
      planscanR:::fi_parse_detail(rvest::read_html(fixture_path("fi", "detail-1498.html")))
    )
  },
  fr = function() {
    planscanR:::fr_parse_record(
      planscanR:::fr_canonical_url("2018108485"),
      jsonlite::fromJSON(fixture_path("fr", "records-2018108485.json"), simplifyVector = FALSE)$results[[1]]
    )
  },
  gr = function() {
    planscanR:::gr_parse_record(
      planscanR:::gr_canonical_url("19895"),
      jsonlite::fromJSON(fixture_path("gr", "list_page1.json"), simplifyVector = FALSE)$data[[1]]
    )
  },
  hr = function() {
    html <- rvest::read_html(fixture_path("hr", "puo-listing.html"))
    block <- planscanR:::hr_project_blocks(html)[[1]]
    title <- planscanR:::hr_block_title(block)
    id <- planscanR:::hr_document_id("PUO", title)
    planscanR:::hr_parse_block(list(
      register = "PUO",
      document_id = id,
      url = planscanR:::hr_canonical_url(planscanR:::hr_register_urls("PUO")[[1]], id),
      title = title,
      assessment_type = "EIA",
      block = block
    ))
  },
  ie = function() {
    page <- jsonlite::fromJSON(fixture_path("ie", "query_page1.json"), simplifyVector = FALSE)
    qa <- jsonlite::fromJSON(fixture_path("ie", "query_attachments.json"), simplifyVector = FALSE)
    idx <- list()
    for (grp in qa$attachmentGroups) {
      parent <- as.character(grp$parentObjectId)
      idx[[parent]] <- vapply(
        grp$attachmentInfos,
        function(i) planscanR:::ie_attachment_url(parent, i$id),
        character(1)
      )
    }
    planscanR:::ie_parse_feature(
      planscanR:::ie_canonical_url("2024092"),
      page$features[[1]],
      idx
    )
  },
  is = function() {
    single <- jsonlite::fromJSON(fixture_path("is", "single_issue_137.json"), simplifyVector = FALSE)
    planscanR:::is_parse_issue(
      planscanR:::is_canonical_url("137"),
      list(
        process_id = "16",
        id = "137",
        issue_number = "0137/2023",
        title = "x",
        published_date = "2023-06-01T09:31:55.254Z",
        closed_date = "2024-12-09T00:00:00.000Z",
        lifecycle = "done",
        has_geography = TRUE,
        process_type = "MAT_A_UMHVERFISAHRIFUM",
        current_phase = "p"
      ),
      single$data$singleIssue
    )$record
  },
  si = function() {
    arr <- jsonlite::fromJSON(fixture_path("si", "screening.json"), simplifyVector = FALSE)
    raw <- arr[[1]]
    entry <- list(
      register = "predhodni-postopek",
      url_segment = raw$URLSegment,
      url = planscanR:::si_canonical_url("predhodni-postopek", raw$URLSegment),
      raw = raw
    )
    planscanR:::si_build_record(entry, character(0))
  },
  pt = function() {
    url <- planscanR:::pt_canonical_url("3892")
    entry <- list(
      pro_id = "3892",
      aia_number = "3892",
      title = "Pedreira",
      proponent = "x",
      localizacao = "Mondim De Basto",
      licenciador = "y",
      autoridade = "z",
      ano_decisao = "2023",
      sentido_decisao = "Favorável condicionado"
    )
    detail <- rvest::read_html(fixture_path("pt", "detail.html"))
    documents <- rvest::read_html(fixture_path("pt", "documentos.html"))
    planscanR:::pt_parse_detail(url, entry, detail, documents)
  },
  gb = function() {
    df <- planscanR:::gb_parse_csv(
      paste(readLines(fixture_path("gb", "applications.csv")), collapse = "\n")
    )
    entry <- planscanR:::gb_map_rows(df)[[1]]
    url <- planscanR:::gb_canonical_url(entry$reference)
    planscanR:::gb_build_record(url, entry, character(0))$record
  },
  it = function() {
    info <- rvest::read_html(fixture_path("it", "info_detail.html"))
    documents <- planscanR:::it_parse_documents(
      rvest::read_html(fixture_path("it", "documentazione.html"))
    )
    entry <- list(
      register = "VIA",
      id = "7917",
      title = "Autostrada A22",
      proponent = "Autostrada del Brennero S.p.A.",
      procedura = "Verifica di Ottemperanza",
      doc_url = "https://va.mite.gov.it/it-IT/Oggetti/Documentazione/7917/19017",
      grp = "19017"
    )
    url <- planscanR:::it_canonical_url(entry$id)
    planscanR:::it_parse_detail(url, entry, info, documents)$record
  },
  sk = function() {
    detail <- jsonlite::fromJSON(
      fixture_path("sk", "detail_with_docs.json"),
      simplifyVector = FALSE
    )
    url <- planscanR:::sk_canonical_url(detail$seoId)
    planscanR:::sk_build_record(url, detail)
  },
  nl = function() {
    with_mocked_bindings(
      planscanR:::nl_parse_detail(
        "https://www.commissiemer.nl/advies/fabriek-voor-de-productie-van-aromaten-uit-niet-herbruikbaar-afvalplastic-in-delfzijl/"
      ),
      perform_html = function(req) rvest::read_html(fixture_path("nl", "advice-detail-aromaten-delfzijl.html")),
      req_planscanr = function(base_url, path = NULL) base_url,
      .package = "planscanR"
    )
  }
)

# Tier 1 (schema-enforced) + Tier 2 (core-conventional) per the contract.
# relevance_model is reader/scoring-populated, so it is NOT asserted on fresh
# handler output (covered by the round-trip test below instead).
expect_output_contract <- function(rec, cc) {
  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, cc)

  # Tier 1: required columns, present + correctly typed.
  expect_true(is.character(rec$country))
  expect_true(is.character(rec$source_portal))
  expect_true(is.character(rec$document_id))
  expect_true(is.character(rec$url))
  expect_s3_class(rec$retrieved_at, "POSIXct")
  expect_true(is.list(rec$attachment_urls))
  expect_true(is.list(rec$local_path))

  # Tier 2: core-conventional columns present (value may be NA), typed.
  tier2 <- c("title", "summary", "competent_authority", "proponent", "date_decision", "download_status")
  expect_true(all(tier2 %in% names(rec)))
  expect_true(is.character(rec$title))
  expect_true(is.character(rec$summary))
  expect_true(is.character(rec$competent_authority))
  expect_true(is.character(rec$proponent))
  expect_s3_class(rec$date_decision, "Date")
  expect_true(is.list(rec$download_status))
}

for (cc in names(make_record)) {
  local({
    country <- cc
    test_that(paste0("output contract: ", country, " returns the core columns, typed"), {
      expect_output_contract(make_record[[country]](), country)
    })
  })
}

test_that("empty_result_tibble() carries the required columns with correct types", {
  e <- planscanR:::empty_result_tibble()
  expect_true(all(planscanR:::required_columns() %in% names(e)))
  expect_identical(nrow(e), 0L)
  expect_true(is.character(e$country))
  expect_s3_class(e$retrieved_at, "POSIXct")
  expect_true(is.list(e$attachment_urls))
  expect_true(is.list(e$local_path))
})

test_that("bind_results() across all 19 countries is type-stable", {
  recs <- lapply(names(make_record), function(cc) make_record[[cc]]())
  bound <- expect_no_error(planscanR::bind_results(!!!recs))
  expect_identical(nrow(bound), 19L)
  expect_setequal(bound$country, names(make_record))
  # Core columns survive the bind, types intact.
  expect_true(all(planscanR:::required_columns() %in% names(bound)))
  expect_s3_class(bound$retrieved_at, "POSIXct")
  expect_s3_class(bound$date_decision, "Date")
})

test_that("the sidecar reader guarantees relevance_model on round-trip", {
  withr::with_tempdir({
    options(planscanR.cache_dir = getwd())
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    rec <- tibble::tibble(
      country = "zz",
      source_portal = "x",
      document_id = "rm1",
      url = "https://x/rm1",
      retrieved_at = as.POSIXct("2025-01-01", tz = "UTC"),
      attachment_urls = list(character(0)),
      local_path = list(character(0))
    )
    planscanR:::write_record_sidecar(rec)
    back <- planscanR:::read_record_sidecar(planscanR:::sidecar_path("zz", "rm1"))
    expect_true("relevance_model" %in% names(back))
  })
})
