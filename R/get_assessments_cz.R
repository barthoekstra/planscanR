#' Fetch environmental-assessment records from the Czech Republic.
#'
#' Implementation of [get_assessments()] for the Czech Republic. Backed by
#' CENIA's *Informační systém EIA/SEA* (<https://portal.cenia.cz/eiasea/>), a
#' server-rendered JSP application (Apache Tomcat — not a SPA). Two **domestic**
#' registers are crawled:
#'
#' * **EIA** — *Záměry na území ČR* (project-level EIA on Czech territory),
#'   `https://portal.cenia.cz/eiasea/view/eia100_cr`.
#' * **SEA** — *Posuzování koncepcí* (concept / plan SEA),
#'   `https://portal.cenia.cz/eiasea/view/SEA100_koncepce`.
#'
#' Both registers are merged into a single result tibble; an
#' `assessment_type` column (`"EIA"` for *Záměry na území ČR*, `"SEA"` for
#' *Posuzování koncepcí*) tags each row and is round-tripped to the sidecar so
#' downstream tooling can tell them apart without re-fetching anything.
#' `document_id` is the portal's register-namespaced detail code, e.g.
#' `"EIA_JHC1237"` / `"SEA_HKK015K"`, so the two registers never collide on
#' disk (no extra prefix is added).
#'
#' @section Scope (domestic CZ only):
#' This handler deliberately crawls **only** the two domestic registers above.
#' The portal also hosts cross-border / foreign registers and several special
#' sub-registers (`eia100_mimo_cr` — projects outside CZ, `sea100_mezistatni`
#' — cross-border SEA, the sub-limit / priority-transport / large-project EIA
#' sub-registers `eia100_podlimitni` / `_pdz` / `_vzvp` / `eia244`, and the
#' territorial-planning SEA sub-registers `sea100_pur*` / `zur*` / `up*`).
#' Those are **never** enumerated. Note that ministry-coded records (`EIA_MZP*`,
#' `SEA_MZP*`) inside the two domestic registers *are* in scope — they are
#' domestic projects/plans assessed by the Ministry, not foreign ones. The two
#' in-scope view codes are hard-coded.
#'
#' @section URL enumeration:
#' Index listings paginate via a **1-based** `p` query parameter (10 records
#' per page); each page is one HTML GET listing the detail code, project/plan
#' title, competent authority (*Příslušný úřad*), annex category (*Zařazení*),
#' last-modified timestamp (*Změněno*), and status (*Stav*). Detail pages live
#' at `/eiasea/detail/EIA_<CODE>` and `/eiasea/detail/SEA_<CODE>` and carry
#' every field a downstream classifier needs. Out-of-range page indices are
#' **clamped to the last page** by the server (they return the last page's rows
#' again rather than an empty page), so pagination stops when a page contributes
#' no detail codes that were not already seen.
#'
#' @section Geometry:
#' The CENIA detail pages expose **no** coordinates or GeoJSON — location is
#' administrative text only (*Kraj* / *Okres* / *Obec* / *Katastr*). No geometry
#' columns are emitted.
#'
#' @section Attachments:
#' Detail pages render document links inline inside the detail table's value
#' cells as `<a class="entity_field" href="/eiasea/download/<token>/<file>">`.
#' Both the base64-ish token and the trailing human filename come straight out
#' of the rendered href, so the handler captures the full href verbatim rather
#' than reconstructing the token. Downloads are anonymous (no authentication).
#' Documents are grouped by process-stage headings (OZNÁMENÍ, ZJIŠŤOVACÍ
#' ŘÍZENÍ, DOKUMENTACE, POSUDEK, VEŘEJNÉ PROJEDNÁNÍ, STANOVISKO for EIA; the
#' oznámení / vyhodnocení / návrh koncepce / stanovisko / schválená koncepce
#' fields for SEA). The handler slugs the nearest stage heading / field label
#' into an `attachment_urls_<slug>` / `local_path_<slug>` list-column (Czech
#' diacritics transliterated to ASCII). The deduplicated union goes into
#' `attachment_urls` / `local_path` (required by the schema).
#'
#' Some attachments are very large ZIP bundles (e.g. a 79 MB `oznameni.zip`);
#' [get_assessments()]'s `max_file_size_mb` cap is honoured during download, so
#' oversized files are skipped and recorded as `"skipped_size"` rather than
#' fetched.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (*Záměry na území ČR* only), or `"SEA"`
#'    (*Posuzování koncepcí* only). Applied here in R.
#' * `date_range` — matched client-side against `date_published` (the
#'    EIA *Datum a čas posledních úprav* last-modified date, or the SEA
#'    *Datum zveřejnění* publication date). `date_decision` is `NA` — the
#'    portal exposes no single clean decision-date field.
#'
#' @section Performance:
#' The two registers are ~22,780 (EIA) + ~640 (SEA) records, so callers almost
#' always pass `limit`. To stay polite to the single Tomcat instance under a
#' large crawl, CZ requests are throttled to 2 requests per second by default.
#' Override via `getOption("planscanR.cz_throttle_rate")` (requests/sec; falsy
#' disables).
#'
#' @section Language:
#' Record content is Czech (ISO-639-1 `cs`; note the country code `cz` differs
#' from the language code). The portal's `lang=en` switch only flips UI chrome,
#' not record content, so the handler fetches with `lang=cs`.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which domestic register(s) to crawl.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_cz(limit = 3, download = FALSE)
#'
#' # SEA only
#' get_assessments_cz(assessment_type = "SEA", limit = 5, download = FALSE)
#' }
get_assessments_cz <- function(
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
  assessment_type = "All",
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  assessment_type <- cz_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.cz_throttle_rate", 2)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "cz")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("cz")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("EIA", "SEA"),
    EIA = "EIA",
    SEA = "SEA"
  )

  index <- list()
  for (reg in registers) {
    block <- tryCatch(
      cz_fetch_search(register = reg, limit = limit),
      error = function(e) {
        warn_partial(
          "Failed to enumerate CENIA {.val {reg}} index: {conditionMessage(e)}"
        )
        list()
      }
    )
    index <- c(index, block)
  }

  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling CZ  ",
      "records {length(records)}",
      if (is.finite(limit)) paste0("/", limit) else paste0("/", length(index)),
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = if (is.finite(limit)) limit else length(index),
    clear = FALSE
  )
  on.exit(cli::cli_progress_done(), add = TRUE)

  for (entry in index) {
    if (length(records) >= limit) {
      break
    }
    u <- cz_canonical_url(entry$register, entry$code)
    rec <- tryCatch(
      cz_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial(
          "Failed to load/parse {.url {u}}: {conditionMessage(e)}"
        )
        NULL
      }
    )
    if (is.null(rec)) {
      next
    }
    if (!cz_record_matches(rec, date_range = date_range)) {
      next
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    rec <- cz_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
    records[[length(records) + 1L]] <- rec
    cli::cli_progress_update()
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
cz_source_portal <- function() "portal.cenia.cz"

#' Public base URL for the portal.
#' @noRd
cz_portal_base <- function() "https://portal.cenia.cz/eiasea"

#' In-scope register view codes (DOMESTIC CZ ONLY).
#'
#' Mirrors the EE `c("KMH", "KSH")` pattern: hard-coded so the cross-border /
#' foreign / sub-limit / territorial-planning registers are never crawled.
#' @noRd
cz_register_view <- function(register) {
  if (register == "EIA") "eia100_cr" else "SEA100_koncepce"
}

#' Detail-code prefix per register (`EIA_` / `SEA_`).
#' @noRd
cz_register_prefix <- function(register) {
  if (register == "EIA") "EIA" else "SEA"
}

#' Canonical landing URL for an EIA / SEA dossier.
#'
#' The detail code is already register-namespaced (e.g. `JHC1237` lives under
#' `EIA_JHC1237`), so the `document_id` is `EIA_<code>` / `SEA_<code>` and the
#' canonical URL is `/eiasea/detail/<document_id>?lang=cs`.
#' @noRd
cz_canonical_url <- function(register, code) {
  sprintf("%s/detail/%s?lang=cs", cz_portal_base(), cz_document_id(register, code))
}

#' Register-namespaced document id (e.g. "EIA_JHC1237", "SEA_HKK015K").
#' @noRd
cz_document_id <- function(register, code) {
  sprintf("%s_%s", cz_register_prefix(register), code)
}

#' Map our `assessment_type` argument to a normalised value.
#' @noRd
cz_normalise_assessment_type <- function(x) {
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

#' Paginate one register's index and return a list of listing-row entries.
#'
#' Each entry is a small named list:
#' `list(register = "EIA"|"SEA", code = "<CODE>", title = ...,
#'  competent_authority = ..., native_type = ..., status = ...,
#'  last_modified = <Date>)`. The detail-page parser is sidecar-first, so this
#' is deliberately the minimum needed to build the canonical URL and decide
#' whether to keep going (limit / pre-filter).
#'
#' Out-of-range pages are clamped to the last page by the server, so we stop
#' when a page contributes no new detail codes.
#' @noRd
cz_fetch_search <- function(register, limit = Inf) {
  out <- list()
  seen <- character(0)
  page <- 1L
  view <- cz_register_view(register)
  repeat {
    req <- req_planscanr(cz_portal_base())
    req <- httr2::req_url_path_append(req, "view", view)
    req <- httr2::req_url_query(req, p = page, lang = "cs")
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      break
    }
    rows <- cz_parse_index_rows(html, register)
    if (length(rows) == 0L) {
      break
    }
    codes <- vapply(rows, function(r) r$code, character(1))
    fresh <- !(codes %in% seen)
    if (!any(fresh)) {
      # Clamped last page (all codes already seen) -> we've reached the end.
      break
    }
    out <- c(out, rows[fresh])
    seen <- c(seen, codes[fresh])
    # Soft stop: stop paginating once we've enumerated at least `limit * 5` raw
    # rows. Filters / sidecar misses may still drop rows, so we overshoot a bit.
    if (is.finite(limit) && length(out) >= as.integer(limit) * 5L) {
      break
    }
    page <- page + 1L
  }
  out
}

#' Parse the rows of one index page.
#'
#' Each result block is a sequence of `<tr>`s inside `table.view`: a header row
#' with the bold code cell + a detail anchor, then label/value rows for
#' Příslušný úřad / Zařazení / Změněno / Stav. We anchor on the detail link,
#' extract the code from its href, and read the sibling label rows by scoping
#' to the block between consecutive detail anchors.
#' @noRd
cz_parse_index_rows <- function(html, register) {
  prefix <- cz_register_prefix(register)
  anchors <- rvest::html_elements(
    html,
    sprintf("table.view a[href*='/detail/%s_']", prefix)
  )
  out <- list()
  for (a in anchors) {
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    code <- cz_extract_code(href, register)
    if (is.na(code)) {
      next
    }
    title <- cz_text(rvest::html_text2(a))
    # The header <tr> for this result holds the bold code cell + this anchor;
    # the following sibling rows carry the label/value cells of this block.
    block_rows <- cz_index_block_rows(a)
    competent_authority <- cz_index_block_value(block_rows, "P\u0159\u00edslu\u0161n\u00fd \u00fa\u0159ad")
    native_type <- cz_index_block_value(block_rows, "Za\u0159azen\u00ed")
    status <- cz_index_block_value(block_rows, "Stav")
    changed <- cz_parse_java_date(cz_index_block_value(block_rows, "Zm\u011bn\u011bno"))
    out[[length(out) + 1L]] <- list(
      register = register,
      code = code,
      title = title %||% NA_character_,
      competent_authority = competent_authority %||% NA_character_,
      native_type = native_type %||% NA_character_,
      status = status %||% NA_character_,
      last_modified = changed
    )
  }
  out
}

#' Collect the result-block rows belonging to one detail anchor.
#'
#' The anchor's own `<tr>` is the header row; the block continues through the
#' following sibling `<tr>`s until the next header row (one that also holds a
#' `/detail/` anchor) or a divider. We read text out of those sibling rows.
#' @noRd
cz_index_block_rows <- function(anchor) {
  header_tr <- rvest::html_element(anchor, xpath = "ancestor::tr[1]")
  if (length(header_tr) == 0L || inherits(header_tr, "xml_missing")) {
    return(list())
  }
  sib <- rvest::html_elements(
    header_tr,
    xpath = "following-sibling::tr[position() <= 3]"
  )
  out <- list(header_tr)
  for (tr in sib) {
    # Stop at the next result's header (a row containing a detail anchor).
    a <- rvest::html_element(tr, "a[href*='/detail/']")
    if (!inherits(a, "xml_missing") && length(a) > 0L) {
      break
    }
    out[[length(out) + 1L]] <- tr
  }
  out
}

#' Read the cell value following an italic `<i>label:</i>` marker in a block.
#'
#' The listing renders fields as `<td><i>Label:</i></td><td>value</td>`; we
#' scan all `<td>`s in the block and return the text of the cell immediately
#' after the one whose italic text matches `label`.
#' @noRd
cz_index_block_value <- function(block_rows, label) {
  for (tr in block_rows) {
    tds <- rvest::html_elements(tr, "td")
    if (length(tds) < 2L) {
      next
    }
    for (i in seq_len(length(tds) - 1L)) {
      it <- rvest::html_element(tds[[i]], "i")
      if (inherits(it, "xml_missing") || length(it) == 0L) {
        next
      }
      lab <- cz_text(rvest::html_text2(it))
      if (!is.null(lab) && grepl(label, lab, fixed = TRUE)) {
        val <- cz_text(rvest::html_text2(tds[[i + 1L]]))
        if (!is.null(val)) {
          return(val)
        }
      }
    }
  }
  NULL
}

#' Extract the detail code (e.g. "JHC1237") from a `/detail/EIA_<CODE>` href.
#' @noRd
cz_extract_code <- function(href, register) {
  prefix <- cz_register_prefix(register)
  m <- regmatches(
    href,
    regexec(paste0("/detail/", prefix, "_([A-Za-z0-9]+)"), href)
  )[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch detail.
#' @noRd
cz_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  detail <- cz_fetch_detail(url)
  cz_parse_detail(url, entry, detail)
}

#' Fetch one EIA / SEA detail page as parsed HTML.
#' @noRd
cz_fetch_detail <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Parse one detail page into a 1-row tibble.
#'
#' The detail page is a single `<table class="detail">` of label/value rows
#' (`<td class="label">…</td><td class="value">…</td>`) interspersed with bold
#' stage-heading rows (`<td colspan="2" …>OZNÁMENÍ</td>`). Field lookup is by
#' the label text; attachments are slugged from the nearest preceding stage
#' heading, falling back to the row label.
#' @noRd
cz_parse_detail <- function(url, entry, html) {
  register <- entry$register
  code <- entry$code
  document_id <- cz_document_id(register, code)

  rows <- cz_extract_detail_rows(html)
  pick <- function(...) cz_detail_value(rows, c(...))

  title <- pick("N\u00e1zev z\u00e1m\u011bru", "N\u00e1zev koncepce") %||% entry$title %||% NA_character_
  status <- pick("Stav") %||% entry$status %||% NA_character_
  competent_authority <- pick("P\u0159\u00edslu\u0161n\u00fd \u00fa\u0159ad") %||%
    entry$competent_authority %||%
    NA_character_
  proponent <- pick("Oznamovatel", "P\u0159edkladatel") %||% NA_character_
  ico <- pick("I\u010cO oznamovatele", "I\u010cO p\u0159edkladatele") %||% NA_character_
  native_type <- pick("Za\u0159azen\u00ed") %||% entry$native_type %||% NA_character_

  # date_published: SEA carries a dedicated "Datum zve\u0159ejn\u011bn\u00ed" publication date
  # (preferred); EIA only exposes "Datum a \u010das posledn\u00edch \u00faprav" (last-modified,
  # Java Date.toString() form). Try the publication date first, in priority
  # order, since both labels can co-occur on a SEA page.
  date_raw <- pick("Datum zve\u0159ejn\u011bn\u00ed") %||% pick("Datum a \u010das posledn\u00edch \u00faprav")
  date_published <- cz_parse_java_date(date_raw)
  if (is.null(date_published) || length(date_published) == 0L) {
    date_published <- entry$last_modified %||% as.Date(NA)
  }
  if (is.na(date_published) && !is.null(entry$last_modified)) {
    date_published <- entry$last_modified
  }

  jurisdiction <- cz_parse_location(html) %||% competent_authority %||% NA_character_

  per_section <- cz_parse_documents(rows)
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "cz",
    source_portal = cz_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = NA_character_,
    competent_authority = competent_authority %||% NA_character_,
    proponent = proponent %||% NA_character_,
    date_published = date_published,
    date_decision = as.Date(NA),
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status %||% NA_character_,
    assessment_type = if (register == "EIA") "EIA" else "SEA",
    register = register,
    code = code,
    ico = ico %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Extract the detail table's rows as a list of `list(label, section, node)`.
#'
#' Carries the active stage-heading (the bold `colspan="2"` rows) forward so
#' each label/value row knows which process stage it belongs to. The `node` is
#' the value `<td>` so attachments and text both come from the same place.
#' @noRd
cz_extract_detail_rows <- function(html) {
  trs <- rvest::html_elements(html, "table.detail > tr, table.detail > tbody > tr")
  out <- list()
  section <- NA_character_
  for (tr in trs) {
    label_td <- rvest::html_element(tr, "td.label")
    value_td <- rvest::html_element(tr, "td.value")
    is_label_row <- !inherits(label_td, "xml_missing") && length(label_td) > 0L
    if (!is_label_row) {
      # A stage-heading row: single colspan="2" bold cell. Update section.
      heading_td <- rvest::html_element(tr, "td[colspan='2']")
      if (!inherits(heading_td, "xml_missing") && length(heading_td) > 0L) {
        txt <- cz_text(rvest::html_text2(heading_td))
        if (!is.null(txt)) {
          section <- txt
        }
      }
      next
    }
    label <- cz_text(rvest::html_text2(label_td))
    if (is.null(label)) {
      next
    }
    out[[length(out) + 1L]] <- list(
      label = sub(":\\s*$", "", label),
      section = section,
      node = value_td
    )
  }
  out
}

#' Return the text value of the first detail row whose label matches any of
#' `labels` (matched after stripping the trailing colon).
#' @noRd
cz_detail_value <- function(rows, labels) {
  for (r in rows) {
    if (r$label %in% labels) {
      td <- r$node
      if (is.null(td) || inherits(td, "xml_missing")) {
        return(NULL)
      }
      v <- cz_text(rvest::html_text2(td))
      if (!is.null(v)) {
        return(v)
      }
    }
  }
  NULL
}

#' Parse the Umístění (location) sub-table into a "Kraj / Okres / Obec" string.
#' @noRd
cz_parse_location <- function(html) {
  tbl <- rvest::html_element(html, "table.detail table.umisteni")
  if (inherits(tbl, "xml_missing") || length(tbl) == 0L) {
    return(NULL)
  }
  data_rows <- rvest::html_elements(tbl, "tr")
  if (length(data_rows) < 2L) {
    return(NULL)
  }
  tds <- rvest::html_elements(data_rows[[2]], "td")
  parts <- vapply(
    tds,
    function(td) cz_text(rvest::html_text2(td)) %||% "",
    character(1)
  )
  parts <- parts[nzchar(parts)]
  if (length(parts) == 0L) {
    return(NULL)
  }
  paste(unique(parts), collapse = " / ")
}

#' Parse document links out of the detail rows, grouped by stage-section slug.
#'
#' Each value `<td>` may contain `<a class="entity_field" href=".../download/...">`
#' links. They are grouped under the slug of the row's active stage section,
#' falling back to the row label when no stage heading is active.
#' @noRd
cz_parse_documents <- function(rows) {
  per_section <- list()
  for (r in rows) {
    td <- r$node
    if (is.null(td) || inherits(td, "xml_missing")) {
      next
    }
    anchors <- rvest::html_elements(td, "a[href*='/download/']")
    if (length(anchors) == 0L) {
      next
    }
    hrefs <- rvest::html_attr(anchors, "href")
    hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
    if (length(hrefs) == 0L) {
      next
    }
    urls <- vapply(hrefs, cz_absolute_url, character(1), USE.NAMES = FALSE)
    key <- if (!is.na(r$section) && nzchar(r$section)) r$section else r$label
    slug <- cz_section_slug(key)
    per_section[[slug]] <- unique(c(per_section[[slug]], urls))
  }
  per_section
}

#' Resolve a relative portal href to an absolute URL.
#'
#' The trailing human filename in the `/download/<token>/<file>` path is kept
#' verbatim (it is part of the canonical URL the portal serves).
#' @noRd
cz_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (startsWith(href, "/eiasea")) {
    return(paste0("https://portal.cenia.cz", href))
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(cz_portal_base(), href)
}

#' Slug a Czech stage-heading / row label to an ASCII column-suffix slug.
#'
#' Transliterates Czech diacritics, lowercases, and collapses non-alphanumerics
#' to underscores. Empty input gets `"document"` as a deterministic fallback.
#' @noRd
cz_section_slug <- function(label) {
  if (is.null(label) || !is.character(label) || length(label) != 1L || is.na(label) || !nzchar(label)) {
    return("document")
  }
  s <- cz_transliterate(label)
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "document" else s
}

#' Transliterate Czech diacritics to ASCII (best-effort).
#' @noRd
cz_transliterate <- function(s) {
  from <- c(
    "\u00e1",
    "\u010d",
    "\u010f",
    "\u00e9",
    "\u011b",
    "\u00ed",
    "\u0148",
    "\u00f3",
    "\u0159",
    "\u0161",
    "\u0165",
    "\u00fa",
    "\u016f",
    "\u00fd",
    "\u017e",
    "\u00c1",
    "\u010c",
    "\u010e",
    "\u00c9",
    "\u011a",
    "\u00cd",
    "\u0147",
    "\u00d3",
    "\u0158",
    "\u0160",
    "\u0164",
    "\u00da",
    "\u016e",
    "\u00dd",
    "\u017d"
  )
  to <- c(
    "a",
    "c",
    "d",
    "e",
    "e",
    "i",
    "n",
    "o",
    "r",
    "s",
    "t",
    "u",
    "u",
    "y",
    "z",
    "A",
    "C",
    "D",
    "E",
    "E",
    "I",
    "N",
    "O",
    "R",
    "S",
    "T",
    "U",
    "U",
    "Y",
    "Z"
  )
  for (i in seq_along(from)) {
    s <- gsub(from[i], to[i], s, fixed = TRUE)
  }
  s
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed CZ record: run downloads (if requested) and write sidecar.
#' @noRd
cz_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "cz"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "cz",
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

#' Apply post-fetch client-side filters.
#'
#' Only `date_range` is enforced here, against `date_published`.
#' @noRd
cz_record_matches <- function(rec, date_range) {
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

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
cz_text <- function(x) {
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

#' Parse a Java `Date.toString()` string into a Date.
#'
#' CENIA renders dates as e.g. `"Thu Jun 04 07:28:50 CEST 2026"` (English
#' weekday/month abbreviations, CEST/CET zone). We extract the month, day, and
#' year tokens directly so the parse is locale- and zone-independent.
#' @noRd
cz_parse_java_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  # Also accept the DD.MM.YYYY form occasionally rendered in document rows.
  dmy <- regmatches(s, regexpr("[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}", s))
  if (length(dmy) == 1L && nzchar(dmy)) {
    d <- suppressWarnings(as.Date(dmy, format = "%d.%m.%Y"))
    if (length(d) == 1L && !is.na(d)) {
      return(d)
    }
  }
  m <- regmatches(
    s,
    regexec(
      "[A-Za-z]{3} ([A-Za-z]{3}) ([0-9]{1,2}) [0-9:]{8} [A-Za-z]+ ([0-9]{4})",
      s
    )
  )[[1]]
  if (length(m) != 4L) {
    return(as.Date(NA))
  }
  months <- c(
    Jan = "01",
    Feb = "02",
    Mar = "03",
    Apr = "04",
    May = "05",
    Jun = "06",
    Jul = "07",
    Aug = "08",
    Sep = "09",
    Oct = "10",
    Nov = "11",
    Dec = "12"
  )
  mm <- months[[m[2]]]
  if (is.null(mm)) {
    return(as.Date(NA))
  }
  dd <- sprintf("%02d", as.integer(m[3]))
  yyyy <- m[4]
  suppressWarnings(as.Date(paste(yyyy, mm, dd, sep = "-")))
}
