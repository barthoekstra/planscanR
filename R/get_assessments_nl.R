#' Fetch environmental-assessment records from the Netherlands.
#'
#' Implementation of [get_assessments()] for the Netherlands. Backed by the
#' Commissie m.e.r. adviezenregister at
#' <https://www.commissiemer.nl/adviezen/>. Record URLs are read from the
#' portal's sitemap index (`wp-sitemap.xml`), following its `advice-sitemap*`
#' sub-sitemaps; per-record metadata is parsed from each detail page with
#' rvest. Free-text and date-range filters are
#' applied client-side as records are parsed; taxonomy filters
#' (`theme`, `advice_type`, `status`) are accepted for forward compatibility
#' but **not yet honoured** in v0.1 — see the "Filter coverage" section below.
#'
#' @section Filter coverage (v0.1):
#' The Commissie m.e.r. portal's taxonomy values (theme, advice type, status)
#' are driven by a JavaScript FacetWP layer that does not yield to programmatic
#' access without a browser session. As a result, this version applies only
#' the filters that are extractable from each detail page:
#'
#' * `query` — case-insensitive substring match against the title and URL slug
#' * `date_range` — matches against `date_decision` (the "Laatste advies
#'    uitgebracht op" field)
#' * `province` — substring match against `competent_authority`
#'    (e.g. `province = "Groningen"` matches "Provincie Groningen")
#'
#' The arguments `theme`, `advice_type`, and `status` are accepted (and
#' validated against the vocabularies in [get_assessments_coverage()]) but
#' currently emit a one-shot warning when supplied. A future release will wire
#' these through to a working portal-side filter path.
#'
#' @section Performance:
#' The portal hosts ~3600 advisory records. Each detail page is fetched once
#' and saved to a sidecar JSON on disk (see [index_cache()]); on later runs a
#' record with an existing sidecar is read straight from disk instead of being
#' re-fetched, so repeat runs are fast. On a first, cold run, enumerating the
#' full register can take many minutes and downloading every attachment can use
#' significant disk space. Always start with a `limit` (and ideally a `query`)
#' when exploring.
#'
#' To avoid stressing the server (commissiemer.nl returns HTTP 429 under a
#' sustained burst), NL requests are throttled to one per second by default
#' — i.e. a ~1 s delay between detail-page fetches. The rate is configurable
#' via `getOption("planscanR.nl_throttle_rate")` (requests/sec); set it to a
#' falsy value to disable. The throttle is scoped to NL only.
#'
#' @section Summary extraction:
#' The `summary` is the project description parsed from the detail page. Most
#' pages carry it in the intro block (`div.intro`); the first non-empty
#' paragraph is taken (some pages open that block with an empty placeholder
#' paragraph). Older pages render no intro block, in which case the summary
#' falls back to the first non-empty paragraph of the main content block
#' (`div.text`, under the "Hoofdpunten uit het advies" heading). Pages with no
#' descriptive prose yield `NA`.
#'
#' @param date_range Length-2 vector `c(from, to)` of dates or parseable strings.
#'   Filters by `date_decision`. `NULL` (default) returns all dates.
#' @param limit Integer. Maximum records to return. Defaults to `Inf`; you
#'   are strongly encouraged to set a small value (e.g. `50`) when exploring.
#' @param download Logical. Download PDF attachments? Default `FALSE`
#'   (downloading is opt-in because it is computationally intensive).
#' @param cache_dir Optional cache root. Defaults to
#'   `tools::R_user_dir("planscanR", "cache")`.
#' @param overwrite Logical. If `TRUE`, re-download attachments that are
#'   already cached. Cached files (non-empty, present on disk) are otherwise
#'   skipped and reported with `status = "cached"` in `download_status`.
#' @param max_file_size_mb Numeric cap (in MiB) on per-file download size.
#'   See [get_assessments()] for details.
#' @param write_sidecar Logical. Persist a `<document_id>.meta.json` per record
#'   alongside its attachments. Use [index_cache()] to reread.
#' @param refresh Logical. If `FALSE` (default), records whose URL already has
#'   a sidecar JSON on disk are loaded directly from JSON — no detail-page
#'   HTTP fetch. Set `TRUE` to force a fresh fetch (e.g. after the portal
#'   actually changed something).
#' @param topic,relevance_threshold,relevance_model Forwarded from
#'   [get_assessments()]. When `topic` is supplied, each candidate record is
#'   scored, and every scored record is sidecar'd and returned regardless of
#'   threshold. `relevance_threshold` **only affects downloading**: records
#'   below the threshold keep their sidecar and their tibble row, but their PDFs
#'   are not downloaded.
#' @param theme,advice_type,status,province Character vectors. See "Filter
#'   coverage". For `theme`, `advice_type`, `status` the valid slugs are in
#'   `get_assessments_coverage()$facets[[1]]`.
#' @param query Free-text search string (substring match on title + URL slug).
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @section Attachments: per-page split:
#' Each advice detail page on commissiemer.nl groups PDFs into two on-page
#' sections, which this handler exposes as separate list-columns:
#'
#' * `attachment_urls_source` / `local_path_source` — files in the
#'   **"Documenten waarop het advies is gebaseerd"** section. These are the
#'   underlying EIA/SEA reports submitted by the proponent and reviewed by the
#'   Commissie. **These are the substantive documents for downstream analysis**
#'   (e.g. the classification pipeline in \pkg{planscanR.screen}).
#' * `attachment_urls_advice` / `local_path_advice` — files in the
#'   **"Adviezen en persberichten"** section: the Commissie's own advisory
#'   reports and press releases.
#' * `attachment_urls` / `local_path` — the union of both (deduplicated),
#'   ordered with source documents first. Required by the planscanR schema.
#'
#' When `download = TRUE`, all files in both sections are fetched.
#'
#' @return A tibble; see [get_assessments()] for the schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_nl(limit = 3, download = FALSE)
#'
#' # Free-text query: any advice with "wind" in the title or slug
#' get_assessments_nl(query = "wind", limit = 10, download = FALSE)
#'
#' # Date range
#' get_assessments_nl(
#'   date_range = c("2024-01-01", "2024-12-31"),
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_nl <- function(
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
  theme = NULL,
  advice_type = NULL,
  status = NULL,
  province = NULL,
  query = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  facets <- commissiemer_facets()
  validate_facet_arg(theme, facets$theme, "theme")
  validate_facet_arg(advice_type, facets$advice_type, "advice_type")
  validate_facet_arg(status, facets$status, "status")
  if (!is.null(theme) || !is.null(advice_type) || !is.null(status)) {
    nl_warn_facet_unsupported()
  }

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }

  # Politeness throttle. commissiemer.nl returns HTTP 429 under a sustained
  # burst (a full-register scan fires thousands of detail-page requests), so
  # we cap NL traffic at a modest rate for the duration of this call. The
  # default is configurable via `planscanR.nl_throttle_rate` (requests/sec);
  # set it to a falsy value to disable. Only NL requests are affected — the
  # option is set locally and unset on exit, so DE/AT stay full-speed.
  nl_rate <- getOption("planscanR.nl_throttle_rate", 1)
  if (!is.null(nl_rate) && is.finite(nl_rate) && nl_rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = nl_rate))
  }

  # Set up the relevance gate (if requested) once per call: build the model,
  # embed the topic once, fire the language-support warning once. Per-record
  # work then becomes a single embed + cosine.
  rel <- setup_relevance(topic, relevance_model, country = "nl")

  urls <- nl_advice_urls()
  if (!is.null(query)) {
    pat <- tolower(query)
    keep <- vapply(urls, function(u) grepl(pat, tolower(u), fixed = TRUE), logical(1))
    urls <- urls[keep]
  }

  # Sidecar-first lookup. A previously-scanned record's metadata is fully
  # captured on disk; reading the JSON is ~ms and skips the network entirely.
  # Set `refresh = TRUE` to bypass and force a fresh detail-page fetch.
  sidecar_index <- if (!refresh) sidecar_url_index("nl") else stats::setNames(character(0), character(0))

  records <- list()
  for (u in urls) {
    if (length(records) >= limit) {
      break
    }
    rec <- tryCatch(nl_load_or_fetch(u, sidecar_index), error = function(e) {
      warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
      NULL
    })
    if (is.null(rec)) {
      next
    }
    if (!nl_record_matches(rec, query = query, date_range = date_range, province = province)) {
      next
    }
    # Score relevance (informational). The threshold no longer gates whether
    # the record is sidecar'd or returned — it only decides whether we spend
    # bandwidth pulling the PDFs.
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    # Download + sidecar happen per-record so the cache is crash-safe: an
    # interrupted run leaves N fully-indexable records on disk instead of N
    # orphan file trees with no metadata. The sidecar is written even when
    # the record's PDFs were not downloaded, so a later re-run with a
    # different threshold can pick them up without re-fetching the detail page.
    rec <- nl_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
    records[[length(records) + 1L]] <- rec
  }

  if (length(records) == 0L) {
    return(empty_result_tibble())
  }

  bind_results(!!!records)
}

#' Finalise a parsed record: run downloads (if requested) and write the sidecar.
#'
#' Called once per record from inside the main loop so each record's state
#' (downloaded files + sidecar) is durable before moving on. A crash between
#' records leaves earlier records fully indexable.
#'
#' @noRd
nl_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  src_urls <- get_section("attachment_urls_source")
  adv_urls <- get_section("attachment_urls_advice")
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "nl"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "nl",
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    # No downloads this run — still record per-URL "pending" rows so the
    # sidecar captures the URL list (and its section tags via the writer).
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  rec$local_path_source <- list(ds$local_path[match(src_urls, ds$url)])
  rec$local_path_advice <- list(ds$local_path[match(adv_urls, ds$url)])
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

#' Validate a search facet argument against its allowed vocabulary.
#' @noRd
validate_facet_arg <- function(value, allowed, arg_name) {
  if (is.null(value)) {
    return(invisible())
  }
  bad <- setdiff(value, allowed)
  if (length(bad) > 0L) {
    cli::cli_abort(
      c(
        "Invalid {arg_name} value{?s}: {.val {bad}}",
        i = "Valid values: {.val {allowed}}"
      ),
      class = "planscanR_error_bad_input"
    )
  }
  invisible()
}

#' One-shot warning that facet filters aren't yet honoured.
#' @noRd
nl_warn_facet_unsupported <- function() {
  if (isTRUE(getOption("planscanR.nl_facet_warned"))) {
    return(invisible())
  }
  warn_partial(c(
    "Taxonomy filters (theme/advice_type/status) are accepted but not yet honoured in this version.",
    i = "Only `query`, `date_range`, and `province` filtering are active. See `?get_assessments_nl`."
  ))
  options(planscanR.nl_facet_warned = TRUE)
  invisible()
}

#' Enumerate all advice URLs from the Commissie m.e.r. sitemap.
#' @noRd
nl_advice_urls <- function() {
  base <- "https://www.commissiemer.nl"
  index_req <- req_planscanr(base, "wp-sitemap.xml")
  index <- perform_xml(index_req)
  ns <- c(d = "http://www.sitemaps.org/schemas/sitemap/0.9")
  sub_urls <- xml2::xml_text(xml2::xml_find_all(index, ".//d:sitemap/d:loc", ns))
  sub_urls <- sub_urls[grepl("/advice-sitemap[0-9]*\\.xml$", sub_urls)]
  unique(unlist(lapply(sub_urls, function(u) {
    sub_req <- req_planscanr(u)
    sub <- perform_xml(sub_req)
    xml2::xml_text(xml2::xml_find_all(sub, ".//d:url/d:loc", ns))
  })))
}

#' Resolve a portal URL to a record tibble — sidecar-first, network-fallback.
#'
#' If a sidecar is on disk for this URL, the record is read from JSON (no HTTP
#' at all). Otherwise the detail page is fetched and parsed as before, and a
#' subsequent `write_record_sidecar()` from the caller will persist it.
#'
#' @param url Portal URL.
#' @param sidecar_index Output of `sidecar_url_index()`; empty vec is fine.
#' @noRd
nl_load_or_fetch <- function(url, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  nl_parse_detail(url)
}

#' Parse a single Commissie m.e.r. advice detail page into a 1-row tibble.
#' @noRd
nl_parse_detail <- function(url) {
  req <- req_planscanr(url)
  html <- perform_html(req)

  title <- rvest::html_text(rvest::html_element(html, "title")) %||% NA_character_
  title <- sub("\\s*-\\s*Commissie\\s+mer\\s*$", "", title)

  # Project description. Two real commissiemer.nl layouts have to be handled
  # (issue #12):
  #   1. Most pages put it in the "intro" block (`div.intro`). Some of those
  #      open with a malformed empty `<p align=justify>` before the real prose
  #      `<p>` (libxml2 auto-closes the empty one), so taking the *first* `<p>`
  #      unconditionally yields an empty string. We take the first NON-EMPTY
  #      paragraph instead.
  #   2. Older pages render no `div.intro` at all; the descriptive prose lives
  #      in the main content block (`div.text`) under an
  #      "Hoofdpunten uit het advies" heading. We fall back to its first
  #      non-empty paragraph. `div.text` matches only the main content column;
  #      footer/sidebar widgets use the distinct `div.textwidget` class.
  summary <- nl_first_nonempty_p(rvest::html_element(html, "div.intro"))
  if (is.na(summary)) {
    summary <- nl_first_nonempty_p(rvest::html_element(html, "div.text"))
  }

  # Sidebar label-value pairs (Bevoegd gezag / Initiatiefnemer / Laatste advies uitgebracht op)
  labels <- rvest::html_text(rvest::html_elements(html, "p.text-h6.font-bold"), trim = TRUE)
  values <- rvest::html_text(
    rvest::html_elements(html, "p.text-h6:not(.font-bold)"),
    trim = TRUE
  )
  sidebar <- stats::setNames(values[seq_along(labels)], labels)

  competent_authority <- nl_lookup(sidebar, "Bevoegd gezag")
  proponent <- nl_lookup(sidebar, "Initiatiefnemer")
  date_decision <- parse_dutch_date(nl_lookup(sidebar, "Laatste advies uitgebracht op"))

  # PDFs are split between two on-page sections:
  #   * "Adviezen en persberichten" — the Commissie's own advice + press releases.
  #   * "Documenten waarop het advies is gebaseerd" — the underlying EIA/SEA
  #     documents the Commissie reviewed. These are the substantive documents
  #     for downstream analysis (BIOGAIN / planscanR.screen classification).
  pdf_advice <- nl_section_pdfs(html, "Adviezen en persberichten")
  pdf_source <- nl_section_pdfs(html, "Documenten waarop het advies is gebaseerd")
  # `attachment_urls` is the required-schema union; ordered with source docs
  # first since those are the high-value ones.
  pdf_urls <- unique(c(pdf_source, pdf_advice))

  # Document ID: the Commissie m.e.r. project number embedded in the PDF URL path
  # pattern, e.g. https://pas.commissiemer.nl/files/nl/3619/...
  doc_id <- nl_extract_project_id(pdf_urls, html)

  tibble::tibble(
    country = "nl",
    source_portal = "commissiemer.nl",
    document_id = doc_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(pdf_urls),
    attachment_urls_source = list(pdf_source),
    attachment_urls_advice = list(pdf_advice),
    local_path = list(character(0)),
    local_path_source = list(character(0)),
    local_path_advice = list(character(0)),
    title = title,
    summary = summary,
    competent_authority = competent_authority %||% NA_character_,
    proponent = proponent %||% NA_character_,
    date_decision = date_decision,
    download_status = list(empty_download_status())
  )
}

#' Extract PDF URLs that live under a specific H2 section on a detail page.
#'
#' Uses an XPath that takes the first sibling div after the matching H2 and
#' selects all `.pdf` anchors within it. Returns a deduplicated character
#' vector (possibly empty).
#'
#' @noRd
nl_section_pdfs <- function(html, section_title) {
  # XPath equality is case- and whitespace-sensitive; normalize-space() handles
  # leading/trailing whitespace inside the rendered <h2>.
  literal <- shQuote(section_title, type = "sh")
  xp <- sprintf(
    "//h2[normalize-space(.) = %s]/following-sibling::div[1]//a[contains(@href, '.pdf')]",
    literal
  )
  nodes <- rvest::html_elements(html, xpath = xp)
  if (length(nodes) == 0L) {
    return(character(0))
  }
  hrefs <- rvest::html_attr(nodes, "href")
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  unique(hrefs)
}

#' First non-empty paragraph text within a node.
#'
#' Returns the trimmed text of the first `<p>` descendant whose text is not
#' blank, or `NA_character_` when the node is missing or holds no prose. Used to
#' tolerate the empty leading `<p>` that some commissiemer.nl `div.intro` blocks
#' carry (issue #12).
#'
#' @noRd
nl_first_nonempty_p <- function(node) {
  if (inherits(node, "xml_missing")) {
    return(NA_character_)
  }
  txt <- trimws(rvest::html_text(rvest::html_elements(node, "p")))
  txt <- txt[nzchar(txt)]
  if (length(txt) > 0L) txt[1] else NA_character_
}

#' Safe lookup in a named vector, returning NA when absent or empty.
#' @noRd
nl_lookup <- function(x, key) {
  if (!key %in% names(x)) {
    return(NA_character_)
  }
  v <- x[[key]]
  if (is.null(v) || !nzchar(v)) NA_character_ else v
}

#' Extract the Commissie m.e.r. project number from the page.
#'
#' Tries (in order):
#'   1. PDF URL pattern `pas.commissiemer.nl/files/nl/<id>/...`.
#'   2. The WordPress `postid-<n>` body-class as a fallback.
#'
#' @noRd
nl_extract_project_id <- function(pdf_urls, html) {
  if (length(pdf_urls) > 0L) {
    m <- regmatches(pdf_urls, regexpr("/files/nl/[0-9]+/", pdf_urls))
    m <- sub("/files/nl/", "", sub("/$", "", m))
    m <- m[nzchar(m)]
    if (length(m) > 0L) {
      return(m[1])
    }
  }
  body_class <- rvest::html_attr(rvest::html_element(html, "body"), "class") %||% ""
  m2 <- regmatches(body_class, regexpr("postid-[0-9]+", body_class))
  if (length(m2) > 0L && nzchar(m2)) {
    return(sub("postid-", "wp-", m2))
  }
  NA_character_
}

#' Apply client-side filters to a single parsed record.
#' @noRd
nl_record_matches <- function(rec, query, date_range, province) {
  if (!is.null(query)) {
    haystack <- tolower(paste(rec$title %||% "", rec$url, sep = " | "))
    if (!grepl(tolower(query), haystack, fixed = TRUE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    d <- rec$date_decision
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  if (!is.null(province)) {
    ca <- rec$competent_authority %||% ""
    if (!any(vapply(province, function(p) grepl(p, ca, ignore.case = TRUE), logical(1)))) {
      return(FALSE)
    }
  }
  TRUE
}
