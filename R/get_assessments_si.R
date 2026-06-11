#' Fetch environmental-assessment records from Slovenia.
#'
#' Implementation of [get_assessments()] for Slovenia. Backed by the
#' Slovenian government portal gov.si (<https://www.gov.si/>), which
#' publishes the environmental-assessment registers as bulk JSON exports
#' under <https://www.gov.si/podrocja/okolje-in-prostor/okolje/okoljske-presoje/>.
#' Three adjacent registers are merged into a single result tibble:
#'
#' * **Predhodni postopek** — the EIA screening register
#'   (`predhodni-postopek`).
#' * **CPVO — državni prostorski načrti** — SEA decisions for state spatial
#'   plans (`cpvo-drzavni`).
#' * **CPVO — občinski prostorski načrti** — SEA decisions for municipal
#'   spatial plans (`cpvo-obcinski`).
#'
#' An `assessment_type` column (`"EIA"` for the screening register, `"SEA"`
#' for the two CPVO registers) tags each row and is preserved in the offline
#' metadata cache so downstream tooling can tell them apart without re-fetching
#' anything; a `register` column carries the raw portal register label.
#' `document_id` is prefixed with `"PRED-"` / `"CPVO-DRZ-"` / `"CPVO-OBC-"`
#' so the three registers never collide on disk.
#'
#' @section URL enumeration:
#' Each register exposes a single bulk JSON export at
#' `<list base URL><list>/export/json/`, returning the whole register as one
#' JSON array (NOT paginated). The handler issues one GET per register and
#' parses every element of the array, respecting the global `limit`. The
#' canonical detail URL for each record is `<list base URL><URLSegment>/`.
#'
#' @section Attachments:
#' The two register shapes resolve attachments differently:
#'
#' * **EIA** (`predhodni-postopek`) records have a real per-record detail page.
#'   The handler fetches the detail HTML (sidecar-first via the cache), collects
#'   every `a[href^="/assets/seznami/"]` link, and absolutises it against
#'   `https://www.gov.si`.
#' * **SEA / CPVO** (`cpvo-drzavni`, `cpvo-obcinski`) records have NO detail
#'   page — the per-record URL 302-redirects to the register's listing, which is
#'   a single HTML table paginated by a `?start=` offset (10 rows/page) whose
#'   `Datoteka` cell holds the download links. The handler crawls every listing
#'   page once per register, then joins each bulk-export record to its row by
#'   normalised title (with a prefix fallback for listing-side title
#'   truncation). The bulk export's own `Datoteka` field is a list of opaque
#'   internal file ids that never appear in the public HTML, so it cannot
#'   resolve attachment URLs on its own. A CPVO record with no confident title
#'   match keeps an empty `attachment_urls` rather than risk another row's
#'   files.
#'
#' Either way `attachment_urls` is a flat list (no per-section split); an empty
#' vector is valid. Because the listing crawl is sidecar-first, a warm re-run
#' performs no listing-page network at all. NOTE: caches written before this
#' fix hold incomplete/incorrect CPVO `attachment_urls`; re-run the affected
#' records once with `refresh = TRUE` to heal them (downloads are not required —
#' the URLs are persisted to the sidecar even at `download = FALSE`).
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (screening only), or `"SEA"` (both CPVO registers).
#'    Applied here in R, not server-side (the bulk exports are unfiltered).
#' * `date_range` — matched client-side against `date_published` (the
#'    portal's *Datum objave* / *Datum* field). `date_decision` is always
#'    `NA` because the portal exposes no separate decision date as a date.
#' * `limit` — caps the total number of records returned across all crawled
#'    registers.
#'
#' @section Performance:
#' The registers are small (a few hundred screening records, a few dozen CPVO
#' records). A cold crawl is one bulk-export GET per register, plus — for EIA —
#' one detail-page fetch per record, or — for CPVO — one pass over the register's
#' paginated listing (a handful of pages, crawled once and shared across all of
#' that register's records). Everything is sidecar-first, so repeat runs are
#' fast and a fully-cached register fetches nothing. To be polite to the shared
#' government portal, SI requests are throttled to 5 requests per second by
#' default (with transient-error retry/backoff); override via
#' `getOption("planscanR.si_throttle_rate")` (requests/sec; falsy disables).
#' The register covers roughly 2021 onward.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
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
#' get_assessments_si(limit = 3, download = FALSE)
#'
#' # SEA only (both CPVO registers)
#' get_assessments_si(assessment_type = "SEA", limit = 10, download = FALSE)
#'
#' # Date range
#' get_assessments_si(
#'   date_range = c("2021-01-01", "2021-12-31"),
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_si <- function(
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
  assessment_type <- si_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.si_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "si")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("si")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("predhodni-postopek", "cpvo-drzavni", "cpvo-obcinski"),
    EIA = "predhodni-postopek",
    SEA = c("cpvo-drzavni", "cpvo-obcinski")
  )

  # Per-entry processing: sidecar-first attachment resolution (CPVO records join
  # to their paginated listing-table row; EIA records scrape their detail page),
  # client-side date filter, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry.
  # `get_cpvo_index` is NULL for EIA and a lazy listing-index accessor for CPVO.
  process_entry <- function(entry, get_cpvo_index) {
    rec <- tryCatch(
      si_load_or_fetch(entry, sidecar_index, get_cpvo_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {entry$url}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!si_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    si_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream each register's bulk export, persisting records as they are parsed.
  # `limit` is global across all crawled registers.
  records <- list()
  for (reg in registers) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    gen <- tryCatch(
      si_fetch_search(register = reg),
      error = function(e) {
        warn_partial(
          "Failed to enumerate gov.si {.val {reg}} export: {conditionMessage(e)}"
        )
        function() NULL
      }
    )
    # CPVO registers have no detail pages; attachments come from the paginated
    # listing table, crawled once per register and looked up by title. EIA gets
    # a NULL accessor and keeps its per-record detail-page scrape.
    get_cpvo_index <- si_make_cpvo_index_accessor(reg)
    block <- stream_crawl(
      gen,
      function(entry) process_entry(entry, get_cpvo_index),
      limit = remaining,
      label = "si"
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
si_source_portal <- function() "gov.si"

#' Public base URL for the portal.
#' @noRd
si_portal_base <- function() "https://www.gov.si"

#' Competent authority for every Slovenian record (fixed national ministry).
#' @noRd
si_competent_authority <- function() {
  "Ministrstvo za okolje, podnebje in energijo"
}

#' Base path for the okoljske-presoje register listing pages.
#' @noRd
si_list_base <- function() {
  "podrocja/okolje-in-prostor/okolje/okoljske-presoje"
}

#' Map a register code to its `assessment_type`.
#' @noRd
si_assessment_type_of <- function(register) {
  if (register == "predhodni-postopek") "EIA" else "SEA"
}

#' Map a register code to its `document_id` prefix.
#' @noRd
si_id_prefix <- function(register) {
  switch(
    register,
    `predhodni-postopek` = "PRED",
    `cpvo-drzavni` = "CPVO-DRZ",
    `cpvo-obcinski` = "CPVO-OBC"
  )
}

#' Map a register code to its list-page URL segment.
#'
#' The two CPVO registers crawl their own listing slug; the screening register
#' uses its short code. Returns the path segment appended after `si_list_base()`.
#' @noRd
si_register_segment <- function(register) {
  switch(
    register,
    `predhodni-postopek` = "predhodni-postopek",
    `cpvo-drzavni` = "odlocitve-o-izvedbi-celovite-presoje-vplivov-na-okolje-drzavnih-prostorskih-nacrtov",
    `cpvo-obcinski` = "odlocitve-o-izvedbi-celovite-presoje-vplivov-na-okolje-obcinskih-prostorskih-nacrtov-2"
  )
}

#' Full list base URL for a register (with trailing slash).
#' @noRd
si_register_base_url <- function(register) {
  sprintf(
    "%s/%s/%s/",
    si_portal_base(),
    si_list_base(),
    si_register_segment(register)
  )
}

#' Canonical detail URL for a record.
#' @noRd
si_canonical_url <- function(register, url_segment) {
  paste0(si_register_base_url(register), url_segment, "/")
}

#' Document-ID per register so the three registers never collide on disk.
#' @noRd
si_document_id <- function(register, url_segment) {
  sprintf("%s-%s", si_id_prefix(register), ascii_slug(url_segment, "record"))
}

#' Normalise the `assessment_type` argument.
#' @noRd
si_normalise_assessment_type <- function(x) {
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

#' Tolerant parser for the Slovenian date format `"29. 09. 2021"`.
#'
#' Strips internal spaces around the dots and parses `%d.%m.%Y`. `NA` for
#' NULL / non-scalar / NA / empty / unparseable.
#' @noRd
si_parse_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  s <- gsub("\\s+", "", trimws(s))
  d <- suppressWarnings(as.Date(s, format = "%d.%m.%Y"))
  if (length(d) == 0L) as.Date(NA) else d
}

# -----------------------------------------------------------------------------
# Bulk-export enumeration
# -----------------------------------------------------------------------------

#' Build a page generator for one register's bulk JSON export.
#'
#' The export is not paginated: a single GET returns the whole register as one
#' JSON array. The generator yields all entries on its first call (mapped into
#' lightweight named lists), then signals exhausted. Pagination state lives in
#' the closure to satisfy the `stream_crawl()` contract.
#' @noRd
si_fetch_search <- function(register) {
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    req <- req_planscanr(si_register_base_url(register))
    req <- httr2::req_url_path_append(req, "export/json/")
    arr <- tryCatch(perform_json(req), error = function(e) NULL)
    if (is.null(arr) || length(arr) == 0L) {
      return(NULL)
    }
    si_map_entries(arr, register)
  }
}

#' Map a bulk-export array into lightweight listing entries.
#'
#' Each entry is a small named list carrying everything the detail-record build
#' needs except the attachments (which come from the detail page).
#' @noRd
si_map_entries <- function(arr, register) {
  out <- list()
  for (raw in arr) {
    url_segment <- si_field(raw, "URLSegment")
    if (is.null(url_segment) || !nzchar(url_segment)) {
      next
    }
    out[[length(out) + 1L]] <- list(
      register = register,
      url_segment = url_segment,
      url = si_canonical_url(register, url_segment),
      raw = raw
    )
  }
  out
}

# -----------------------------------------------------------------------------
# CPVO listing-table crawl + title join (issue #17)
#
# The two CPVO/SEA registers have no per-record detail page: every record is a
# row in a single HTML table that paginates by a `?start=` offset (10 rows per
# page), and the download links live in that row's "Datoteka" cell. We crawl
# the whole table once per register and join each bulk-export record to its row
# by normalised title. (The bulk export's own "Datoteka" field is a list of
# opaque internal file ids that never appear in the public HTML, so it cannot
# resolve attachment URLs on its own.)
# -----------------------------------------------------------------------------

#' Is this register one of the listing-table (CPVO/SEA) registers?
#' @noRd
si_register_is_cpvo <- function(register) {
  register %in% c("cpvo-drzavni", "cpvo-obcinski")
}

#' Normalise a title for the CPVO listing-table join.
#'
#' Lower-cases (locale-correct for Slovenian diacritics), turns non-breaking
#' spaces into ordinary ones, collapses internal whitespace, and trims. Returns
#' `NA_character_` for NULL / NA / empty so callers can treat "no key" uniformly.
#' @noRd
si_normalise_title <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NA_character_)
  }
  s <- gsub("\u00a0", " ", as.character(x), fixed = TRUE)
  s <- tolower(s)
  s <- trimws(gsub("\\s+", " ", s))
  if (!nzchar(s)) NA_character_ else s
}

#' Absolutise gov.si `/assets/...` attachment hrefs (order-preserving, unique).
#' @noRd
si_absolutise_assets <- function(hrefs) {
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  if (length(hrefs) == 0L) {
    return(character(0))
  }
  abs_urls <- ifelse(
    grepl("^https?://", hrefs),
    hrefs,
    paste0(si_portal_base(), hrefs)
  )
  unique(abs_urls)
}

#' Parse one CPVO listing page's table into per-row records.
#'
#' Columns are located by HEADER NAME, not position: the drzavni register has no
#' `Občina` column, so its `Datoteka` cell sits one column to the left of the
#' obcinski register's. Attachment capture is scoped to each row's `Datoteka`
#' cell so page chrome (logos, stylesheets) is never mistaken for an attachment.
#' Returns a list of `list(title, title_norm, datum, attachment_urls)`.
#' @noRd
si_parse_listing_table <- function(html) {
  tbl <- rvest::html_element(html, "table")
  if (inherits(tbl, "xml_missing") || length(tbl) == 0L) {
    return(list())
  }
  rows <- rvest::html_elements(tbl, "tr")
  if (length(rows) < 2L) {
    return(list())
  }
  header <- trimws(rvest::html_text2(rvest::html_elements(rows[[1]], "th, td")))
  col_of <- function(name) {
    hit <- which(tolower(header) == tolower(name))
    if (length(hit) == 0L) NA_integer_ else hit[[1]]
  }
  i_title <- col_of("Naziv")
  i_datum <- col_of("Datum")
  i_dat <- col_of("Datoteka")
  if (is.na(i_title) || is.na(i_dat)) {
    return(list())
  }
  out <- list()
  for (r in rows[-1]) {
    cells <- rvest::html_elements(r, "td")
    if (length(cells) < max(i_title, i_dat)) {
      next
    }
    title <- trimws(rvest::html_text2(cells[[i_title]]))
    if (!nzchar(title)) {
      next
    }
    datum <- as.Date(NA)
    if (!is.na(i_datum) && length(cells) >= i_datum) {
      raw_datum <- gsub(
        "\u00a0",
        " ",
        rvest::html_text2(cells[[i_datum]]),
        fixed = TRUE
      )
      datum <- si_parse_date(raw_datum)
    }
    hrefs <- rvest::html_attr(rvest::html_elements(cells[[i_dat]], "a"), "href")
    hrefs <- hrefs[!is.na(hrefs) & grepl("/assets/", hrefs, fixed = TRUE)]
    out[[length(out) + 1L]] <- list(
      title = title,
      title_norm = si_normalise_title(title),
      datum = datum,
      attachment_urls = si_absolutise_assets(hrefs)
    )
  }
  out
}

#' Fetch one CPVO listing page at its `?start=` offset, or NULL on error.
#'
#' The dedicated seam keeps the network boundary mockable in tests.
#' @noRd
si_fetch_listing_page <- function(base_url, start) {
  req <- req_planscanr(base_url)
  req <- httr2::req_url_query(req, start = start)
  tryCatch(perform_html(req), error = function(e) NULL)
}

#' Crawl every page of a CPVO register's listing table and parse its rows.
#'
#' Walks the `?start=` offsets (10 rows/page) until a page yields no NEW rows,
#' deduplicating by normalised title so a clamped last page cannot loop forever.
#' Politeness throttle + transient-retry come from [req_planscanr()].
#' @noRd
si_build_cpvo_listing_index <- function(register) {
  base_url <- si_register_base_url(register)
  rows <- list()
  seen <- character(0)
  start <- 0L
  repeat {
    html <- si_fetch_listing_page(base_url, start)
    if (is.null(html)) {
      break
    }
    page_rows <- si_parse_listing_table(html)
    fresh <- Filter(
      function(r) !is.na(r$title_norm) && !(r$title_norm %in% seen),
      page_rows
    )
    if (length(fresh) == 0L) {
      break
    }
    seen <- c(seen, vapply(fresh, function(r) r$title_norm, character(1)))
    rows <- c(rows, fresh)
    start <- start + 10L
    if (start > 100000L) {
      break
    }
  }
  rows
}

#' Build a lazy, memoised accessor for a CPVO register's listing index.
#'
#' Returns NULL for the EIA register (which has real per-record detail pages).
#' For a CPVO register, returns a zero-arg closure that builds the listing index
#' on first call and caches it — so a fully sidecar-cached (warm) run, which
#' never reaches the closure, performs no listing-page network at all.
#' @noRd
si_make_cpvo_index_accessor <- function(register) {
  if (!si_register_is_cpvo(register)) {
    return(NULL)
  }
  built <- FALSE
  cached <- NULL
  function() {
    if (!built) {
      cached <<- si_build_cpvo_listing_index(register)
      built <<- TRUE
    }
    cached
  }
}

#' Look up a record's attachments in the CPVO listing index by title.
#'
#' Tier 1 is an exact normalised-title match. Tier 2 handles listing-side
#' truncation: the listing cell clips long titles, but the bulk-export `Title`
#' is full, so a sufficiently long (>= 60 char) listing title that prefixes the
#' record title is a confident match. Ambiguity is broken by `datum`. Returns
#' the attachment URL vector, or NULL when there is no confident match — the
#' caller then leaves the record's attachments empty rather than risk
#' mis-attributing another row's files (abbreviated listing titles land here).
#' @noRd
si_lookup_cpvo_attachments <- function(rows, title, datum = as.Date(NA)) {
  tn <- si_normalise_title(title)
  if (is.na(tn) || length(rows) == 0L) {
    return(NULL)
  }
  resolve <- function(cands) {
    if (length(cands) == 1L) {
      return(cands[[1]]$attachment_urls)
    }
    if (!is.na(datum)) {
      byd <- Filter(function(r) !is.na(r$datum) && r$datum == datum, cands)
      if (length(byd) == 1L) {
        return(byd[[1]]$attachment_urls)
      }
    }
    unique(unlist(lapply(cands, function(r) r$attachment_urls)))
  }
  exact <- Filter(function(r) identical(r$title_norm, tn), rows)
  if (length(exact) >= 1L) {
    return(resolve(exact))
  }
  pref <- Filter(
    function(r) {
      !is.na(r$title_norm) &&
        nchar(r$title_norm) >= 60L &&
        startsWith(tn, r$title_norm)
    },
    rows
  )
  if (length(pref) >= 1L) {
    return(resolve(pref))
  }
  NULL
}

# -----------------------------------------------------------------------------
# Detail-record building
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else build attachments.
#'
#' EIA records scrape their per-record detail page. CPVO records have no detail
#' page (the per-record URL 302-redirects to the listing), so their attachments
#' are joined from the register's paginated listing index via `get_cpvo_index`
#' (a lazy accessor; NULL for EIA). A CPVO record with no confident title match
#' keeps an empty attachment list rather than risk another row's files.
#' @noRd
si_load_or_fetch <- function(entry, sidecar_index, get_cpvo_index = NULL) {
  url <- entry$url
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  if (!is.null(get_cpvo_index)) {
    rows <- get_cpvo_index()
    title <- si_field(entry$raw, "Title") %||% si_field(entry$raw, "Naziv")
    datum <- si_parse_date(si_field(entry$raw, "Datum"))
    attachments <- si_lookup_cpvo_attachments(rows, title, datum)
    if (is.null(attachments)) {
      warn_partial(
        paste0(
          "No gov.si listing-table match for CPVO record ",
          "{.val {entry$url_segment}}; attachments left empty"
        )
      )
      attachments <- character(0)
    }
    return(si_build_record(entry, attachments))
  }
  attachments <- si_fetch_attachments(url)
  si_build_record(entry, attachments)
}

#' Fetch a detail page and collect its `/assets/seznami/` attachment URLs.
#' @noRd
si_fetch_attachments <- function(url) {
  req <- req_planscanr(url)
  html <- tryCatch(perform_html(req), error = function(e) NULL)
  if (is.null(html)) {
    return(character(0))
  }
  si_parse_attachments(html)
}

#' Parse `a[href^="/assets/seznami/"]` links from a detail page, absolutised.
#' @noRd
si_parse_attachments <- function(html) {
  anchors <- rvest::html_elements(html, "a[href^='/assets/seznami/']")
  if (length(anchors) == 0L) {
    return(character(0))
  }
  hrefs <- rvest::html_attr(anchors, "href")
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  if (length(hrefs) == 0L) {
    return(character(0))
  }
  unique(paste0(si_portal_base(), hrefs))
}

#' Build a 1-row record tibble from a listing entry + scraped attachments.
#' @noRd
si_build_record <- function(entry, attachments) {
  register <- entry$register
  raw <- entry$raw
  document_id <- si_document_id(register, entry$url_segment)

  if (register == "predhodni-postopek") {
    title <- si_field(raw, "Poseg")
    date_published <- si_parse_date(si_field(raw, "Datum objave"))
    proponent <- si_field(raw, "Naziv")
    proponent_address <- si_field(raw, "Naslov")
    case_number <- si_field(raw, "\u0160tevilka zadeve")
    annex_code <- si_field(raw, "Oznaka posega")
    native_type <- NA_character_
    decision <- NA_character_
  } else {
    title <- si_field(raw, "Title")
    if (is.null(title) || !nzchar(title)) {
      title <- si_field(raw, "Naziv")
    }
    date_published <- si_parse_date(si_field(raw, "Datum"))
    proponent <- NA_character_
    proponent_address <- NA_character_
    case_number <- NA_character_
    annex_code <- NA_character_
    decision <- si_field(raw, "Odlo\u010ditev")
    native_type <- decision
  }

  attachments <- attachments %||% character(0)

  tibble::tibble(
    country = "si",
    source_portal = si_source_portal(),
    document_id = document_id,
    url = entry$url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(attachments),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    summary = NA_character_,
    competent_authority = si_competent_authority(),
    proponent = proponent %||% NA_character_,
    date_published = date_published,
    date_decision = as.Date(NA),
    native_type = native_type %||% NA_character_,
    status = NA_character_,
    assessment_type = si_assessment_type_of(register),
    register = register,
    proponent_address = proponent_address %||% NA_character_,
    case_number = case_number %||% NA_character_,
    annex_code = annex_code %||% NA_character_,
    decision = decision %||% NA_character_,
    download_status = list(empty_download_status())
  )
}

#' Read a scalar field from a bulk-export record, returning NULL when absent.
#'
#' Values arrive as JSON scalars; some fields (e.g. `Sklep / Odločba`)
#' are nested objects and are deliberately not surfaced here. Returns a trimmed
#' non-empty character or NULL.
#' @noRd
si_field <- function(raw, key) {
  v <- raw[[key]]
  if (is.null(v) || length(v) != 1L || is.list(v)) {
    return(NULL)
  }
  s <- trimws(as.character(v))
  if (is.na(s) || !nzchar(s)) NULL else s
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed SI record: run downloads (if requested) and write sidecar.
#' @noRd
si_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "si"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "si",
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

#' Apply post-fetch client-side filters (only `date_range`).
#' @noRd
si_record_matches <- function(rec, date_range) {
  if (!is.null(date_range)) {
    d <- rec$date_published
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}
