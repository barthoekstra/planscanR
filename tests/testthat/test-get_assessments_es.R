# Tests for get_assessments_es(). The Spanish MITECO/SABIA portal TLS-
# fingerprints libcurl and is reachable ONLY through the optional {chromote}
# headless-browser transport, which cannot run on CI. So every automated test
# here MOCKS the browser seams (browser_available / browser_open / browser_fetch
# / browser_submit_form / browser_close / browser_download) and feeds the
# recorded HTML fixtures:
#  - results.html : the bulk proy_resultados table (4 rows)
#  - ficha.html   : one record's listadoDocumentacion document table (3 docs)

read_es_fixture_text <- function(name) {
  paste(readLines(fixture_path("es", name), warn = FALSE), collapse = "\n")
}

.es_results_html <- read_es_fixture_text("results.html")
.es_ficha_html <- read_es_fixture_text("ficha.html")

# A dummy session object: the mocked seams ignore it, but the handler passes it
# around, so it just needs to be non-NULL.
.es_dummy_session <- structure(list(), class = "es_dummy_session")

# A browser_fetch mock: the only POST the handler issues is the bulk
# proy_resultados, so always hand back the results fixture.
mock_browser_fetch_es <- function(...) {
  list(status = 200L, body = .es_results_html)
}

# A browser_submit_form mock: the ficha navigation issues two submits per
# record (proy_estado_tramitacion, then listadoDocumentacion). Only the listado
# step is parsed, so we hand back the ficha fixture for it and an empty page for
# the intermediate estado step.
mock_browser_submit_form_es <- function(session, fields, ...) {
  if (identical(fields$accion, "listadoDocumentacion")) {
    return(.es_ficha_html)
  }
  "<html><body></body></html>"
}

local_mock_es_browser <- function(env = parent.frame()) {
  testthat::local_mocked_bindings(
    browser_available = function() TRUE,
    browser_open = function(...) .es_dummy_session,
    browser_close = function(...) invisible(NULL),
    browser_fetch = mock_browser_fetch_es,
    browser_submit_form = mock_browser_submit_form_es,
    # The bulk-results body needs the per-session datosPropios token, which is
    # read off the live form; supply a stub so no real session is touched.
    es_harvest_datos_propios = function(session) "DatosPropios@deadbeef",
    .env = env
  )
}

# -- Parse-fn units ----------------------------------------------------------

test_that("es_parse_results extracts code/title/status + assessment_type/register", {
  rows <- planscanR:::es_parse_results(.es_results_html, "proyectos")
  expect_identical(length(rows), 4L)
  first <- rows[[1]]
  expect_identical(first$register, "proyectos")
  expect_identical(first$code, "20260126")
  expect_match(first$title, "TOROZOS 3 BESS")
  expect_identical(first$status, "INICIO")
  expect_identical(
    first$url,
    "https://sede.miteco.gob.es/portal/site/seMITECO/navServicioContenido#20260126"
  )
})

test_that("es_document_id prefixes per register so EIA/SEA never collide", {
  expect_identical(planscanR:::es_document_id("proyectos", "20210330"), "EIA-20210330")
  expect_identical(planscanR:::es_document_id("planes", "20210330"), "SEA-20210330")
})

test_that("es_origin selects the right dual-source origin", {
  expect_match(planscanR:::es_origin("proyectos"), "navServicioContenido$")
  expect_match(planscanR:::es_origin("planes"), "navSabiaPlanes$")
})

test_that("es_parse_documents groups PDFs by Tipo de documento slug", {
  docs <- planscanR:::es_parse_documents(.es_ficha_html, "proyectos", "20210330")
  expect_setequal(
    names(docs$per_section),
    c("documentacion_ambiental", "documento_de_listado_de_consultas", "resolucion")
  )
  # Stable synthetic URLs carried in attachment_urls.
  expect_match(
    docs$per_section$resolucion,
    "navServicioContenido#20210330/PUBLICACION"
  )
  # Live (session-bound) resource.process URLs are resolved separately.
  expect_identical(length(docs$live), 3L)
  expect_true(all(grepl("resource.process", unname(docs$live))))
})

test_that("es_section_slug folds Spanish diacritics before slugging", {
  expect_identical(planscanR:::es_section_slug("Resolución"), "resolucion")
  expect_identical(planscanR:::es_section_slug("Documentación ambiental"), "documentacion_ambiental")
  expect_identical(planscanR:::es_section_slug(NA_character_), "documento")
})

test_that("es_search_xml injects Titulo/Codigo and escapes XML metacharacters", {
  xml <- planscanR:::es_search_xml(query = "eólica & mar", codigo = "2021<33>0")
  expect_match(xml, "<Titulo>eólica &amp; mar</Titulo>")
  expect_match(xml, "<Codigo>2021&lt;33&gt;0</Codigo>")
  # Empty by default.
  expect_match(planscanR:::es_search_xml(), "<Codigo></Codigo><Titulo></Titulo>")
})

test_that("es_normalise_assessment_type accepts the vocabulary case-insensitively", {
  expect_identical(planscanR:::es_normalise_assessment_type(NULL), "All")
  expect_identical(planscanR:::es_normalise_assessment_type(""), "All")
  expect_identical(planscanR:::es_normalise_assessment_type("eia"), "EIA")
  expect_identical(planscanR:::es_normalise_assessment_type("SEA"), "SEA")
  expect_error(
    planscanR:::es_normalise_assessment_type("nope"),
    class = "planscanR_error_bad_input"
  )
})

test_that("es_build_record produces a schema-valid 1-row tibble with section columns", {
  entry <- list(
    register = "proyectos",
    code = "20210330",
    title = "PROYECTO DE EJEMPLO",
    status = "PUBLICADO BOE",
    url = planscanR:::es_canonical_url("proyectos", "20210330")
  )
  docs <- planscanR:::es_parse_documents(.es_ficha_html, "proyectos", "20210330")
  rec <- planscanR:::es_build_record(entry, docs)
  expect_s3_class(rec, "tbl_df")
  expect_identical(nrow(rec), 1L)
  expect_identical(rec$country, "es")
  expect_identical(rec$source_portal, "sede.miteco.gob.es")
  expect_identical(rec$document_id, "EIA-20210330")
  expect_identical(rec$assessment_type, "EIA")
  expect_identical(rec$register, "proyectos")
  expect_identical(rec$expediente, "20210330")
  expect_identical(
    rec$competent_authority,
    "Ministerio para la Transición Ecológica y el Reto Demográfico"
  )
  expect_identical(length(rec$attachment_urls[[1]]), 3L)
  expect_true("attachment_urls_resolucion" %in% names(rec))
})

# -- Graceful degradation ----------------------------------------------------

test_that("get_assessments_es aborts with a classed error when no browser is available", {
  local_mocked_bindings(browser_available = function() FALSE)
  expect_error(
    get_assessments_es(limit = 1, download = FALSE),
    class = "planscanR_error_browser_unavailable"
  )
})

# -- End-to-end on fixtures (mocked browser) ---------------------------------

test_that("get_assessments_es end-to-end on fixtures (dual-source; sidecar-first reuse)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)
    # Browser is slow; turn off the throttle in tests.
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.es_throttle_rate = NULL), add = TRUE)

    local_mock_es_browser()

    res <- get_assessments_es(limit = 100, download = FALSE)
    planscanR:::validate_result_schema(res)
    # 4 rows per register, both registers -> 8.
    expect_identical(nrow(res), 8L)
    expect_setequal(res$assessment_type, c("EIA", "SEA"))
    expect_true(all(c("EIA", "SEA") %in% sub("-.*$", "", res$document_id)))
    # Each record's ficha (same fixture) yields 3 grouped attachments.
    expect_true(all(lengths(res$attachment_urls) == 3L))

    sidecars <- list.files(
      file.path(cache, "files", "es"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE
    )
    expect_length(sidecars, 8L)

    # Second call with refresh = FALSE must NOT re-navigate the ficha.
    local_mocked_bindings(
      es_fetch_ficha = function(...) {
        stop("es_fetch_ficha should not run on a cached record")
      }
    )
    res2 <- get_assessments_es(limit = 100, download = FALSE)
    expect_identical(nrow(res2), 8L)
  })
})

test_that("get_assessments_es honours the assessment_type filter (dual-source selection)", {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.cache_dir = NULL, planscanR.es_throttle_rate = NULL), add = TRUE)
    local_mock_es_browser()

    res_eia <- get_assessments_es(assessment_type = "EIA", limit = 100, download = FALSE)
    expect_identical(nrow(res_eia), 4L)
    expect_setequal(res_eia$assessment_type, "EIA")
    expect_setequal(res_eia$register, "proyectos")

    res_sea <- get_assessments_es(assessment_type = "SEA", limit = 100, download = FALSE)
    expect_identical(nrow(res_sea), 4L)
    expect_setequal(res_sea$assessment_type, "SEA")
    expect_setequal(res_sea$register, "planes")
  })
})

test_that("get_assessments_es honours query, codigo and the global limit", {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.cache_dir = NULL, planscanR.es_throttle_rate = NULL), add = TRUE)
    local_mock_es_browser()

    # query matches one row's title (client-side substring).
    res_q <- get_assessments_es(query = "TOROZOS 2", limit = 100, download = FALSE)
    expect_identical(nrow(res_q), 2L) # one per register
    expect_true(all(grepl("TOROZOS 2", res_q$title)))

    # codigo matches one exact expediente per register.
    res_c <- get_assessments_es(codigo = "20260124", limit = 100, download = FALSE)
    expect_identical(nrow(res_c), 2L)
    expect_setequal(res_c$expediente, "20260124")

    # Global limit caps across both registers (proyectos crawled first).
    res_lim <- get_assessments_es(limit = 1, download = FALSE)
    expect_identical(nrow(res_lim), 1L)
    expect_identical(res_lim$assessment_type, "EIA")
  })
})

test_that("get_assessments_es date_range drops records with no date", {
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.cache_dir = NULL, planscanR.es_throttle_rate = NULL), add = TRUE)
    local_mock_es_browser()

    # The listing carries no dates, so any explicit date_range drops every row.
    res <- get_assessments_es(
      date_range = c("2026-01-01", "2026-12-31"),
      limit = 100,
      download = FALSE
    )
    expect_identical(nrow(res), 0L)
  })
})

test_that("get_assessments_es downloads PDFs through the browser (browser_download)", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.cache_dir = NULL, planscanR.es_throttle_rate = NULL), add = TRUE)
    local_mock_es_browser()

    # browser_download mock: write a tiny PDF to dest and report success.
    local_mocked_bindings(
      browser_download = function(session, url, dest_path, max_bytes = Inf, ...) {
        dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)
        writeBin(charToRaw("%PDF-1.4\nmock"), dest_path)
        list(
          status = 200L,
          content_type = "application/pdf",
          size_bytes = file.info(dest_path)$size,
          written = TRUE,
          reason = NA_character_
        )
      }
    )

    res <- get_assessments_es(assessment_type = "EIA", limit = 1, download = TRUE)
    expect_identical(nrow(res), 1L)
    ds <- res$download_status[[1]]
    expect_identical(nrow(ds), 3L)
    expect_true(all(ds$status == "downloaded"))
    expect_true(all(file.exists(ds$local_path)))
    # Section-scoped local paths populated.
    expect_true("local_path_resolucion" %in% names(res))
    expect_length(res$local_path_resolucion[[1]], 1L)
  })
})

# -- Sidecar / extras round-trip + relevance ---------------------------------

test_that("ES -> sidecar round-trip preserves the country-specific extras", {
  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.cache_dir = NULL, planscanR.es_throttle_rate = NULL), add = TRUE)
    local_mock_es_browser()

    res <- get_assessments_es(assessment_type = "EIA", limit = 4, download = FALSE)
    idx <- index_cache(country = "es")
    expect_identical(nrow(idx), 4L)
    expect_true(all(c("register", "assessment_type", "expediente") %in% names(idx)))
    expect_setequal(idx$assessment_type, "EIA")
    expect_true("attachment_urls_resolucion" %in% names(idx))
  })
})

test_that("get_assessments_es scores topics and adds relevance_score_<slug> columns", {
  skip_if_not_installed("planscanR.screen")
  withr::with_tempdir({
    options(planscanR.cache_dir = file.path(getwd(), "cache"))
    options(planscanR.es_throttle_rate = 0)
    on.exit(options(planscanR.cache_dir = NULL, planscanR.es_throttle_rate = NULL), add = TRUE)
    local_mock_es_browser()

    res <- get_assessments_es(
      assessment_type = "EIA",
      limit = 4,
      download = FALSE,
      write_sidecar = FALSE,
      topic = c(bess = "almacenamiento", autovia = "autovia"),
      relevance_model = make_fake_model(languages = c("es", "en"))
    )
    expect_identical(nrow(res), 4L)
    expect_true("relevance_score_bess" %in% names(res))
    expect_true("relevance_score_autovia" %in% names(res))
    expect_true(is.numeric(res$relevance_score_bess))
  })
})

# -- Live integration test ---------------------------------------------------

test_that("get_assessments('es') fetches a real record end-to-end (needs a browser)", {
  skip_if_offline_tests()
  skip_if_not(planscanR:::browser_available())
  with_temp_cache({
    res <- get_assessments("es", limit = 1, download = FALSE)
    expect_s3_class(res, "tbl_df")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_identical(res$country, "es")
    expect_identical(res$source_portal, "sede.miteco.gob.es")
    expect_true(grepl("^https://sede\\.miteco\\.gob\\.es", res$url))
  })
})
