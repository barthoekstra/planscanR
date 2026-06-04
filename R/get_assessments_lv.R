#' Fetch environmental-assessment records from Latvia.
#'
#' Implementation of [get_assessments()] for Latvia. Backed by the
#' Environmental State Bureau (*Vides pārraudzības valsts birojs*) portal at
#' <https://www.eva.gov.lv/>, a server-rendered Drupal site. The portal
#' exposes two **structurally different** halves, merged into a single result
#' tibble and selected via an `assessment_type` argument:
#'
#' * **EIA** — *Ietekmes uz vidi novērtējums* (project-level EIA). A Drupal
#'   Views listing at
#'   `https://www.eva.gov.lv/lv/ietekmes-uz-vidi-novertejumu-projekti?page=N`
#'   whose rows each link to a per-project detail page.
#' * **SEA** — *Stratēģiskais ietekmes uz vidi novērtējums* (plan/programme
#'   SEA). Three flat sub-pages — `/lv/atzinumi` (opinions), `/lv/lemumi`
#'   (decisions), `/lv/monitorings` (monitoring) — each listing documents as
#'   direct `/lv/media/{id}/download?attachment` PDF links.
#'
#' An `assessment_type` column (`"EIA"` / `"SEA"`) tags each row and is
#' preserved in the offline metadata cache so downstream tooling can tell them
#' apart without re-fetching anything; a `register` column carries the raw
#' sub-register label (`"ivn-projekti"` for EIA; `"atzinumi"` / `"lemumi"` /
#' `"monitorings"` for SEA). `document_id` is prefixed per register
#' (`"IVN-"`, `"ATZ-"`, `"LEM-"`, `"MON-"`) so the registers never collide on
#' disk.
#'
#' @section URL enumeration:
#' The portal is server-rendered HTML (no JSON API). The two halves are
#' enumerated differently:
#'
#' * **EIA** — the Views listing paginates via a **0-indexed** `?page=N` query
#'   parameter (~20 records per page). The portal's exposed-form filters are
#'   POST/AJAX (a GET `?combine=` is ignored), so this handler does a full
#'   crawl `?page=0,1,2,…`, stopping when a page yields no records. Each row
#'   links to a per-project detail page (sidecar-first).
#' * **SEA** — each of the three flat sub-pages is fetched once. They are
#'   year-grouped HTML tables (no pagination, no detail pages) whose rows carry
#'   a direct `/lv/media/{id}/download?attachment` PDF link, a document number,
#'   a date, and the planning-document title.
#'
#' @section Geometry:
#' None. The portal exposes location only as Latvian prose (cadastral numbers,
#' parishes, municipalities), surfaced for EIA records in the `location` extra
#' column. No coordinate geometry is available, so `geometry_path` /
#' `geometry_crs` are never set.
#'
#' @section Attachments:
#' The two halves differ fundamentally:
#'
#' * **EIA — metadata-only.** EIA detail pages carry metadata but **no
#'   downloadable document attachments** (decisions are referenced as prose /
#'   numbers). Every EIA record therefore has `attachment_urls = character(0)`;
#'   documents are filled in downstream by [discover_attachments()]
#'   (`discover = TRUE`).
#' * **SEA — direct PDFs.** Each SEA sub-page row links to a public PDF at
#'   `https://www.eva.gov.lv/lv/media/{id}/download?attachment` (no
#'   authentication; the server returns `application/pdf`). One attachment per
#'   record.
#'
#' Because the EIA half is metadata-only, the country's
#' `get_assessments_coverage()$status` starts with `"supported (metadata-only`,
#' which is the marker `discover_attachments()` keys on.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which half to crawl: `"All"` (default),
#'    `"EIA"` (the Views listing), or `"SEA"` (the three sub-pages). Applied
#'    here in R; the portal's own filters are POST/AJAX and not honoured.
#' * `query` — matched client-side as a case-insensitive substring of the
#'    record title.
#' * `date_range` — matched client-side against `date_published` /
#'    `date_decision`. A record whose date is `NA` is dropped only when a
#'    `date_range` is explicitly set (matching the other handlers); SEA
#'    monitoring entries that carry no date are kept when no `date_range` is
#'    given.
#' * `limit` — caps the total number of records returned across all crawled
#'    registers.
#'
#' @section Performance:
#' The EIA register is a few hundred projects across ~20-record pages; the
#' three SEA sub-pages are single fetches each. To be polite to the shared
#' government portal, LV requests are throttled to 5 requests per second by
#' default; override via `getOption("planscanR.lv_throttle_rate")`
#' (requests/sec; falsy disables). A `limit` keeps cold runs bounded; repeat
#' runs are sidecar-first.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query, matched client-side as a
#'   case-insensitive substring of the record title.
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which half (Views listing / SEA sub-pages) to crawl.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_lv(limit = 3, download = FALSE)
#'
#' # SEA only (the three flat sub-pages, with direct PDFs)
#' get_assessments_lv(assessment_type = "SEA", limit = 10, download = TRUE)
#'
#' # Title substring
#' get_assessments_lv(query = "veja", limit = 20, download = FALSE)
#' }
get_assessments_lv <- function(
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
  assessment_type <- lv_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.lv_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "lv")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("lv")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Which halves to crawl. EIA is one Views listing; SEA is the three flat
  # sub-pages. Each is enumerated as a stream_crawl() generator below.
  do_eia <- assessment_type %in% c("All", "EIA")
  do_sea <- assessment_type %in% c("All", "SEA")

  # Per-entry processing: sidecar-first detail fetch (EIA) or pass-through
  # (SEA), client-side filters, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry. Called
  # once per listing entry by stream_crawl().
  process_entry <- function(entry) {
    u <- entry$url
    rec <- tryCatch(
      lv_load_or_fetch(u, entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!lv_record_matches(rec, query = query, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    lv_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Build the ordered list of register streams to crawl, each as a factory
  # closure that builds its stream_crawl() generator on demand. `limit` is
  # global across all of them, so a full EIA crawl can consume all of it before
  # SEA. The EIA half is one Views listing; SEA is the three flat sub-pages.
  factories <- list()
  if (do_eia) {
    factories <- c(factories, list(function() lv_fetch_eia()))
  }
  if (do_sea) {
    sea_factories <- lapply(lv_sea_subpages(), function(sub) {
      force(sub)
      function() lv_fetch_sea(sub)
    })
    factories <- c(factories, sea_factories)
  }

  records <- list()
  for (make_gen in factories) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    gen <- tryCatch(
      make_gen(),
      error = function(e) {
        warn_partial("Failed to enumerate eva.gov.lv register: {conditionMessage(e)}")
        function() NULL
      }
    )
    block <- stream_crawl(gen, process_entry, limit = remaining, label = "lv")
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
lv_source_portal <- function() "eva.gov.lv"

#' Public base URL for the portal.
#' @noRd
lv_portal_base <- function() "https://www.eva.gov.lv"

#' Competent authority for every Latvian record (the national bureau).
#'
#' Latvian verbatim.
#' @noRd
lv_competent_authority <- function() "Vides pārraudzības valsts birojs"

#' EIA Views listing path.
#' @noRd
lv_eia_path <- function() "lv/ietekmes-uz-vidi-novertejumu-projekti"

#' The three flat SEA sub-pages, keyed by register slug.
#' @noRd
lv_sea_subpages <- function() c("atzinumi", "lemumi", "monitorings")

#' Map a SEA sub-page register slug to its document-ID prefix.
#' @noRd
lv_sea_prefix <- function(register) {
  switch(
    register,
    atzinumi = "ATZ",
    lemumi = "LEM",
    monitorings = "MON",
    "SEA"
  )
}

#' Map a SEA sub-page register slug to its native document type (Latvian).
#' @noRd
lv_sea_native_type <- function(register) {
  switch(
    register,
    atzinumi = "atzinums",
    lemumi = "lēmums",
    monitorings = "monitorings",
    register
  )
}

#' Normalise the `assessment_type` argument.
#' @noRd
lv_normalise_assessment_type <- function(x) {
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
# EIA enumeration (0-indexed Views listing → metadata-only detail pages)
# -----------------------------------------------------------------------------

#' Build a page generator for the EIA Views listing.
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call fetches the next 0-indexed `?page=N` listing page and returns its rows
#' as entries, or `NULL` once the listing is exhausted (an empty / short page).
#' Pagination state lives in the closure.
#'
#' Each entry is a small named list with `register = "ivn-projekti"`,
#' `assessment_type = "EIA"`, the detail-page `url`, and the listing-card
#' fields (title, status, proponent, decision-year text). The detail-page
#' parser is sidecar-first, so the entry carries enough to build the canonical
#' URL and a useful fallback if the detail fetch fails.
#' @noRd
lv_fetch_eia <- function() {
  page <- 0L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(lv_portal_base())
    req <- httr2::req_url_path_append(req, lv_eia_path())
    req <- httr2::req_url_query(req, page = page)
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      done <<- TRUE
      return(NULL)
    }
    rows <- lv_parse_eia_rows(html)
    if (length(rows) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    page <<- page + 1L
    rows
  }
}

#' Parse the rows of one EIA listing page into entries.
#' @noRd
lv_parse_eia_rows <- function(html) {
  nodes <- rvest::html_elements(html, "div.views-row div.node-catalog-item")
  out <- list()
  for (node in nodes) {
    a <- rvest::html_element(node, "h3 a[rel='bookmark']")
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    title <- lv_text(rvest::html_text2(a))
    fields <- lv_parse_classifier_row(node)
    out[[length(out) + 1L]] <- list(
      register = "ivn-projekti",
      assessment_type = "EIA",
      url = lv_absolute_url(href),
      title = title,
      status = fields[["IVN Statuss"]],
      proponent = fields[["IVN projekta ierosinātājs"]],
      decision_text = fields[["Lēmums par IVN nepieciešamību"]]
    )
  }
  out
}

#' Parse a `.classifier-row` block into a named list of label → value.
#'
#' Each child carries a `.field-label` div and a sibling value (`<span>`). Used
#' on both the listing cards and the detail page (same markup).
#' @noRd
lv_parse_classifier_row <- function(node) {
  row <- rvest::html_element(node, "div.classifier-row")
  if (length(row) == 0L || inherits(row, "xml_missing")) {
    return(list())
  }
  cells <- rvest::html_elements(row, xpath = "./div")
  out <- list()
  for (cell in cells) {
    label <- lv_text(rvest::html_text2(rvest::html_element(cell, "div.field-label")))
    if (is.null(label)) {
      next
    }
    span <- rvest::html_element(cell, "span")
    value <- if (inherits(span, "xml_missing")) NULL else lv_text(rvest::html_text2(span))
    out[[label]] <- value
  }
  out
}

# -----------------------------------------------------------------------------
# SEA enumeration (three flat sub-pages → direct media PDFs)
# -----------------------------------------------------------------------------

#' Build a one-shot page generator for one SEA sub-page.
#'
#' SEA sub-pages are flat (no pagination, no detail pages), so the generator
#' fetches the page once on its first call, emits all of its document entries,
#' and returns `NULL` thereafter.
#'
#' Each entry is a named list with `register` (the sub-page slug),
#' `assessment_type = "SEA"`, the sub-page `url` (the stable sidecar key, with
#' a `#media-{id}` anchor so each document keys distinctly), `media_url` (the
#' absolute `/lv/media/{id}/download?attachment` link), `media_id`, `title`,
#' `number`, and `date_text`.
#' @noRd
lv_fetch_sea <- function(register) {
  emitted <- FALSE
  function() {
    if (emitted) {
      return(NULL)
    }
    emitted <<- TRUE
    req <- req_planscanr(lv_portal_base())
    req <- httr2::req_url_path_append(req, "lv", register)
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      return(list())
    }
    lv_parse_sea_entries(html, register)
  }
}

#' Parse one SEA sub-page into document entries.
#'
#' Iterates over every `/lv/media/{id}/download?attachment` anchor on the page.
#' For each anchor, the title is taken from the enclosing table row's
#' "Plānošanas dokuments" cell when present, else from the link's `title`
#' attribute (the PDF filename). The document number and date come from the row
#' cells when the layout is tabular; monitoring entries are prose-based and may
#' carry neither.
#' @noRd
lv_parse_sea_entries <- function(html, register) {
  anchors <- rvest::html_elements(html, "a[href*='/lv/media/']")
  out <- list()
  seen <- character(0)
  page_url <- paste0(lv_portal_base(), "/lv/", register)
  for (a in anchors) {
    href <- rvest::html_attr(a, "href")
    media_id <- lv_extract_media_id(href)
    if (is.na(media_id) || media_id %in% seen) {
      next
    }
    seen <- c(seen, media_id)
    filename <- lv_text(rvest::html_attr(a, "title"))
    row_fields <- lv_sea_row_fields(a)
    title <- row_fields$title %||% filename %||% lv_text(rvest::html_text2(a)) %||% NA_character_
    out[[length(out) + 1L]] <- list(
      register = register,
      assessment_type = "SEA",
      url = paste0(page_url, "#media-", media_id),
      media_url = lv_media_url(media_id),
      media_id = media_id,
      title = title,
      number = row_fields$number,
      date_text = row_fields$date_text
    )
  }
  out
}

#' Pull the document number, date, and planning-document title from a SEA
#' media anchor's enclosing table row, if any.
#'
#' The opinions / decisions sub-pages are 3-column tables
#' (number | date | planning document). The monitoring sub-page is prose, in
#' which case the anchor has no `<tr>` ancestor and all fields are `NULL`.
#' @noRd
lv_sea_row_fields <- function(a) {
  tr <- rvest::html_element(a, xpath = "ancestor::tr[1]")
  if (length(tr) == 0L || inherits(tr, "xml_missing")) {
    return(list(number = NULL, date_text = NULL, title = NULL))
  }
  tds <- rvest::html_elements(tr, xpath = "./td")
  number <- if (length(tds) >= 1L) lv_text(rvest::html_text2(tds[[1]])) else NULL
  date_text <- if (length(tds) >= 2L) lv_text(rvest::html_text2(tds[[2]])) else NULL
  title <- if (length(tds) >= 3L) lv_text(rvest::html_text2(tds[[length(tds)]])) else NULL
  list(number = number, date_text = date_text, title = title)
}

#' Extract the numeric media id from a `/lv/media/{id}/download` href.
#' @noRd
lv_extract_media_id <- function(href) {
  if (is.null(href) || length(href) != 1L || is.na(href) || !nzchar(href)) {
    return(NA_character_)
  }
  m <- regmatches(href, regexec("/lv/media/([0-9]+)/download", href))[[1]]
  if (length(m) != 2L) {
    return(NA_character_)
  }
  m[2]
}

#' Build the absolute media download URL for a media id.
#' @noRd
lv_media_url <- function(media_id) {
  sprintf("%s/lv/media/%s/download?attachment", lv_portal_base(), media_id)
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else build the record.
#'
#' EIA entries trigger a detail-page fetch + parse (metadata-only); SEA entries
#' are self-contained (the sub-page row already carried everything), so they
#' are built without a further fetch.
#' @noRd
lv_load_or_fetch <- function(url, entry, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  if (identical(entry$assessment_type, "SEA")) {
    return(lv_build_sea_record(url, entry))
  }
  html <- lv_fetch_html(url)
  lv_parse_eia_detail(url, entry, html)
}

#' Fetch one EIA detail page as parsed HTML.
#' @noRd
lv_fetch_html <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Parse one EIA detail page into a 1-row tibble (metadata-only).
#'
#' The detail page carries an `<h1>` title, a `.classifier-row` block
#' (IVN Statuss / IVN projekta ierosinātājs / Lēmums par IVN nepieciešamību),
#' and body paragraphs whose `<strong>` labels include the location
#' ("Paredzētās darbības norises vieta") and a short description
#' ("Īss paredzētās darbības raksturojums"). There are **no** attachment links,
#' so `attachment_urls` is empty (documents come via discovery downstream).
#' @noRd
lv_parse_eia_detail <- function(url, entry, html) {
  h1 <- lv_text(rvest::html_text2(rvest::html_element(html, "h1")))
  fields <- lv_parse_classifier_row(html)

  title <- h1 %||% entry$title %||% NA_character_
  status <- fields[["IVN Statuss"]] %||% entry$status %||% NA_character_
  proponent <- fields[["IVN projekta ierosinātājs"]] %||% entry$proponent %||% NA_character_
  decision_text <- fields[["Lēmums par IVN nepieciešamību"]] %||% entry$decision_text

  location <- lv_strong_value(html, "Paredzētās darbības norises vieta")
  summary <- lv_strong_value(html, "Īss paredzētās darbības raksturojums")

  lv_eia_record(
    url = url,
    title = title,
    status = status,
    proponent = proponent,
    decision_text = decision_text,
    location = location,
    summary = summary
  )
}

#' Assemble an EIA (metadata-only) record tibble.
#' @noRd
lv_eia_record <- function(url, title, status, proponent, decision_text, location, summary) {
  document_id <- paste0("IVN-", lv_doc_slug(url))
  tibble::tibble(
    country = "lv",
    source_portal = lv_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    summary = summary %||% NA_character_,
    competent_authority = lv_competent_authority(),
    proponent = proponent %||% NA_character_,
    date_published = as.Date(NA),
    date_decision = lv_decision_date(decision_text),
    native_type = "IVN",
    jurisdiction = NA_character_,
    status = status %||% NA_character_,
    assessment_type = "EIA",
    register = "ivn-projekti",
    location = location %||% NA_character_,
    decision = decision_text %||% NA_character_,
    download_status = list(empty_download_status())
  )
}

#' Build a SEA record tibble from a sub-page entry (direct PDF attachment).
#' @noRd
lv_build_sea_record <- function(url, entry) {
  document_id <- paste0(lv_sea_prefix(entry$register), "-", entry$media_id)
  media_urls <- if (is.null(entry$media_url) || is.na(entry$media_url)) {
    character(0)
  } else {
    entry$media_url
  }
  tibble::tibble(
    country = "lv",
    source_portal = lv_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(media_urls),
    local_path = list(character(0)),
    title = entry$title %||% NA_character_,
    summary = NA_character_,
    competent_authority = lv_competent_authority(),
    proponent = NA_character_,
    date_published = parse_dmy(entry$date_text),
    date_decision = as.Date(NA),
    native_type = lv_sea_native_type(entry$register),
    jurisdiction = NA_character_,
    status = NA_character_,
    assessment_type = "SEA",
    register = entry$register,
    location = NA_character_,
    decision = entry$number %||% NA_character_,
    download_status = list(empty_download_status())
  )
}

#' Pull the text following a `<strong>Label:</strong>` inside a body paragraph.
#'
#' Detail-page body paragraphs are `<p><strong>Label: </strong>value</p>`. We
#' find the paragraph whose `<strong>` begins with `label` and return the
#' remaining text of the paragraph. Returns trimmed non-empty text or `NULL`.
#' @noRd
lv_strong_value <- function(html, label) {
  ps <- rvest::html_elements(html, "p")
  for (p in ps) {
    strong <- rvest::html_element(p, "strong")
    if (length(strong) == 0L || inherits(strong, "xml_missing")) {
      next
    }
    label_text <- lv_text(rvest::html_text2(strong))
    if (is.null(label_text)) {
      next
    }
    norm <- sub("[:\\s]*$", "", label_text, perl = TRUE)
    if (!startsWith(tolower(label_text), tolower(label))) {
      next
    }
    full <- lv_text(rvest::html_text2(p))
    if (is.null(full)) {
      return(NULL)
    }
    value <- sub(
      paste0("^\\Q", norm, "\\E\\s*:?\\s*"),
      "",
      full,
      perl = TRUE
    )
    return(lv_text(value))
  }
  NULL
}

#' Derive a stable document slug from an EIA detail URL (the last path segment).
#' @noRd
lv_doc_slug <- function(url) {
  path <- sub("#.*$", "", url)
  path <- sub("\\?.*$", "", path)
  segment <- basename(path)
  ascii_slug(segment, "ivn")
}

#' Parse the EIA "Lēmums par IVN nepieciešamību" field into a Date.
#'
#' The field is usually just a year (e.g. `"2026"`); it may also carry a full
#' `DD.MM.YYYY`. We prefer the full date, else map a bare year to its Jan 1.
#' @noRd
lv_decision_date <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    return(as.Date(NA))
  }
  d <- parse_dmy(x)
  if (!is.na(d)) {
    return(d)
  }
  m <- regmatches(x, regexpr("[0-9]{4}", x))
  if (length(m) == 0L || !nzchar(m)) {
    return(as.Date(NA))
  }
  suppressWarnings(as.Date(paste0(m, "-01-01")))
}

#' Resolve a relative portal href to an absolute URL.
#' @noRd
lv_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(lv_portal_base(), href)
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed LV record: run downloads (if requested) and write sidecar.
#'
#' EIA records carry no attachment URLs (metadata-only), so `download` is a
#' no-op for them; SEA records carry one direct PDF each.
#' @noRd
lv_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  if (download && length(urls) > 0L) {
    inform_download(length(urls), cache_dir(file.path("files", "lv"), create = TRUE))
    ds <- download_attachments(
      urls,
      country = "lv",
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
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
#'
#' `date_range` is matched against `date_published` when present, else
#' `date_decision`. A record whose relevant date is `NA` is dropped only when a
#' `date_range` was explicitly set.
#' @noRd
lv_record_matches <- function(rec, query = NULL, date_range = NULL) {
  if (!is.null(query) && nzchar(query)) {
    title <- rec$title
    if (is.na(title) || !grepl(tolower(query), tolower(title), fixed = TRUE)) {
      return(FALSE)
    }
  }
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
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Coerce a scalar to a trimmed non-empty character, else NULL.
#' @noRd
lv_text <- function(x) {
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
