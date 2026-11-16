#' Fetch Asian Infrastructure Investment Bank projects (explicit source `aiib`).
#'
#' Implementation of the explicit source `"aiib"` for
#' `get_assessments("cn", source = "aiib")`: the public AIIB project register
#' (<https://www.aiib.org/en/projects/list/>) with the project documents
#' (ESIA, ESMP, IEE, RAP, ESMPF, monitoring reports, procurement notices, ...)
#' linked from each project page. AIIB is an international development bank,
#' not a national EIA register: only some projects (mostly Category A/B
#' sovereign loans) publish an environmental and social assessment, and
#' Category C, financial-intermediary and policy projects often have none.
#'
#' @section Enumeration:
#' One `GET` of `/en/projects/list/.content/all-projects-data.js` returns the
#' whole register as a JavaScript assignment (`var data=[...]`, with a trailing
#' comma). The wrapper is stripped and the array parsed; an unexpected shape
#' aborts with `planscanR_error_bad_response`. There is no pagination. The
#' record key is the listing `path` (unique); `document_id` is
#' `"aiib_<slug of path>"`. Because the path contains the status segment, a
#' project that moves from proposed to approved gets a new path and thus a new
#' `document_id`. The project number (e.g. `000543`) is only shown on the
#' detail page and is kept as `project_number`. The complete raw listing row
#' is kept as `listing_json`.
#'
#' @section Detail pages and attachments:
#' The project page is fetched for every returned record (sidecar-first, so
#' bounded by `limit`). Every link in the page's `div.doc` columns (and any
#' stray `div.link a`) is captured, grouped by the native section heading
#' (`attachment_urls_<heading slug>`, e.g. `aiib_documents`,
#' `client_cofinancing_partner_documents`, `procurement_documents`). The label
#' is the full native link text, including any caption text before the link and
#' the language suffix (`attachment_labels_<slug>`, parallel to the URLs); no
#' role or eligibility classification is applied, so consumers decide what
#' counts as an assessment. Links to hosts outside `aiib.org` (partner
#' portals) are **not** downloaded; they are kept as listed URLs in
#' `external_urls_<slug>` (labels in `external_labels_<slug>`). `documents_json`
#' holds every link with section, label, URL and an external flag. Also kept:
#' `summary` (the DESCRIPTION text), `objective`, `sector`, `status`,
#' `es_category`, `project_number`, `borrower`, `implementing_entity`
#' (organisation lines only: person names, titles and e-mail addresses are not
#' stored), `detail_fields_json` (all summary/financing/timeline items),
#' `paragraphs_json` and `news_json`. `date_published` is the "FINANCING
#' APPROVAL" date when the page shows one with a full day.
#'
#' A failed detail fetch, or a 200 page without the expected project and
#' document containers, yields a listing-only record with
#' `detail_status = "failed"` and a `planscanR_warning_partial`; it is not
#' written to the sidecar cache, so the next run retries it.
#'
#' @section Geography:
#' AIIB uses English country names (field `economy`), not ISO codes. The ISO-2
#' `country` is mapped through an internal table (see [aiib_country_names()]);
#' records are matched on the `economy` field, not on the name prefix (the
#' two disagree for a few rows; both are kept: `economy`, `name_prefix`). A
#' valid code absent from the table (including the NL/DE/DK/AT focus
#' countries, which AIIB does not finance) is an error; a mapped code with no
#' rows returns a typed empty result. Records with `economy = "Multicountry"`
#' have no member list and are excluded from every country-filtered result.
#' Output `country` is the requested code. After parsing, economy values not
#' in the table raise a `planscanR_warning_partial`.
#'
#' @section Filters:
#' * `query`: case-insensitive substring on name, economy and sector.
#' * `status`: native listing status (e.g. `"Approved"`), case-insensitive.
#' * `date_range`: against the listing approval year (proposed projects, shown
#'   as `-`, are excluded when a range is given).
#'
#' @param country ISO-2 code (supplied by [get_assessments()]).
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query,status See the Filters section.
#' @param ... Unused; unknown arguments are warned about.
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments_sources()]
#' @keywords internal
#' @noRd
get_assessments_aiib <- function(
  country,
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
  status = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  assert_iso2_format(country)
  tbl <- aiib_country_names()
  if (!country %in% names(tbl)) {
    cli::cli_abort(
      c(
        "AIIB has no country name mapped for {.val {country}}.",
        i = "Mapped codes: {.val {names(tbl)}}. AIIB projects are mostly in Asia; the NL/DE/DK/AT focus countries have none."
      ),
      class = "planscanR_error_bad_input"
    )
  }
  date_range <- parse_date_range(date_range)
  if (!is.null(status) && (!is.character(status) || length(status) != 1L || is.na(status))) {
    cli::cli_abort("{.arg status} must be a single non-NA string.", class = "planscanR_error_bad_input")
  }
  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rel <- setup_relevance(topic, relevance_model, country = country)
  sidecar_index <- if (!refresh) {
    sidecar_url_index(country)
  } else {
    stats::setNames(character(0), character(0))
  }

  rows <- aiib_fetch_listing()
  target <- aiib_norm_name(tbl[[country]])
  keep <- vapply(rows, function(r) identical(aiib_norm_name(r$economy), target), logical(1))
  rows <- rows[keep]
  rows <- Filter(function(r) aiib_listing_matches(r, query, status, date_range), rows)

  process_entry <- function(entry) {
    u <- aiib_url(entry$path)
    hit <- sidecar_index[u]
    rec <- if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
      read_record_sidecar(hit)
    } else {
      tryCatch(
        {
          detail <- perform_html(req_planscanr(u))
          aiib_build_record(entry, country, aiib_parse_detail(detail))
        },
        error = function(e) {
          warn_partial("AIIB detail page {.url {u}} failed, record is listing-only: {conditionMessage(e)}")
          aiib_build_record(entry, country, NULL)
        }
      )
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    aiib_finalise_record(rec, should_download, overwrite, max_file_size_mb, write_sidecar)
  }

  done <- FALSE
  gen <- function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    rows
  }
  records <- stream_crawl(gen, process_entry, limit = limit, label = country)
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

aiib_source_portal <- function() "aiib.org"

aiib_base <- function() "https://www.aiib.org"

aiib_url <- function(path) paste0(aiib_base(), path)

#' ISO-2 -> AIIB economy name.
#'
#' Generated from the distinct `economy` values of `all-projects-data.js`
#' (regenerate: parse the file, `sort(unique(economy))`, map each name to its
#' ISO-3166-1 alpha-2 code; "Multicountry" is a sentinel and deliberately
#' unmapped). Non-ASCII names use escapes.
#' @noRd
aiib_country_names <- function() {
  c(
    dz = "Algeria",
    ar = "Argentina",
    am = "Armenia",
    az = "Azerbaijan",
    bh = "Bahrain",
    bd = "Bangladesh",
    bj = "Benin",
    br = "Brazil",
    kh = "Cambodia",
    cn = "China",
    ck = "Cook Islands",
    ci = "C\u00f4te d'Ivoire",
    ec = "Ecuador",
    eg = "Egypt",
    sv = "El Salvador",
    fj = "Fiji",
    ge = "Georgia",
    hk = "Hong Kong, China",
    hu = "Hungary",
    `in` = "India",
    id = "Indonesia",
    jo = "Jordan",
    kz = "Kazakhstan",
    kg = "Kyrgyzstan",
    la = "Lao PDR",
    mg = "Madagascar",
    my = "Malaysia",
    mv = "Maldives",
    mn = "Mongolia",
    ma = "Morocco",
    mm = "Myanmar",
    np = "Nepal",
    om = "Oman",
    pk = "Pakistan",
    pg = "Papua New Guinea",
    ph = "Philippines",
    ro = "Romania",
    ru = "Russian Federation",
    rw = "Rwanda",
    sa = "Saudi Arabia",
    sg = "Singapore",
    za = "South Africa",
    lk = "Sri Lanka",
    tj = "Tajikistan",
    th = "Thailand",
    tg = "Togo",
    tr = "T\u00fcrkiye",
    ae = "United Arab Emirates",
    uz = "Uzbekistan",
    vn = "Viet Nam"
  )
}

#' Normalise a name for comparison (typographic apostrophe, whitespace).
#' @noRd
aiib_norm_name <- function(x) {
  x <- as.character(x %||% NA_character_)
  trimws(gsub("[\u2019\u2018]", "'", x))
}

#' Perform a GET and return the body as UTF-8 text (mock seam).
#' @noRd
aiib_perform_text <- function(req) {
  httr2::resp_body_string(httr2::req_perform(req), encoding = "UTF-8")
}

#' Parse the JavaScript data file into a list of listing rows.
#' @noRd
aiib_parse_listing <- function(txt) {
  bad <- function(why) {
    cli::cli_abort(
      c("Unexpected AIIB project data file: {why}.", i = "The portal format may have changed."),
      class = "planscanR_error_bad_response"
    )
  }
  if (!is.character(txt) || length(txt) != 1L || is.na(txt)) {
    bad("no text body")
  }
  m <- regmatches(
    txt,
    regexec("(?s)^\\s*(?:var|let|const)?\\s*[A-Za-z_$][A-Za-z0-9_$]*\\s*=\\s*(\\[.*\\])\\s*;?\\s*$", txt, perl = TRUE)
  )[[1]]
  if (length(m) != 2L) {
    bad("not a single array assignment")
  }
  json <- sub(",\\s*\\]$", "]", m[2])
  rows <- tryCatch(jsonlite::fromJSON(json, simplifyVector = FALSE), error = function(e) NULL)
  ok <- is.list(rows) &&
    length(rows) > 0L &&
    all(vapply(
      rows,
      function(r) is.list(r) && is.character(r$path) && nzchar(r$path) && is.character(r$name),
      logical(1)
    ))
  if (!ok) {
    bad("not a non-empty array of project rows with `path` and `name`")
  }
  paths <- vapply(rows, function(r) r$path, character(1))
  if (anyDuplicated(paths)) {
    warn_partial("AIIB data file repeats {sum(duplicated(paths))} path{?s}; duplicates dropped.")
    rows <- rows[!duplicated(paths)]
  }
  rows
}

#' Fetch + parse the listing; warns about economy names not in the table.
#' @noRd
aiib_fetch_listing <- function() {
  req <- req_planscanr(aiib_base())
  req <- httr2::req_url_path_append(req, "en", "projects", "list", ".content", "all-projects-data.js")
  rows <- aiib_parse_listing(aiib_perform_text(req))
  known <- aiib_norm_name(c(aiib_country_names(), "Multicountry"))
  eco <- unique(aiib_norm_name(vapply(rows, function(r) r$economy %||% NA_character_, character(1))))
  unk <- setdiff(eco, known)
  if (length(unk) > 0L) {
    warn_partial(
      "AIIB lists economy value{?s} not in the ISO table (new or renamed?): {.val {unk}}. Those projects cannot be matched by country."
    )
  }
  rows
}

#' Client-side filters on a listing row.
#' @noRd
aiib_listing_matches <- function(r, query, status, date_range) {
  if (!is.null(status) && !identical(tolower(r$status %||% ""), tolower(status))) {
    return(FALSE)
  }
  if (!is.null(query)) {
    hay <- tolower(paste(r$name, r$economy, r$sector, sep = " | "))
    if (!grepl(tolower(query), hay, fixed = TRUE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    yr <- suppressWarnings(as.integer(r$date %||% NA_character_))
    from <- as.integer(format(date_range[1], "%Y"))
    to <- as.integer(format(date_range[2], "%Y"))
    if (is.na(yr) || yr < from || yr > to) {
      return(FALSE)
    }
  }
  TRUE
}

aiib_text <- function(x) {
  x <- gsub("[[:space:]\u00a0]+", " ", x)
  trimws(x)
}

aiib_chr <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(NA_character_)
  }
  x <- as.character(x)
  if (nzchar(trimws(x))) x else NA_character_
}

#' Parse a project detail page (xml_document). Errors if the project or
#' document containers are missing (so the caller treats it as a failure).
#' @noRd
aiib_parse_detail <- function(page) {
  title <- rvest::html_element(page, "h1.project-name")
  docs_box <- rvest::html_elements(page, ".feature-documents")
  if (inherits(title, "xml_missing") || length(docs_box) == 0L) {
    cli::cli_abort(
      "Page lacks the expected project title or document container.",
      class = "planscanR_error_bad_response"
    )
  }
  items <- rvest::html_elements(page, ".summary-item")
  fields <- stats::setNames(
    lapply(items, function(i) aiib_text(rvest::html_text(rvest::html_element(i, ".summary-item-value")))),
    vapply(items, function(i) aiib_text(rvest::html_text(rvest::html_element(i, ".summary-item-name"))), character(1))
  )

  paras <- rvest::html_elements(page, "div.paragraph")
  para <- list()
  borrower <- NA_character_
  implementing <- NA_character_
  news <- list()
  for (p in paras) {
    h <- rvest::html_element(p, "h2")
    if (inherits(h, "xml_missing")) {
      next
    }
    hn <- aiib_text(rvest::html_text(h))
    cls <- rvest::html_attr(h, "class") %||% ""
    if (grepl("news-title", cls, fixed = TRUE)) {
      for (a in rvest::html_elements(p, "a[href]")) {
        news[[length(news) + 1L]] <- list(
          title = aiib_text(rvest::html_text(a)),
          url = aiib_abs(rvest::html_attr(a, "href"))
        )
      }
    } else if (grepl("borrower-content|implementing-content", as.character(p))) {
      # the project team leader block (a person) is deliberately not stored
      if (grepl("^BORROWER", hn)) {
        borrower <- aiib_org_line(p)
      }
      if (grepl("^IMPLEMENTING", hn)) implementing <- aiib_org_line(p)
    } else if (nzchar(hn) && !grepl("headline", cls, fixed = TRUE)) {
      para[[hn]] <- aiib_text(sub(hn, "", rvest::html_text(p), fixed = TRUE))
    }
  }

  links <- list()
  cols <- rvest::html_elements(page, "div.doc")
  for (col in cols) {
    sec <- ascii_slug(rvest::html_text(rvest::html_element(col, ".headline")), "documents")
    for (a in rvest::html_elements(col, "a[href]")) {
      links[[length(links) + 1L]] <- aiib_link(a, sec)
    }
  }
  for (a in rvest::html_elements(page, "div.link a[href]")) {
    if (length(rvest::html_elements(a, xpath = "ancestor::div[contains(@class,'doc')]")) == 0L) {
      links[[length(links) + 1L]] <- aiib_link(a, "documents")
    }
  }
  links <- Filter(Negate(is.null), links)
  list(
    title = aiib_text(rvest::html_text(title)),
    fields = fields,
    paragraphs = para,
    borrower = borrower,
    implementing_entity = implementing,
    news = news,
    links = links
  )
}

#' Organisation text of a borrower / implementing block: the paragraphs that
#' are neither bold-only (person or unit names) nor e-mail lines, joined.
#' @noRd
aiib_org_line <- function(node) {
  keep <- Filter(
    function(p) {
      length(rvest::html_elements(p, "a[href^='mailto:']")) == 0L && length(rvest::html_elements(p, "strong")) == 0L
    },
    as.list(rvest::html_elements(node, "p"))
  )
  txt <- aiib_text(vapply(keep, function(p) rvest::html_text(p), character(1)))
  txt <- txt[nzchar(txt)]
  if (length(txt) == 0L) NA_character_ else paste(txt, collapse = "; ")
}

#' Resolve a href against the AIIB host; NA for mailto/javascript/anchors.
#' @noRd
aiib_abs <- function(href) {
  href <- trimws(href %||% "")
  if (!nzchar(href) || grepl("^(mailto:|javascript:|#|tel:)", href, ignore.case = TRUE)) {
    return(NA_character_)
  }
  if (grepl("^//", href)) {
    href <- paste0("https:", href)
  }
  if (grepl("^https?://", href, ignore.case = TRUE)) {
    return(utils::URLencode(sub("^http://([^/]*aiib\\.org)", "https://\\1", href, ignore.case = TRUE)))
  }
  utils::URLencode(paste0(aiib_base(), if (!startsWith(href, "/")) "/", href))
}

aiib_is_internal <- function(url) {
  host <- sub("^https?://([^/:?#]+).*$", "\\1", tolower(url))
  host == "aiib.org" || endsWith(host, ".aiib.org")
}

#' One link: full native text (caption text before the anchor + anchor text).
#' @noRd
aiib_link <- function(a, section) {
  url <- aiib_abs(rvest::html_attr(a, "href"))
  if (is.na(url)) {
    return(NULL)
  }
  before <- rvest::html_text(rvest::html_elements(a, xpath = "preceding-sibling::text()"))
  label <- aiib_text(paste(c(before, rvest::html_text(a)), collapse = " "))
  list(section = section, label = label, url = url, external = !aiib_is_internal(url))
}

#' Parse "November 25, 2021" (full day only) to Date, else NA.
#' @noRd
aiib_date <- function(x) {
  x <- aiib_chr(x)
  if (is.na(x) || !grepl("^[A-Za-z]+ [0-9]{1,2}, [0-9]{4}$", x)) {
    return(as.Date(NA))
  }
  withr::with_locale(c(LC_TIME = "C"), as.Date(strptime(x, "%B %d, %Y", tz = "UTC")))
}

#' Build the 1-row record from a listing row and parsed detail (or NULL when
#' the detail fetch failed).
#' @noRd
aiib_build_record <- function(entry, country, d) {
  json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null"))
  f <- function(nm) if (is.null(d)) NA_character_ else aiib_chr(d$fields[[nm]])
  slug <- ascii_slug(sub("\\.html$", "", sub("^/en/projects/", "", entry$path)), "project")
  links <- if (is.null(d)) list() else d$links
  sections <- unique(vapply(links, function(l) l$section, character(1)))
  nm <- entry$name %||% NA_character_
  pref <- if (grepl(":", nm, fixed = TRUE)) aiib_text(sub(":.*$", "", nm)) else NA_character_
  desc <- if (is.null(d)) NA_character_ else aiib_chr(d$paragraphs[["DESCRIPTION"]])
  obj <- if (is.null(d)) NA_character_ else aiib_chr(d$paragraphs[["OBJECTIVE"]])

  rec <- tibble::tibble(
    country = country,
    source_portal = aiib_source_portal(),
    document_id = paste0("aiib_", slug),
    url = aiib_url(entry$path),
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0)),
    title = if (is.null(d)) aiib_chr(nm) else d$title,
    summary = if (is.na(desc)) obj else desc,
    competent_authority = NA_character_,
    proponent = if (is.null(d)) NA_character_ else aiib_chr(d$borrower),
    date_published = if (is.null(d)) as.Date(NA) else aiib_date(d$fields[["FINANCING APPROVAL"]]),
    date_decision = as.Date(NA),
    native_type = if (identical(entry$project_type, "NULL")) NA_character_ else aiib_chr(entry$project_type),
    status = aiib_chr(entry$status),
    economy = aiib_chr(entry$economy),
    name_prefix = pref,
    sector = aiib_chr(entry$sector),
    financing_type = aiib_chr(entry$financing_type),
    approval_year = aiib_chr(entry$date),
    path = entry$path,
    project_number = f("PROJECT NUMBER"),
    es_category = f("E&S CATEGORY"),
    detail_status = if (is.null(d)) "failed" else "ok",
    objective = obj,
    implementing_entity = if (is.null(d)) NA_character_ else aiib_chr(d$implementing_entity),
    detail_fields_json = if (is.null(d)) NA_character_ else json(d$fields),
    paragraphs_json = if (is.null(d)) NA_character_ else json(d$paragraphs),
    news_json = if (is.null(d)) NA_character_ else json(unname(d$news)),
    documents_json = json(unname(links)),
    listing_json = json(entry),
    download_status = list(empty_download_status())
  )
  # Native listing fields not already columns (keep every native field).
  for (k in setdiff(
    names(entry),
    c("path", "name", "status", "economy", "sector", "date", "financing_type", "project_type")
  )) {
    rec[[paste0("listing_", k)]] <- aiib_chr(entry[[k]])
  }
  internal <- list()
  for (s in sections) {
    sl <- Filter(function(l) l$section == s, links)
    for (ext in c(FALSE, TRUE)) {
      sub_l <- Filter(function(l) identical(l$external, ext), sl)
      u <- vapply(sub_l, function(l) l$url, character(1))
      keep <- !duplicated(u)
      if (!any(keep)) {
        next
      }
      lab <- vapply(sub_l, function(l) l$label, character(1))[keep]
      if (ext) {
        rec[[paste0("external_urls_", s)]] <- list(u[keep])
        rec[[paste0("external_labels_", s)]] <- list(lab)
      } else {
        rec[[paste0("attachment_urls_", s)]] <- list(u[keep])
        rec[[paste0("attachment_labels_", s)]] <- list(lab)
        rec[[paste0("local_path_", s)]] <- list(character(0))
        internal <- c(internal, list(u[keep]))
      }
    }
  }
  rec$attachment_urls <- list(unique(unlist(internal, use.names = FALSE)) %||% character(0))
  rec
}

#' Download (if requested) and write the sidecar; listing-only records are
#' never written so the next run retries the detail page.
#' @noRd
aiib_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  if (download && length(urls) > 0L) {
    inform_download(length(urls), cache_dir(file.path("files", rec$country), create = TRUE))
    ds <- download_attachments(
      urls,
      country = rec$country,
      document_id = rec$document_id,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb
    )
  } else {
    ds <- pending_download_status(urls)
  }
  rec$download_status <- list(ds)
  rec$local_path <- list(ds$local_path)
  for (cn in grep("^attachment_urls_", names(rec), value = TRUE)) {
    sec <- sub("^attachment_urls_", "", cn)
    rec[[paste0("local_path_", sec)]] <- list(ds$local_path[match(rec[[cn]][[1]], ds$url)])
  }
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar && !identical(rec$detail_status, "failed")) {
    tryCatch(
      write_fetched_record_sidecar(rec, downloads = ds),
      error = function(e) {
        warn_partial("Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}")
      }
    )
  }
  rec
}
