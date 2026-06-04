#' Fetch environmental-assessment records from Portugal.
#'
#' Implementation of [get_assessments()] for Portugal. Backed by the
#' *SIAIA* portal of the Agência Portuguesa do Ambiente (APA),
#' <https://siaia.apambiente.pt/>, which publishes the national register of
#' **AIA** procedures (*Avaliação de Impacte Ambiental* — project-level EIA).
#'
#' Only the AIA register is in scope. APA runs a separate register for **AAE**
#' (*Avaliação Ambiental Estratégica* — plan/programme SEA) under a different
#' application; it is **not** covered here, so there is no `assessment_type`
#' argument (this is a single-register handler). Every row is therefore an
#' EIA-equivalent procedure.
#'
#' SIAIA exposes the project location only as free-text *concelho* (municipal)
#' names — there is no machine-readable geometry — so no GeoJSON sidecar is
#' written (unlike the Estonian handler).
#'
#' @section URL enumeration:
#' SIAIA is a server-rendered ASP.NET MVC application. The listing lives at
#' `https://siaia.apambiente.pt/ProcessoAIA?pagina=<n>` (1-based pages, ~100
#' rows/page). Each listing row links to a detail page
#' `/ProcessoAIA/Detalhes/{pro_id}` and a document list
#' `/ListaDocumentos?pro_id={pro_id}`. The handler walks pages with a page
#' generator (see `stream_crawl()`); an out-of-range page returns an empty
#' table body, which terminates the crawl. The canonical record URL is the
#' detail page `https://siaia.apambiente.pt/ProcessoAIA/Detalhes/{pro_id}`.
#'
#' Per record, metadata is read from the detail page's *Campo / Conteúdo*
#' table (sidecar-first via the cache), and attachments from the document
#' list.
#'
#' @section Attachments: per-phase section split:
#' SIAIA renders each document with a Portuguese *type* label (e.g.
#' *"DIA - Declaração Impacte Ambiental"*, *"EIA Relatório Sintese (RS)"*,
#' *"Parecer comissão de avaliação"*, *"Relatório da consulta pública"*).
#' The portal does not print explicit phase headings, so the handler derives
#' a coarse **phase** from each label and groups by it. Phases:
#'
#' * `dia` — *DIA* (Declaração de Impacte Ambiental — the decision).
#' * `eia` — *EIA* documents (relatório síntese, RNT, anexos, peças
#'   desenhadas, projeto, elementos adicionais — the substantive dossier).
#' * `consulta_publica` — *Consulta Pública* documents.
#' * `parecer` — *Parecer* documents (e.g. Parecer da Comissão de Avaliação).
#' * `outros` — anything that matches none of the above.
#'
#' Each phase that carries documents becomes its own parallel list-column
#' `attachment_urls_<slug>` / `local_path_<slug>` (the slug is `ascii_slug()`
#' of the phase). `attachment_urls` / `local_path` are the deduplicated union
#' across all phases (required by the planscanR schema). PDF URLs are direct
#' and of the form `https://siaia.apambiente.pt/AIADOC/AIA{n}/{file}.pdf`
#' (some documents are `.zip` archives — these are kept as attachments too).
#'
#' @section Filter coverage (v0.1):
#' SIAIA offers server-side authority/year filters, but for v1 every filter is
#' applied **client-side** for simplicity and predictability:
#'
#' * `query` — case-insensitive substring match on `title` (the project
#'   designation).
#' * `date_range` — matched against `date_decision` when the detail page
#'   exposes a full *Data da decisão*; for records that only carry a decision
#'   *year* (the listing's *Ano Decisão*), the year is matched against the
#'   range instead.
#' * `limit` — caps the total number of records returned.
#'
#' @section Performance:
#' The register holds a few thousand AIA procedures across a few dozen listing
#' pages. A cold crawl is one listing GET per page plus one detail GET per
#' record (sidecar-first, so repeat runs are fast). To be polite to the shared
#' government portal, PT requests are throttled to 5 requests per second by
#' default; override via `getOption("planscanR.pt_throttle_rate")`
#' (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query. Applied as a client-side
#'   case-insensitive substring match on the project title.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_pt(limit = 3, download = FALSE)
#'
#' # Substring query on the project designation
#' get_assessments_pt(query = "solar", limit = 20, download = FALSE)
#'
#' # Date range (matched against the decision date / year)
#' get_assessments_pt(
#'   date_range = c("2023-01-01", "2023-12-31"),
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_pt <- function(
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
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.pt_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "pt")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("pt")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Per-entry processing: sidecar-first detail fetch, client-side filters,
  # relevance scoring, optional download, and the sidecar write. Returns the
  # 1-row record or NULL to drop the entry.
  process_entry <- function(entry) {
    u <- pt_canonical_url(entry$pro_id)
    rec <- tryCatch(
      pt_load_or_fetch(u, entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!pt_record_matches(rec, date_range = date_range, query = query)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    pt_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  gen <- tryCatch(
    pt_fetch_search(),
    error = function(e) {
      warn_partial(
        "Failed to enumerate SIAIA listing: {conditionMessage(e)}"
      )
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "pt")

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
pt_source_portal <- function() "siaia.apambiente.pt"

#' Public base URL for the portal.
#' @noRd
pt_portal_base <- function() "https://siaia.apambiente.pt"

#' Canonical detail URL for a record.
#' @noRd
pt_canonical_url <- function(pro_id) {
  sprintf("%s/ProcessoAIA/Detalhes/%s", pt_portal_base(), pro_id)
}

#' Document-list URL for a record.
#' @noRd
pt_documentos_url <- function(pro_id) {
  sprintf("%s/ListaDocumentos?pro_id=%s", pt_portal_base(), pro_id)
}

#' Document-ID for a record.
#'
#' Built from the Nº AIA when present (path-safe via `ascii_slug()`), prefixed
#' `AIA-`; falls back to the pro_id. Stable and filesystem-safe either way.
#' @noRd
pt_document_id <- function(aia_number, pro_id) {
  base <- if (!is.null(aia_number) && nzchar(aia_number)) aia_number else pro_id
  sprintf("AIA-%s", ascii_slug(base, pro_id))
}

#' Map a Portuguese document-type label to a coarse phase slug.
#'
#' SIAIA prints no phase headings; each document carries a free-text type
#' label. We classify it into one of five phases by keyword. The matching is
#' accent-insensitive (labels arrive with Portuguese diacritics) and ordered:
#' DIA before generic EIA, so "DIA - Declaração..." doesn't fall through to
#' the EIA bucket. Unknown labels collect under `outros`.
#' @noRd
pt_phase_slug <- function(label) {
  if (is.null(label) || length(label) != 1L || is.na(label) || !nzchar(label)) {
    return("outros")
  }
  l <- tolower(label)
  # Fold the common Portuguese diacritics so keyword matching is robust.
  l <- chartr("áàâãéêíóôõúç", "aaaaeeiooouc", l)
  if (grepl("\\bdia\\b|declaracao", l)) {
    return("dia")
  }
  if (grepl("consulta publica", l)) {
    return("consulta_publica")
  }
  if (grepl("parecer", l)) {
    return("parecer")
  }
  if (
    grepl(
      "\\beia\\b|relatorio sintese|resumo nao tecnico|anexo|aditamento|projeto|projecto|pecas desenhadas|elementos adicionais",
      l
    )
  ) {
    return("eia")
  }
  "outros"
}

#' Canonical ordering of phase slugs in the deduplicated union.
#' @noRd
pt_phase_order <- function() {
  c("dia", "eia", "consulta_publica", "parecer", "outros")
}

#' Parse a SIAIA `DD/MM/YYYY` date string to a `Date`.
#'
#' `NA` for NULL / non-scalar / NA / empty / unparseable.
#' @noRd
pt_parse_date <- function(x) {
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

#' Extract a 4-digit year from a string, or `NA_character_`.
#' @noRd
pt_parse_year <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NA_character_)
  }
  m <- regmatches(x, regexpr("[0-9]{4}", x))
  if (length(m) == 0L || !nzchar(m)) NA_character_ else m
}

# -----------------------------------------------------------------------------
# Listing enumeration
# -----------------------------------------------------------------------------

#' Build a page generator over the SIAIA listing.
#'
#' Returns a zero-arg closure (the `stream_crawl()` `next_page` contract): each
#' call fetches the next 1-based listing page and returns its row entries, or
#' `NULL` once the register is exhausted. Pagination state lives in the
#' closure. The generator ends when a page returns no HTML or an empty table
#' body (SIAIA serves an empty `<tbody>` for out-of-range pages).
#'
#' Each entry is a small named list carrying the listing-row fields the
#' detail-record build needs as fallbacks: `pro_id`, `title`, `proponent`,
#' `aia_number`, `localizacao`, `licenciador`, `autoridade`, `ano_decisao`,
#' `sentido_decisao`.
#' @noRd
pt_fetch_search <- function() {
  page <- 1L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(pt_portal_base(), "ProcessoAIA")
    req <- httr2::req_url_query(req, pagina = page)
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      done <<- TRUE
      return(NULL)
    }
    rows <- pt_parse_listing_rows(html)
    if (length(rows) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    page <<- page + 1L
    rows
  }
}

#' Parse the rows of one listing page into lightweight entries.
#' @noRd
pt_parse_listing_rows <- function(html) {
  trs <- rvest::html_elements(html, "table tbody tr")
  out <- list()
  for (tr in trs) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) < 9L) {
      next
    }
    a <- rvest::html_element(tr, "a[href*='Detalhes/']")
    href <- rvest::html_attr(a, "href")
    pro_id <- pt_extract_pro_id(href)
    if (is.na(pro_id)) {
      next
    }
    out[[length(out) + 1L]] <- list(
      pro_id = pro_id,
      aia_number = pt_text(rvest::html_text2(tds[[1]])),
      title = pt_text(rvest::html_text2(a)),
      proponent = pt_text(rvest::html_text2(tds[[4]])),
      localizacao = pt_text(rvest::html_text2(tds[[5]])),
      licenciador = pt_text(rvest::html_text2(tds[[6]])),
      autoridade = pt_text(rvest::html_text2(tds[[7]])),
      ano_decisao = pt_text(rvest::html_text2(tds[[8]])),
      sentido_decisao = pt_text(rvest::html_text2(tds[[9]]))
    )
  }
  out
}

#' Extract the pro_id from a `Detalhes/{id}` href.
#' @noRd
pt_extract_pro_id <- function(href) {
  if (is.null(href) || length(href) != 1L || is.na(href)) {
    return(NA_character_)
  }
  m <- regmatches(href, regexec("Detalhes/([0-9]+)", href))[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

# -----------------------------------------------------------------------------
# Detail-record building
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch + parse.
#' @noRd
pt_load_or_fetch <- function(url, entry, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  detail <- pt_fetch_detail(url)
  documents <- pt_fetch_documents(entry$pro_id)
  pt_parse_detail(url, entry, detail, documents)
}

#' Fetch one detail page as parsed HTML.
#' @noRd
pt_fetch_detail <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Fetch one document-list page as parsed HTML.
#' @noRd
pt_fetch_documents <- function(pro_id) {
  req <- req_planscanr(pt_documentos_url(pro_id))
  tryCatch(perform_html(req), error = function(e) NULL)
}

#' Parse a detail page + document list into a 1-row tibble.
#'
#' Metadata comes from the detail page's *Campo / Conteúdo* table (with
#' listing-row fallbacks); attachments are grouped by phase from the document
#' list. Per-phase `attachment_urls_<slug>` / `local_path_<slug>` columns are
#' attached, and `attachment_urls` is the deduplicated union.
#' @noRd
pt_parse_detail <- function(url, entry, html, documents) {
  fields <- pt_parse_detail_fields(html)

  aia_number <- fields[["Nº AIA"]] %||% entry$aia_number
  pro_id <- entry$pro_id
  document_id <- pt_document_id(aia_number, pro_id)

  title <- fields[["Designação do projeto"]] %||% entry$title %||% NA_character_
  proponent <- fields[["Proponente"]] %||% entry$proponent %||% NA_character_
  competent_authority <- fields[["Autoridade AIA"]] %||% entry$autoridade %||% NA_character_
  licensing_authority <- fields[["Licenciador"]] %||% entry$licenciador %||% NA_character_
  municipalities <- fields[["Localização (Concelhos)"]] %||% entry$localizacao %||% NA_character_
  decision_sense <- fields[["Sentido da Decisão"]] %||% entry$sentido_decisao %||% NA_character_
  status <- fields[["Estado"]] %||% NA_character_

  date_decision <- pt_parse_date(fields[["Data da decisão"]])
  # date_published: prefer the public-consultation start date when exposed.
  date_published <- pt_parse_date(fields[["Início de consulta pública"]])

  # decision_year: a full date wins; else fall back to the listing's Ano Decisão.
  decision_year <- if (!is.na(date_decision)) {
    format(date_decision, "%Y")
  } else {
    pt_parse_year(entry$ano_decisao)
  }

  per_section <- pt_parse_documents(documents)
  slug_order <- intersect(pt_phase_order(), names(per_section))
  slug_order <- c(slug_order, setdiff(names(per_section), slug_order))
  union_urls <- unique(unlist(per_section[slug_order], use.names = FALSE))
  if (is.null(union_urls)) {
    union_urls <- character(0)
  }

  rec <- tibble::tibble(
    country = "pt",
    source_portal = pt_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    summary = NA_character_,
    competent_authority = competent_authority %||% NA_character_,
    proponent = proponent %||% NA_character_,
    date_published = date_published,
    date_decision = date_decision,
    native_type = decision_sense %||% NA_character_,
    status = status %||% NA_character_,
    aia_number = aia_number %||% NA_character_,
    municipalities = municipalities %||% NA_character_,
    licensing_authority = licensing_authority %||% NA_character_,
    decision_sense = decision_sense %||% NA_character_,
    decision_year = decision_year %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in slug_order) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Parse the detail page's *Campo / Conteúdo* table into a named character map.
#'
#' Keys are the Portuguese field labels (verbatim); values are the trimmed
#' cell text. The "Documentos" row is skipped (it holds document links, parsed
#' separately). Empty values are dropped so `%||%` fallbacks fire.
#' @noRd
pt_parse_detail_fields <- function(html) {
  trs <- rvest::html_elements(html, "table tbody tr")
  out <- list()
  for (tr in trs) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) != 2L) {
      next
    }
    key <- pt_text(rvest::html_text2(tds[[1]]))
    if (is.null(key) || identical(key, "Documentos")) {
      next
    }
    val <- pt_text(rvest::html_text2(tds[[2]]))
    if (!is.null(val)) {
      out[[key]] <- val
    }
  }
  out
}

#' Parse a document-list page into a named list of URL vectors keyed by phase.
#'
#' Every document `<li>` carries an `onclick="downloadPdf('<path>')"` (the
#' reliable URL source — PDFs additionally have a `data-link`, ZIP archives
#' don't). The visible label preceding the trailing `<span> - X</span>` is the
#' Portuguese document type, which we classify into a coarse phase slug. URLs
#' are absolutised against the portal base.
#' @noRd
pt_parse_documents <- function(html) {
  if (is.null(html)) {
    return(list())
  }
  lis <- rvest::html_elements(html, "li.list-group-item")
  if (length(lis) == 0L) {
    return(list())
  }
  per_section <- list()
  for (li in lis) {
    href <- pt_document_href(li)
    if (is.na(href) || !nzchar(href)) {
      next
    }
    url <- pt_absolute_url(href)
    label <- pt_document_label(li)
    slug <- pt_phase_slug(label)
    per_section[[slug]] <- unique(c(per_section[[slug]], url))
  }
  per_section
}

#' Pull a document's relative path from a list item.
#'
#' Prefers `data-link` (present on PDF anchors); falls back to the
#' `downloadPdf('<path>')` onclick (present on every item, including ZIPs).
#' @noRd
pt_document_href <- function(li) {
  a <- rvest::html_element(li, "a.document-link")
  if (!inherits(a, "xml_missing")) {
    dl <- rvest::html_attr(a, "data-link")
    if (!is.na(dl) && nzchar(dl)) {
      return(dl)
    }
  }
  btn <- rvest::html_element(li, "button[onclick*='downloadPdf']")
  if (inherits(btn, "xml_missing")) {
    return(NA_character_)
  }
  onclick <- rvest::html_attr(btn, "onclick")
  if (is.na(onclick) || !nzchar(onclick)) {
    return(NA_character_)
  }
  m <- regmatches(onclick, regexec("downloadPdf\\('([^']+)'\\)", onclick))[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

#' Pull a document's type label from a list item.
#'
#' The label is the text of the `.document-link` anchor (PDFs) or `span.me-2`
#' wrapper (ZIPs), minus the trailing `<span> - X</span>` suffix.
#' @noRd
pt_document_label <- function(li) {
  node <- rvest::html_element(li, "a.document-link")
  if (inherits(node, "xml_missing")) {
    node <- rvest::html_element(li, "span.me-2")
  }
  if (inherits(node, "xml_missing")) {
    return(NA_character_)
  }
  # Drop the trailing "<span> - X</span>" filename-echo: it's the innermost
  # span. Removing every descendant span would also strip a `span.me-2`
  # wrapper (used for ZIP rows), so target only spans with no element
  # children — the leaf filename-echo.
  inner <- rvest::html_elements(node, "span")
  for (sp in inner) {
    if (length(rvest::html_elements(sp, "*")) == 0L) {
      xml2::xml_remove(sp)
    }
  }
  pt_text(rvest::html_text2(node)) %||% NA_character_
}

#' Resolve a relative portal href to an absolute URL.
#' @noRd
pt_absolute_url <- function(href) {
  if (grepl("^https?://", href)) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(pt_portal_base(), href)
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed PT record: run downloads (if requested) and write sidecar.
#' @noRd
pt_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)

  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "pt"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "pt",
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  for (col in section_cols) {
    slug <- sub("^attachment_urls_", "", col)
    sec_urls <- get_section(col)
    rec[[paste0("local_path_", slug)]] <- list(ds$local_path[match(sec_urls, ds$url)])
  }
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar) {
    tryCatch(
      write_record_sidecar(rec, downloads = ds),
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

#' Apply client-side filters to a single parsed PT record.
#'
#' `query` is a case-insensitive substring match on the title. `date_range`
#' matches `date_decision` when present, otherwise the `decision_year`.
#' @noRd
pt_record_matches <- function(rec, date_range, query) {
  if (!is.null(query) && nzchar(query)) {
    t <- rec$title %||% ""
    if (!grepl(query, t, ignore.case = TRUE, fixed = FALSE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    d <- rec$date_decision
    if (!is.na(d)) {
      if (d < date_range[1] || d > date_range[2]) {
        return(FALSE)
      }
    } else {
      yr <- suppressWarnings(as.integer(rec$decision_year))
      if (is.na(yr)) {
        return(FALSE)
      }
      lo <- as.integer(format(date_range[1], "%Y"))
      hi <- as.integer(format(date_range[2], "%Y"))
      if (yr < lo || yr > hi) {
        return(FALSE)
      }
    }
  }
  TRUE
}

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
pt_text <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  s <- gsub("[ \t]*\n[ \t]*", " ", s)
  s <- gsub("\\s{2,}", " ", s)
  s <- trimws(s)
  if (!nzchar(s)) NULL else s
}
