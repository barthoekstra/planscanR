#' Fetch public-inquiry records from Luxembourg.
#'
#' Implementation of [get_assessments()] for Luxembourg. Backed by the national
#' **public-inquiry portal** (<https://enquetes.public.lu>, "Enquêtes
#' publiques"). Records are listed through the portal's own anonymous JSON
#' search endpoint (`/ctie/searchresults`, 21 items per page) and enriched from
#' each inquiry's detail page (parsed with `rvest`). Language is French (`fr`);
#' portal-native values are kept verbatim.
#'
#' @section Scope: all inquiries, not only EIAs:
#' The portal lists **every** public inquiry (about 2,100 since 2020: classified
#' establishments, water permits, environment, ...). The handler returns all of
#' them by default and keeps the native theme(s) (`theme`, `theme_label`,
#' `theme_tags`) and inquiry type (`survey_type`) as columns. **The portal has
#' no native "EIA report" flag**, and the handler does not guess which
#' inquiries are EIAs from title keywords: `assessment_type` is `NA`. Filter on
#' the native `theme` (for example `"environement"`, the portal's spelling) or
#' on the title (`query`) instead. Only the "environement" theme (about 57
#' inquiries) mixes EIAs with Natura 2000, plans and permits; most
#' classified-establishment and water inquiries carry no EIA report.
#'
#' @section Listing and completeness:
#' The search endpoint needs a constant `data-id` that the handler reads from
#' the `<cmp-search-results>` element of `/fr/enquetes.html` (never hardcoded).
#' Pages are requested from 1 until an empty page or until the reported
#' `totalMatches` is reached; ids are de-duplicated and the number of UNIQUE ids
#' is compared with the total. A malformed envelope or a failed first page is
#' an error; a failed, short, empty-too-early or repeated later page, three
#' consecutive failed pages, or fewer unique ids than the total (the warning
#' names ids listed more than once, which suggests a shifted listing) raise a
#' `planscanR_warning_partial` instead of returning a silently complete result.
#' Known case: the portal lists inquiry 1041 twice, so a full crawl of all
#' themes (and the "environement" theme) warns that 56 of 57 were retrieved. Inquiries closed or archived since about 2020
#' remain listed; earlier ones are not on the portal.
#'
#' @section Records:
#' `document_id` is `"lu_"` plus the native inquiry id (stable, also the last
#' number in the title). Every native listing field is kept in the
#' `listing_json` column (the raw search item). `date_published` is the
#' opening date and `date_close` the closing date (both as shown on the detail
#' page; the listing's timestamps are shifted by one or two hours); `date_decision` is `NA`
#' (the portal exposes no decision date). `competent_authority` is the
#' authority organising the inquiry (as written on the page; several are
#' joined with `"; "`), `supervising_authority` the authority following the
#' file, `jurisdiction` the municipalities. `proponent` is the
#' requester ("Requérant : ...") line of the description when the page has one,
#' else `NA`. Also kept:
#' `native_id`, `reference_number`, `status_native`, `survey_type`,
#' `nb_contributions`, `last_modified_native`, `procedure_type`,
#' `municipalities_concerned`, `neighbouring_municipalities`, `related_links`
#' (opinions and meetings linked from the page) and every text section of the
#' page in `detail_sections` (JSON). No geometry (locations are municipality
#' names only).
#'
#' @section Attachments:
#' The detail page is fetched for every returned record (sidecar-first; a
#' record whose detail fetch failed, or whose page looks unexpected, e.g. the
#' few listed items whose page returns 404, is returned as a **listing-only
#' record** (`detail_fetched = FALSE`: title, theme, status, dates,
#' municipalities, reference number and `listing_json`, no attachments) with a
#' `planscanR_warning_partial`; it is never cached and is retried next run). Every file link on the
#' page (host `*download.public.lu`) is captured with its native label, grouped
#' by the portal's own grouping into `attachment_urls_<slug>` columns: the
#' accordion headings (normally `fichiers`), the per-case "Tout télécharger"
#' archive (`tout_telecharger`, a zip that duplicates the other files) and
#' links embedded in the description (`description`, for example a 7z dossier).
#' Native labels per slug are in `attachment_labels_native`. Zip and 7z files
#' are downloaded as-is, never unpacked, and bounded by `max_file_size_mb`
#' (oversized files are reported as `skipped_size`); the main EIA report is
#' often inside a zip.
#'
#' @section Filter coverage:
#' `theme` (a native theme slug, see [get_assessments_coverage()]; sent to the
#' portal and re-checked client-side), `query` (case-insensitive title
#' substring), and `date_range` (against the opening date of the
#' listing, the same calendar day as `date_published`) are applied before
#' the detail fetch; `limit` caps the result. Requests are throttled to 5
#' req/s (`getOption("planscanR.lu_throttle_rate")`).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query, matched client-side as a
#'   case-insensitive substring of the record title.
#' @param theme Optional native theme slug: one of `"etablissement"`,
#'   `"gestion_eau"`, `"environement"` (sic), `"agriculture"`, `"amenagement"`,
#'   `"energie"`, `"patrimoine"`, `"autres"`.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' get_assessments_lu(theme = "environement", limit = 3, download = FALSE)
#' }
get_assessments_lu <- function(
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
  theme = NULL,
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  date_range <- parse_date_range(date_range)
  if (!is.null(theme)) {
    theme <- tolower(theme)
    if (length(theme) != 1L || is.na(theme) || !theme %in% lu_themes()) {
      cli::cli_abort(c(
        "{.arg theme} must be one of {.val {lu_themes()}}.",
        i = "These are the portal's native theme slugs (note the spelling {.val environement})."
      ))
    }
  }

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.lu_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "lu")
  sidecar_index <- if (!refresh) {
    sidecar_url_index("lu")
  } else {
    stats::setNames(character(0), character(0))
  }

  process_entry <- function(entry) {
    if (!lu_entry_matches(entry, query = query, date_range = date_range, theme = theme)) {
      return(NULL)
    }
    rec <- tryCatch(
      lu_load_or_fetch(entry, sidecar_index),
      error = function(e) {
        warn_partial(
          "Failed to load/parse {.url {entry$url}}: {conditionMessage(e)}; keeping listing metadata only (retried on the next run)."
        )
        lu_listing_record(entry)
      }
    )
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    lu_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  gen <- lu_fetch_search(theme)
  records <- stream_crawl(gen, process_entry, limit = limit, label = "lu")
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

# -----------------------------------------------------------------------------
# Constants and small helpers
# -----------------------------------------------------------------------------

#' @noRd
lu_source_portal <- function() "enquetes.public.lu"

#' @noRd
lu_portal_base <- function() "https://enquetes.public.lu"

#' Native theme slugs (snapshot of the portal's theme facet; "environement" is
#' the portal's own spelling).
#' @noRd
lu_themes <- function() {
  c(
    "etablissement",
    "gestion_eau",
    "environement",
    "agriculture",
    "amenagement",
    "energie",
    "patrimoine",
    "autres"
  )
}

#' Collapse whitespace (incl. no-break space) and trim.
#' @noRd
lu_text <- function(x) {
  trimws(gsub("[[:space:]\u00a0\ufeff]+", " ", x))
}

#' Fold French accents to ASCII (for column-name slugs).
#' @noRd
lu_ascii <- function(x) {
  chartr(
    "\u00e0\u00e2\u00e4\u00e7\u00e9\u00e8\u00ea\u00eb\u00ee\u00ef\u00f4\u00f6\u00f9\u00fb\u00fc\u00ff",
    "aaaceeeeiioouuuy",
    tolower(x)
  )
}

#' @noRd
lu_is_missing_node <- function(x) {
  inherits(x, "xml_missing") || length(x) == 0L
}

#' First scalar string of a possibly list-wrapped JSON value, else `NA`.
#' @noRd
lu_chr <- function(x) {
  x <- unlist(x, use.names = FALSE)
  if (length(x) == 0L || is.na(x[1])) NA_character_ else as.character(x[1])
}

#' Parse `YYYY/MM/DD hh:mm:ss` (listing) or `DD.MM.YYYY` (detail); else `NA`.
#' @noRd
lu_parse_date <- function(x) {
  x <- lu_chr(x)
  if (is.na(x)) {
    return(as.Date(NA))
  }
  if (grepl("^[0-9]{4}/[0-9]{2}/[0-9]{2}", x)) {
    return(as.Date(substr(x, 1L, 10L), format = "%Y/%m/%d"))
  }
  m <- regmatches(x, regexpr("[0-9]{2}\\.[0-9]{2}\\.[0-9]{4}", x))
  if (length(m) == 0L) {
    return(as.Date(NA))
  }
  as.Date(m, format = "%d.%m.%Y")
}

# -----------------------------------------------------------------------------
# Network seams
# -----------------------------------------------------------------------------

#' Fetch the inquiry list page (carries the search component's `data-id`).
#' @noRd
lu_fetch_home <- function() {
  perform_html(req_planscanr(lu_portal_base(), "fr/enquetes.html"))
}

#' Fetch one JSON result page (1-based). `theme` is the native slug or `NULL`.
#' @noRd
lu_fetch_page <- function(id, page, theme = NULL) {
  req <- req_planscanr(lu_portal_base(), "ctie/searchresults")
  query <- list(id = id, page = page)
  if (!is.null(theme)) {
    query$r <- paste0("f/aem_theme/tags_theme:enquetes_publiques\\", theme)
  }
  perform_json(httr2::req_url_query(req, !!!query))
}

#' Fetch one detail page by absolute URL.
#' @noRd
lu_fetch_detail <- function(url) {
  perform_html(req_planscanr(lu_portal_base(), sub("^https://[^/]+/", "", url)))
}

#' Read the search component's constant `data-id` from the list page.
#' @noRd
lu_search_id <- function() {
  node <- rvest::html_element(lu_fetch_home(), "cmp-search-results[data-id]")
  id <- if (lu_is_missing_node(node)) NA_character_ else rvest::html_attr(node, "data-id")
  if (is.na(id) || !nzchar(id)) {
    cli::cli_abort(
      "No search {.field data-id} found on {.url {lu_portal_base()}/fr/enquetes.html}; the portal layout may have changed."
    )
  }
  id
}

# -----------------------------------------------------------------------------
# Listing (JSON search results)
# -----------------------------------------------------------------------------

#' Why an envelope is unusable, or `NULL` when it is valid.
#' @noRd
lu_envelope_problem <- function(j) {
  s <- if (is.list(j)) j$search else NULL
  if (!is.list(s) || !is.list(s$items)) {
    return("malformed response: no `search$items` list")
  }
  total <- suppressWarnings(as.numeric(unlist(s$totalMatches)[1]))
  if (length(total) != 1L || is.na(total) || total < 0) {
    return("malformed response: no numeric `search$totalMatches`")
  }
  NULL
}

#' Portal-relative detail path of a listing item (`/fr/enquetes/800/820.html`).
#'
#' Some items carry no `page` object; the base64 `b64_uri` content path in
#' `hitMetaData` identifies them just as well.
#' @noRd
lu_item_path <- function(item) {
  p <- lu_chr(item$page$path)
  if (!is.na(p) && nzchar(p)) {
    return(sub("^(https?:)?//[^/]+", "", p))
  }
  b64 <- lu_chr(item$hitMetaData$b64_uri)
  if (is.na(b64)) {
    return(NA_character_)
  }
  dec <- tryCatch(rawToChar(jsonlite::base64_dec(b64)), error = function(e) NA_character_)
  if (is.na(dec) || !grepl("^/content/enquetes_publiques/[a-z]{2}/enquetes/", dec)) {
    return(NA_character_)
  }
  paste0(sub("^/content/enquetes_publiques", "", dec), ".html")
}

#' Parse one listing item into an entry; `NULL` when it has no usable id/link.
#' @noRd
lu_parse_item <- function(item) {
  hit <- item$hitMetaData %||% list()
  path <- lu_item_path(item)
  id <- if (is.na(path)) NA_character_ else sub("^.*/([0-9]+)\\.html$", "\\1", path)
  if (is.na(id) || !grepl("^[0-9]+$", id)) {
    return(NULL)
  }
  tags <- unlist(hit$theme_list %||% hit$theme, use.names = FALSE)
  slugs <- unique(sub("^.*[/\\\\]", "", tags))
  labels <- unlist(item$page$themes %||% item$themes, use.names = FALSE)
  nb <- suppressWarnings(as.integer(lu_chr(hit$enquetes_publiques_nb_contributions)))
  list(
    id = id,
    url = paste0(lu_portal_base(), path),
    title = lu_text(lu_chr(hit$link_title %||% hit$page_title %||% item$page$title)),
    theme_slugs = slugs,
    theme = if (length(slugs)) paste(slugs, collapse = "; ") else NA_character_,
    theme_tags = if (length(tags)) paste(tags, collapse = "; ") else NA_character_,
    theme_label = if (length(labels)) paste(labels, collapse = "; ") else NA_character_,
    status_native = lu_chr(hit$enquetes_publiques_status),
    survey_type = lu_chr(hit$enquetes_publiques_survey_type),
    municipalities = {
      m <- unlist(hit$enquetes_publiques_municipalities_list, use.names = FALSE)
      if (length(m)) paste(m, collapse = ", ") else lu_chr(hit$enquetes_publiques_municipalities)
    },
    open_date = lu_parse_date(hit$enquetes_publiques_enquiry_open_date),
    nb_contributions = if (length(nb) == 1L) nb else NA_integer_,
    last_modified_native = lu_chr(hit$last_modified),
    description = lu_chr(hit$jcr_description),
    listing_json = as.character(jsonlite::toJSON(item, auto_unbox = TRUE, null = "null"))
  )
}

#' Page generator. First call reads the search `data-id`; each call returns the
#' next page of new entries, or `NULL` when exhausted. See the file docs for the
#' error / partial-warning rules.
#' @noRd
lu_fetch_search <- function(theme = NULL) {
  sid <- NULL
  page <- 1L
  total <- NA_real_
  max_pages <- NA_integer_
  per_page <- NA_integer_
  seen <- character(0)
  dups <- character(0)
  skipped_total <- 0L
  fail_streak <- 0L
  done <- FALSE
  warned <- FALSE
  warn <- function(msg, .envir = parent.frame()) {
    warned <<- TRUE
    warn_partial(msg, .envir = .envir)
  }
  finish <- function() {
    done <<- TRUE
    got <- length(seen) + skipped_total
    if (!warned && got < total) {
      dup_note <- if (length(dups)) {
        paste0(
          "; listed more than once: ",
          paste(unique(dups), collapse = ", "),
          " (the listing may have shifted)"
        )
      } else {
        ""
      }
      warn("Luxembourg listing is incomplete: {got} of {total} reported inquiries retrieved{dup_note}.")
    }
    NULL
  }
  function() {
    if (done) {
      return(NULL)
    }
    if (is.null(sid)) {
      sid <<- lu_search_id()
    }
    while (TRUE) {
      if (!is.na(max_pages) && page > max_pages) {
        return(finish())
      }
      pg <- page
      page <<- page + 1L
      j <- tryCatch(lu_fetch_page(sid, pg, theme), error = function(e) e)
      if (inherits(j, "error")) {
        if (pg == 1L) {
          cli::cli_abort("Failed to fetch the first Luxembourg result page: {conditionMessage(j)}")
        }
        warn("Failed to fetch Luxembourg result page {pg}: {conditionMessage(j)}")
        fail_streak <<- fail_streak + 1L
        if (fail_streak >= 3L) {
          warn("Stopping after 3 consecutive failed Luxembourg result pages.")
          done <<- TRUE
          return(NULL)
        }
        next
      }
      fail_streak <<- 0L
      problem <- lu_envelope_problem(j)
      if (!is.null(problem)) {
        if (pg == 1L) {
          cli::cli_abort("Luxembourg result page 1 is unusable: {problem}.")
        }
        warn("Luxembourg result page {pg} is unusable ({problem}); stopping.")
        done <<- TRUE
        return(NULL)
      }
      items <- j$search$items
      if (pg == 1L) {
        total <<- as.numeric(unlist(j$search$totalMatches)[1])
        per_page <<- suppressWarnings(as.integer(unlist(j$itemsPerPage)[1]))
        if (is.na(per_page) || per_page < 1L) {
          per_page <<- max(length(items), 1L)
        }
        max_pages <<- as.integer(ceiling(total / per_page))
        if (total > 0 && length(items) == 0L) {
          cli::cli_abort("Luxembourg result page 1 reports {total} inquiries but returned none.")
        }
      }
      if (length(items) == 0L) {
        return(finish())
      }
      if (length(items) < per_page && pg < max_pages) {
        warn("Luxembourg result page {pg} is short ({length(items)} of {per_page} items).")
      }
      entries <- list()
      skipped <- 0L
      for (item in items) {
        e <- lu_parse_item(item)
        if (is.null(e)) {
          skipped <- skipped + 1L
        } else if (!e$id %in% seen) {
          seen <<- c(seen, e$id)
          entries[[length(entries) + 1L]] <- e
        } else {
          dups <<- c(dups, e$id)
        }
      }
      if (skipped > 0L) {
        warn("Skipped {skipped} Luxembourg listing item{?s} without a usable id/link on page {pg}.")
      }
      if (length(entries) == 0L && skipped == 0L) {
        warn("Luxembourg result page {pg} only repeated known inquiries; stopping.")
        done <<- TRUE
        return(NULL)
      }
      # unique ids against the reported total: the portal lists inquiry 1041
      # twice (seen live), so a full crawl of all themes still warns, naming it
      skipped_total <<- skipped_total + skipped
      if (length(seen) + skipped_total >= total) {
        done <<- TRUE
      }
      if (length(entries) > 0L) {
        return(entries)
      }
    }
  }
}

#' Client-side `theme` + `query` + `date_range` filters on a listing entry.
#' @noRd
lu_entry_matches <- function(entry, query = NULL, date_range = NULL, theme = NULL) {
  if (!is.null(theme) && !theme %in% tolower(entry$theme_slugs)) {
    return(FALSE)
  }
  if (!is.null(query) && nzchar(query)) {
    if (is.na(entry$title) || !grepl(tolower(query), tolower(entry$title), fixed = TRUE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    d <- entry$open_date
    if (is.na(d) || d < date_range[1] || d > date_range[2]) {
      return(FALSE)
    }
  }
  TRUE
}

# -----------------------------------------------------------------------------
# Detail parsing
# -----------------------------------------------------------------------------

#' @noRd
lu_load_or_fetch <- function(entry, sidecar_index) {
  hit <- sidecar_index[entry$url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    # extras come back from the sidecar as plain JSON types; restore ours
    rec <- read_record_sidecar(hit)
    # a listing-only record is never a warm hit: retry the detail page
    if (!("detail_fetched" %in% names(rec) && isFALSE(as.logical(rec$detail_fetched)))) {
      rec$date_close <- as.Date(rec$date_close)
      rec$nb_contributions <- as.integer(rec$nb_contributions)
      return(rec)
    }
  }
  lu_build_record(entry, lu_fetch_detail(entry$url))
}

#' Text of a `<li>`: its own label text plus its `span.block` values joined
#' with `"; "` (several authorities).
#' @noRd
lu_li_text <- function(li) {
  spans <- rvest::html_elements(li, "span.block")
  if (length(spans) == 0L) {
    return(lu_text(rvest::html_text(li)))
  }
  label <- xml2::xml_text(xml2::xml_find_first(li, "./text()"))
  paste(
    lu_text(label),
    paste(lu_text(rvest::html_text(spans)), collapse = "; ")
  )
}

#' Parse the detail page: header metas, text sections (heading -> items) and
#' every file link with its native label and native group.
#' @noRd
lu_parse_detail <- function(html, id) {
  h1 <- rvest::html_element(html, "h1")
  metas <- rvest::html_element(html, ".page-metas")
  h1_text <- if (lu_is_missing_node(h1)) "" else lu_text(rvest::html_text(h1))
  if (lu_is_missing_node(metas) || !grepl(paste0("(^|[^0-9])", id, "$"), h1_text)) {
    stop("unexpected detail page (no inquiry header for id ", id, ")", call. = FALSE)
  }
  meta <- function(sel) {
    n <- rvest::html_element(metas, sel)
    if (lu_is_missing_node(n)) NA_character_ else lu_text(rvest::html_text(n))
  }

  sections <- list()
  current <- NULL
  for (node in rvest::html_elements(html, "div.cmp-text")) {
    h2 <- rvest::html_element(node, "h2")
    if (!lu_is_missing_node(h2)) {
      current <- lu_text(rvest::html_text(h2))
      if (is.null(sections[[current]])) {
        sections[[current]] <- character(0)
      }
      next
    }
    if (is.null(current)) {
      next
    }
    lis <- rvest::html_elements(node, "li")
    ps <- rvest::html_elements(node, "p")
    items <- if (length(lis)) {
      vapply(lis, lu_li_text, character(1))
    } else if (length(ps)) {
      lu_text(rvest::html_text(ps))
    } else {
      lu_text(rvest::html_text(node))
    }
    sections[[current]] <- c(sections[[current]], items[nzchar(items)])
  }

  related <- list()
  files <- data.frame(label = character(0), url = character(0), group = character(0))
  for (a in rvest::html_elements(html, "a[href]")) {
    href <- rvest::html_attr(a, "href")
    abs <- if (startsWith(href, "//")) paste0("https:", href) else href
    label <- lu_text(rvest::html_text(a))
    acc <- xml2::xml_find_first(a, "ancestor::details[1]")
    if (!lu_is_missing_node(acc) || grepl("^https?://[^/]*download\\.public\\.lu/", abs)) {
      title_node <- rvest::html_element(a, ".cmp-list__item-title")
      if (!lu_is_missing_node(title_node)) {
        label <- lu_text(rvest::html_text(title_node))
      }
      group <- if (!lu_is_missing_node(acc)) {
        lu_text(rvest::html_text(rvest::html_element(acc, "h3")))
      } else if (grepl("cmp-button", rvest::html_attr(a, "class") %||% "", fixed = TRUE)) {
        trimws(sub("\\s*\\(.*$", "", label))
      } else {
        "description"
      }
      files[nrow(files) + 1L, ] <- list(label, abs, ascii_slug(lu_ascii(group), "other"))
    } else if (
      grepl("^(https?:)?//", href) &&
        !lu_is_missing_node(xml2::xml_find_first(a, "ancestor::div[contains(@class,'cmp-text')][1]"))
    ) {
      related[[length(related) + 1L]] <- list(label = label, url = abs)
    }
  }
  list(
    h1 = h1_text,
    domain = meta(".meta-domain"),
    state = sub("^Statut\\s*:\\s*", "", meta(".meta-state")),
    open_date = lu_parse_date(meta(".meta-enquiryOpenDate")),
    close_date = lu_parse_date(meta(".meta-enquiryCloseDate")),
    sections = sections,
    related = related,
    files = files[!duplicated(files$url), , drop = FALSE]
  )
}

#' Value of the first section item `"<label> : <value>"` matching `label_rx`.
#' @noRd
lu_section_value <- function(sections, label_rx) {
  items <- unlist(sections, use.names = FALSE)
  rx <- paste0("^", label_rx, "\\s*:\\s*")
  hit <- items[grepl(rx, items)]
  if (length(hit) == 0L) {
    return(NA_character_)
  }
  v <- lu_text(sub(rx, "", hit[1]))
  if (nzchar(v)) v else NA_character_
}

#' Plain text of a listing description (HTML entities decoded); `NA` if absent.
#' @noRd
lu_listing_text <- function(x) {
  if (is.null(x) || is.na(x)) {
    return(NA_character_)
  }
  lu_text(xml2::xml_text(xml2::read_html(paste0("<p>", x, "</p>"))))
}

#' Listing-only record (detail page unavailable): title, theme, status, dates,
#' municipalities, reference number and the raw listing item; no attachments.
#' @noRd
lu_listing_record <- function(entry) {
  lu_build_record(entry, NULL)
}

#' Build a 1-row record from a listing entry and its detail page (`NULL` html
#' gives the listing-only record).
#' @noRd
lu_build_record <- function(entry, html = NULL) {
  fetched <- !is.null(html)
  d <- if (fetched) {
    lu_parse_detail(html, entry$id)
  } else {
    list(
      h1 = entry$title,
      domain = NA_character_,
      state = NA_character_,
      open_date = as.Date(NA),
      close_date = as.Date(NA),
      sections = list(),
      related = list(),
      files = data.frame(label = character(0), url = character(0), group = character(0))
    )
  }
  s <- d$sections
  files <- d$files
  or_na <- function(x, fallback) if (is.na(x) || !nzchar(x)) fallback else x
  details <- s[["D\u00e9tails de l'enqu\u00eate publique"]]
  description <- if (length(details)) paste(details, collapse = "\n") else NA_character_
  ref_text <- if (is.na(description)) lu_listing_text(entry$description) else description
  reference <- if (is.na(ref_text)) {
    NA_character_
  } else {
    m <- regmatches(
      ref_text,
      regexec("Num\u00e9ro de r\u00e9f\u00e9rence\\s*:\\s*([^[:space:]]+)", ref_text)
    )[[1]]
    if (length(m) == 2L) m[2] else NA_character_
  }
  per_section <- split(files$url, factor(files$group, levels = unique(files$group)))
  labels <- vapply(
    names(per_section),
    function(g) paste(unique(files$label[files$group == g]), collapse = " / "),
    character(1)
  )
  rec <- tibble::tibble(
    country = "lu",
    source_portal = lu_source_portal(),
    document_id = paste0("lu_", entry$id),
    url = entry$url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(unique(files$url)),
    local_path = list(character(0)),
    title = or_na(entry$title, lu_text(sub(" - [0-9]+$", "", d$h1))),
    summary = description,
    competent_authority = lu_section_value(s, "Autorit\u00e9 en charge de l.organisation[^:]*"),
    proponent = lu_section_value(s, "Requ\u00e9rant"),
    date_published = if (is.na(d$open_date)) entry$open_date else d$open_date,
    date_decision = as.Date(NA),
    date_close = d$close_date,
    native_type = entry$survey_type,
    jurisdiction = or_na(entry$municipalities, NA_character_),
    assessment_type = NA_character_,
    native_id = entry$id,
    reference_number = reference,
    theme = entry$theme,
    theme_label = or_na(entry$theme_label, d$domain),
    theme_tags = entry$theme_tags,
    survey_type = entry$survey_type,
    status_native = or_na(d$state, entry$status_native),
    nb_contributions = entry$nb_contributions,
    last_modified_native = entry$last_modified_native,
    supervising_authority = lu_section_value(s, "Autorit\u00e9 en charge du suivi[^:]*"),
    procedure_type = lu_section_value(s, "Type de proc\u00e9dure"),
    municipalities_concerned = lu_section_value(s, "Commune\\(s\\) concern\u00e9e\\(s\\)"),
    neighbouring_municipalities = lu_section_value(s, "Communes limitrophes"),
    related_links = if (length(d$related)) {
      as.character(jsonlite::toJSON(d$related, auto_unbox = TRUE))
    } else {
      NA_character_
    },
    attachment_labels_native = paste(sprintf("%s=%s", names(labels), labels), collapse = "; "),
    detail_fetched = fetched,
    detail_sections = if (fetched) as.character(jsonlite::toJSON(s, auto_unbox = FALSE)) else NA_character_,
    listing_json = entry$listing_json,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(unname(per_section[[slug]]))
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

# -----------------------------------------------------------------------------
# Finalise
# -----------------------------------------------------------------------------

#' Run downloads (zip/7z kept as-is) and write the sidecar.
#' @noRd
lu_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
  urls <- rec$attachment_urls[[1]]
  section_cols <- grep("^attachment_urls_", names(rec), value = TRUE)
  section_urls <- stats::setNames(
    lapply(section_cols, function(cn) rec[[cn]][[1]]),
    sub("^attachment_urls_", "", section_cols)
  )
  if (download) {
    if (length(urls) > 0L) {
      inform_download(length(urls), cache_dir(file.path("files", "lu"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "lu",
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
  if (write_sidecar && isTRUE(rec$detail_fetched)) {
    tryCatch(
      write_fetched_record_sidecar(rec, downloads = rec$download_status[[1]]),
      error = function(e) {
        warn_partial("Could not write sidecar for {.val {rec$document_id}}: {conditionMessage(e)}")
      }
    )
  }
  rec
}
