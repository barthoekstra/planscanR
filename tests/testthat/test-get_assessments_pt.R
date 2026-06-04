# Tests for get_assessments_pt(). Offline strategy: stub the page generator
# (pt_fetch_search) and the per-record HTML fetches (pt_fetch_detail /
# pt_fetch_documents) so no live HTTP is needed in CI. Fixtures (SIAIA,
# server-rendered ASP.NET MVC):
#  - listing.html      : a 3-row trimmed ProcessoAIA listing
#  - detail.html       : the /ProcessoAIA/Detalhes/3892 detail page
#  - documentos.html   : the /ListaDocumentos?pro_id=3892 document list (20 docs,
#                        grouped across DIA / EIA / Consulta Pública / Parecer)

read_pt_html <- function(name) {
  rvest::read_html(fixture_path("pt", name))
}

.pt_fix_listing <- read_pt_html("listing.html")
.pt_fix_detail <- read_pt_html("detail.html")
.pt_fix_documentos <- read_pt_html("documentos.html")

# A synthetic listing entry that lines up with the detail/documentos fixtures
# (pro_id 3892). Mirrors pt_parse_listing_rows() output.
.pt_entry_3892 <- list(
  pro_id = "3892",
  aia_number = "3892",
  title = "Pedreira n.º 6823 “Travesseiras”",
  proponent = "Prego & Fernandes, Extracção de Pedra Lda",
  localizacao = "Mondim De Basto",
  licenciador = "Agência Portuguesa do Ambiente, I.P.",
  autoridade = "Comissão de Coordenação e Desenvolvimento Regional do Norte",
  ano_decisao = "2023",
  sentido_decisao = "Favorável condicionado"
)

# -- Parse-fn unit tests vs fixtures ----------------------------------------

test_that("pt_parse_listing_rows extracts rows (title, proponent, pro_id)", {
  rows <- planscanR:::pt_parse_listing_rows(.pt_fix_listing)
  expect_gte(length(rows), 1L)
  first <- rows[[1]]
  expect_match(first$pro_id, "^[0-9]+$")
  expect_true(nzchar(first$title))
  expect_true(nzchar(first$proponent))
  expect_true(nzchar(first$aia_number))
  # The 3892 record is in the trimmed fixture.
  ids <- vapply(rows, function(r) r$pro_id, character(1))
  expect_true("3892" %in% ids)
})

test_that("pt_extract_pro_id pulls the id from a Detalhes href", {
  expect_identical(planscanR:::pt_extract_pro_id("/ProcessoAIA/Detalhes/3892"), "3892")
  expect_identical(planscanR:::pt_extract_pro_id("Detalhes/42"), "42")
  expect_true(is.na(planscanR:::pt_extract_pro_id("/somewhere/else")))
  expect_true(is.na(planscanR:::pt_extract_pro_id(NA_character_)))
})

test_that("pt_parse_date parses the SIAIA DD/MM/YYYY format", {
  expect_identical(planscanR:::pt_parse_date("23/02/2023"), as.Date("2023-02-23"))
  expect_identical(planscanR:::pt_parse_date("01/11/2022"), as.Date("2022-11-01"))
  expect_true(is.na(planscanR:::pt_parse_date(NULL)))
  expect_true(is.na(planscanR:::pt_parse_date("")))
  expect_true(is.na(planscanR:::pt_parse_date("not a date")))
})

test_that("pt_phase_slug classifies Portuguese document labels into phases", {
  expect_identical(planscanR:::pt_phase_slug("DIA - Declaração Impacte Ambiental"), "dia")
  expect_identical(planscanR:::pt_phase_slug("EIA Relatório Sintese (RS)"), "eia")
  expect_identical(planscanR:::pt_phase_slug("Resumo não técnico"), "eia")
  expect_identical(planscanR:::pt_phase_slug("Parecer comissão de avaliação"), "parecer")
  expect_identical(planscanR:::pt_phase_slug("Relatório da consulta pública"), "consulta_publica")
  expect_identical(planscanR:::pt_phase_slug("Algo desconhecido"), "outros")
  expect_identical(planscanR:::pt_phase_slug(NULL), "outros")
  expect_identical(planscanR:::pt_phase_slug(NA_character_), "outros")
})

test_that("pt_parse_detail_fields reads the Campo/Conteudo table", {
  f <- planscanR:::pt_parse_detail_fields(.pt_fix_detail)
  expect_identical(f[["Nº AIA"]], "3892")
  expect_match(f[["Designação do projeto"]], "Travesseiras")
  expect_match(f[["Autoridade AIA"]], "Comissão de Coordenação")
  expect_identical(f[["Data da decisão"]], "23/02/2023")
  expect_identical(f[["Sentido da Decisão"]], "Favorável condicionado")
  # The Documentos row is skipped (parsed separately).
  expect_null(f[["Documentos"]])
})

test_that("pt_parse_documents groups PDF links by phase with the AIADOC pattern", {
  per_section <- planscanR:::pt_parse_documents(.pt_fix_documentos)
  expect_true(all(c("dia", "eia", "parecer", "consulta_publica") %in% names(per_section)))
  all_urls <- unlist(per_section, use.names = FALSE)
  expect_length(all_urls, 20L)
  # Direct AIADOC links rooted at the portal.
  expect_true(all(grepl("^https://siaia\\.apambiente\\.pt/AIADOC/AIA", all_urls)))
  # The DIA phase holds the decision document.
  expect_length(per_section$dia, 1L)
  expect_match(per_section$dia, "_dia")
})

test_that("pt_parse_detail builds a 1-row record with per-phase columns + union", {
  url <- planscanR:::pt_canonical_url("3892")
  rec <- planscanR:::pt_parse_detail(url, .pt_entry_3892, .pt_fix_detail, .pt_fix_documentos)

  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "pt")
  expect_identical(rec$source_portal, "siaia.apambiente.pt")
  expect_identical(rec$document_id, "AIA-3892")
  expect_identical(rec$url, url)
  expect_match(rec$title, "Travesseiras")
  expect_match(rec$competent_authority, "Comissão de Coordenação")
  expect_match(rec$proponent, "Prego")
  expect_identical(rec$date_decision, as.Date("2023-02-23"))
  expect_identical(rec$date_published, as.Date("2022-11-01") + 10L) # 11/11/2022
  expect_identical(rec$decision_year, "2023")
  expect_match(rec$native_type, "Favorável")
  # Extras (English snake_case, Portuguese values verbatim).
  expect_identical(rec$aia_number, "3892")
  expect_identical(rec$municipalities, "Mondim De Basto")
  expect_match(rec$licensing_authority, "Agência Portuguesa")
  expect_match(rec$decision_sense, "Favorável")
  # Per-phase attachment columns + deduplicated union.
  expect_true("attachment_urls_dia" %in% names(rec))
  expect_true("attachment_urls_eia" %in% names(rec))
  expect_true("attachment_urls_consulta_publica" %in% names(rec))
  expect_true("attachment_urls_parecer" %in% names(rec))
  union <- rec$attachment_urls[[1]]
  expect_length(union, 20L)
  expect_true(all(grepl("^https://siaia\\.apambiente\\.pt/AIADOC/AIA", union)))
})

test_that("pt_record_matches honours query and date_range", {
  rec <- tibble::tibble(
    title = "Central Solar do Pinhal",
    date_decision = as.Date("2023-02-23"),
    decision_year = "2023"
  )
  # query: positive + negative
  expect_true(planscanR:::pt_record_matches(rec, NULL, "solar"))
  expect_true(planscanR:::pt_record_matches(rec, NULL, "SOLAR"))
  expect_false(planscanR:::pt_record_matches(rec, NULL, "barragem"))
  # date_range against the full decision date.
  expect_true(planscanR:::pt_record_matches(rec, as.Date(c("2023-01-01", "2023-12-31")), NULL))
  expect_false(planscanR:::pt_record_matches(rec, as.Date(c("2020-01-01", "2020-12-31")), NULL))
  # date_range against decision_year when only a year is known.
  rec_year <- tibble::tibble(
    title = "x",
    date_decision = as.Date(NA),
    decision_year = "2021"
  )
  expect_true(planscanR:::pt_record_matches(rec_year, as.Date(c("2021-01-01", "2021-12-31")), NULL))
  expect_false(planscanR:::pt_record_matches(rec_year, as.Date(c("2019-01-01", "2019-12-31")), NULL))
})

# -- End-to-end on fixtures --------------------------------------------------

# Page generator that yields the single 3892 entry once, then signals exhausted.
pt_mock_search <- function() {
  function() {
    emitted <- FALSE
    function() {
      if (emitted) {
        return(NULL)
      }
      emitted <<- TRUE
      list(.pt_entry_3892)
    }
  }
}

test_that("get_assessments_pt end-to-end on fixtures (sidecar-first)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      pt_fetch_search = pt_mock_search(),
      pt_fetch_detail = function(url) .pt_fix_detail,
      pt_fetch_documents = function(pro_id) .pt_fix_documentos
    )

    res <- get_assessments_pt(limit = 5, download = FALSE)
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$document_id, "AIA-3892")
    expect_identical(res$url, planscanR:::pt_canonical_url("3892"))

    # Sidecar landed on disk.
    sidecars <- list.files(
      file.path(cache, "files", "pt"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 1L)

    # Second call with refresh = FALSE must NOT re-invoke the detail fetch.
    local_mocked_bindings(
      pt_fetch_detail = function(...) {
        stop("pt_fetch_detail should not be called on a cached URL")
      },
      pt_fetch_documents = function(...) {
        stop("pt_fetch_documents should not be called on a cached URL")
      }
    )
    res2 <- get_assessments_pt(limit = 5, download = FALSE)
    expect_identical(nrow(res2), 1L)
    expect_identical(res2$document_id, "AIA-3892")
  })
})

test_that("get_assessments_pt honours query, date_range and limit", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      pt_fetch_search = pt_mock_search(),
      pt_fetch_detail = function(url) .pt_fix_detail,
      pt_fetch_documents = function(pro_id) .pt_fix_documentos
    )

    # query: positive matches the project designation.
    res_q <- get_assessments_pt(query = "Travesseiras", download = FALSE)
    expect_identical(nrow(res_q), 1L)
    # query: negative drops the only record.
    res_qneg <- get_assessments_pt(query = "no-such-project-xyz", download = FALSE)
    expect_identical(nrow(res_qneg), 0L)

    # date_range: positive window contains the 2023 decision.
    res_d <- get_assessments_pt(date_range = c("2023-01-01", "2023-12-31"), download = FALSE)
    expect_identical(nrow(res_d), 1L)
    # date_range: negative window.
    res_dneg <- get_assessments_pt(date_range = c("2019-01-01", "2019-12-31"), download = FALSE)
    expect_identical(nrow(res_dneg), 0L)

    # limit caps the total.
    res_lim <- get_assessments_pt(limit = 0, download = FALSE)
    expect_identical(nrow(res_lim), 0L)
  })
})

test_that("PT -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      pt_fetch_search = pt_mock_search(),
      pt_fetch_detail = function(url) .pt_fix_detail,
      pt_fetch_documents = function(pro_id) .pt_fix_documentos
    )

    res <- get_assessments_pt(limit = 5, download = FALSE)
    idx <- index_cache(country = "pt")
    expect_identical(nrow(idx), 1L)
    expect_identical(idx$document_id, "AIA-3892")

    # Country-specific extras round-trip through extras{}.
    expect_true(all(
      c("aia_number", "municipalities", "licensing_authority", "decision_sense", "decision_year") %in% names(idx)
    ))
    expect_identical(idx$aia_number, "3892")
    expect_identical(idx$municipalities, "Mondim De Basto")
    expect_match(idx$decision_sense, "Favorável")
    # Per-phase attachment URL columns survive too.
    expect_true(any(grepl("^attachment_urls_", names(idx))))
    expect_true("attachment_urls_dia" %in% names(idx))
  })
})

test_that("get_assessments_pt scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      pt_fetch_search = pt_mock_search(),
      pt_fetch_detail = function(url) .pt_fix_detail,
      pt_fetch_documents = function(pro_id) .pt_fix_documentos
    )

    res <- get_assessments_pt(
      limit = 5,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(quarry = "pedreira", solar = "energia solar"),
      relevance_model = make_fake_model(languages = c("pt", "en"))
    )
    expect_identical(nrow(res), 1L)
    expect_true("relevance_score_quarry" %in% names(res))
    expect_true("relevance_score_solar" %in% names(res))
    expect_true(is.numeric(res$relevance_score_quarry))
  })
})

# -- Live integration test --------------------------------------------------

test_that("get_assessments_pt() fetches a real record end-to-end", {
  skip_if_offline_tests()
  # Called directly rather than via get_assessments("pt", ...): dispatch
  # registration (supported_countries() / select_assessments_handler()) lives
  # in shared files wired by the Lead after this vertical slice merges. Once
  # registered, get_assessments("pt", limit = 1, download = FALSE) is the
  # public form and resolves to exactly this handler.
  with_temp_cache({
    res <- get_assessments_pt(limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "pt")
    expect_identical(res$source_portal, "siaia.apambiente.pt")
    expect_true(grepl("^https://siaia\\.apambiente\\.pt", res$url))
  })
})
