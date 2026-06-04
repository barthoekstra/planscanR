#' Fetch environmental-assessment records from Croatia.
#'
#' Implementation of [get_assessments()] for Croatia. Croatia has **no**
#' machine-readable register or API: the "register" is a small set of
#' server-rendered ASP.NET CMS pages on the Ministry of Environment and Green
#' Transition portal (`mzozt.gov.hr`, formerly `mingor.gov.hr` /
#' `mingo.hr` — old links 30x-redirect to the new host). Each procedure is an
#' inlined `<li><strong>PROJECT TITLE</strong> <ul>...document links...</ul></li>`
#' block with direct, anonymous `.pdf` (sometimes `.zip`) download links.
#'
#' Two "registers" are merged into a single result tibble; an
#' `assessment_type` column (`"EIA"` for PUO, `"SEA"` for SPUO) tags each row
#' and is round-tripped to the sidecar so downstream tooling can tell them
#' apart without re-fetching anything. `document_id` is prefixed with
#' `"HR-PUO-"` / `"HR-SPUO-"` so the two registers never collide on disk.
#'
#' * **PUO** — *Procjena utjecaja zahvata na okoliš* (project-level EIA). One
#'   master archive page lists every procedure (years 2012–present) inline.
#' * **SPUO** — *Strateška procjena utjecaja na okoliš* (plan/programme SEA).
#'   Two pages: Ministry-competent procedures and other-competent-body
#'   procedures.
#'
#' @section URL enumeration:
#' There is **no** pagination, no per-record detail endpoint, and no native
#' procedure id. The whole record (title + all documents, grouped by stage)
#' lives inline in one of three master pages. The handler fetches each master
#' page once and treats each `<li><strong>` block as one record. Because there
#' is no native id, `document_id` is a stable deterministic hash of the title
#' (`HR-PUO-<sha1(title)[1:10]>` / `HR-SPUO-...`), folding in a cleanly-parseable
#' year when present. `url` is the master-page URL plus `#<document_id>` so each
#' record has a unique landing URL (required for sidecar reuse) while still
#' pointing a human at the right page.
#'
#' @section Geometry:
#' The CMS pages expose **no** coordinates or GeoJSON. No geometry columns are
#' emitted. Spatial information, where present, is inside the PDFs.
#'
#' @section Attachments:
#' Documents are grouped by the stage sub-heading they sit under (PUO
#' *informacija o zahtjevu* / *javni uvid* / *nacrt rješenja* / *rješenje*; SPUO
#' procedures often list their documents flat under the title with no stage
#' sub-heading, which fall under the `document` slug). Known stage labels get a
#' stable curated slug (see the internal `hr_stage_map()`); anything else is
#' auto-slugged from the heading (Croatian diacritics transliterated to ASCII,
#' lowercased, non-alphanumerics collapsed to underscores). Each stage becomes
#' an `attachment_urls_<slug>` / `local_path_<slug>` list-column; the
#' deduplicated union goes into `attachment_urls` / `local_path` (required by
#' the schema).
#'
#' The `href` is captured verbatim as rendered (with its spaces and Croatian
#' diacritics). Those characters are percent-encoded for the network request at
#' download time; the original un-encoded href is what the sidecar stores.
#' Downloads are anonymous (no authentication). Some attachments are `.zip`.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — selects which register(s) to crawl: `"All"`
#'    (default), `"EIA"` (PUO only), or `"SEA"` (SPUO only).
#' * `query` — client-side substring match on the project/plan title (the CMS
#'    pages have no server-side search).
#' * `date_range` — matched client-side against `date_published` (the earliest
#'    document date in the block). `date_decision` is the *rješenje* / *odluka*
#'    (decision) date when present, else `NA`.
#'
#' @section Performance:
#' The PUO master page is large (~550 procedures / ~2,500 documents in one
#' HTML fetch); SPUO is small. Enumeration is only ~3 HTML fetches plus N PDF
#' downloads, so HR requests are throttled to 5 requests per second by default
#' (politeness for the download phase). Override via
#' `getOption("planscanR.hr_throttle_rate")` (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query matched client-side against the project/plan
#'   title.
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
#' get_assessments_hr(limit = 3, download = FALSE)
#'
#' # Wind-themed slice (client-side title match)
#' get_assessments_hr(query = "vjetroelektrana", limit = 20, download = FALSE)
#'
#' # SEA only
#' get_assessments_hr(assessment_type = "SEA", download = FALSE)
#' }
get_assessments_hr <- function(
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
  assessment_type <- hr_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.hr_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "hr")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("hr")
  } else {
    stats::setNames(character(0), character(0))
  }

  registers <- switch(
    assessment_type,
    All = c("PUO", "SPUO"),
    EIA = "PUO",
    SEA = "SPUO"
  )

  # Per-entry processing: cheap title filter, sidecar-first block parse,
  # client-side date filter, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry. Shared
  # across both registers' streams and called once per listing row by
  # stream_crawl().
  process_entry <- function(entry) {
    # Cheap client-side title filter before the (potentially cached) full parse.
    if (!hr_title_matches(entry$title, query)) {
      return(NULL)
    }
    rec <- tryCatch(
      hr_load_or_fetch(entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial(
          "Failed to load/parse {.url {entry$url}}: {conditionMessage(e)}"
        )
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!hr_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    hr_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream each register page-by-page, persisting records as they are parsed
  # instead of enumerating the whole register first. `limit` is global across
  # both registers, so a full PUO crawl can consume all of it before SPUO.
  records <- list()
  for (reg in registers) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    gen <- tryCatch(
      hr_enumerate_register(reg),
      error = function(e) {
        warn_partial(
          "Failed to enumerate mzozt.gov.hr {.val {reg}} pages: {conditionMessage(e)}"
        )
        function() NULL
      }
    )
    block <- stream_crawl(gen, process_entry, limit = remaining, label = "hr")
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
hr_source_portal <- function() "mzozt.gov.hr"

#' Public base URL for the portal.
#' @noRd
hr_portal_base <- function() "https://mzozt.gov.hr"

#' The PUO (EIA) master archive page URL.
#' @noRd
hr_puo_url <- function() {
  paste0(
    "https://mzozt.gov.hr/o-ministarstvu-1065/djelokrug-rada/",
    "uprava-za-procjenu-utjecaja-na-okolis-i-odrzivo-gospodarenje-otpadom-1271/",
    "procjena-utjecaja-na-okolis-puo-spuo/",
    "procjena-utjecaja-zahvata-na-okolis-puo-4014/4014"
  )
}

#' The SPUO (SEA) master page URLs (Ministry-competent + other-competent).
#' @noRd
hr_spuo_urls <- function() {
  base <- paste0(
    "https://mzozt.gov.hr/o-ministarstvu-1065/djelokrug-rada/",
    "uprava-za-procjenu-utjecaja-na-okolis-i-odrzivo-gospodarenje-otpadom-1271/",
    "procjena-utjecaja-na-okolis-puo-spuo/",
    "strateska-procjena-utjecaja-na-okolis-spuo-4015/"
  )
  c(
    paste0(
      base,
      "postupci-strateske-procjene-nadlezno-tijelo-je-ministarstvo/4037"
    ),
    paste0(base, "4038")
  )
}

#' Master-page URL(s) for a register.
#' @noRd
hr_register_urls <- function(register) {
  if (register == "PUO") hr_puo_url() else hr_spuo_urls()
}

#' Competent authority constant for the Ministry-competent registers.
#' @noRd
hr_ministry_authority <- function() {
  "Ministarstvo za\u0161tite okoli\u0161a i zelene tranzicije"
}

#' Map our `assessment_type` argument to a normalised value.
#' @noRd
hr_normalise_assessment_type <- function(x) {
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

#' Build a page generator for a register's master page(s).
#'
#' Returns a zero-arg closure (the [stream_crawl()] `next_page` contract): each
#' call fetches the NEXT master page of the register, light-parses its project
#' `<li><strong>` blocks into index entries, and returns them; `NULL` once every
#' master page has been consumed. A register's master pages are fixed (PUO has
#' one, SPUO has two), so the generator walks them in order — yielding one page's
#' worth of entries per call — and the within-register de-duplication state
#' (`seen_ids`, for the same plan appearing across the two SPUO pages) lives in
#' the closure so it persists across pages.
#'
#' Each entry is a small named list:
#' `list(register = "PUO"|"SPUO", document_id = ..., url = ..., title = ...,
#'  assessment_type = "EIA"|"SEA", block = <xml_node>)`. The full block parse is
#' deferred (sidecar-first), so this is deliberately the minimum needed to
#' build the canonical URL, decide whether to keep going, and (on a cache miss)
#' hand the block node to `hr_parse_block()`.
#' @noRd
hr_enumerate_register <- function(register) {
  urls <- hr_register_urls(register)
  i <- 0L
  seen_ids <- character(0)
  function() {
    repeat {
      i <<- i + 1L
      if (i > length(urls)) {
        return(NULL)
      }
      page_url <- urls[[i]]
      html <- tryCatch(hr_fetch_page(page_url), error = function(e) NULL)
      if (is.null(html)) {
        next
      }
      blocks <- hr_project_blocks(html)
      out <- list()
      for (block in blocks) {
        title <- hr_block_title(block)
        if (is.null(title)) {
          next
        }
        document_id <- hr_document_id(register, title)
        # De-duplicate within a register (the same plan can appear twice across
        # the two SPUO pages); keep the first occurrence.
        if (document_id %in% seen_ids) {
          next
        }
        seen_ids <<- c(seen_ids, document_id)
        out[[length(out) + 1L]] <- list(
          register = register,
          document_id = document_id,
          url = hr_canonical_url(page_url, document_id),
          title = title,
          assessment_type = if (register == "PUO") "EIA" else "SEA",
          block = block
        )
      }
      # A master page may contribute no new entries (empty page, or all-dupes
      # across the two SPUO pages). Don't yield an empty list — stream_crawl
      # treats that as exhaustion — instead advance to the next master page.
      if (length(out) == 0L) {
        next
      }
      return(out)
    }
  }
}

#' Fetch one master page as parsed HTML.
#' @noRd
hr_fetch_page <- function(url) {
  req <- req_planscanr(url)
  perform_html(req)
}

#' Canonical landing URL: master-page URL + "#" + document_id.
#'
#' The master pages carry no per-procedure permalink, so we synthesise a unique
#' URL per record (required for `sidecar_url_index()` reuse) that still points a
#' human at the right page.
#' @noRd
hr_canonical_url <- function(page_url, document_id) {
  paste0(page_url, "#", document_id)
}

#' Stable deterministic document id from the project/plan title.
#'
#' There is no native procedure id and documents get added over time, so we key
#' off a short SHA-1 of the normalised title. A cleanly-parseable trailing year
#' (e.g. "...2023.") is folded in so two same-named procedures in different
#' years don't collide.
#' @noRd
hr_document_id <- function(register, title) {
  prefix <- if (register == "PUO") "HR-PUO-" else "HR-SPUO-"
  norm <- tolower(trimws(gsub("\\s+", " ", title)))
  hash <- substr(openssl::sha1(norm), 1L, 10L)
  year <- hr_extract_year(title)
  if (!is.na(year)) {
    sprintf("%s%s-%s", prefix, hash, year)
  } else {
    paste0(prefix, hash)
  }
}

#' Pull a plausible 4-digit year (2000-2099) from a title, else NA.
#' @noRd
hr_extract_year <- function(title) {
  m <- regmatches(title, gregexpr("\\b20[0-9]{2}\\b", title))[[1]]
  if (length(m) == 0L) {
    return(NA_character_)
  }
  # Use the latest year mentioned (plan-period titles like "2022.-2027.").
  as.character(max(as.integer(m)))
}

#' Select the top-level project `<li><strong>` blocks on a master page.
#'
#' Project blocks are the `<li>` elements whose first element child is a
#' `<strong>` — the procedure title. Stage sub-headings and document anchors are
#' nested deeper and excluded by requiring the `<strong>` to be a direct child.
#' @noRd
hr_project_blocks <- function(html) {
  nodes <- rvest::html_elements(html, xpath = "//li[strong]")
  # Keep only those whose strong is a *direct* child carrying the title text.
  Filter(
    function(n) {
      strong <- rvest::html_element(n, xpath = "./strong")
      if (inherits(strong, "xml_missing")) {
        return(FALSE)
      }
      nzchar(hr_text(rvest::html_text2(strong)) %||% "")
    },
    nodes
  )
}

#' Extract the title from a project block's leading `<strong>`(s).
#'
#' Some titles are split across several adjacent `<strong>` runs (a few carry
#' stray empty `<strong>` tags or an anchor-wrapped strong); we join the direct
#' `<strong>` children and collapse whitespace.
#' @noRd
hr_block_title <- function(block) {
  strongs <- rvest::html_elements(block, xpath = "./strong | ./a/strong")
  parts <- vapply(strongs, function(s) hr_text(rvest::html_text2(s)) %||% "", character(1))
  parts <- parts[nzchar(parts)]
  if (length(parts) == 0L) {
    return(NULL)
  }
  hr_text(paste(parts, collapse = " "))
}

# -----------------------------------------------------------------------------
# Block parsing (sidecar-first)
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else parse the block.
#' @noRd
hr_load_or_fetch <- function(entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[entry$url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  hr_parse_block(entry)
}

#' Parse one project block into a 1-row tibble.
#'
#' Walks the block's first-level `<ul>`: each `<li>` is either a stage
#' sub-heading (leading text + a nested `<ul>` of anchors) or — for flat
#' SPUO/Ministry-competent procedures — a bare document anchor directly under
#' the title. Anchors are grouped by stage slug; per-anchor `DD.MM.YYYY.` date
#' prefixes feed `date_published` / `date_decision`.
#' @noRd
hr_parse_block <- function(entry) {
  block <- entry$block
  register <- entry$register
  document_id <- entry$document_id
  url <- entry$url
  title <- entry$title

  per_section <- hr_parse_documents(block)
  union_urls <- hr_union_urls(per_section)

  dates <- hr_collect_dates(block)
  date_published <- if (length(dates) > 0L) min(dates) else as.Date(NA)
  decision_dates <- hr_decision_dates(block)
  date_decision <- if (length(decision_dates) > 0L) max(decision_dates) else as.Date(NA)

  native_type <- hr_native_type(block, register)
  status <- hr_infer_status(block, register)
  jurisdiction <- hr_jurisdiction_from_title(title)
  competent_authority <- if (register == "PUO" || hr_is_ministry_url(url)) {
    hr_ministry_authority()
  } else {
    NA_character_
  }

  rec <- tibble::tibble(
    country = "hr",
    source_portal = hr_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = NA_character_,
    competent_authority = competent_authority %||% NA_character_,
    proponent = NA_character_,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status %||% NA_character_,
    assessment_type = entry$assessment_type,
    register = register,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Parse the document anchors of a project block, grouped by stage slug.
#'
#' Returns a named list of URL vectors keyed by stage slug. Stage sub-headings
#' (an `<li>` with leading text and a nested `<ul>` of anchors) map to their
#' curated/auto slug; flat anchors directly under the title fall under
#' `"document"`.
#' @noRd
hr_parse_documents <- function(block) {
  ul <- rvest::html_element(block, xpath = "./ul")
  if (inherits(ul, "xml_missing")) {
    return(list())
  }
  lis <- rvest::html_elements(ul, xpath = "./li")
  per_section <- list()
  for (li in lis) {
    sub_ul <- rvest::html_element(li, xpath = "./ul")
    if (!inherits(sub_ul, "xml_missing")) {
      # Stage sub-heading: leading text before the nested <ul> is the heading.
      heading <- hr_li_leading_text(li)
      slug <- hr_stage_slug(heading)
      urls <- hr_anchor_urls(sub_ul)
      if (length(urls) > 0L) {
        per_section[[slug]] <- unique(c(per_section[[slug]], urls))
      }
    } else {
      # Flat document anchor directly under the title.
      urls <- hr_anchor_urls(li)
      if (length(urls) > 0L) {
        per_section[["document"]] <- unique(c(per_section[["document"]], urls))
      }
    }
  }
  per_section
}

#' Document hrefs (anchors) inside a node, captured verbatim.
#' @noRd
hr_anchor_urls <- function(node) {
  anchors <- rvest::html_elements(node, xpath = ".//a[@href]")
  hrefs <- rvest::html_attr(anchors, "href")
  hrefs <- hrefs[!is.na(hrefs) & nzchar(hrefs)]
  hrefs <- hrefs[grepl("\\.(pdf|zip|docx?|xlsx?)$", hrefs, ignore.case = TRUE) | grepl("^https?://", hrefs)]
  unique(hrefs)
}

#' Leading text of an `<li>` up to (but excluding) its nested `<ul>`.
#'
#' libxml2 renders an `<li>STAGE<ul>...</ul></li>` so the heading is the text
#' node(s) before the nested `<ul>`. We read the `<li>`'s own text, then strip
#' the nested-`<ul>` text from the tail.
#' @noRd
hr_li_leading_text <- function(li) {
  own <- rvest::html_text2(li)
  sub_ul <- rvest::html_element(li, xpath = "./ul")
  if (!inherits(sub_ul, "xml_missing")) {
    inner <- rvest::html_text2(sub_ul)
    own <- sub(inner, "", own, fixed = TRUE)
  }
  hr_text(own)
}

#' Deduplicated union of per-section URLs, curated stages first.
#' @noRd
hr_union_urls <- function(per_section) {
  if (length(per_section) == 0L) {
    return(character(0))
  }
  curated_slugs <- unname(hr_stage_map())
  slug_order <- c(
    intersect(curated_slugs, names(per_section)),
    setdiff(names(per_section), curated_slugs)
  )
  unique(unlist(per_section[slug_order], use.names = FALSE)) %||% character(0)
}

# -----------------------------------------------------------------------------
# Stage slugging (curated map + auto-slug fallback)
# -----------------------------------------------------------------------------

#' Curated map from known PUO stage headings to stable planscanR slugs.
#'
#' Croatia's stage labels are messy (casing, `&nbsp;`, zero-width characters,
#' diacritics), so we normalise heavily before matching. This is NOT exhaustive:
#' any heading not listed here is auto-slugged from its normalised text via
#' `hr_stage_slug()`, so a new stage type flows through to its own
#' `attachment_urls_<slug>` column without a code change.
#' @noRd
hr_stage_map <- function() {
  c(
    "puo informacija o zahtjevu" = "informacija_o_zahtjevu",
    "puo javni uvid" = "javni_uvid",
    "puo nacrt rjesenja" = "nacrt_rjesenja",
    "puo nacrt" = "nacrt_rjesenja",
    "puo rjesenje" = "rjesenje"
  )
}

#' Slug a stage heading to a column-suffix slug.
#'
#' Normalises spacing / `&nbsp;` / casing / Croatian diacritics, then looks the
#' result up in the curated map; on a miss, auto-slugs from the normalised text.
#' Empty input gets `"document"` as a deterministic fallback.
#' @noRd
hr_stage_slug <- function(heading) {
  norm <- hr_normalise_heading(heading)
  if (is.null(norm) || !nzchar(norm)) {
    return("document")
  }
  curated <- hr_stage_map()
  if (norm %in% names(curated)) {
    return(unname(curated[[norm]]))
  }
  s <- gsub("[^a-z0-9]+", "_", norm)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "document" else s
}

#' Normalise a heading: strip `&nbsp;`/zero-width, transliterate diacritics,
#' lowercase, collapse whitespace.
#' @noRd
hr_normalise_heading <- function(heading) {
  if (is.null(heading) || !is.character(heading) || length(heading) != 1L || is.na(heading)) {
    return(NULL)
  }
  s <- heading
  # Non-breaking spaces / zero-width chars -> plain space / nothing.
  s <- gsub("\u00a0", " ", s)
  s <- gsub("[\u200b\u200c\u200d\ufeff]", "", s)
  s <- hr_transliterate(s)
  s <- tolower(s)
  s <- gsub("\\s+", " ", s)
  trimws(s)
}

#' Transliterate Croatian diacritics to ASCII (žćšđč -> z c s d c).
#' @noRd
hr_transliterate <- function(s) {
  from <- c(
    "\u017e",
    "\u017d",
    "\u0107",
    "\u0106",
    "\u0161",
    "\u0160",
    "\u0111",
    "\u0110",
    "\u010d",
    "\u010c"
  )
  to <- c("z", "z", "c", "c", "s", "s", "d", "d", "c", "c")
  for (i in seq_along(from)) {
    s <- gsub(from[i], to[i], s, fixed = TRUE)
  }
  s
}

# -----------------------------------------------------------------------------
# Dates / metadata
# -----------------------------------------------------------------------------

#' Collect every `DD.MM.YYYY` date appearing in a block's anchor texts.
#' @noRd
hr_collect_dates <- function(block) {
  anchors <- rvest::html_elements(block, xpath = ".//a")
  texts <- vapply(anchors, function(a) rvest::html_text2(a) %||% "", character(1))
  hr_parse_dates(texts)
}

#' Collect the decision-stage (`rješenje` / `odluka`) dates in a block.
#' @noRd
hr_decision_dates <- function(block) {
  anchors <- rvest::html_elements(block, xpath = ".//a")
  texts <- vapply(anchors, function(a) rvest::html_text2(a) %||% "", character(1))
  decision <- grepl("rje\u0161enj|odluk", texts, ignore.case = TRUE)
  hr_parse_dates(texts[decision])
}

#' Parse a vector of anchor texts to the Dates carried by their `DD.MM.YYYY.`
#' prefixes (texts with no date are dropped).
#' @noRd
hr_parse_dates <- function(texts) {
  out <- as.Date(character(0))
  for (t in texts) {
    m <- regmatches(t, regexpr("[0-9]{1,2}\\.[0-9]{1,2}\\.[0-9]{4}", t))
    if (length(m) == 0L || !nzchar(m)) {
      next
    }
    d <- suppressWarnings(as.Date(m, format = "%d.%m.%Y"))
    if (!is.na(d)) {
      out <- c(out, d)
    }
  }
  out
}

#' native_type: the stage sub-headings present (PUO), else a generic SPUO tag.
#' @noRd
hr_native_type <- function(block, register) {
  ul <- rvest::html_element(block, xpath = "./ul")
  if (inherits(ul, "xml_missing")) {
    return(if (register == "PUO") NA_character_ else "SPUO")
  }
  lis <- rvest::html_elements(ul, xpath = "./li[ul]")
  headings <- vapply(
    lis,
    function(li) hr_normalise_heading(hr_li_leading_text(li)) %||% "",
    character(1)
  )
  headings <- unique(headings[nzchar(headings)])
  if (length(headings) == 0L) {
    return(if (register == "PUO") NA_character_ else "SPUO")
  }
  paste(headings, collapse = " | ")
}

#' Infer a coarse status from the stages present (decision => decided).
#'
#' PUO procedures are "decided" once a *rješenje* (decision) document is
#' present; SPUO procedures once an adoption *odluka* is present. Both signals
#' are also reflected in the decision-date collection, so we fall back to that.
#' @noRd
hr_infer_status <- function(block, register) {
  txt <- rvest::html_text2(block)
  decided <- grepl("rje\u0161enj", txt, ignore.case = TRUE) ||
    grepl("Odluka o prihva|Odluka o usvaja|Odluka o dono", txt, ignore.case = TRUE) ||
    length(hr_decision_dates(block)) > 0L
  if (decided) "decided" else "ongoing"
}

#' Heuristically pull a county/grad from the title into `jurisdiction`.
#'
#' Titles commonly end "..., Grad X, Y županija" or "..., Općina X, Y županija".
#' We grab the trailing administrative segments when trivially present, else NA.
#' @noRd
hr_jurisdiction_from_title <- function(title) {
  if (is.null(title) || is.na(title) || !nzchar(title)) {
    return(NA_character_)
  }
  parts <- trimws(strsplit(title, ",")[[1]])
  admin <- parts[grepl(
    "(Grad|Op\u0107ina|\u017eupanija)",
    parts,
    ignore.case = TRUE
  )]
  if (length(admin) == 0L) {
    return(NA_character_)
  }
  paste(admin, collapse = " / ")
}

#' Whether a canonical URL points at the Ministry-competent SPUO page.
#' @noRd
hr_is_ministry_url <- function(url) {
  grepl("nadlezno-tijelo-je-ministarstvo", url)
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed HR record: run downloads (if requested) and write sidecar.
#' @noRd
hr_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "hr"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "hr",
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

#' Client-side title substring filter (case-insensitive). NULL/empty = pass.
#' @noRd
hr_title_matches <- function(title, query) {
  if (is.null(query) || !nzchar(query)) {
    return(TRUE)
  }
  if (is.null(title) || is.na(title) || !nzchar(title)) {
    return(FALSE)
  }
  # Case-insensitive literal substring match (no regex metacharacters).
  grepl(tolower(query), tolower(title), fixed = TRUE)
}

#' Apply post-fetch client-side filters (only `date_range`, vs date_published).
#' @noRd
hr_record_matches <- function(rec, date_range) {
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
hr_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- as.character(x)
  s <- gsub("\u00a0", " ", s)
  s <- gsub("[\u200b\u200c\u200d\ufeff]", "", s)
  s <- trimws(s)
  s <- gsub("[ \t]*\n[ \t]*", "\n", s)
  s <- gsub("[ \t]{2,}", " ", s)
  s <- gsub("\n{2,}", "\n", s)
  s <- trimws(s)
  if (!nzchar(s)) NULL else s
}
