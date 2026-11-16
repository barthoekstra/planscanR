#' Fetch environmental-assessment records from Cyprus.
#'
#' Implementation of [get_assessments()] for Cyprus. Backed by the Department
#' of Environment **EIA register** (<https://eia.moa.gov.cy/public/>), a
#' server-rendered HTML portal; records are parsed with `rvest`. Language is
#' Greek (`el`); portal-native values are kept verbatim.
#'
#' @section Coverage window:
#' The portal has no archive or year selector. The only enumerable listing is
#' the **current-year view** (`/public/currentYearView.html`, one finite
#' unpaginated table; completion dates seen 2024-2026). The handler reads that
#' whole table once and never guesses `no=` identifiers, so results are a
#' current-year window, **not national completeness**. The separate SEA
#' register (`/public/sea/`) is not covered (too few enumerable plans with
#' accessible reports).
#'
#' @section Records:
#' Each listing row links to `/public/eiaview.html?no=<id>`. The detail page
#' supplies every key/value metadata row (all kept verbatim in the
#' `native_fields` JSON column) and the *Σχετικά Αρχεία* file table.
#' `document_id` is `"cy_"` plus the native `no`. Both full EIA studies
#' (listing label *ΜΕΕΠ*, kept in `listing_type`) and *Screening* rows are
#' returned; no eligibility rule is applied beyond the native labels
#' (`listing_type`, and `native_type` = the detail *Είδος*). `date_published`
#' is the letter date (*Ημερομηνία Επιστολής*) and `date_decision` the
#' completion date (*Ημερομηνία Ολοκλήρωσης*), both `DD-MM-YYYY`. The project
#' number (`project_number`), file number (`file_number`), `no`
#' (`native_no`), category, district, area and town are extras. The proponent
#' is not a separate field and is `NA`.
#'
#' @section Attachments:
#' Files are grouped by the portal's server folder in the download path
#' (`Meep`, `Gnomatevseis`, `oikologiki axiologisi`, `Bebaiwseis Simmorfwsis`,
#' `Ekthesis Pliroforion`, ...) into `attachment_urls_<slug>` columns (ASCII
#' slugs, e.g. `meep`); the native Greek row labels per slug (*Μελέτη*,
#' *Γνωμάτευση*, ...) are kept in `attachment_labels_native`. Main EIA studies
#' are often `.zip` archives; they are downloaded as-is, never extracted, and
#' are bounded by `max_file_size_mb`. Anonymous downloads. No geometry
#' (coordinates are normally `...`; kept as text in `native_fields`).
#'
#' @section Filter coverage:
#' `query` (case-insensitive title substring) and `date_range` (against
#' `date_published`) are applied client-side; `limit` caps the result. Requests
#' are throttled to 5 req/s (`getOption("planscanR.cy_throttle_rate")`).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query, matched client-side as a
#'   case-insensitive substring of the record title.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' get_assessments_cy(limit = 3, download = FALSE)
#' }
get_assessments_cy <- function(
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
  rate <- getOption("planscanR.cy_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "cy")
  sidecar_index <- if (!refresh) {
    sidecar_url_index("cy")
  } else {
    stats::setNames(character(0), character(0))
  }

  process_entry <- function(entry) {
    rec <- tryCatch(
      cy_load_or_fetch(entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {entry$url}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec) || !cy_record_matches(rec, query = query, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    cy_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  gen <- cy_fetch_search()
  records <- stream_crawl(gen, process_entry, limit = limit, label = "cy")
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

#' @noRd
cy_source_portal <- function() "eia.moa.gov.cy"

#' @noRd
cy_portal_base <- function() "https://eia.moa.gov.cy/public"

#' Absolutise a portal-relative href against `/public/`.
#' @noRd
cy_absolute_url <- function(href) {
  if (grepl("^https?://", href)) {
    return(href)
  }
  paste0(cy_portal_base(), "/", sub("^/+", "", href))
}

#' Native detail-key labels (trailing colon stripped) -> output column.
#' @noRd
cy_key_map <- function() {
  c(
    project_number = "Αριθμός Έργου",
    file_number = "Αριθμός Φακέλου",
    title = "Περιγραφή",
    native_type = "Είδος",
    category = "Κατηγορία",
    district = "Επαρχία",
    area = "Περιοχή",
    competent_authority = "Αρμόδια Αρχή",
    letter_date = "Ημερομηνία Επιστολής",
    completion_date = "Ημερομηνία Ολοκλήρωσης"
  )
}

#' Parse a `DD-MM-YYYY` date; `NA` otherwise.
#' @noRd
cy_parse_date <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x)) {
    return(as.Date(NA))
  }
  m <- regmatches(x, regexpr("[0-9]{1,2}-[0-9]{1,2}-[0-9]{4}", x))
  if (length(m) == 0L) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(as.Date(m, format = "%d-%m-%Y"))
  if (length(d) == 0L) as.Date(NA) else d
}

#' Collapse whitespace and trim.
#' @noRd
cy_text <- function(x) {
  trimws(gsub("[[:space:] ﻿]+", " ", x))
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Fetch the (single, finite) current-year listing. Network seam.
#' @noRd
cy_fetch_listing <- function() {
  req <- req_planscanr(cy_portal_base(), "currentYearView.html")
  perform_html(req)
}

#' Fetch one detail page. Network seam.
#' @noRd
cy_fetch_detail <- function(no) {
  req <- req_planscanr(cy_portal_base(), "eiaview.html")
  req <- httr2::req_url_query(req, no = no)
  perform_html(req)
}

#' Page generator: the listing is one finite page, so the first call returns
#' every entry and the next returns NULL.
#' @noRd
cy_fetch_search <- function() {
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    entries <- tryCatch(
      cy_parse_listing(cy_fetch_listing()),
      error = function(e) {
        warn_partial("Failed to enumerate eia.moa.gov.cy: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(entries)) {
      return(NULL)
    }
    if (length(entries) == 0L) {
      warn_partial("Cyprus listing returned zero rows; the portal layout may have changed.")
      return(NULL)
    }
    entries
  }
}

#' Parse the listing table into entries (deduplicated on the native `no`).
#' @noRd
cy_parse_listing <- function(html) {
  rows <- rvest::html_elements(html, "table#example1 tbody tr")
  out <- list()
  seen <- character(0)
  for (tr in rows) {
    cells <- rvest::html_elements(tr, "td")
    href <- rvest::html_attr(rvest::html_element(tr, "a[href*='eiaview']"), "href")
    if (length(cells) < 6L || is.na(href)) {
      next
    }
    no <- sub(".*[?&]no=([0-9]+).*", "\\1", href)
    if (!grepl("^[0-9]+$", no) || no %in% seen) {
      next
    }
    seen <- c(seen, no)
    txt <- cy_text(rvest::html_text(cells))
    out[[length(out) + 1L]] <- list(
      no = no,
      url = cy_absolute_url(href),
      listing_number = txt[1],
      listing_title = txt[2],
      town = txt[3],
      listing_area = txt[4],
      listing_category = txt[5],
      listing_type = txt[6]
    )
  }
  out
}

# -----------------------------------------------------------------------------
# Detail parsing
# -----------------------------------------------------------------------------

#' @noRd
cy_load_or_fetch <- function(entry, sidecar_index) {
  hit <- sidecar_index[entry$url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  cy_build_record(entry, cy_fetch_detail(entry$no))
}

#' Section slug + native folder for a download href (`download.php?f=<path>`).
#' @noRd
cy_href_folder <- function(href) {
  f <- sub("^.*[?&]f=([^&]*).*$", "\\1", href)
  f <- utils::URLdecode(gsub("+", " ", f, fixed = TRUE))
  parts <- strsplit(f, "/", fixed = TRUE)[[1]]
  parts <- parts[nzchar(parts)]
  if (length(parts) >= 2L) parts[2] else NA_character_
}

#' Parse detail HTML into `list(fields = named chr (native key -> value),
#' files = data.frame(label, url, slug))`.
#' @noRd
cy_parse_detail <- function(html) {
  kv_rows <- rvest::html_elements(html, "table#example1 tr")
  fields <- character(0)
  for (tr in kv_rows) {
    key <- sub("[[:space:]:]+$", "", cy_text(rvest::html_text(rvest::html_element(tr, "td strong"))))
    cells <- rvest::html_elements(tr, "td")
    if (is.na(key) || !nzchar(key) || length(cells) < 2L) {
      next
    }
    fields[[key]] <- cy_text(rvest::html_text(cells[[2]]))
  }
  if (length(fields) == 0L) {
    stop("no key/value metadata found on detail page", call. = FALSE)
  }
  links <- rvest::html_elements(html, "a[href*='download.php']")
  files <- data.frame(label = character(0), url = character(0), slug = character(0))
  for (a in links) {
    href <- rvest::html_attr(a, "href")
    label <- cy_text(rvest::html_text(rvest::html_element(
      xml2::xml_parent(xml2::xml_parent(a)),
      "td:first-child"
    )))
    files[nrow(files) + 1L, ] <- list(
      label,
      cy_absolute_url(href),
      ascii_slug(cy_href_folder(href), "dokumenta")
    )
  }
  list(fields = fields, files = files[!duplicated(files$url), , drop = FALSE])
}

#' Build a 1-row record from a listing entry and its detail HTML.
#' @noRd
cy_build_record <- function(entry, html) {
  parsed <- cy_parse_detail(html)
  f <- parsed$fields
  get <- function(col) {
    v <- unname(f[cy_key_map()[[col]]])
    if (length(v) == 0L || is.na(v) || !nzchar(v) || v == "...") NA_character_ else v
  }
  files <- parsed$files
  per_section <- split(files$url, factor(files$slug, levels = unique(files$slug)))
  labels <- vapply(
    names(per_section),
    function(s) paste(unique(files$label[files$slug == s]), collapse = " / "),
    character(1)
  )
  rec <- tibble::tibble(
    country = "cy",
    source_portal = cy_source_portal(),
    document_id = paste0("cy_", entry$no),
    url = entry$url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(unique(files$url)),
    local_path = list(character(0)),
    title = get("title") %||% entry$listing_title,
    summary = NA_character_,
    competent_authority = get("competent_authority"),
    proponent = NA_character_,
    date_published = cy_parse_date(get("letter_date")),
    date_decision = cy_parse_date(get("completion_date")),
    native_type = get("native_type"),
    jurisdiction = get("district"),
    assessment_type = "EIA",
    listing_type = entry$listing_type,
    native_no = entry$no,
    project_number = get("project_number") %||% entry$listing_number,
    file_number = get("file_number"),
    category = get("category") %||% entry$listing_category,
    district = get("district"),
    area = get("area") %||% entry$listing_area,
    town = entry$town,
    attachment_labels_native = paste(
      sprintf("%s=%s", names(labels), labels),
      collapse = "; "
    ),
    native_fields = as.character(jsonlite::toJSON(as.list(f), auto_unbox = TRUE)),
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(unname(per_section[[slug]]))
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

# -----------------------------------------------------------------------------
# Finalise + filters
# -----------------------------------------------------------------------------

#' Run downloads (zip kept as-is) and write the sidecar.
#' @noRd
cy_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)
  section_urls <- stats::setNames(
    lapply(section_cols, function(cn) rec[[cn]][[1]]),
    sub("^attachment_urls_", "", section_cols)
  )
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "cy"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "cy",
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
      write_fetched_record_sidecar(rec, downloads = rec$download_status[[1]]),
      error = function(e) {
        warn_partial("Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}")
      }
    )
  }
  rec
}

#' Client-side `query` + `date_range` filters.
#' @noRd
cy_record_matches <- function(rec, query = NULL, date_range = NULL) {
  if (!is.null(query) && nzchar(query)) {
    if (is.na(rec$title) || !grepl(tolower(query), tolower(rec$title), fixed = TRUE)) {
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
