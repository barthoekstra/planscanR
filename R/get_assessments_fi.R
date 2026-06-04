#' Fetch environmental-assessment records from Finland.
#'
#' Implementation of [get_assessments()] for Finland, backed by the national
#' environmental-administration portal **ymparisto.fi**
#' (<https://www.ymparisto.fi/>), a Drupal + React site whose site-search is
#' served by an Elasticsearch index exposed through a same-origin proxy. The
#' register filtered to `type = yva_project` holds the country's
#' *ympäristövaikutusten arviointi* (YVA) project dossiers — i.e.
#' project-level environmental impact assessments (EIA).
#'
#' @section Scope — EIA / YVA only (no SEA):
#' **This handler delivers EIA (YVA) records only.** The ymparisto.fi search
#' index has no SOVA / SEA (*suunnitelmien ja ohjelmien vaikutusten arviointi*)
#' content type — `yva_project` is the only project type in the register — so
#' there is no plan/programme-level strategic assessment to fetch here. The
#' `assessment_type` argument therefore accepts only `"All"` / `"EIA"` (both
#' meaning the same thing); there is no `"SEA"` path. If a Finnish SOVA/SEA
#' register surfaces later it would be a separate handler.
#'
#' @section URL enumeration:
#' The portal proxies raw Elasticsearch Query DSL: a `POST` to
#' `https://www.ymparisto.fi/fi/app/search/query` with a JSON body. The
#' handler filters to `{"query":{"term":{"type":"yva_project"}}}` and paginates
#' with ES `from` / `size` against a stable `sort` (`[{"id":"asc"}]`). The
#' ~1,334 YVA records sit comfortably under the 10,000 `max_result_window`, so
#' simple from-paging covers the whole register. `hits.total.value` carries the
#' count; each result is a `hits.hits[]._source` object. A free-text `query` is
#' added as a `bool.must` `match` on `content` + `title`. The proxy is an open
#' passthrough that returns a Drupal HTTP 500 on a malformed body, so only
#' read-shaped queries (`query` / `from` / `size` / `sort`) are sent and every
#' parse is defensive.
#'
#' @section Geometry:
#' None. Neither the search index nor the landing page exposes coordinates, so
#' no geometry columns are emitted.
#'
#' @section Attachments:
#' Attachment URLs are **not** in the Elasticsearch index — they live only on
#' the HTML landing page. For each kept record the handler GETs the record's
#' `url` (the `link` page) and scrapes every `<a href>` under
#' `/sites/default/files/` (restricted to that path to skip CSS/JS noise),
#' resolving them to absolute
#' `https://www.ymparisto.fi/sites/default/files/documents/<file>.{pdf,doc,docx}`
#' URLs. Files are anonymous (no auth). Because the URLs come from the HTML,
#' this detail fetch runs even when `download = FALSE` (to *populate*
#' `attachment_urls`); it is skipped only when a sidecar already exists for the
#' URL (sidecar-first).
#'
#' Documents are typed by their **anchor text** (the page has no structured
#' section markup) via a curated keyword map with an auto-slug fallback:
#' `arviointiohjelma` → `programme`, `arviointiselostus` → `report`,
#' `lausunto` → `statement`, `kuulutus` → `notice`, `tiivistelma` → `summary`;
#' anything else is auto-slugged from the anchor text. Each discovered type
#' becomes one `attachment_urls_<slug>` / `local_path_<slug>` list-column.
#' `attachment_urls` / `local_path` remain the deduplicated union (required by
#' the schema).
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side free-text (`bool.must` `match` on `content` +
#'    `title` in the ES body).
#' * `assessment_type` — `"All"` (default) or `"EIA"`; both crawl the single
#'    `yva_project` register. No `"SEA"` (none in the register).
#' * `date_range` — matched client-side against `date_published`
#'    (`publishTime`, a unix-seconds epoch). `date_decision` is always `NA`:
#'    the index has no structured decision timestamp.
#'
#' @section Performance:
#' One ES page enumerates 100 records; the ~1,334 per-record HTML landing-page
#' GETs (needed to harvest attachment URLs) dominate a cold crawl. To avoid
#' disrupting the service, FI requests are throttled to 5 requests per second
#' by default; override via `getOption("planscanR.fi_throttle_rate")`
#' (requests/sec; falsy disables). A Swedish `/sv/` index exists but is ignored
#' in v0.1 — the handler defaults to the Finnish `/fi/` index.
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query; sent server-side as a `match` on the ES
#'   `content` + `title` fields.
#' @param assessment_type One of `"All"` (default) or `"EIA"`. The Finnish
#'   register is YVA/EIA-only, so both select the same single `yva_project`
#'   register; `"SEA"` is rejected.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_fi(limit = 3, download = FALSE)
#'
#' # Wind-themed slice (server-side full-text)
#' get_assessments_fi(query = "tuulivoima", limit = 20, download = FALSE)
#' }
get_assessments_fi <- function(
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
  # YVA/EIA-only register: only "All"/"EIA" are meaningful.
  assessment_type <- fi_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  # Politeness throttle. The ~1,334 detail-page GETs (one per kept record, to
  # harvest attachment URLs) dominate a cold crawl; cap at 5 req/s by default.
  rate <- getOption("planscanR.fi_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "fi")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("fi")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Per-entry processing: build the canonical URL, sidecar-first detail fetch,
  # client-side date filter, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry. Called
  # once per listing row by stream_crawl().
  process_entry <- function(entry) {
    u <- fi_canonical_url(entry$link)
    if (is.na(u) || !nzchar(u)) {
      return(NULL)
    }
    rec <- tryCatch(
      fi_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!fi_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    fi_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream the single YVA register page-by-page, persisting records as they are
  # parsed instead of enumerating the whole index first.
  gen <- tryCatch(
    fi_fetch_search(query = query, limit = limit),
    error = function(e) {
      warn_partial(
        "Failed to enumerate ymparisto.fi YVA index: {conditionMessage(e)}"
      )
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "fi")

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
fi_source_portal <- function() "ymparisto.fi"

#' Public base URL for the portal (origin of landing pages + attachments).
#' @noRd
fi_portal_base <- function() "https://www.ymparisto.fi"

#' Elasticsearch search-proxy endpoint (POST, raw ES Query DSL body).
#' @noRd
fi_search_endpoint <- function() "https://www.ymparisto.fi/fi/app/search/query"

#' Elasticsearch page size for the from-paged listing.
#' @noRd
fi_page_size <- function() 100L

#' The single content type that backs the YVA register.
#' @noRd
fi_yva_type <- function() "yva_project"

#' Map our `assessment_type` argument to a normalised value.
#'
#' The Finnish register is YVA/EIA-only, so only `"All"` / `"EIA"` are
#' meaningful (both select the single `yva_project` register). `"SEA"` is
#' rejected because there is no strategic-assessment content type to fetch.
#' @noRd
fi_normalise_assessment_type <- function(x) {
  if (is.null(x) || !nzchar(x)) {
    return("All")
  }
  valid <- c("All", "EIA")
  hit <- valid[tolower(valid) == tolower(x)]
  if (length(hit) == 0L) {
    cli::cli_abort(
      c(
        "{.arg assessment_type} must be one of {.val {valid}} (got {.val {x}}).",
        i = "The Finnish ymparisto.fi register is EIA/YVA-only; there is no SEA register to crawl."
      ),
      class = "planscanR_error_bad_input"
    )
  }
  hit
}

#' Canonical landing URL for a YVA record from its (relative) `link`.
#'
#' The ES `_source.link` is a site-relative path; the canonical landing page
#' is `https://www.ymparisto.fi<link>`. Already-absolute links are returned
#' verbatim. `sidecar_url_index()` keys on this exact URL for cache reuse.
#' @noRd
fi_canonical_url <- function(link) {
  if (is.null(link) || length(link) != 1L || is.na(link) || !nzchar(link)) {
    return(NA_character_)
  }
  link <- trimws(as.character(link))
  if (startsWith(link, "http")) {
    return(link)
  }
  if (!startsWith(link, "/")) {
    link <- paste0("/", link)
  }
  paste0(fi_portal_base(), link)
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' Build a page generator for the Elasticsearch index (`type=yva_project`).
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call POSTs the next ES from/size page (stable id sort) and returns that
#' page's `_source` objects, or `NULL` once the index is exhausted. Each
#' `_source` is a named list with `id`, `link`, `title`, `description`,
#' `publishTime`, `projectPhase`, `organization`, `municipality`, `province`,
#' `subjectArea`, `typeLabel`, .... Pagination state (the `from` offset, the
#' running emitted count, and the exhausted flag) lives in the closure, so the
#' streaming driver pulls only as many pages as the limit needs and records are
#' persisted page-by-page.
#'
#' The single network seam is still `fi_es_search()` (the test mock boundary),
#' invoked once per generator call. Termination mirrors the original from-paging
#' loop: empty hits, reaching `hits.total.value`, or a short server page each
#' end the register. `limit` is retained for call-site compatibility (and the
#' soft `limit * 3` page ceiling), but stream_crawl already stops pulling pages
#' once enough records are kept.
#' @noRd
fi_fetch_search <- function(query = NULL, limit = Inf) {
  from <- 0L
  size <- fi_page_size()
  emitted <- 0L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    body <- fi_search_body(query = query, from = from, size = size)
    payload <- fi_es_search(body)
    hits <- fi_es_hits(payload)
    if (length(hits) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    page <- list()
    for (h in hits) {
      src <- h$`_source`
      if (is.list(src)) {
        page[[length(page) + 1L]] <- src
      }
    }
    emitted <<- emitted + length(page)
    total <- fi_es_total(payload)
    if (!is.null(total) && emitted >= total) {
      done <<- TRUE
    } else if (is.finite(limit) && emitted >= as.integer(limit) * 3L) {
      # Soft stop: stop paging once we've enumerated at least `limit * 3` rows.
      done <<- TRUE
    } else if (length(hits) < size) {
      # Server short page → end of register.
      done <<- TRUE
    } else {
      from <<- from + size
    }
    page
  }
}

#' Build the Elasticsearch Query DSL body for one listing page.
#'
#' Always constrains `type = yva_project`. A non-empty `query` adds a
#' `bool.must` `match` over `content` + `title`. Only read-shaped fields
#' (`query` / `from` / `size` / `sort`) are sent — the proxy 500s a malformed
#' body.
#' @noRd
fi_search_body <- function(query = NULL, from = 0L, size = 100L) {
  type_filter <- list(term = list(type = fi_yva_type()))
  if (!is.null(query) && nzchar(query)) {
    es_query <- list(
      bool = list(
        filter = list(type_filter),
        must = list(
          list(
            multi_match = list(
              query = as.character(query),
              fields = list("content", "title")
            )
          )
        )
      )
    )
  } else {
    es_query <- type_filter
  }
  list(
    from = from,
    size = size,
    query = es_query,
    sort = list(list(id = "asc"))
  )
}

#' The single network seam for the listing: POST the ES body, parse JSON.
#'
#' Tests mock this binding to replay a recorded listing fixture instead of
#' hitting the proxy.
#' @noRd
fi_es_search <- function(body) {
  req <- req_planscanr(fi_search_endpoint())
  req <- httr2::req_body_json(req, body, auto_unbox = TRUE)
  perform_json(req)
}

#' Pull the `hits.hits[]` array out of an ES response (defensively).
#' @noRd
fi_es_hits <- function(payload) {
  if (!is.list(payload)) {
    return(list())
  }
  hits <- payload$hits$hits
  if (is.null(hits) || !is.list(hits)) {
    return(list())
  }
  hits
}

#' Pull `hits.total.value` out of an ES response (or NULL).
#' @noRd
fi_es_total <- function(payload) {
  if (!is.list(payload)) {
    return(NULL)
  }
  v <- payload$hits$total$value
  if (is.null(v)) {
    return(NULL)
  }
  as.integer(v)
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch + parse.
#'
#' Mirrors the BE / EE pattern. When the sidecar is missing, fetches the HTML
#' landing page (to harvest the attachment URLs, which are absent from the ES
#' index), then builds the record from the ES `_source` + the scraped links.
#' @noRd
fi_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  html <- fi_fetch_detail(url)
  per_section <- fi_parse_detail(html)
  fi_build_record(url, entry, per_section)
}

#' Fetch one YVA landing page as parsed HTML.
#'
#' The single HTML network seam; tests mock this to replay a detail fixture.
#' @noRd
fi_fetch_detail <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Scrape attachment URLs from a landing page, grouped by curated type.
#'
#' Returns a named list of absolute-URL vectors keyed by the curated slug
#' (`programme` / `report` / `statement` / `notice` / `summary`) or an
#' auto-slug derived from the anchor text. Only `<a href>` under
#' `/sites/default/files/` are considered (this excludes the CSS/JS asset
#' references, which are not anchors). Anchors that don't end in a document
#' extension are still captured (some links lack one), but pure asset paths
#' under `/files/css/` or `/files/js/` are dropped.
#' @noRd
fi_parse_detail <- function(html) {
  anchors <- rvest::html_elements(
    html,
    xpath = "//a[contains(@href, '/sites/default/files/')]"
  )
  per_section <- list()
  for (a in anchors) {
    href <- rvest::html_attr(a, "href")
    if (is.na(href) || !nzchar(href)) {
      next
    }
    # Drop aggregated asset bundles (CSS/JS) that also live under /files/.
    if (grepl("/sites/default/files/(css|js)/", href)) {
      next
    }
    url <- fi_absolute_url(href)
    text <- fi_text(rvest::html_text2(a))
    slug <- fi_section_slug(text)
    per_section[[slug]] <- unique(c(per_section[[slug]], url))
  }
  per_section
}

#' Curated anchor-text keyword → stable slug map.
#'
#' The landing page has no structured section markup, so documents are typed
#' from their anchor text. Each entry is a lowercase Finnish keyword (matched
#' as a substring against the anchor text) mapped to a stable column slug.
#' Order matters: the first matching keyword wins, so the more specific
#' `arviointiselostus` (report) is checked before `arviointiohjelma`
#' (programme) would be — they share a stem but differ at the suffix.
#' @noRd
fi_section_map <- function() {
  # Order matters: the first matching keyword wins. The specific
  # document-*kind* words (a summary / statement / notice *of* a programme or
  # report) are checked before the broad `ohjelma` / `selostus` stems, so e.g.
  # "Arviointiohjelman Tiivistelmä" types as `summary`, not `programme`.
  c(
    tiivistelma = "summary",
    lausunto = "statement",
    kuulutus = "notice",
    arviointiselostus = "report",
    arviointiohjelma = "programme",
    selostus = "report",
    ohjelma = "programme"
  )
}

#' Map an anchor-text string to a column/sidecar slug.
#'
#' Known keywords (see `fi_section_map()`) get their curated slug, matched as a
#' case-insensitive, diacritic-folded substring of the anchor text. Everything
#' else is auto-slugged from the text: Finnish diacritics are transliterated
#' (ä/ö → a/o), then lowercased with non-alphanumerics collapsed to
#' underscores, truncated to a sane length so a long anchor doesn't yield a
#' giant column name.
#' @noRd
fi_section_slug <- function(text) {
  folded <- fi_fold(text)
  if (nzchar(folded)) {
    map <- fi_section_map()
    for (kw in names(map)) {
      if (grepl(kw, folded, fixed = TRUE)) {
        return(unname(map[[kw]]))
      }
    }
  }
  s <- ascii_slug(folded, "document")
  if (identical(s, "document")) {
    return("document")
  }
  # Cap the auto-slug so a verbose anchor doesn't produce an unwieldy column.
  if (nchar(s) > 40L) {
    s <- substr(s, 1L, 40L)
    s <- gsub("_+$", "", s)
  }
  s
}

#' Lowercase + transliterate Finnish diacritics for slug / keyword matching.
#' @noRd
fi_fold <- function(x) {
  if (is.null(x) || length(x) != 1L || is.na(x) || !nzchar(x)) {
    return("")
  }
  s <- tolower(as.character(x))
  s <- gsub("\u00e4", "a", s)
  s <- gsub("\u00f6", "o", s)
  s <- gsub("\u00e5", "a", s)
  s <- gsub("\u00fc", "u", s)
  trimws(s)
}

#' Resolve a relative portal href to an absolute URL.
#' @noRd
fi_absolute_url <- function(href) {
  href <- trimws(href)
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(fi_portal_base(), href)
}

#' Build a 1-row record tibble from an ES `_source` + the scraped attachments.
#'
#' All metadata comes from the index; the per-section attachment columns come
#' from `per_section` (the curated/auto-slugged scrape of the landing page).
#' `document_id` is prefixed `YVA-<id>` (the id space is shared across content
#' types, so the prefix + the `type` filter prevent cross-type collisions).
#' @noRd
fi_build_record <- function(url, entry, per_section) {
  raw_id <- as.character(entry$id %||% NA_character_)
  document_id <- if (is.na(raw_id) || !nzchar(raw_id)) {
    paste0("YVA-", fi_id_from_url(url))
  } else {
    paste0("YVA-", raw_id)
  }

  title <- fi_text(entry$title) %||% NA_character_
  # `description` is the short abstract; `content` is the full (often long)
  # narrative. Prefer description for `summary`.
  summary_text <- fi_text(entry$description) %||% NA_character_

  date_published <- fi_epoch_to_date(entry$publishTime)

  competent_authority <- fi_join(entry$organization)
  jurisdiction <- fi_compose_jurisdiction(entry$municipality, entry$province)
  status <- fi_join(entry$projectPhase)
  native_type <- fi_join(entry$subjectArea)

  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "fi",
    source_portal = fi_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = summary_text,
    competent_authority = competent_authority %||% NA_character_,
    # The index exposes no proponent (hankkeesta vastaava) as a structured
    # field — it only appears in prose. Left NA.
    proponent = NA_character_,
    date_published = date_published,
    date_decision = as.Date(NA),
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status %||% NA_character_,
    assessment_type = "EIA",
    type_label = fi_text(entry$typeLabel) %||% NA_character_,
    project_phase = status %||% NA_character_,
    subject_area = native_type %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Compose a jurisdiction string from municipality + province arrays.
#'
#' Municipalities first (the more specific), then any provinces not already
#' named, joined with "; ". Returns NULL when both are empty.
#' @noRd
fi_compose_jurisdiction <- function(municipality, province) {
  muni <- fi_chr_vec(municipality)
  prov <- fi_chr_vec(province)
  prov <- setdiff(prov, muni)
  parts <- c(muni, prov)
  if (length(parts) == 0L) {
    return(NULL)
  }
  paste(parts, collapse = "; ")
}

#' Last path segment of a landing URL, as a fallback document id.
#' @noRd
fi_id_from_url <- function(url) {
  seg <- sub("[?#].*$", "", url)
  seg <- sub("/+$", "", seg)
  basename(seg)
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed FI record: run downloads (if requested) and write sidecar.
#' @noRd
fi_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "fi"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "fi",
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
#' `query` is honoured server-side by the ES proxy, so only `date_range` is
#' enforced here (against `date_published`).
#' @noRd
fi_record_matches <- function(rec, date_range) {
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
fi_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  s <- gsub("[ \t]{2,}", " ", s)
  if (!nzchar(s)) NULL else s
}

#' Coerce an ES array field to a character vector (drop NA / empty).
#' @noRd
fi_chr_vec <- function(x) {
  if (is.null(x) || length(x) == 0L) {
    return(character(0))
  }
  out <- vapply(
    as.list(x),
    function(v) {
      if (is.null(v) || length(v) != 1L || is.na(v)) NA_character_ else as.character(v)
    },
    character(1)
  )
  out <- trimws(out[!is.na(out)])
  out[nzchar(out)]
}

#' Join an ES array field into a single "; "-separated scalar (or NULL).
#' @noRd
fi_join <- function(x) {
  v <- fi_chr_vec(x)
  if (length(v) == 0L) {
    return(NULL)
  }
  paste(unique(v), collapse = "; ")
}

#' Parse a unix-seconds epoch into a Date (UTC), or NA.
#' @noRd
fi_epoch_to_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  n <- suppressWarnings(as.numeric(x))
  if (is.na(n)) {
    return(as.Date(NA))
  }
  as.Date(as.POSIXct(n, origin = "1970-01-01", tz = "UTC"))
}
