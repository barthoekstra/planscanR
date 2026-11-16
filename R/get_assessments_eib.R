#' Fetch records from the European Investment Bank public register.
#'
#' Implementation of the explicit source `"eib"` for [get_assessments()]:
#' `get_assessments("de", source = "eib")`. Backed by the EIB public register
#' of environmental and social documents (<https://www.eib.org/en/registers/>)
#' for EIB-financed projects. This is an organisation source, not a national
#' portal: it is not in [supported_countries()] and not in
#' [get_assessments_coverage()]; see [get_assessments_sources()].
#'
#' @section Granularity and scope:
#' One record per register **document** (`document_id = "eib_<id>"`); one
#' project has many documents sharing `project_number`. ALL document types the
#' register holds for the country are kept, with the native type label in
#' `role` / `native_type` and one `attachment_urls_<type-slug>` section each.
#' The types are not reclassified. Labels such as `ESIA`, `Environmental Impact
#' Assessment` and `SEA` identify full reports (although the `ESIA` bucket also
#' holds permits, decisions and placeholder rows); `ESDS`, `ESCS` and `NTS` are
#' summaries. A `Link to promoter website` row may have no file; whether a file
#' exists is only known after download, when a missing file is recorded as a
#' failure in `download_status`. The record `url` is the register page. Coverage is EIB-financed projects only
#' (publication from about 2011), not national completeness.
#'
#' @section Geography:
#' The register tags documents with ISO-2 country codes (plus non-ISO tags such
#' as `C7` "EU Countries" and regional `A1`-`A9`). A record matches when ANY of
#' its tags equals the requested code (multi-country records appear under each
#' requested country with the same `document_id`). Regional/non-ISO-only and
#' untagged rows are excluded. The complete native tag list is kept in
#' `country_codes` / `country_labels`.
#'
#' @section Listing and completeness:
#' One request to `/provider-eib-plr/app/registers/list?countries=<ISO2>`
#' returns the whole filtered list. When the response's `totalItems` differs
#' from the returned row count a `planscanR_warning_partial` states both
#' numbers (the register itself shows such gaps). Per-record metadata comes
#' from `/registers/item/{id}`; files from `/attachments/registers/{id}.pdf`.
#' Files over `max_file_size_mb` are not silently dropped: they stay in the
#' record and get `skipped_size` in `download_status`.
#'
#' @param country Lowercase ISO-2 code (supplied by [get_assessments()]).
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()]. `date_range` filters `date_published`.
#' @param document_type Optional character vector of native document types,
#'   matched case-insensitively against the full label or its bracketed
#'   abbreviation (e.g. `"ESIA"`).
#' @param ... Unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_sources()]
#' @keywords internal
#' @examples
#' \dontrun{
#' get_assessments("de", source = "eib", document_type = "ESIA", limit = 5)
#' }
get_assessments_eib <- function(
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
  document_type = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  if (
    !is.null(document_type) && (!is.character(document_type) || length(document_type) == 0L || anyNA(document_type))
  ) {
    cli::cli_abort(
      "{.arg document_type} must be a non-empty character vector without NA.",
      class = "planscanR_error_bad_input"
    )
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

  process_entry <- function(entry) {
    if (!eib_type_matches(eib_listing_type(entry), document_type)) {
      return(NULL)
    }
    if (!grepl("^[0-9]+$", as.character(entry$id %||% ""))) {
      warn_partial("Skipping EIB row with a non-numeric id: {.val {as.character(entry$id %||% NA)}}")
      return(NULL)
    }
    url <- eib_page_url(entry$id)
    hit <- sidecar_index[url]
    rec <- NULL
    if (length(hit) == 1L && !is.na(hit) && file.exists(hit)) {
      rec <- read_record_sidecar(hit)
      # Sidecar JSON hands extra date columns back as character.
      for (col in intersect(c("document_date", "last_update_date", "status_date"), names(rec))) {
        rec[[col]] <- as.Date(rec[[col]])
      }
      # A record cached without its item detail is retried, not served warm.
      if (isFALSE(rec$detail_fetched[[1]])) {
        rec <- NULL
      }
    }
    if (is.null(rec)) {
      detail <- tryCatch(
        eib_fetch_item(entry$id),
        error = function(e) {
          warn_partial("EIB item {.val {entry$id}} detail failed, keeping listing metadata only: {conditionMessage(e)}")
          NULL
        }
      )
      if (is.null(detail)) {
        warn_partial("EIB item {.val {entry$id}} returned no detail, keeping listing metadata only.")
      }
      rec <- eib_parse_entry(entry, detail, country)
    }
    if (!is.null(date_range)) {
      d <- rec$date_published
      if (is.na(d) || d < date_range[1] || d > date_range[2]) {
        return(NULL)
      }
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    eib_finalise_record(rec, should_download, overwrite, max_file_size_mb, write_sidecar)
  }

  gen <- eib_fetch_listing(country)
  records <- stream_crawl(gen, process_entry, limit = limit, label = country)
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

eib_source_portal <- function() "eib.org/registers"

eib_page_url <- function(id) paste0("https://www.eib.org/en/registers/all/", id)

eib_file_url <- function(id) paste0("https://www.eib.org/attachments/registers/", id, ".pdf")

eib_listing_type <- function(entry) as.character(unlist(entry$additionalInformation)[1L] %||% NA_character_)

#' Case-insensitive match of a native type label against the user filter.
#' @noRd
eib_type_matches <- function(label, wanted) {
  if (is.null(wanted)) {
    return(TRUE)
  }
  if (is.na(label)) {
    return(FALSE)
  }
  l <- tolower(label)
  w <- tolower(wanted)
  any(l == w | vapply(paste0("(", w, ")"), grepl, logical(1), x = l, fixed = TRUE))
}

#' Country-tag values of a listing row (all tags whose subType is countries).
#' @noRd
eib_tags <- function(entry, sub_type) {
  tags <- Filter(function(t) identical(t$subType, sub_type), entry$primaryTags %||% list())
  list(
    value = vapply(tags, function(t) as.character(t$value %||% NA_character_), character(1)),
    label = vapply(tags, function(t) as.character(t$label %||% NA_character_), character(1))
  )
}

#' Page generator: one filtered listing call, then exhausted.
#'
#' Rows are post-checked so only rows whose country tags include the code
#' (case-insensitive) survive; warns when `totalItems` != returned rows.
#' @noRd
eib_fetch_listing <- function(country) {
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    done <<- TRUE
    req <- req_planscanr("https://www.eib.org/provider-eib-plr/app/registers/list")
    req <- httr2::req_url_query(req, countries = toupper(country))
    payload <- perform_json(req)
    if (!is.list(payload) || !is.list(payload$data) || isFALSE(payload$valid)) {
      cli::cli_abort(
        c(
          "The EIB register listing for {.val {toupper(country)}} returned an invalid response (no {.field data} or {.field valid} is false).",
          i = "The register API may have changed or be unavailable; retry later."
        ),
        class = "planscanR_error_bad_response"
      )
    }
    rows <- payload$data
    total <- suppressWarnings(as.integer(payload$totalItems %||% NA))
    if (is.na(total)) {
      warn_partial(
        "EIB register listing for {.val {toupper(country)}} has no {.field totalItems}; completeness is unknown."
      )
    } else if (total != length(rows)) {
      warn_partial(
        "EIB register listing for {.val {toupper(country)}} returned {length(rows)} rows but reports totalItems = {total}; the result may be incomplete."
      )
    }
    Filter(function(r) toupper(country) %in% toupper(eib_tags(r, "countries")$value), rows)
  }
}

#' Fetch the item detail (NULL data when absent).
#' @noRd
eib_fetch_item <- function(id) {
  req <- req_planscanr("https://www.eib.org/provider-eib-plr/app/registers/item", path = as.character(id))
  perform_json(req)$data
}

eib_ms_date <- function(ms) {
  if (is.null(ms) || length(ms) != 1L || is.na(suppressWarnings(as.numeric(ms)))) {
    return(as.Date(NA))
  }
  as.Date(as.POSIXct(as.numeric(ms) / 1000, origin = "1970-01-01", tz = "UTC"))
}

na_or <- function(x, fallback) if (length(x) == 0L || is.na(x)) fallback else x

eib_val <- function(x) {
  v <- if (is.list(x)) x$value else x
  if (is.null(v) || length(v) != 1L || is.na(v) || !nzchar(v)) NA_character_ else as.character(v)
}

#' Build a 1-row record from a listing row plus (optional) item detail.
#' @noRd
eib_parse_entry <- function(entry, detail, country) {
  id <- as.character(entry$id)
  info <- unlist(entry$additionalInformation)
  cty <- eib_tags(entry, "countries")
  sec <- eib_tags(entry, "sectors")
  label <- na_or(eib_val(detail$documentType), eib_listing_type(entry))
  pub <- eib_ms_date(detail$publicationDate)
  if (is.na(pub)) {
    pub <- eib_ms_date(entry$startDate)
  }
  join <- function(x) if (length(x) == 0L) NA_character_ else paste(x, collapse = "; ")
  sector_vals <- if (!is.null(detail$sectors)) {
    vapply(detail$sectors, function(s) eib_val(s), character(1))
  } else {
    sec$label
  }
  rec <- tibble::tibble(
    country = country,
    source_portal = eib_source_portal(),
    document_id = paste0("eib_", id),
    url = eib_page_url(id),
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(eib_file_url(id)),
    local_path = list(character(0)),
    title = as.character(detail$documentTitle %||% entry$title %||% NA_character_),
    summary = NA_character_,
    competent_authority = NA_character_,
    proponent = NA_character_,
    date_published = pub,
    date_decision = as.Date(NA),
    native_type = label,
    role = label,
    status = NA_character_,
    eib_id = id,
    project_number = as.character(detail$projectNumber %||% info[3L] %||% NA_character_),
    language = na_or(eib_val(detail$documentLanguage), as.character(info[2L])),
    language_id = as.character(detail$documentLanguage$id %||% NA_character_),
    sector_sections = join(na.omit(vapply(detail$sectors %||% list(), function(s) eib_val(s$section), character(1)))),
    country_regions = join(na.omit(vapply(detail$countries %||% list(), function(c) eib_val(c$region), character(1)))),
    document_type_id = as.character(detail$documentType$id %||% NA_character_),
    document_focus = eib_val(detail$documentFocus),
    availability = eib_val(detail$availability),
    topic_native = eib_val(detail$topic),
    sectors = join(sector_vals[!is.na(sector_vals)]),
    country_codes = join(cty$value),
    country_labels = join(cty$label),
    document_date = eib_ms_date(detail$documentDate),
    last_update_date = eib_ms_date(detail$lastUpdateDate),
    status_date = eib_ms_date(detail$statusDate),
    detail_fetched = !is.null(detail),
    download_status = list(empty_download_status())
  )
  eib_add_section(rec, label)
}

#' Per-type attachment section column holding the single file URL.
#' @noRd
eib_add_section <- function(rec, label) {
  slug <- ascii_slug(label, "document")
  rec[[paste0("attachment_urls_", slug)]] <- rec$attachment_urls
  rec[[paste0("local_path_", slug)]] <- list(character(0))
  rec
}

eib_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  if (download) {
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
  for (col in grep("^attachment_urls_", names(rec), value = TRUE)) {
    sec <- sub("^attachment_urls_", "", col)
    rec[[paste0("local_path_", sec)]] <- list(ds$local_path[match(rec[[col]][[1]], ds$url)])
  }
  rec$file_sha256 <- list(ds$sha256)
  if (write_sidecar) {
    tryCatch(
      write_fetched_record_sidecar(rec, downloads = ds),
      error = function(e) warn_partial("Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}")
    )
  }
  rec
}
