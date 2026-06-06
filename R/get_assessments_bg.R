#' Fetch environmental-assessment records from Bulgaria.
#'
#' Implementation of [get_assessments()] for Bulgaria. Backed by the Ministry
#' of Environment and Water (МОСВ) public registers hosted at
#' `registers.moew.government.bg`, which publish two adjacent registers:
#'
#' * **ОВОС** — *Оценка на въздействието върху околната среда* (project-level
#'   EIA), `https://registers.moew.government.bg/ovos/`.
#' * **ЕО** — *Екологична оценка* (plan/programme SEA),
#'   `https://registers.moew.government.bg/eo/`.
#'
#' Both registers are merged into a single result tibble; an
#' `assessment_type` column (`"EIA"` for ОВОС, `"SEA"` for ЕО) tags each row
#' and is preserved in the offline metadata cache so downstream tooling can tell them
#' apart without re-fetching anything. `document_id` is prefixed with
#' `"OVOS-"` / `"EO-"` (e.g. `"OVOS-21617"`, `"EO-44841"`) so the two
#' registers never collide on disk.
#'
#' @section URL enumeration:
#' The registers are server-rendered ASP.NET MVC pages (no SPA, no viewstate).
#' Index listings paginate via a numeric `offset` plus a `limit` query
#' parameter (`?offset=<n>&limit=<k>`); each page is one HTML GET listing the
#' dossier number, incoming number, project/plan name, proponent, applicable
#' procedure, and status. The page text *Намерени <N> досиета.* ("Found N
#' dossiers") is the authoritative total. Detail pages live at `/ovos/lot/<id>`
#' (ОВОС) and `/eo/lot/<id>` (ЕО) and carry every field a downstream
#' classifier needs.
#'
#' @section Geometry:
#' The МОСВ registers expose **no** coordinates or GeoJSON anywhere — location
#' is administrative text only (Област / Община / Населено място). No geometry
#' columns are emitted.
#'
#' @section Attachments:
#' Detail pages render document links inline inside the lot table's value
#' cells, of the form
#' `https://registers.moew.government.bg/ovos/file?fileKey=<uuid>&fileName=<name>`
#' (and `/eo/file?...`). The `fileName` query parameter is required by the
#' server, so the handler captures the full href as rendered rather than
#' reconstructing it. Downloads are anonymous (no authentication). Documents
#' are typed only by the table-row label they sit under (Уведомление,
#' Описание, Писмо, …); the handler slugs that label into an
#' `attachment_urls_<slug>` / `local_path_<slug>` list-column. The
#' deduplicated union goes into `attachment_urls` / `local_path` (required by
#' the schema).
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side substring match on the project/plan name,
#'    forwarded as `projectName`.
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (ОВОС only), or `"SEA"` (ЕО only). Applied here in R.
#' * `date_range` — matched client-side against `date_published` (the
#'    dossier submission date). `date_decision` is the termination-decision
#'    date (*Дата на решението за прекратяване*) when present, else `NA`.
#'
#' @section Performance:
#' The two registers are ~35,000 (ОВОС) + ~10,000 (ЕО) records, so callers
#' almost always pass `limit` and/or `query`. Detail fetches are slow
#' (~4 s server-side), so BG requests are throttled to 2 requests per second
#' by default to stay polite to a government host. Override via
#' `getOption("planscanR.bg_throttle_rate")` (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query forwarded as `projectName` (project/plan name
#'   substring match).
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
#' get_assessments_bg(limit = 3, download = FALSE)
#'
#' # Wind-themed slice
#' get_assessments_bg(query = "вятър", limit = 20, download = FALSE)
#'
#' # SEA only
#' get_assessments_bg(assessment_type = "SEA", limit = 5, download = FALSE)
#' }
get_assessments_bg <- function(
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
  assessment_type <- bg_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.bg_throttle_rate", 2)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "bg")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("bg")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("OVOS", "EO"),
    EIA = "OVOS",
    SEA = "EO"
  )

  # Per-entry processing: sidecar-first detail fetch, client-side date filter,
  # relevance scoring, optional download, and the sidecar write. Returns the
  # 1-row record or NULL to drop the entry. Shared across both registers'
  # streams and called once per listing row by stream_crawl().
  process_entry <- function(entry) {
    u <- bg_canonical_url(entry$register, entry$id)
    rec <- tryCatch(
      bg_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!bg_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    bg_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream each register page-by-page, persisting records as they are parsed
  # instead of enumerating the whole register first. `limit` is global across
  # both registers, so a full OVOS crawl can consume all of it before EO.
  records <- list()
  for (reg in registers) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    page_gen <- tryCatch(
      bg_fetch_search(register = reg, query = query),
      error = function(e) {
        warn_partial(
          "Failed to enumerate MOEW {.val {reg}} index: {conditionMessage(e)}"
        )
        function() NULL
      }
    )
    # Wrap the page generator so each page's not-yet-cached detail pages are
    # fetched concurrently (capped at 8) before stream_crawl() processes the
    # rows; process_entry() then parses/scores/writes them serially.
    gen <- function() {
      bg_prefetch_details(page_gen(), sidecar_index, max_active = 8L)
    }
    block <- stream_crawl(gen, process_entry, limit = remaining, label = "bg")
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
bg_source_portal <- function() "registers.moew.government.bg"

#' Public base URL for the portal.
#' @noRd
bg_portal_base <- function() "https://registers.moew.government.bg"

#' Default index page size requested from the server.
#' @noRd
bg_page_size <- function() 100L

#' URL path segment for a register.
#' @noRd
bg_register_path <- function(register) if (register == "OVOS") "ovos" else "eo"

#' Canonical landing URL for an ОВОС or ЕО dossier.
#' @noRd
bg_canonical_url <- function(register, id) {
  sprintf("%s/%s/lot/%s", bg_portal_base(), bg_register_path(register), id)
}

#' Document-ID prefix per register so OVOS 533 and EO 533 never collide on disk.
#' @noRd
bg_document_id <- function(register, id) {
  sprintf("%s-%s", register, id)
}

#' Map our `assessment_type` argument to a normalised value.
#' @noRd
bg_normalise_assessment_type <- function(x) {
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

#' Build a page generator for one register's index.
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call fetches the next listing page (by `offset`) and returns its listing-row
#' entries, or `NULL` once the register is exhausted. Pagination state (offset)
#' lives in the closure, so the streaming driver pulls only as many pages as the
#' limit needs and records are persisted page-by-page.
#'
#' Each entry is a small named list:
#' `list(register = "OVOS"|"EO", id = "<n>", dossier_number = ...,
#'  title = ..., proponent = ..., native_type = ..., status = ...)`.
#' The detail-page parser is sidecar-first, so this is deliberately the
#' minimum needed to build the canonical URL.
#'
#' Termination mirrors the original: the generator ends on a failed fetch, an
#' empty page, or a short page (`length(rows) < size`, the last page).
#' @noRd
bg_fetch_search <- function(register, query = NULL) {
  size <- bg_page_size()
  path <- bg_register_path(register)
  offset <- 0L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(bg_portal_base())
    req <- httr2::req_url_path_append(req, path)
    req <- httr2::req_url_query(req, offset = offset, limit = size)
    if (!is.null(query) && nzchar(query)) {
      req <- httr2::req_url_query(req, projectName = as.character(query))
    }
    html <- tryCatch(perform_html(req), error = function(e) NULL)
    if (is.null(html)) {
      done <<- TRUE
      return(NULL)
    }
    rows <- bg_parse_index_rows(html, register)
    if (length(rows) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    # Server short-page -> this is the last page; emit it, then stop.
    if (length(rows) < size) {
      done <<- TRUE
    }
    offset <<- offset + size
    rows
  }
}

#' Parse the rows of one index page.
#' @noRd
bg_parse_index_rows <- function(html, register) {
  path <- bg_register_path(register)
  trs <- rvest::html_elements(html, "table.table-resolutions tbody tr.header")
  out <- list()
  for (tr in trs) {
    a <- rvest::html_element(tr, "a[href*='/lot/']")
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    id <- bg_extract_id(href, register)
    if (is.na(id)) {
      next
    }
    tds <- rvest::html_elements(tr, "td")
    cell <- function(i) {
      if (length(tds) < i) {
        return(NA_character_)
      }
      bg_text(rvest::html_text2(tds[[i]])) %||% NA_character_
    }
    out[[length(out) + 1L]] <- list(
      register = register,
      id = id,
      dossier_number = cell(1L),
      incoming_number = cell(2L),
      title = cell(3L),
      proponent = cell(4L),
      native_type = cell(5L),
      status = cell(6L)
    )
  }
  out
}

#' Extract the lot id from an `href` attribute.
#' @noRd
bg_extract_id <- function(href, register) {
  path <- bg_register_path(register)
  m <- regmatches(
    href,
    regexec(paste0(path, "/lot/([0-9]+)"), href)
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
bg_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  # Use the page-level parallel prefetch's HTML when present (see
  # bg_prefetch_details()); otherwise fall back to a serial fetch.
  detail <- entry$detail_html %||% bg_fetch_detail(url)
  bg_parse_detail(url, entry, detail)
}

#' Fetch one ОВОС / ЕО detail page as parsed HTML.
#' @noRd
bg_fetch_detail <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Prefetch a listing page's detail HTML concurrently.
#'
#' BG's wall-clock is dominated by the per-record detail GET (~4 s server-side),
#' and those fetches are independent, so we overlap them: build one request per
#' not-yet-cached entry and run them through [httr2::req_perform_parallel()]
#' (capped at `max_active`, throttle/retry still applied via [req_planscanr()]).
#' The parsed HTML is attached to each entry as `$detail_html` for
#' [bg_load_or_fetch()] to consume; sidecar-cached entries are skipped, and any
#' request that errors is simply left without `$detail_html` so it falls back to
#' the serial path. Scoring/parsing/sidecar writes stay sequential downstream
#' (relevance scoring goes through reticulate, which is not concurrency-safe).
#' @noRd
bg_prefetch_details <- function(entries, sidecar_index, max_active = 8L) {
  if (length(entries) == 0L) {
    return(entries)
  }
  urls <- vapply(
    entries,
    function(e) bg_canonical_url(e$register, e$id),
    character(1)
  )
  hit <- sidecar_index[urls]
  cached <- !is.na(hit) & nzchar(hit) & file.exists(hit)
  need <- which(!cached)
  if (length(need) == 0L) {
    return(entries)
  }
  reqs <- lapply(urls[need], req_planscanr)
  resps <- tryCatch(
    httr2::req_perform_parallel(
      reqs,
      on_error = "continue",
      progress = FALSE,
      max_active = max_active
    ),
    error = function(e) NULL
  )
  if (is.null(resps)) {
    return(entries)
  }
  for (k in seq_along(need)) {
    resp <- resps[[k]]
    if (!inherits(resp, "httr2_response")) {
      next
    }
    entries[[need[k]]]$detail_html <- tryCatch(
      rvest::read_html(httr2::resp_body_string(resp)),
      error = function(e) NULL
    )
  }
  entries
}

#' Parse one detail page into a 1-row tibble.
#'
#' The detail page is a single `<table class="table-lot">` of nested
#' row-groups: each `<tr>` carries zero or more `<th class="rowgroup-header">`
#' section headers, then a final `<th>` label and a `<td>` value. Field lookup
#' is by that last-`<th>` label; attachments are slugged from the label of the
#' row they sit in.
#' @noRd
bg_parse_detail <- function(url, entry, html) {
  register <- entry$register
  id <- entry$id
  document_id <- bg_document_id(register, id)

  rows <- bg_extract_rows(html, register)

  # Field lookups by row label. The first matching label wins. ОВОС and ЕО use
  # slightly different vocabularies for some fields, so we try several labels.
  pick <- function(...) bg_field(rows, c(...))

  # title: investment proposal (ОВОС) / plan name (ЕО). ОВОС has a dedicated
  # label; ЕО reuses the generic "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435" label but under the plan
  # description section, so we disambiguate by the row's rowgroup section.
  title <- pick(
    "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435 \u043d\u0430 \u0438\u043d\u0432\u0435\u0441\u0442\u0438\u0446\u0438\u043e\u043d\u043d\u043e\u0442\u043e \u043f\u0440\u0435\u0434\u043b\u043e\u0436\u0435\u043d\u0438\u0435"
  ) %||%
    bg_field_in_section(
      rows,
      "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435",
      "\u041e\u043f\u0438\u0441\u0430\u043d\u0438\u0435 \u043d\u0430 \u043f\u043b\u0430\u043d\u0430/\u043f\u0440\u043e\u0433\u0440\u0430\u043c\u0430\u0442\u0430"
    ) %||%
    entry$title %||%
    NA_character_

  # proponent: the "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435" / "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435/\u0418\u043c\u0435" under the
  # Възложител (proponent) / Вносител (submitter) section.
  proponent <- bg_field_in_section(
    rows,
    c(
      "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435/\u0418\u043c\u0435",
      "\u041d\u0430\u0438\u043c\u0435\u043d\u043e\u0432\u0430\u043d\u0438\u0435"
    ),
    c(
      "\u0412\u044a\u0437\u043b\u043e\u0436\u0438\u0442\u0435\u043b",
      "\u0412\u043d\u043e\u0441\u0438\u0442\u0435\u043b"
    )
  ) %||%
    entry$proponent %||%
    NA_character_

  competent_authority <- pick(
    "\u041a\u043e\u043c\u043f\u0435\u0442\u0435\u043d\u0442\u0435\u043d \u043e\u0440\u0433\u0430\u043d"
  ) %||%
    NA_character_
  native_type <- pick(
    "\u041f\u0440\u0438\u043b\u043e\u0436\u0438\u043c\u0430 \u043f\u0440\u043e\u0446\u0435\u0434\u0443\u0440\u0430"
  ) %||%
    entry$native_type %||%
    NA_character_

  # date_published: the submission date (under the proposal/plan section).
  date_published <- parse_dmy(pick("\u0414\u0430\u0442\u0430")) %||% as.Date(NA)
  if (length(date_published) == 0L || is.null(date_published)) {
    date_published <- as.Date(NA)
  }
  # date_decision: the termination-decision date, when present.
  date_decision <- parse_dmy(pick(
    "\u0414\u0430\u0442\u0430 \u043d\u0430 \u0440\u0435\u0448\u0435\u043d\u0438\u0435\u0442\u043e \u0437\u0430 \u043f\u0440\u0435\u043a\u0440\u0430\u0442\u044f\u0432\u0430\u043d\u0435"
  )) %||%
    as.Date(NA)
  if (length(date_decision) == 0L || is.null(date_decision)) {
    date_decision <- as.Date(NA)
  }

  region <- pick("\u041e\u0431\u043b\u0430\u0441\u0442")
  municipality <- pick("\u041e\u0431\u0449\u0438\u043d\u0430")
  settlement <- pick("\u041d\u0430\u0441\u0435\u043b\u0435\u043d\u043e \u043c\u044f\u0441\u0442\u043e")
  jurisdiction <- bg_join_path(c(region, municipality, settlement))

  dossier_number <- pick("\u041d\u043e\u043c\u0435\u0440 \u043d\u0430 \u0434\u043e\u0441\u0438\u0435") %||%
    entry$dossier_number %||%
    NA_character_
  status <- entry$status %||% NA_character_

  per_section <- bg_parse_documents(rows)
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "bg",
    source_portal = bg_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = NA_character_,
    competent_authority = competent_authority %||% NA_character_,
    proponent = proponent,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status %||% NA_character_,
    assessment_type = if (register == "OVOS") "EIA" else "SEA",
    register = register,
    dossier_number = dossier_number %||% NA_character_,
    region = region %||% NA_character_,
    municipality = municipality %||% NA_character_,
    settlement = settlement %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Extract the detail table's rows as a list of `list(label, sections, node)`.
#'
#' Each `<tr>` carries 0+ rowgroup-header `<th>` cells, a final label `<th>`,
#' and a `<td>` value cell. Rowgroup headers only render on the first row of
#' each group (the others are spanned via `rowspan`), so we carry the active
#' section context forward across rows. We key on the last `<th>` (the label),
#' record the active rowgroup section labels, and keep the `<td>` node so
#' attachments and text both come from the same place.
#' @noRd
bg_extract_rows <- function(html, register) {
  trs <- rvest::html_elements(html, "table.table-lot tbody tr")
  out <- list()
  # Stack of (section-label, remaining-rowspan) entries that propagate down.
  active <- list()
  for (tr in trs) {
    ths <- rvest::html_elements(tr, "th")
    if (length(ths) == 0L) {
      next
    }
    headers <- ths[
      vapply(ths, function(t) grepl("rowgroup-header", rvest::html_attr(t, "class") %||% ""), logical(1))
    ]
    for (h in headers) {
      span <- suppressWarnings(as.integer(rvest::html_attr(h, "rowspan") %||% "1"))
      if (is.na(span) || span < 1L) {
        span <- 1L
      }
      active[[length(active) + 1L]] <- list(
        label = bg_text(rvest::html_text2(h)) %||% "",
        remaining = span
      )
    }
    sections <- unique(vapply(active, function(a) a$label, character(1)))
    sections <- sections[nzchar(sections)]

    label <- bg_text(rvest::html_text2(ths[[length(ths)]]))
    if (!is.null(label)) {
      td <- rvest::html_element(tr, "td")
      out[[length(out) + 1L]] <- list(label = label, sections = sections, node = td)
    }

    # Decrement every active section's remaining span; drop the exhausted ones.
    for (i in seq_along(active)) {
      active[[i]]$remaining <- active[[i]]$remaining - 1L
    }
    active <- Filter(function(a) a$remaining > 0L, active)
  }
  out
}

#' Return the text value of the first row whose label matches any of `labels`.
#' @noRd
bg_field <- function(rows, labels) {
  for (r in rows) {
    if (r$label %in% labels) {
      td <- r$node
      if (is.null(td) || inherits(td, "xml_missing")) {
        return(NULL)
      }
      return(bg_text(rvest::html_text2(td)))
    }
  }
  NULL
}

#' Return the text value of the first row whose label matches any of `labels`
#' AND whose active rowgroup sections include any of `sections`.
#'
#' Disambiguates the several generic `Наименование` rows on a detail page
#' (proponent name vs plan name vs document names) by the rowgroup section the
#' row sits under.
#' @noRd
bg_field_in_section <- function(rows, labels, sections) {
  for (r in rows) {
    if (r$label %in% labels && any(r$sections %in% sections)) {
      td <- r$node
      if (is.null(td) || inherits(td, "xml_missing")) {
        return(NULL)
      }
      return(bg_text(rvest::html_text2(td)))
    }
  }
  NULL
}

#' Parse document links out of the detail rows, grouped by row-label slug.
#'
#' Each row's value `<td>` may contain one or more `<a href=".../file?...">`
#' download links. We group them under the slugged row label.
#' @noRd
bg_parse_documents <- function(rows) {
  per_section <- list()
  for (r in rows) {
    td <- r$node
    if (is.null(td) || inherits(td, "xml_missing")) {
      next
    }
    anchors <- rvest::html_elements(td, "a[href*='/file?']")
    if (length(anchors) == 0L) {
      next
    }
    hrefs <- rvest::html_attr(anchors, "href")
    hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
    if (length(hrefs) == 0L) {
      next
    }
    urls <- vapply(hrefs, bg_absolute_url, character(1), USE.NAMES = FALSE)
    slug <- bg_section_slug(r$label)
    per_section[[slug]] <- unique(c(per_section[[slug]], urls))
  }
  per_section
}

#' Resolve a relative portal href to an absolute URL.
#'
#' The `fileName` query parameter is required by the server, so the full href
#' is kept verbatim (only the host is prepended). Cyrillic bytes already
#' arrive percent-encoded in the rendered HTML.
#' @noRd
bg_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(bg_portal_base(), href)
}

#' Slug a Bulgarian row label to an ASCII column-suffix slug.
#'
#' Transliterates Cyrillic, lowercases, and collapses non-alphanumerics to
#' underscores. Empty input gets `"document"` as a deterministic fallback.
#' @noRd
bg_section_slug <- function(label) {
  if (is.null(label) || !is.character(label) || length(label) != 1L || is.na(label) || !nzchar(label)) {
    return("document")
  }
  s <- bg_transliterate(label)
  s <- tolower(s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "document" else s
}

#' Transliterate Cyrillic to Latin (best-effort, BGN/PCGN-ish).
#' @noRd
bg_transliterate <- function(s) {
  from <- c(
    "\u0430",
    "\u0431",
    "\u0432",
    "\u0433",
    "\u0434",
    "\u0435",
    "\u0436",
    "\u0437",
    "\u0438",
    "\u0439",
    "\u043a",
    "\u043b",
    "\u043c",
    "\u043d",
    "\u043e",
    "\u043f",
    "\u0440",
    "\u0441",
    "\u0442",
    "\u0443",
    "\u0444",
    "\u0445",
    "\u0446",
    "\u0447",
    "\u0448",
    "\u0449",
    "\u044a",
    "\u044c",
    "\u044e",
    "\u044f"
  )
  to <- c(
    "a",
    "b",
    "v",
    "g",
    "d",
    "e",
    "zh",
    "z",
    "i",
    "y",
    "k",
    "l",
    "m",
    "n",
    "o",
    "p",
    "r",
    "s",
    "t",
    "u",
    "f",
    "h",
    "ts",
    "ch",
    "sh",
    "sht",
    "a",
    "y",
    "yu",
    "ya"
  )
  s <- tolower(s)
  for (i in seq_along(from)) {
    s <- gsub(from[i], to[i], s, fixed = TRUE)
  }
  s
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed BG record: run downloads (if requested) and write sidecar.
#' @noRd
bg_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "bg"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "bg",
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
#' The server honours `projectName` (query), so by the time a record arrives
#' here it has already passed that. Only `date_range` is enforced here,
#' against `date_published`.
#' @noRd
bg_record_matches <- function(rec, date_range) {
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
bg_text <- function(x) {
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

#' Compose an administrative-path string from region / municipality / place.
#' @noRd
bg_join_path <- function(parts) {
  parts <- parts[!vapply(parts, function(p) is.null(p) || is.na(p) || !nzchar(p), logical(1))]
  if (length(parts) == 0L) {
    return(NA_character_)
  }
  paste(unlist(parts), collapse = " / ")
}
