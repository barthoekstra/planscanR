#' Fetch environmental-assessment records from Italy.
#'
#' Implementation of [get_assessments()] for Italy. Backed by the
#' Ministero dell'Ambiente e della Sicurezza Energetica (MASE) portal
#' *Valutazioni e Autorizzazioni Ambientali* (<https://va.mite.gov.it>),
#' which publishes two adjacent public registers:
#'
#' * **VIA** — *Valutazione di Impatto Ambientale* (project-level EIA),
#'   `https://va.mite.gov.it/it-IT/Ricerca/ViaProcedura`.
#' * **VAS** — *Valutazione Ambientale Strategica* (plan/programme SEA),
#'   `https://va.mite.gov.it/it-IT/Ricerca/VasProcedura`.
#'
#' Both registers are merged into a single result tibble; an
#' `assessment_type` column (`"EIA"` for VIA, `"SEA"` for VAS) tags each row
#' and is preserved in the offline metadata cache so downstream tooling can
#' tell them apart without re-fetching anything; a `register` column carries
#' the raw portal label (`"VIA"` / `"VAS"`). `document_id` is prefixed with
#' `"VIA-"` / `"VAS-"` (e.g. `"VIA-7917"`, `"VAS-12037"`) so the two registers
#' never collide on disk.
#'
#' @section URL enumeration:
#' The portal is server-rendered HTML (no JSON API). Each register's search
#' listing paginates via a 1-based `?pagina=N` query parameter; every page is
#' one HTML GET that lists the project/plan title, proponent, procedure type,
#' a detail (*Info*) link and a documentation (*Doc*) link. The page footer
#' carries a `"Pagina X di Y"` counter. The generator advances page-by-page
#' until it has passed the last page or a page yields no rows. Detail pages
#' live at `/it-IT/Oggetti/Info/{id}`; the detail-page parser is sidecar-first.
#'
#' @section Geometry:
#' None. The portal exposes location only as named Italian text lists
#' (*Regioni* / *Province* / *Comuni*), surfaced as the `regions`,
#' `provinces`, and `municipalities` extra columns. No coordinate geometry is
#' available, so `geometry_path` / `geometry_crs` are never set.
#'
#' @section Attachments:
#' Each record's *Documentazione* index lives at
#' `/it-IT/Oggetti/Documentazione/{id}/{grp}` (the `{grp}` raggruppamento id
#' comes from the listing's Doc link or the Info page's procedure table). It is
#' a paginated `?pagina=N` HTML table whose rows carry a *Sezione* (category)
#' and a direct, public download link
#' `https://va.mite.gov.it/File/Documento/{fileId}` (no authentication; the
#' server returns `application/pdf`). Documents are grouped by their *Sezione*;
#' the handler emits one `attachment_urls_<slug>` / `local_path_<slug>`
#' list-column per discovered section (the slug is the ASCII-folded *Sezione*
#' string) plus the deduplicated union in `attachment_urls` / `local_path`
#' (required by the schema), following the DE per-section pattern.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (VIA only), or `"SEA"` (VAS only). Applied here in R.
#' * `query` — matched client-side as a case-insensitive substring of the
#'    record title. (The portal's own free-text / Procedura search is
#'    server-side, but client-side filtering is sufficient for v0.1.)
#' * `date_range` — matched client-side against `date_published` (the
#'    procedure's *Data avvio* / start date). `date_decision` is the *Data
#'    Decreto VIA* / decision date parsed from the Info page's procedure
#'    timeline when present, else `NA`.
#' * `limit` — caps the total number of records returned across both crawled
#'    registers.
#'
#' @section Performance:
#' The VIA register is large (~10 600 projects across ~1 060 listing pages);
#' VAS is far smaller (~270 plans). A cold full crawl is therefore dominated by
#' VIA listing-page fetches plus one Info + one Documentazione fetch per
#' record. To be polite to the shared government portal, IT requests are
#' throttled to 5 requests per second by default; override via
#' `getOption("planscanR.it_throttle_rate")` (requests/sec; falsy disables).
#' A `limit` keeps cold runs bounded; repeat runs are sidecar-first.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query, matched client-side as a
#'   case-insensitive substring of the record title.
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which register(s) to crawl.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_it(limit = 3, download = FALSE)
#'
#' # SEA only (VAS register)
#' get_assessments_it(assessment_type = "SEA", limit = 10, download = FALSE)
#'
#' # Title substring
#' get_assessments_it(query = "autostrada", limit = 20, download = FALSE)
#' }
get_assessments_it <- function(
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
  assessment_type = "All",
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  assessment_type <- it_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.it_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "it")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("it")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("VIA", "VAS"),
    EIA = "VIA",
    SEA = "VAS"
  )

  # Per-entry processing: sidecar-first detail fetch, client-side filters,
  # relevance scoring, optional download, and the sidecar write. Returns the
  # 1-row record or NULL to drop the entry. Shared across both registers'
  # streams and called once per listing row by stream_crawl().
  process_entry <- function(entry) {
    u <- it_canonical_url(entry$id)
    rec <- tryCatch(
      it_load_or_fetch(u, entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!it_record_matches(rec, query = query, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    it_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream each register page-by-page, persisting records as they are parsed.
  # `limit` is global across both registers, so a full VIA crawl can consume
  # all of it before VAS.
  records <- list()
  for (reg in registers) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    gen <- tryCatch(
      it_fetch_search(register = reg),
      error = function(e) {
        warn_partial(
          "Failed to enumerate MASE {.val {reg}} register: {conditionMessage(e)}"
        )
        function() NULL
      }
    )
    block <- stream_crawl(gen, process_entry, limit = remaining, label = "it")
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
it_source_portal <- function() "va.mite.gov.it"

#' Public base URL for the portal.
#' @noRd
it_portal_base <- function() "https://va.mite.gov.it"

#' Competent authority for every Italian record (the national ministry MASE).
#'
#' The Info page does not carry an explicit "Autorita competente" field; the
#' portal is the national MASE register, so we tag every record with the
#' ministry. Italian verbatim.
#' @noRd
it_competent_authority <- function() {
  "Ministero dell'Ambiente e della Sicurezza Energetica"
}

#' Search-listing path for one register.
#' @noRd
it_search_path <- function(register) {
  if (register == "VIA") "it-IT/Ricerca/ViaProcedura" else "it-IT/Ricerca/VasProcedura"
}

#' Canonical landing (Info) URL for a dossier.
#' @noRd
it_canonical_url <- function(id) {
  sprintf("%s/it-IT/Oggetti/Info/%s", it_portal_base(), id)
}

#' Document-ID prefix per register so VIA 100 and VAS 100 never collide.
#' @noRd
it_document_id <- function(register, id) {
  sprintf("%s-%s", register, id)
}

#' Map a register code to its `assessment_type`.
#' @noRd
it_assessment_type_of <- function(register) {
  if (register == "VIA") "EIA" else "SEA"
}

#' Normalise the `assessment_type` argument.
#' @noRd
it_normalise_assessment_type <- function(x) {
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

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Build a page generator for one register's search listing.
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call fetches the next listing page (advancing the 1-based `pagina=` query)
#' and returns its rows as entries, or `NULL` once the register is exhausted.
#' Pagination state lives in the closure. The generator stops once it has
#' served the last page (per the `"Pagina X di Y"` counter) or hits an empty
#' page.
#'
#' Each entry is a small named list:
#' `list(register, id, title, proponent, procedura, doc_url, grp)`. The
#' detail-page parser is sidecar-first, so this is the minimum needed to build
#' the canonical URL and reach the document index.
#' @noRd
it_fetch_search <- function(register) {
  page <- 1L
  last_page <- NA_integer_
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(it_portal_base())
    req <- httr2::req_url_path_append(req, it_search_path(register))
    req <- httr2::req_url_query(req, pagina = page)
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      done <<- TRUE
      return(NULL)
    }
    if (is.na(last_page)) {
      last_page <<- it_parse_last_page(html)
    }
    rows <- it_parse_index_rows(html, register)
    if (length(rows) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    if (!is.na(last_page) && page >= last_page) {
      done <<- TRUE
    } else {
      page <<- page + 1L
    }
    rows
  }
}

#' Parse the `"Pagina X di Y"` counter into the last page number (Y).
#' @noRd
it_parse_last_page <- function(html) {
  txt <- it_text(rvest::html_text2(html))
  if (is.null(txt)) {
    return(NA_integer_)
  }
  m <- regmatches(txt, regexec("Pagina\\s+[0-9]+\\s+di\\s+([0-9]+)", txt))[[1]]
  if (length(m) != 2L) {
    return(NA_integer_)
  }
  suppressWarnings(as.integer(m[2]))
}

#' Parse the rows of one search-listing page.
#' @noRd
it_parse_index_rows <- function(html, register) {
  trs <- rvest::html_elements(html, "table.ElencoViaVasRicerca tr")
  out <- list()
  for (tr in trs) {
    info <- rvest::html_element(tr, "a.icona-info-progetto")
    href <- rvest::html_attr(info, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    id <- it_extract_info_id(href)
    if (is.na(id)) {
      next
    }
    tds <- rvest::html_elements(tr, "td")
    title <- if (length(tds) >= 1L) it_text(rvest::html_text2(tds[[1]])) else NULL
    proponent <- if (length(tds) >= 2L) it_text(rvest::html_text2(tds[[2]])) else NULL
    procedura <- if (length(tds) >= 3L) it_text(rvest::html_text2(tds[[3]])) else NULL
    doc <- rvest::html_element(tr, "a.icona-documentazione-tecnico-amm")
    doc_href <- rvest::html_attr(doc, "href")
    grp <- it_extract_doc_grp(doc_href)
    out[[length(out) + 1L]] <- list(
      register = register,
      id = id,
      title = title,
      proponent = proponent,
      procedura = procedura,
      doc_url = if (is.na(doc_href) || !nzchar(doc_href)) NA_character_ else it_absolute_url(doc_href),
      grp = grp
    )
  }
  out
}

#' Extract the numeric id from an `/it-IT/Oggetti/Info/{id}` href.
#' @noRd
it_extract_info_id <- function(href) {
  m <- regmatches(href, regexec("/Oggetti/Info/([0-9]+)", href))[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

#' Extract the raggruppamento (grp) id from a Documentazione href.
#' @noRd
it_extract_doc_grp <- function(href) {
  if (is.null(href) || length(href) != 1L || is.na(href) || !nzchar(href)) {
    return(NA_character_)
  }
  m <- regmatches(href, regexec("/Oggetti/Documentazione/[0-9]+/([0-9]+)", href))[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch + parse.
#' @noRd
it_load_or_fetch <- function(url, entry, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  info <- it_fetch_html(url)
  doc_url <- entry$doc_url %||% it_doc_url_from_info(info, entry$id)
  documents <- if (!is.null(doc_url) && !is.na(doc_url) && nzchar(doc_url)) {
    it_fetch_documents(doc_url)
  } else {
    list()
  }
  it_parse_detail(url, entry, info, documents)$record
}

#' Fetch one HTML page (Info or Documentazione) as parsed HTML.
#' @noRd
it_fetch_html <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Fetch a Documentazione index page and parse its per-section file URLs.
#' @noRd
it_fetch_documents <- function(doc_url) {
  html <- tryCatch(it_fetch_html(doc_url), error = function(e) NULL)
  if (is.null(html)) {
    return(list())
  }
  it_parse_documents(html)
}

#' Resolve the Documentazione URL from the Info page when the listing omitted it.
#' @noRd
it_doc_url_from_info <- function(html, id) {
  a <- rvest::html_element(html, "a.icona-documentazione-tecnico-amm")
  href <- rvest::html_attr(a, "href")
  if (is.na(href) || !nzchar(href)) {
    return(NA_character_)
  }
  it_absolute_url(href)
}

#' Parse one Info page into a 1-row tibble (+ a NULL geometry, for symmetry).
#'
#' Returns `list(record = <tibble>, geometry = NULL)`. Conventional columns are
#' filled from the Info page's `<p><strong>Label</strong>: value</p>` fields and
#' the procedure timeline table; English-snake-cased extras keep verbatim
#' Italian values. Per-section attachment columns come from the parsed
#' documentation index.
#' @noRd
it_parse_detail <- function(url, entry, html, documents = list()) {
  register <- entry$register
  id <- entry$id
  document_id <- it_document_id(register, id)

  title <- it_field_value(html, "Progetto") %||%
    it_field_value(html, "Piano/Programma") %||%
    it_field_value(html, "Opera") %||%
    entry$title %||%
    NA_character_
  proponent <- it_field_value(html, "Proponente") %||% entry$proponent %||% NA_character_
  native_type <- it_field_value(html, "Tipologia di opera") %||% entry$procedura %||% NA_character_
  procedura <- entry$procedura %||% it_field_value(html, "Tipologia di opera")

  regions <- it_field_value(html, "Regioni")
  provinces <- it_field_value(html, "Province")
  municipalities <- it_field_value(html, "Comuni")

  proc <- it_parse_procedure_table(html)
  date_published <- proc$date_published %||% as.Date(NA)
  date_decision <- proc$date_decision %||% as.Date(NA)
  status <- proc$status %||% NA_character_
  outcome <- proc$outcome

  per_section <- documents %||% list()
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "it",
    source_portal = it_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = NA_character_,
    competent_authority = it_competent_authority(),
    proponent = proponent,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    jurisdiction = regions %||% NA_character_,
    status = status,
    assessment_type = it_assessment_type_of(register),
    register = register,
    procedura = procedura %||% NA_character_,
    regions = regions %||% NA_character_,
    provinces = provinces %||% NA_character_,
    municipalities = municipalities %||% NA_character_,
    outcome = outcome %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  list(record = rec, geometry = NULL)
}

#' Pull the value following `<p><strong>Label</strong>: value</p>`.
#'
#' Labels appear with or without a trailing colon inside the `<strong>`
#' (`"Regioni:"` vs `"Progetto"`); we match the leading label text and return
#' the remaining text of the paragraph. Some value spans on other MASE pages
#' wrap content in `<!--small -->VALUE<!--/small -->` HTML comments, which
#' libxml2 renders as text; we re-parse the paragraph and drop comment nodes
#' first (mirrors the EE comment-leak guard). Returns trimmed non-empty text or
#' NULL.
#' @noRd
it_field_value <- function(html, label) {
  ps <- rvest::html_elements(html, "p")
  for (p in ps) {
    strong <- rvest::html_element(p, "strong")
    if (length(strong) == 0L || inherits(strong, "xml_missing")) {
      next
    }
    label_text <- it_text(rvest::html_text2(strong))
    if (is.null(label_text)) {
      next
    }
    norm <- sub(":\\s*$", "", label_text)
    if (!identical(tolower(norm), tolower(label))) {
      next
    }
    # Re-parse the paragraph, drop comment nodes (comment-leak guard), then take
    # the full text and strip the leading label + colon.
    cell <- xml2::read_html(as.character(p))
    comments <- xml2::xml_find_all(cell, ".//comment()")
    if (length(comments) > 0L) {
      xml2::xml_remove(comments)
    }
    full <- it_text(rvest::html_text2(cell))
    if (is.null(full)) {
      return(NULL)
    }
    # Remove the label prefix (with or without its colon) and any leading colon.
    value <- sub(
      paste0("^\\Q", norm, "\\E\\s*:?\\s*"),
      "",
      full,
      perl = TRUE
    )
    return(it_text(value))
  }
  NULL
}

#' Parse the Info page's procedure timeline table.
#'
#' The `table.DatiAmministrativiResTable` carries one `tr.trProcedura` per
#' procedure (Procedura / Codice istanza / Codice procedura / Data avvio /
#' Stato procedura) followed by hidden `tr.datiAmministrativi` detail rows
#' (label / value pairs) that include the *Data Decreto VIA* and *Esito*. We
#' take the first procedure's start date as `date_published`, its stato as
#' `status`, and scan the hidden rows for the decree date (`date_decision`) and
#' the *Esito* (`outcome`). Returns a list; fields are NULL when absent.
#' @noRd
it_parse_procedure_table <- function(html) {
  out <- list(
    date_published = NULL,
    date_decision = NULL,
    status = NULL,
    outcome = NULL
  )
  table <- rvest::html_element(html, "table.DatiAmministrativiResTable")
  if (length(table) == 0L || inherits(table, "xml_missing")) {
    return(out)
  }
  proc_rows <- rvest::html_elements(table, "tr.trProcedura")
  if (length(proc_rows) >= 1L) {
    tds <- rvest::html_elements(proc_rows[[1]], "td")
    if (length(tds) >= 4L) {
      out$date_published <- it_parse_date(it_text(rvest::html_text2(tds[[4]])))
    }
    if (length(tds) >= 5L) {
      out$status <- it_text(rvest::html_text2(tds[[5]]))
    }
  }
  # Hidden label/value rows: scan for the decree date and the outcome.
  detail_rows <- rvest::html_elements(table, "tr.datiAmministrativi")
  for (tr in detail_rows) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) < 2L) {
      next
    }
    key <- it_text(rvest::html_text2(tds[[1]]))
    val <- it_text(rvest::html_text2(tds[[2]]))
    if (is.null(key)) {
      next
    }
    keyl <- tolower(key)
    if (grepl("decreto", keyl) && is.null(out$date_decision)) {
      out$date_decision <- it_parse_date(val)
    } else if (grepl("^esito", keyl) && is.null(out$outcome)) {
      out$outcome <- val
    }
  }
  out
}

#' Parse the Documentazione index table into a named list of URL vectors.
#'
#' Each row of `table.Documentazione` carries a *Sezione* (category) cell and a
#' download anchor pointing at `/File/Documento/{fileId}`. URLs are grouped by
#' the ASCII-folded *Sezione* slug (DE per-section pattern); rows with no
#' section fall back to `"documento"`.
#' @noRd
it_parse_documents <- function(html) {
  table <- rvest::html_element(html, "table.Documentazione")
  if (length(table) == 0L || inherits(table, "xml_missing")) {
    return(list())
  }
  trs <- rvest::html_elements(table, "tr")
  per_section <- list()
  for (tr in trs) {
    a <- rvest::html_element(tr, "a[href*='/File/Documento/']")
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    url <- it_absolute_url(href)
    tds <- rvest::html_elements(tr, "td")
    sezione <- if (length(tds) >= 3L) it_text(rvest::html_text2(tds[[3]])) else NULL
    slug <- it_section_slug(sezione)
    per_section[[slug]] <- unique(c(per_section[[slug]], url))
  }
  per_section
}

#' Resolve a relative portal href to an absolute URL.
#' @noRd
it_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(it_portal_base(), href)
}

#' Slug a *Sezione* string to an ASCII column-suffix slug.
#'
#' Italian uses no diacritics that `ascii_slug()` cannot fold to underscores;
#' empty input gets `"documento"` as a deterministic fallback.
#' @noRd
it_section_slug <- function(sezione) {
  ascii_slug(sezione, "documento")
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed IT record: run downloads (if requested) and write sidecar.
#' @noRd
it_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "it"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "it",
      document_id = rec$document_id,
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

# -----------------------------------------------------------------------------
# Filters
# -----------------------------------------------------------------------------

#' Apply post-fetch client-side filters (`query` substring + `date_range`).
#' @noRd
it_record_matches <- function(rec, query = NULL, date_range = NULL) {
  if (!is.null(query) && nzchar(query)) {
    title <- rec$title
    # Case-insensitive substring match on the title (fixed, not regex).
    if (is.na(title) || !grepl(tolower(query), tolower(title), fixed = TRUE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Tolerant parser for the Italian `DD/MM/YYYY` date format.
#'
#' Extracts the first `DD/MM/YYYY` (1- or 2-digit day/month) match, so a date
#' embedded in surrounding text parses. `NA` for NULL / non-scalar / NA /
#' empty / no-match.
#' @noRd
it_parse_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- trimws(as.character(x))
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  m <- regmatches(s, regexpr("[0-9]{1,2}/[0-9]{1,2}/[0-9]{4}", s))
  if (length(m) == 0L || !nzchar(m)) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(as.Date(m, format = "%d/%m/%Y"))
  if (length(d) == 0L) as.Date(NA) else d
}

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
it_text <- function(x) {
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
