#' Fetch environmental-assessment records from Spain.
#'
#' Implementation of [get_assessments()] for Spain. Backed by the
#' **MITECO / SABIA** public consultation portal *Consulta pública de
#' evaluaciones ambientales* on the electronic headquarters
#' (<https://sede.miteco.gob.es>). It covers the
#' **national-competence** environmental assessments only — most Spanish EIA is
#' decided by the autonomous communities and lives in their regional registers,
#' which are out of scope here.
#'
#' The portal publishes two adjacent registers behind the same Liferay backend,
#' merged into a single result tibble and selected via an `assessment_type`
#' argument:
#'
#' * **EIA** — *Evaluación de Impacto Ambiental de proyectos*, reached through
#'   the `navServicioContenido` origin (`register = "proyectos"`).
#' * **SEA** — *Evaluación Ambiental Estratégica de planes y programas*, reached
#'   through the `navSabiaPlanes` origin (`register = "planes"`).
#'
#' An `assessment_type` column (`"EIA"` / `"SEA"`) tags each row and is preserved
#' in the offline metadata cache; a `register` column carries the raw register
#' label (`"proyectos"` / `"planes"`). `document_id` is prefixed
#' `"EIA-"` / `"SEA-"` (e.g. `"EIA-20210330"`) so the two registers never
#' collide on disk.
#'
#' @section Requires the optional \{chromote\} headless-browser transport:
#' **This is the only handler in the family that cannot run on a pure-R
#' install.** The SABIA portal *TLS-fingerprints* the client: `libcurl`'s
#' ClientHello is rejected before any HTTP is exchanged, so `httr2` cannot even
#' complete the handshake. The handler therefore reaches the portal exclusively
#' through the optional headless-browser transport (a real headless Chrome
#' driven by the **\{chromote\}** package, listed in `Suggests`). The browser
#' navigates to the portal origin — clearing the TLS gate the way a real browser
#' does and establishing the Liferay session cookie — and then runs the portal's
#' own `fetch()` / form submissions in-page so every request rides Chrome's TLS
#' stack and cookies. All parsing stays in R.
#'
#' If \{chromote\} or a Chrome/Chromium binary is not available the handler
#' aborts up front with an actionable message (class
#' `planscanR_error_browser_unavailable`). Install \{chromote\} and Google Chrome
#' (or set `options(planscanR.chrome_path=)` / the `CHROMOTE_CHROME` environment
#' variable) to enable it. **Every other country works without a browser.**
#'
#' @section URL enumeration:
#' One session per register. The handler opens the register's origin (which
#' clears the TLS gate and sets the session cookie), harvests the per-session
#' `datosPropios` token from the search form, and issues a single bulk
#' `accion=proy_resultados` POST. The response is a multi-megabyte page whose
#' `<table id="tablaResultados">` carries **every** record as a row of
#' `expediente code | title | estado de tramitación`. The handler parses all
#' rows in R, respecting the global `limit`, and reuses the same session for the
#' per-record document-panel (*ficha*) navigation.
#'
#' @section Attachments:
#' The portal's document URLs are **session-bound and ephemeral** — a
#' `BINARYPORTLET resource.process` URL is valid only inside the live session
#' that rendered the *Acceso a la Documentación* panel (it carries per-render
#' `javax.portlet.sync` tokens), and the PDFs are themselves on the
#' TLS-fingerprinted host. So the handler does **not** persist those live URLs.
#' Instead it stores a stable synthetic identity URL per document
#' (`<origin>#<code>/<NOMBRE_SABIA>`) in `attachment_urls`, grouped by the
#' portal's *Tipo de documento* into `attachment_urls_<slug>` columns (the slug
#' is the ASCII-folded document-type label). When `download = TRUE`, the handler
#' navigates the live session to the record's *listadoDocumentacion* page,
#' resolves each synthetic URL to the live resource URL in the DOM, and pulls the
#' bytes in-session via the browser (`browser_download()`), honouring
#' `max_file_size_mb`. A record whose ficha exposes no documents yields an empty
#' `attachment_urls` vector, which is valid.
#'
#' @section Geometry:
#' None. SABIA exposes no public per-record geometry (no WMS/WFS), so
#' `geometry_path` / `geometry_crs` are never set.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which register(s) to crawl: `"All"` (default),
#'    `"EIA"` (proyectos), or `"SEA"` (planes).
#' * `query` — a free-text title substring. Forwarded into the server-side
#'    `xml` *Buscador* `<Titulo>` filter, and also re-checked client-side.
#' * `codigo` — an exact expediente code, forwarded into the `xml`
#'    `<Codigo>` filter (and re-checked client-side).
#' * `date_range` — matched client-side; the listing carries no dates, so this
#'    drops every record unless a ficha-derived date is present (rare), matching
#'    the other metadata-light handlers.
#' * `limit` — caps the total number of records returned across both registers.
#'
#' @section Performance:
#' The list is one bulk POST per register (the full ~7,760-project page). The
#' per-record ficha navigation is several in-page form submissions, so it is
#' slow; a `Sys.sleep` of `getOption("planscanR.es_throttle_rate", 2)` seconds is
#' inserted between ficha fetches. Repeat runs are sidecar-first, so the ficha
#' navigation is skipped for records already cached.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text title query (server-side + client-side).
#' @param codigo Optional exact expediente code filter (server-side +
#'   client-side).
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which register(s) to crawl.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Requires {chromote} + a Chrome/Chromium binary.
#' get_assessments_es(limit = 3, download = FALSE)
#'
#' # SEA only (planes register)
#' get_assessments_es(assessment_type = "SEA", limit = 10, download = FALSE)
#'
#' # Title substring + download the national-competence PDFs through the browser
#' get_assessments_es(query = "eólica", limit = 5, download = TRUE)
#' }
get_assessments_es <- function(
  date_range = NULL,
  limit = Inf,
  download = FALSE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  codigo = NULL,
  assessment_type = "All",
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }

  # Single network path is the browser; abort early (and actionably) when the
  # optional transport is unavailable, before any cache/relevance setup.
  if (!browser_available()) {
    require_browser("es")
  }

  date_range <- parse_date_range(date_range)
  assessment_type <- es_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }

  rel <- setup_relevance(topic, relevance_model, country = "es")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("es")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("proyectos", "planes"),
    EIA = "proyectos",
    SEA = "planes"
  )

  throttle <- getOption("planscanR.es_throttle_rate", 2)

  records <- list()
  for (reg in registers) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    block <- tryCatch(
      es_crawl_register(
        register = reg,
        sidecar_index = sidecar_index,
        rel = rel,
        query = query,
        codigo = codigo,
        date_range = date_range,
        limit = remaining,
        download = download,
        overwrite = overwrite,
        max_file_size_mb = max_file_size_mb,
        write_sidecar = write_sidecar,
        relevance_threshold = relevance_threshold,
        throttle = throttle
      ),
      planscanR_error_browser_unavailable = function(e) stop(e),
      error = function(e) {
        warn_partial(
          "Failed to crawl SABIA {.val {reg}} register: {conditionMessage(e)}"
        )
        list()
      }
    )
    records <- c(records, block)
  }

  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

#' Source portal identifier used in `source_portal` and sidecar JSON.
#' @noRd
es_source_portal <- function() "sede.miteco.gob.es"

#' Public host base for the portal.
#' @noRd
es_portal_base <- function() "https://sede.miteco.gob.es"

#' Competent authority for every Spanish national-competence record.
#'
#' Spanish verbatim. The ficha does not surface a per-record órgano sustantivo
#' in a stable place, so we tag every record with the national ministry.
#' @noRd
es_competent_authority <- function() {
  "Ministerio para la Transici\u00f3n Ecol\u00f3gica y el Reto Demogr\u00e1fico"
}

#' Map a register code to its portal origin (search/results page).
#' @noRd
es_origin <- function(register) {
  base <- "https://sede.miteco.gob.es/portal/site/seMITECO/"
  switch(
    register,
    proyectos = paste0(base, "navServicioContenido"),
    planes = paste0(base, "navSabiaPlanes")
  )
}

#' Map a register code to its `assessment_type`.
#' @noRd
es_assessment_type_of <- function(register) {
  if (register == "proyectos") "EIA" else "SEA"
}

#' Map a register code to its `document_id` prefix.
#' @noRd
es_id_prefix <- function(register) {
  if (register == "proyectos") "EIA" else "SEA"
}

#' Document-ID per register so EIA 20210330 and SEA 20210330 never collide.
#' @noRd
es_document_id <- function(register, code) {
  sprintf("%s-%s", es_id_prefix(register), code)
}

#' Stable canonical (sidecar-keying) URL for a record.
#'
#' The portal has no GET-addressable detail URL (everything is POST-driven), so
#' we synthesise a stable per-record string: the register origin plus the
#' expediente code as a fragment.
#' @noRd
es_canonical_url <- function(register, code) {
  sprintf("%s#%s", es_origin(register), code)
}

#' Stable synthetic identity URL for one document of a record.
#'
#' The live `resource.process` URLs are session-bound and ephemeral, so we never
#' persist them. This stable string keys the document on the sidecar and is what
#' `attachment_urls` carries; the live URL is resolved per-download in-session.
#' @noRd
es_attachment_url <- function(register, code, nombre_sabia) {
  sprintf("%s#%s/%s", es_origin(register), code, nombre_sabia)
}

#' Normalise the `assessment_type` argument.
#' @noRd
es_normalise_assessment_type <- function(x) {
  if (is.null(x) || !nzchar(x)) {
    return("All")
  }
  valid <- c("All", "EIA", "SEA")
  hit <- valid[tolower(valid) == tolower(x)]
  if (length(hit) == 0L) {
    cli::cli_abort(
      "{.arg assessment_type} must be one of {.val {valid}} (got {.val {x}}).",
      class = "planscanR_error_bad_input"
    )
  }
  hit
}

#' The bulk-search XML body (empty filters = all), with optional Titulo/Codigo.
#' @noRd
es_search_xml <- function(query = NULL, codigo = NULL) {
  esc <- function(x) {
    if (is.null(x) || is.na(x) || !nzchar(x)) {
      return("")
    }
    x <- gsub("&", "&amp;", x, fixed = TRUE)
    x <- gsub("<", "&lt;", x, fixed = TRUE)
    gsub(">", "&gt;", x, fixed = TRUE)
  }
  sprintf(
    paste0(
      "<DatosFirmados><DatosProcedimiento><Buscador>",
      "<Codigo>%s</Codigo><Titulo>%s</Titulo><EstadoTramitacion></EstadoTramitacion>",
      "<OrganoSustantivo></OrganoSustantivo><Tipo></Tipo><Promotor></Promotor>",
      "<Comunidad></Comunidad></Buscador></DatosProcedimiento></DatosFirmados>"
    ),
    esc(codigo),
    esc(query)
  )
}

# -----------------------------------------------------------------------------
# Browser-backed enumeration + ficha navigation (one session per register)
# -----------------------------------------------------------------------------

#' Crawl one register end-to-end on a single browser session.
#'
#' Opens the register origin (clears the TLS gate + sets the cookie), issues the
#' bulk results POST, parses every row, then for each row (sidecar-first) builds
#' the record — fetching + parsing the ficha document panel and, when
#' `download = TRUE`, pulling the PDFs in-session. The shared session is closed
#' on exit.
#' @noRd
es_crawl_register <- function(
  register,
  sidecar_index,
  rel,
  query,
  codigo,
  date_range,
  limit,
  download,
  overwrite,
  max_file_size_mb,
  write_sidecar,
  relevance_threshold,
  throttle
) {
  origin <- es_origin(register)
  session <- browser_open(origin, wait = 4)
  on.exit(browser_close(session), add = TRUE)

  body <- es_results_body(session, query = query, codigo = codigo)
  res <- browser_fetch(
    session,
    origin,
    method = "POST",
    body = body,
    headers = list("Content-Type" = "application/x-www-form-urlencoded")
  )
  if (is.null(res$body) || !nzchar(res$body)) {
    return(list())
  }
  rows <- es_parse_results(res$body, register)
  if (!is.null(codigo) && nzchar(codigo)) {
    rows <- Filter(function(r) identical(r$code, codigo), rows)
  }
  if (!is.null(query) && nzchar(query)) {
    rows <- Filter(
      function(r) !is.null(r$title) && grepl(tolower(query), tolower(r$title), fixed = TRUE),
      rows
    )
  }

  # The bulk results were fetched via in-page fetch(), which does NOT change the
  # rendered DOM — but the per-record ficha navigation submits the *results-page*
  # form (it carries `codigo_seleccionado`), which only exists once the results
  # page is rendered. `dom_state` lazily lands the DOM on the results page the
  # first time a ficha is actually navigated (skipped entirely when every record
  # is sidecar-cached).
  dom_state <- new.env(parent = emptyenv())
  dom_state$on_results <- FALSE

  records <- list()
  first <- TRUE
  for (entry in rows) {
    if (length(records) >= limit) {
      break
    }
    if (!first && is.numeric(throttle) && is.finite(throttle) && throttle > 0) {
      Sys.sleep(throttle)
    }
    first <- FALSE
    rec <- tryCatch(
      es_process_entry(
        entry = entry,
        session = session,
        dom_state = dom_state,
        sidecar_index = sidecar_index,
        rel = rel,
        date_range = date_range,
        download = download,
        overwrite = overwrite,
        max_file_size_mb = max_file_size_mb,
        write_sidecar = write_sidecar,
        relevance_threshold = relevance_threshold
      ),
      error = function(e) {
        warn_partial(
          "Failed to process {.val {entry$code}}: {conditionMessage(e)}"
        )
        NULL
      }
    )
    if (!is.null(rec)) {
      records[[length(records) + 1L]] <- rec
    }
  }
  records
}

#' Build the urlencoded `proy_resultados` POST body for the open session.
#'
#' Harvests the per-session `datosPropios` token from the live form and folds in
#' the search XML (empty filters by default; optional Titulo / Codigo).
#' @noRd
es_results_body <- function(session, query = NULL, codigo = NULL) {
  dp <- es_harvest_datos_propios(session)
  xml <- es_search_xml(query = query, codigo = codigo)
  enc <- function(s) utils::URLencode(s, reserved = TRUE)
  paste0(
    "datosFirmados=&datosSolicitante=&datosPropios=",
    enc(dp),
    "&xml=",
    enc(xml),
    "&accion=proy_resultados&id_pagina_cargada=BUSCADOR"
  )
}

#' Read the per-session `datosPropios` Java object ref from the live form.
#' @noRd
es_harvest_datos_propios <- function(session) {
  session$Runtime$evaluate(
    "(document.querySelector('[name=datosPropios]') || {}).value || ''",
    returnByValue = TRUE
  )$result$value %||%
    ""
}

#' Parse `<table id="tablaResultados">` into listing entries.
#'
#' Each data row is `<td>{code}</td><td><a>{title}</a></td><td>{status}</td>`.
#' The leading radio/label cells are HTML-commented out, so the code is the
#' first non-empty `<td>`.
#' @noRd
es_parse_results <- function(html_text, register) {
  html <- xml2::read_html(html_text)
  table <- rvest::html_element(html, "#tablaResultados")
  if (length(table) == 0L || inherits(table, "xml_missing")) {
    return(list())
  }
  trs <- rvest::html_elements(table, "tr")
  out <- list()
  for (tr in trs) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) < 3L) {
      next
    }
    code <- es_text(rvest::html_text2(tds[[1]]))
    if (is.null(code) || !grepl("^[0-9]+$", code)) {
      next
    }
    title <- es_text(rvest::html_text2(tds[[2]]))
    status <- es_text(rvest::html_text2(tds[[3]]))
    out[[length(out) + 1L]] <- list(
      register = register,
      code = code,
      title = title,
      status = status,
      url = es_canonical_url(register, code)
    )
  }
  out
}

#' Sidecar-first processing of one listing entry into a finalised record.
#' @noRd
es_process_entry <- function(
  entry,
  session,
  dom_state,
  sidecar_index,
  rel,
  date_range,
  download,
  overwrite,
  max_file_size_mb,
  write_sidecar,
  relevance_threshold
) {
  url <- entry$url
  hit <- sidecar_index[url]
  cached <- length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)

  if (cached) {
    rec <- read_record_sidecar(hit)
  } else {
    docs <- es_fetch_ficha(session, entry$register, entry$code, dom_state)
    rec <- es_build_record(entry, docs)
  }

  if (!es_record_matches(rec, date_range = date_range)) {
    return(NULL)
  }
  if (!is.null(rel)) {
    rec <- apply_relevance(rec, rel)
  }
  should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
  es_finalise_record(
    rec,
    session = session,
    dom_state = dom_state,
    download = should_download,
    overwrite = overwrite,
    max_file_size_mb = max_file_size_mb,
    write_sidecar = write_sidecar
  )
}

#' Ensure the live DOM is on the results page (form-render) before ficha nav.
#'
#' The bulk results came back via in-page `fetch()`, which leaves the rendered
#' DOM on the search page. The ficha steps submit the *results-page* form, so we
#' render it once per session (guarded by `dom_state$on_results`).
#' @noRd
es_ensure_results_dom <- function(session, dom_state) {
  if (isTRUE(dom_state$on_results)) {
    return(invisible(TRUE))
  }
  browser_submit_form(
    session,
    fields = list(accion = "proy_resultados"),
    wait = 5
  )
  dom_state$on_results <- TRUE
  invisible(TRUE)
}

#' Navigate the live session to a record's document panel and parse it.
#'
#' Two in-page form submissions advance the cookie-backed portlet state:
#' `proy_estado_tramitacion` (select the expediente) then
#' `listadoDocumentacion` (render the `tablaDocumentos`). Returns the parsed
#' per-section document table.
#' @noRd
es_fetch_ficha <- function(session, register, code, dom_state) {
  es_ensure_results_dom(session, dom_state)
  browser_submit_form(
    session,
    fields = list(codigo_seleccionado = code, accion = "proy_estado_tramitacion"),
    wait = 4
  )
  html_text <- browser_submit_form(
    session,
    fields = list(codigo_seleccionado = code, accion = "listadoDocumentacion"),
    wait = 4
  )
  # We have navigated away from the results listing; the next ficha must
  # re-render it first.
  dom_state$on_results <- FALSE
  es_parse_documents(html_text, register, code)
}

#' Parse `<table id="tablaDocumentos">` into a per-section list.
#'
#' Each row is `<td>{Tipo de documento}</td><td><a href="...resource.process/?
#' ...NOMBRE_SABIA=...">{name}</a></td>`. Returns
#' `list(per_section = <named list of stable synthetic URLs>,
#'       live = <named map: stable URL -> live resource URL>)`. The live URLs are
#' valid only inside the session that produced this HTML (used immediately for
#' download); the synthetic URLs are stable and persisted.
#' @noRd
es_parse_documents <- function(html_text, register, code) {
  html <- xml2::read_html(html_text)
  table <- rvest::html_element(html, "#tablaDocumentos")
  if (length(table) == 0L || inherits(table, "xml_missing")) {
    return(list(per_section = list(), live = stats::setNames(character(0), character(0))))
  }
  trs <- rvest::html_elements(table, "tbody tr")
  if (length(trs) == 0L) {
    trs <- rvest::html_elements(table, "tr")
  }
  per_section <- list()
  live <- character(0)
  for (tr in trs) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) < 2L) {
      next
    }
    a <- rvest::html_element(tds[[length(tds)]], "a[href*='resource.process']")
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    nombre <- es_nombre_sabia(href)
    if (is.null(nombre)) {
      next
    }
    tipo <- es_text(rvest::html_text2(tds[[1]]))
    slug <- es_section_slug(tipo)
    stable <- es_attachment_url(register, code, nombre)
    per_section[[slug]] <- unique(c(per_section[[slug]], stable))
    live[stable] <- es_absolute_url(href)
  }
  list(per_section = per_section, live = live)
}

#' Extract the (still-urlencoded) NOMBRE_SABIA token from a resource.process href.
#' @noRd
es_nombre_sabia <- function(href) {
  m <- regmatches(href, regexpr("NOMBRE_SABIA%3D[^&]+", href))
  if (length(m) == 0L || !nzchar(m)) {
    return(NULL)
  }
  sub("^NOMBRE_SABIA%3D", "", m)
}

#' Resolve a portal-relative href to an absolute URL.
#' @noRd
es_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(es_portal_base(), href)
}

#' Slug a *Tipo de documento* label to an ASCII column suffix.
#'
#' Spanish diacritics (á/é/í/ó/ú/ñ) are folded to their base letters before
#' `ascii_slug()` collapses the rest.
#' @noRd
es_section_slug <- function(tipo) {
  if (is.null(tipo) || is.na(tipo) || !nzchar(tipo)) {
    return("documento")
  }
  folded <- chartr(
    "\u00e1\u00e9\u00ed\u00f3\u00fa\u00fc\u00f1\u00c1\u00c9\u00cd\u00d3\u00da\u00dc\u00d1",
    "aeiouunAEIOUUN",
    tipo
  )
  ascii_slug(folded, "documento")
}

# -----------------------------------------------------------------------------
# Record building
# -----------------------------------------------------------------------------

#' Build a 1-row record tibble from a listing entry + parsed document panel.
#' @noRd
es_build_record <- function(entry, docs) {
  register <- entry$register
  document_id <- es_document_id(register, entry$code)
  per_section <- docs$per_section %||% list()
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "es",
    source_portal = es_source_portal(),
    document_id = document_id,
    url = entry$url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = entry$title %||% NA_character_,
    summary = NA_character_,
    competent_authority = es_competent_authority(),
    proponent = NA_character_,
    date_published = as.Date(NA),
    date_decision = as.Date(NA),
    native_type = entry$status %||% NA_character_,
    status = entry$status %||% NA_character_,
    assessment_type = es_assessment_type_of(register),
    register = register,
    expediente = entry$code,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

# -----------------------------------------------------------------------------
# Per-record finalise (browser download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed ES record: run in-session browser downloads + write sidecar.
#'
#' For `download = TRUE` we must re-resolve the live (session-bound) resource
#' URLs because the sidecar only carries stable synthetic URLs. We re-navigate
#' the session to the record's document panel, map each synthetic URL to its
#' live URL, and pull the bytes with `browser_download()`. When `download` is
#' `FALSE` the attachment URLs are recorded as `pending`.
#' @noRd
es_finalise_record <- function(rec, session, dom_state, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)
  section_urls <- stats::setNames(
    lapply(section_cols, function(cn) rec[[cn]][[1]]),
    sub("^attachment_urls_", "", section_cols)
  )

  if (download && length(urls) > 0L) {
    inform_download(length(urls), cache_dir(file.path("files", "es"), create = TRUE))
    ds <- es_browser_download_all(
      rec,
      session = session,
      dom_state = dom_state,
      urls = urls,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  for (slug in names(section_urls)) {
    rec[[paste0("local_path_", slug)]] <- list(ds$local_path[match(section_urls[[slug]], ds$url)])
  }
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar) {
    tryCatch(
      write_record_sidecar(rec, downloads = rec$download_status[[1]]),
      error = function(e) {
        warn_partial(
          "Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}"
        )
      }
    )
  }
  rec
}

#' Download every attachment of a record in-session, returning a download_status.
#'
#' Re-navigates the session to the record's document panel to obtain the live
#' (ephemeral) resource URLs keyed by the stable synthetic URL, then pulls each
#' with `browser_download()`. Builds the same-shaped status tibble the other
#' handlers produce.
#' @noRd
es_browser_download_all <- function(rec, session, dom_state, urls, overwrite, max_file_size_mb) {
  register <- rec$register
  code <- rec$expediente
  document_id <- rec$document_id
  docs <- tryCatch(
    es_fetch_ficha(session, register, code, dom_state),
    error = function(e) list(per_section = list(), live = stats::setNames(character(0), character(0)))
  )
  live <- docs$live %||% stats::setNames(character(0), character(0))
  cap <- max_file_size_bytes(max_file_size_mb)

  rows <- lapply(urls, function(u) {
    dest <- cache_path_internal(u, "es", document_id)
    cached <- resolve_cached_path_internal(dest)
    if (!is.na(cached) && !overwrite) {
      return(list(
        url = u,
        local_path = cached,
        status = "cached",
        size_bytes = unname(file.info(cached)$size),
        sha256 = file_sha256(cached),
        reason = NA_character_
      ))
    }
    live_url <- if (u %in% names(live)) live[[u]] else NA_character_
    if (is.na(live_url) || !nzchar(live_url)) {
      return(list(
        url = u,
        local_path = NA_character_,
        status = "failed",
        size_bytes = NA_real_,
        sha256 = NA_character_,
        reason = "could not resolve live document URL in session"
      ))
    }
    if (overwrite) {
      stem <- tools::file_path_sans_ext(dest)
      for (p in Sys.glob(paste0(stem, ".*"))) {
        unlink(p, force = TRUE)
      }
    }
    dl <- browser_download(session, live_url, dest, max_bytes = cap)
    if (!isTRUE(dl$written)) {
      status <- if (identical(dl$reason, NA_character_)) {
        "failed"
      } else if (grepl("exceeds cap", dl$reason %||% "")) {
        "skipped_size"
      } else {
        "failed"
      }
      return(list(
        url = u,
        local_path = NA_character_,
        status = status,
        size_bytes = dl$size_bytes %||% NA_real_,
        sha256 = NA_character_,
        reason = dl$reason %||% "download failed"
      ))
    }
    final_dest <- finalize_extension(dest, dl$content_type)
    list(
      url = u,
      local_path = final_dest,
      status = "downloaded",
      size_bytes = unname(file.info(final_dest)$size),
      sha256 = file_sha256(final_dest),
      reason = NA_character_
    )
  })
  do.call(rbind, lapply(rows, tibble::as_tibble_row))
}

# -----------------------------------------------------------------------------
# Filters
# -----------------------------------------------------------------------------

#' Apply post-fetch client-side filters (only `date_range`).
#'
#' The listing carries no dates, so a `date_range` is matched against
#' `date_published` / `date_decision` when present (rare), and a record with no
#' date is dropped only when a range is explicitly set.
#' @noRd
es_record_matches <- function(rec, date_range = NULL) {
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d)) {
      d <- rec$date_decision
    }
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helper
# -----------------------------------------------------------------------------

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
es_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  s <- gsub("[ \t]*\n[ \t]*", "\n", s)
  s <- gsub("[ \t]{2,}", " ", s)
  s <- gsub("\n{2,}", "\n", s)
  s <- trimws(s)
  if (!nzchar(s)) NULL else s
}
