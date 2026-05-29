#' Fetch environmental-assessment records from Germany.
#'
#' Implementation of [get_assessments()] for Germany. Backed by the
#' UVP-Verbund portal at <https://www.uvp-verbund.de/>, a federated catalogue
#' of UVP (Umweltverträglichkeitsprüfung) procedures published by all
#' federal-state authorities. URL enumeration uses the portal's own
#' server-side full-text search (`/freitextsuche`) — there is no XML sitemap.
#' Per-record metadata is parsed from each detail page with rvest.
#'
#' @section URL enumeration:
#' The portal exposes no sitemap, no OAI-PMH, and no CSW endpoint. The only
#' enumeration route is the search interface itself:
#'
#' ```
#' https://www.uvp-verbund.de/freitextsuche?q=<query>&toggle_procedure=&ranking=score&page=<n>
#' ```
#'
#' The portal is Solr-backed but its `q=*:*` wildcard is broken for
#' pagination: page 1 renders, every subsequent page returns the header but
#' no results. As a "match-most" fallback when `query` is `NULL` we use
#' `q=uvp`, which paginates correctly and covers ~93% of the register
#' (~22,574 of ~24,270 records). For full coverage, run the scan against
#' multiple seed queries and union the results.
#' `toggle_procedure=` (empty value) is set explicitly: the portal's default
#' (`toggle_procedure=on`) restricts results to currently-running plus
#' last-year-modified procedures and silently drops ~80% of historical
#' records.
#'
#' On a cold cache, a full enumeration over ~2,258 pages is slow; users are
#' strongly encouraged to set `limit` (and ideally `query`) when exploring.
#'
#' @section Filter coverage (v0.1):
#' Only filters that map cleanly to portal-side parameters or to extractable
#' detail-page fields are active in this version:
#'
#' * `query` — passed straight through as the server-side `q` parameter
#'   (real full-text search, not a client-side substring match).
#' * `date_range` — matches against `date_decision`, which on this portal
#'   carries the **"Zuletzt geaendert"** date (last-modified timestamp shown
#'   in the detail page header).
#' * `jurisdiction` — substring match against the federal-state partner
#'   (from `div.teaser-logo-partner img[alt]`, e.g. `"Baden-Württemberg"`).
#'
#' The portal's `procedure=` facet (Zulassungsverfahren, Bauleitplanung,
#' etc.) is reserved for a future release.
#'
#' @section Attachments: per-page section split:
#' UVP detail pages group documents under `h4.title-font` headings. The set of
#' headings is **open-ended and discovered per page** rather than fixed: every
#' heading that carries documents becomes its own parallel list-column
#' `attachment_urls_<slug>` / `local_path_<slug>`, and the per-file `section`
#' tag is persisted in the sidecar JSON. Known headings get a stable, curated
#' slug; any other heading is auto-slugged from its title (German digraphs
#' transliterated to ASCII), so a newly-appearing section type is captured
#' without a code change.
#'
#' Curated slugs (see the internal `de_section_map()`):
#'
#' * `uvp_bericht` — *"UVP-Bericht, ggf. Antragsunterlagen"* (the UVP report
#'   itself plus the applicant's project documents — the substantive documents
#'   for downstream analysis).
#' * `berichte` — *"Berichte und Empfehlungen"* (technical reports and
#'   recommendations).
#' * `entscheidung` — *"Entscheidung"* (the decision / Bescheid documents).
#' * `auslegung` — *"Auslegungsinformationen"* (public-consultation notices).
#' * `weitere` — *"Weitere Unterlagen"* (catch-all section; often very large).
#'
#' `attachment_urls` / `local_path` are the deduplicated union across all
#' discovered sections, ordered curated-first (in the order above) then any
#' auto-slugged sections in page order. Required by the planscanR schema.
#'
#' When `download = TRUE`, files in **all** discovered sections are fetched —
#' subject to `max_file_size_mb` and the relevance threshold. (The
#' `data-raw/biogain_acquire.R` runbook can restrict downloads to a chosen
#' subset of sections; the handler itself always captures them all.)
#'
#' @param date_range Length-2 vector `c(from, to)` of dates or parseable
#'   strings. Filters by `date_decision`.
#' @param limit Integer. Maximum records to return. Defaults to `Inf`; you
#'   are strongly encouraged to set a small value (e.g. `50`) when exploring,
#'   because a cold-cache full crawl enumerates all ~2,258 search pages.
#' @param download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh
#'   See [get_assessments()].
#' @param topic,relevance_threshold,relevance_model Forwarded from
#'   [get_assessments()]. `relevance_threshold` **only affects downloading**:
#'   records below it keep their sidecar and their tibble row, only their PDFs
#'   are skipped.
#' @param query Free-text search string. Sent server-side as `q=<query>`.
#'   When `NULL`, the broad fallback `q=uvp` is used (matches ~93% of the
#'   register). The portal's own `q=*:*` wildcard is unusable because page 2+
#'   never renders — see the *URL enumeration* section.
#' @param jurisdiction Character vector. Substring match on the
#'   federal-state partner displayed on each detail page
#'   (e.g. `jurisdiction = "Bayern"` keeps Bavarian records).
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_de(limit = 3, download = FALSE)
#'
#' # Wind-energy search
#' get_assessments_de(query = "windenergie", limit = 20, download = FALSE)
#'
#' # Date range
#' get_assessments_de(
#'   date_range = c("2024-01-01", "2024-12-31"),
#'   limit = 20,
#'   download = FALSE
#' )
#' }
get_assessments_de <- function(
  date_range = NULL,
  limit = Inf,
  download = TRUE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  jurisdiction = NULL,
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

  rel <- setup_relevance(topic, relevance_model, country = "de")

  if (is.null(query) && !is.finite(limit)) {
    de_warn_full_crawl()
  }

  sidecar_index <- if (!refresh) {
    sidecar_url_index("de")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Streaming page-by-page crawl. We pull one search-result page, fan its
  # docuuids out into per-record fetch + parse + score + sidecar, then move
  # to the next search page. This means:
  #   * a record lands on disk within ~200 ms of its docuuid being discovered
  #     (the prior fetch-all-URLs-then-process design forced ~9 min of pure
  #     URL enumeration before *any* record could be persisted);
  #   * `limit` early-exit stops both loops, so a small limit actually fetches
  #     a small number of pages instead of paginating the whole register;
  #   * a crash leaves whatever was already sidecared on disk and the next
  #     call resumes via the sidecar short-circuit.
  base <- "https://www.uvp-verbund.de"
  records <- list()
  seen_uuids <- character(0)
  page <- 1L
  max_pages <- 3000L
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling DE  ",
      "page {page}  |  records {length(records)}",
      if (is.finite(limit)) paste0("/", limit) else "",
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = if (is.finite(limit)) limit else NA,
    clear = FALSE
  )
  on.exit(cli::cli_progress_done(), add = TRUE)

  while (length(records) < limit && page <= max_pages) {
    page_uuids <- tryCatch(de_search_page(query, page), error = function(e) {
      warn_partial("Failed to fetch search page {page}: {conditionMessage(e)}")
      character(0)
    })
    new_uuids <- page_uuids[!tolower(page_uuids) %in% tolower(seen_uuids)]
    if (length(new_uuids) == 0L) {
      break
    }
    seen_uuids <- c(seen_uuids, new_uuids)
    for (uuid in new_uuids) {
      if (length(records) >= limit) {
        break
      }
      u <- paste0(base, "/trefferanzeige?docuuid=", uuid)
      rec <- tryCatch(de_load_or_fetch(u, sidecar_index), error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      })
      if (is.null(rec)) {
        next
      }
      if (!de_record_matches(rec, date_range = date_range, jurisdiction = jurisdiction)) {
        next
      }
      if (!is.null(rel)) {
        rec <- apply_relevance(rec, rel)
      }
      should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
      rec <- de_finalise_record(
        rec,
        download = should_download,
        overwrite = overwrite,
        max_file_size_mb = max_file_size_mb,
        write_sidecar = write_sidecar
      )
      records[[length(records) + 1L]] <- rec
      cli::cli_progress_update()
    }
    page <- page + 1L
  }

  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

#' Curated map from UVP-Verbund's known German section H4 titles to stable
#' planscanR slugs.
#'
#' This is NOT an exhaustive list of what the portal can show — it's the set
#' of titles we give a hand-picked, stable slug to. Any heading not listed
#' here is still captured by [de_parse_detail()]; it just gets an auto-slug
#' from [de_section_slug()] instead of a curated one. The map also fixes the
#' canonical ordering of the deduplicated `attachment_urls` union (these
#' first, substantive sections leading).
#'
#' Slugs become column suffixes (`attachment_urls_<slug>` /
#' `local_path_<slug>`) and the per-file `section` tag inside the sidecar JSON.
#' @noRd
de_section_map <- function() {
  c(
    "UVP-Bericht, ggf. Antragsunterlagen" = "uvp_bericht",
    "Berichte und Empfehlungen" = "berichte",
    "Entscheidung" = "entscheidung",
    "Auslegungsinformationen" = "auslegung",
    "Weitere Unterlagen" = "weitere"
  )
}

#' List the distinct document-section headings present on a detail page.
#'
#' The portal renders each attachment group under an `h4.title-font` heading.
#' We collapse internal whitespace (so the value lines up with the
#' `normalize-space()` comparison in [de_section_pdfs()]) and de-duplicate, so
#' a page that repeats a heading is visited once.
#' @noRd
de_document_section_titles <- function(html) {
  nodes <- rvest::html_elements(html, "h4.title-font")
  if (length(nodes) == 0L) {
    return(character(0))
  }
  titles <- gsub("\\s+", " ", rvest::html_text(nodes, trim = TRUE))
  unique(titles[nzchar(titles)])
}

#' Map a section heading to a column/sidecar slug.
#'
#' Known headings (see [de_section_map()]) get their curated slug. Everything
#' else is auto-slugged from the title: German digraphs are transliterated
#' (ae/oe/ue/ss) so the slug is ASCII, then lowercased with non-alphanumerics
#' collapsed to underscores. This is what lets a previously-unseen section
#' type (e.g. "Entscheidung" before it was curated, or any future heading)
#' flow through to its own `attachment_urls_<slug>` column and sidecar tag
#' without a code change.
#' @noRd
de_section_slug <- function(title) {
  curated <- de_section_map()
  if (title %in% names(curated)) {
    return(unname(curated[[title]]))
  }
  s <- title
  s <- gsub("\u00e4", "ae", s)
  s <- gsub("\u00f6", "oe", s)
  s <- gsub("\u00fc", "ue", s)
  s <- gsub("\u00df", "ss", s)
  s <- gsub("\u00c4", "ae", s)
  s <- gsub("\u00d6", "oe", s)
  s <- gsub("\u00dc", "ue", s)
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "section" else s
}

#' One-shot warning that an unconstrained full crawl will be slow.
#' @noRd
de_warn_full_crawl <- function() {
  if (isTRUE(getOption("planscanR.de_fullcrawl_warned"))) {
    return(invisible())
  }
  warn_partial(c(
    "Enumerating the UVP-Verbund register with the default fallback query (`q=uvp`, ~22,574 records across ~2,258 search pages) on a cold cache will take many minutes.",
    i = "Set {.arg limit} (and ideally {.arg query}) when exploring."
  ))
  options(planscanR.de_fullcrawl_warned = TRUE)
  invisible()
}

# -----------------------------------------------------------------------------
# URL enumeration
# -----------------------------------------------------------------------------

#' Fetch one search-result page and return its docuuids (case preserved).
#'
#' Builds the `freitextsuche?q=<...>&toggle_procedure=&ranking=score&page=<n>`
#' request, fetches the HTML, and pulls every `?docuuid=<...>` anchor out of
#' it. Duplicates within the page (each card has both a title and image
#' anchor pointing to the same uuid) are dropped. Cross-page dedup is the
#' caller's responsibility — the streaming crawl in `get_assessments_de()`
#' carries a `seen_uuids` ledger across pages.
#'
#' @param query Optional free-text query. `NULL` -> `q=uvp` (paginating
#'   fallback; the portal's Solr `*:*` doesn't paginate past page 1).
#' @param page 1-based page index.
#' @return Character vector of docuuids found on that page (case preserved;
#'   the portal's detail-page route is case-sensitive). Empty vector on
#'   network failure or an empty page.
#' @noRd
de_search_page <- function(query, page) {
  base <- "https://www.uvp-verbund.de"
  q <- if (is.null(query) || !nzchar(query)) "uvp" else query
  req <- req_planscanr(base, "freitextsuche")
  req <- httr2::req_url_query(
    req,
    q = q,
    toggle_procedure = "",
    ranking = "score",
    page = page
  )
  html <- perform_html(req)
  de_extract_uuids(html)
}

#' Extract docuuids from a search-results HTML page.
#' @noRd
de_extract_uuids <- function(html) {
  links <- rvest::html_elements(
    html,
    xpath = "//a[contains(@href, '/trefferanzeige?docuuid=')]"
  )
  if (length(links) == 0L) {
    return(character(0))
  }
  hrefs <- rvest::html_attr(links, "href")
  # Portal mixes lowercase and uppercase hex UUIDs (and a handful of pure-digit
  # legacy IDs); accept both. Dedup is case-insensitive but the original case
  # is preserved in the returned string because the portal's detail-page route
  # IS case-sensitive — lowercasing the uuid in the URL yields an empty page.
  m <- regmatches(hrefs, regexpr("docuuid=[A-Fa-f0-9-]+", hrefs))
  uuids <- sub("^docuuid=", "", m)
  uuids[!duplicated(tolower(uuids))]
}

# -----------------------------------------------------------------------------
# Detail-page parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper around the detail-page parser.
#' @noRd
de_load_or_fetch <- function(url, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  de_parse_detail(url)
}

#' Parse a single UVP-Verbund detail page into a 1-row tibble.
#' @noRd
de_parse_detail <- function(url) {
  req <- req_planscanr(url)
  html <- perform_html(req)

  docuuid <- de_docuuid_from_url(url)

  title <- rvest::html_text(rvest::html_element(html, "h1"), trim = TRUE)
  if (is.null(title) || is.na(title) || !nzchar(title)) {
    title <- NA_character_
  } else {
    title <- gsub("\\s+", " ", title)
  }

  date_decision <- de_parse_german_date(
    de_strip_label(
      rvest::html_text(
        rvest::html_element(html, "div.helper.text.date span"),
        trim = TRUE
      ),
      "Zuletzt ge\u00e4ndert"
    )
  )

  summary <- rvest::html_text(
    rvest::html_element(
      html,
      xpath = "//h3[contains(normalize-space(.),'Allgemeine Vorhabenbeschreibung')]/following-sibling::p[1]"
    ),
    trim = TRUE
  )
  if (is.null(summary) || is.na(summary) || !nzchar(summary)) {
    summary <- NA_character_
  } else {
    summary <- gsub("\\s+", " ", summary)
  }

  native_type <- rvest::html_text(
    rvest::html_element(
      html,
      xpath = "//h3[contains(normalize-space(.),'UVP-Kategorie')]/following-sibling::div//span[contains(@class,'text')][1]"
    ),
    trim = TRUE
  )
  if (is.null(native_type) || is.na(native_type) || !nzchar(native_type)) {
    native_type <- NA_character_
  }

  jurisdiction <- rvest::html_attr(
    rvest::html_element(html, "div.teaser-logo-partner img"),
    "alt"
  )
  if (is.null(jurisdiction) || is.na(jurisdiction) || !nzchar(jurisdiction)) {
    jurisdiction <- NA_character_
  }

  competent_authority <- de_extract_competent_authority(html)

  # Document sections. The portal groups attachments under `h4.title-font`
  # headings, but the set is open-ended: beyond the common four (UVP-Bericht,
  # Berichte, Auslegung, Weitere) pages also carry e.g. "Entscheidung", and
  # occasionally repeat a heading. So we DISCOVER whatever headings the page
  # actually has rather than assuming a fixed list. Known titles get a stable
  # curated slug from `de_section_map()`; anything else is auto-slugged from
  # its title, so a newly-appearing section type is captured and
  # section-tagged in the sidecar without any code change.
  per_section <- list()
  for (title_de in de_document_section_titles(html)) {
    urls <- de_section_pdfs(html, title_de)
    if (length(urls) == 0L) {
      next
    }
    slug <- de_section_slug(title_de)
    # Merge if two headings map to the same slug (e.g. a page with two
    # separate "Auslegungsinformationen" blocks).
    per_section[[slug]] <- unique(c(per_section[[slug]], urls))
  }

  # Union ordering: curated sections first in their canonical order, then any
  # auto-slugged sections in the order they appeared on the page.
  curated_slugs <- unname(de_section_map())
  slug_order <- c(
    intersect(curated_slugs, names(per_section)),
    setdiff(names(per_section), curated_slugs)
  )
  ordered_union <- unique(unlist(per_section[slug_order], use.names = FALSE))
  if (is.null(ordered_union)) {
    ordered_union <- character(0)
  }

  rec <- tibble::tibble(
    country = "de",
    source_portal = "uvp-verbund.de",
    document_id = docuuid,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(ordered_union),
    local_path = list(character(0)),
    title = title,
    summary = summary,
    competent_authority = competent_authority %||% NA_character_,
    proponent = NA_character_, # not a labelled field on UVP-Verbund detail pages
    native_type = native_type,
    jurisdiction = jurisdiction,
    date_decision = date_decision,
    download_status = list(empty_download_status())
  )
  # Attach the per-section list-columns (only for sections that actually had
  # documents on this page; absent sections simply have no column, and
  # `bind_results()` pads them when binding heterogeneous records).
  for (slug in slug_order) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Extract docuuid from a `?docuuid=<uuid>` URL.
#' @noRd
de_docuuid_from_url <- function(url) {
  m <- regmatches(url, regexpr("docuuid=[A-Fa-f0-9-]+", url))
  if (length(m) == 0L) {
    return(NA_character_)
  }
  sub("^docuuid=", "", m[1])
}

#' Extract PDF (and generic attachment) URLs from a specific H4 section.
#'
#' Each documents section under `h4.title-font` has the same structure: the
#' next sibling div contains the file list. We follow every `a.link.download`
#' inside, treating non-PDFs (e.g. zipped raster overlays the portal serves)
#' the same way — they're still attachments worth caching for downstream
#' analysis. Returns absolute URLs.
#' @noRd
de_section_pdfs <- function(html, section_title) {
  literal <- shQuote(section_title, type = "sh")
  xp <- sprintf(
    "//h4[contains(@class,'title-font') and normalize-space(.) = %s]/following-sibling::div[1]//a[contains(@class,'link') and contains(@class,'download')]",
    literal
  )
  nodes <- rvest::html_elements(html, xpath = xp)
  if (length(nodes) == 0L) {
    return(character(0))
  }
  hrefs <- rvest::html_attr(nodes, "href")
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  # Some links may be protocol-relative or root-relative.
  abs <- vapply(hrefs, de_absolutise, character(1), USE.NAMES = FALSE)
  unique(abs)
}

#' Convert a possibly-relative href into an absolute URL rooted at the portal.
#' @noRd
de_absolutise <- function(href) {
  if (grepl("^https?://", href)) {
    return(href)
  }
  if (startsWith(href, "//")) {
    return(paste0("https:", href))
  }
  if (startsWith(href, "/")) {
    return(paste0("https://www.uvp-verbund.de", href))
  }
  # Truly relative; rare on this portal. Best-effort: rebase on root.
  paste0("https://www.uvp-verbund.de/", href)
}

#' Strip a leading label from a value string (e.g. "Zuletzt geändert 24.02.2026" → "24.02.2026").
#' @noRd
de_strip_label <- function(s, label) {
  if (is.null(s) || is.na(s) || !nzchar(s)) {
    return(NA_character_)
  }
  s <- trimws(s)
  pat <- paste0("^", label, "\\s+")
  sub(pat, "", s)
}

#' Pull the competent authority from the "Ansprechpartner" block under "Adressen".
#'
#' The first `<p>` after the `<h4>Ansprechpartner</h4>` block holds the
#' authority name(s), often spanning multiple lines (LRA + Regierungspräsidium,
#' etc.). We collapse internal whitespace.
#' @noRd
de_extract_competent_authority <- function(html) {
  node <- rvest::html_element(
    html,
    xpath = "//h4[contains(normalize-space(.),'Ansprechpartner')]/following-sibling::p[1]"
  )
  if (inherits(node, "xml_missing")) {
    return(NA_character_)
  }
  txt <- rvest::html_text(node, trim = TRUE)
  if (is.null(txt) || is.na(txt) || !nzchar(txt)) {
    return(NA_character_)
  }
  # Multi-line authority blocks get collapsed to a single comma-joined line so
  # the field is queryable with substring matches (e.g. jurisdiction filter).
  parts <- strsplit(txt, "\n", fixed = TRUE)[[1]]
  parts <- trimws(parts)
  parts <- parts[nzchar(parts)]
  paste(parts, collapse = ", ")
}

#' Parse a German-formatted date like "24.02.2026" into a Date.
#' @noRd
de_parse_german_date <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  s <- trimws(s)
  m <- regmatches(s, regexpr("^([0-9]{1,2})\\.([0-9]{1,2})\\.([0-9]{4})", s))
  if (length(m) == 0L) {
    return(as.Date(NA))
  }
  parts <- strsplit(m, "\\.")[[1]]
  day <- suppressWarnings(as.integer(parts[1]))
  mon <- suppressWarnings(as.integer(parts[2]))
  yr <- suppressWarnings(as.integer(parts[3]))
  if (is.na(day) || is.na(mon) || is.na(yr)) {
    return(as.Date(NA))
  }
  as.Date(sprintf("%04d-%02d-%02d", yr, mon, day))
}

# -----------------------------------------------------------------------------
# Per-record finalise (downloads + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed record: run downloads (if requested) and write the sidecar.
#'
#' Mirrors `nl_finalise_record()`. The sidecar is always written when
#' `write_sidecar = TRUE`, even if `download = FALSE` — in that case the
#' `download_status` carries one `"pending"` row per attachment URL so the
#' sidecar still records what was found on the page.
#' @noRd
de_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  get_section <- function(col) {
    v <- rec[[col]]
    if (is.null(v)) character(0) else v[[1]]
  }
  urls <- get_section("attachment_urls")
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)

  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "de"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "de",
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
  # Populate `local_path_<section>` parallel to each `attachment_urls_<section>`.
  for (col in section_cols) {
    slug <- sub("^attachment_urls_", "", col)
    sec_urls <- get_section(col)
    rec[[paste0("local_path_", slug)]] <- list(ds$local_path[match(sec_urls, ds$url)])
  }
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

#' Apply client-side filters to a single parsed DE record.
#' @noRd
de_record_matches <- function(rec, date_range, jurisdiction) {
  if (!is.null(date_range)) {
    d <- rec$date_decision
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  if (!is.null(jurisdiction)) {
    j <- rec$jurisdiction %||% ""
    if (!any(vapply(jurisdiction, function(p) grepl(p, j, ignore.case = TRUE), logical(1)))) {
      return(FALSE)
    }
  }
  TRUE
}
