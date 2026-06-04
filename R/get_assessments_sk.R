#' Fetch environmental-assessment records from Slovakia.
#'
#' Implementation of [get_assessments()] for Slovakia. Backed by the Slovak
#' EIA/SEA central information system *enviroportal.sk*
#' (<https://www.enviroportal.sk/>), a React single-page app served by a
#' Symfony **API Platform** JSON backend. The handler talks to that JSON API
#' directly (pure `httr2`, no browser) with the `Accept: application/ld+json`
#' content negotiation header.
#'
#' The portal publishes a single `eia_projects` collection that mixes
#' project-level EIA and plan/programme SEA records; the `zbierka` (law
#' collection) string carries the discriminator (`"časť EIA"` vs
#' `"časť SEA"`). The handler tags each row with an `assessment_type`
#' column (`"EIA"` / `"SEA"`, derived from `zbierka`) and filters client-side
#' when an `assessment_type` argument is supplied; a `register` column carries
#' the raw collection label (`"eia_projects"`). `document_id` is the globally
#' unique numeric portal `id`, prefixed `"SK-"` (e.g. `"SK-171227"`), so records
#' never collide on disk.
#'
#' @section URL enumeration:
#' The list endpoint is `GET /api/eia_projects?page=N` (with
#' `Accept: application/ld+json`). Its `hydra:member` is an **array of arrays**:
#' a bucket of record objects, a pagination-metadata object, and (sometimes) an
#' empty bucket. The handler flattens one level and keeps only the record
#' objects (those with a `seoId`). `hydra:totalItems` / `hydra:view` are
#' unreliable or absent, so the page generator paginates `page = 1, 2, 3, …`
#' **until a page flattens to zero records** (the seam `sk_fetch_search()`,
#' parsed with `perform_json` after attaching the `ld+json` Accept header). The
#' canonical detail URL for each record is the human SPA page
#' `https://www.enviroportal.sk/eia/detail/{seoId}`; the API detail path is
#' `/api/eia_projects/{seoId}`.
#'
#' @section Attachments:
#' Each record's detail JSON carries `dokumenty$data`, an array of **step
#' groups** (`{step, number, items}`) where the `step` names the procedural
#' phase. Each `items[]` element is either a document group (`{title, items:[
#' {type, label, id, url, …} ]}`) or a plain text field (`{type:"text", …}`).
#' The handler collects every leaf whose `type` is a downloadable file
#' (`"PDF"`, etc.), absolutises its `url` (`/eia/dokument/{id}` →
#' `https://www.enviroportal.sk/eia/dokument/{id}`), and groups the URLs by the
#' `step` (phase) name into per-section `attachment_urls_<slug>` columns (the
#' DE / IT pattern; the slug is the Slovak-transliterated, ASCII-folded step)
#' plus the deduplicated union in `attachment_urls`. A record with no
#' downloadable documents yields an empty `attachment_urls` vector, which is
#' valid.
#'
#' @section Filter coverage (v0.1):
#' * `assessment_type` — `"All"` (default), `"EIA"`, or `"SEA"`. The API serves
#'    one mixed list, so each record is tagged from `zbierka` and the filter is
#'    applied here in R.
#' * `query` — matched client-side as a case-insensitive substring of the
#'    record title.
#' * `date_range` — matched client-side against `date_published` (the date part
#'    of the portal's *datumPoslednejZmeny* / last-change timestamp).
#'    `date_decision` is always `NA` (the API exposes no separate decision
#'    date).
#' * `limit` — caps the total number of records returned.
#'
#' @section Performance:
#' The register is large (~18 700 records across ~940 pages of 20). A cold crawl
#' is one list GET per page plus one detail GET per record (sidecar-first, so
#' repeat runs are fast). A `limit` keeps exploratory runs bounded. To be polite
#' to the shared government portal, SK requests are throttled to 5 requests per
#' second by default; override via `getOption("planscanR.sk_throttle_rate")`
#' (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Optional free-text query, matched client-side as a
#'   case-insensitive substring of the record title.
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Filters the mixed `eia_projects` list client-side by the `zbierka`-derived
#'   type.
#' @param ... Reserved for future extensions; unused arguments are warned
#'   about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_sk(limit = 3, download = FALSE)
#'
#' # SEA only
#' get_assessments_sk(assessment_type = "SEA", limit = 10, download = FALSE)
#'
#' # Title substring
#' get_assessments_sk(query = "skladov", limit = 20, download = FALSE)
#' }
get_assessments_sk <- function(
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
  assessment_type <- sk_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.sk_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "sk")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("sk")
  } else {
    stats::setNames(character(0), character(0))
  }

  # Per-entry processing: sidecar-first detail fetch (for attachments + full
  # fields), client-side filters, relevance scoring, optional download, and the
  # sidecar write. Returns the 1-row record or NULL to drop the entry.
  process_entry <- function(entry) {
    u <- sk_canonical_url(entry$seo_id)
    rec <- tryCatch(
      sk_load_or_fetch(u, entry, sidecar_index),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!sk_record_matches(rec, assessment_type = assessment_type, query = query, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    sk_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  gen <- tryCatch(
    sk_fetch_search(),
    error = function(e) {
      warn_partial(
        "Failed to enumerate enviroportal.sk eia_projects: {conditionMessage(e)}"
      )
      function() NULL
    }
  )
  records <- stream_crawl(gen, process_entry, limit = limit, label = "sk")

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
sk_source_portal <- function() "enviroportal.sk"

#' Public base URL for the portal.
#' @noRd
sk_portal_base <- function() "https://www.enviroportal.sk"

#' Raw register label carried in the `register` output column.
#' @noRd
sk_register_label <- function() "eia_projects"

#' Canonical human SPA detail URL for a record (sidecar key).
#' @noRd
sk_canonical_url <- function(seo_id) {
  sprintf("%s/eia/detail/%s", sk_portal_base(), seo_id)
}

#' Document-ID for a record: the globally-unique numeric portal id, `SK-`-prefixed.
#' @noRd
sk_document_id <- function(id) {
  sprintf("SK-%s", id)
}

#' Absolutise a `/eia/dokument/{id}` document path.
#' @noRd
sk_absolute_url <- function(href) {
  if (startsWith(href, "http")) {
    return(href)
  }
  if (!startsWith(href, "/")) {
    href <- paste0("/", href)
  }
  paste0(sk_portal_base(), href)
}

#' Derive the `assessment_type` from a `zbierka` law string.
#'
#' `"časť SEA"` → `"SEA"`; otherwise `"EIA"` when the string mentions
#' EIA; otherwise `NA`.
#' @noRd
sk_assessment_type_of <- function(zbierka) {
  if (is.null(zbierka) || length(zbierka) != 1L || is.na(zbierka) || !nzchar(zbierka)) {
    return(NA_character_)
  }
  if (grepl("SEA", zbierka, ignore.case = TRUE)) {
    return("SEA")
  }
  if (grepl("EIA", zbierka, ignore.case = TRUE)) {
    return("EIA")
  }
  NA_character_
}

#' Normalise the `assessment_type` argument.
#' @noRd
sk_normalise_assessment_type <- function(x) {
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

#' Build a page generator for the `eia_projects` list endpoint.
#'
#' Returns a zero-arg closure (the stream_crawl() `next_page` contract): each
#' call fetches the next `?page=N` of the list endpoint, flattens the
#' array-of-arrays `hydra:member` one level, keeps the record objects, and maps
#' them into lightweight listing entries. Because `hydra:totalItems` /
#' `hydra:view` are unreliable, the generator paginates until a page flattens to
#' zero records.
#' @noRd
sk_fetch_search <- function() {
  page <- 1L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(sk_portal_base())
    req <- httr2::req_url_path_append(req, "api", "eia_projects")
    req <- httr2::req_url_query(req, page = page)
    req <- httr2::req_headers(req, Accept = "application/ld+json")
    payload <- tryCatch(perform_json(req), error = function(e) NULL)
    if (is.null(payload)) {
      done <<- TRUE
      return(NULL)
    }
    records <- sk_flatten_members(payload[["hydra:member"]])
    if (length(records) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    page <<- page + 1L
    sk_map_entries(records)
  }
}

#' Flatten the array-of-arrays `hydra:member` one level and keep record objects.
#'
#' `hydra:member` is a list of buckets: some are arrays of record objects, one
#' is a pagination-metadata object (no `seoId`), and some are empty. We
#' concatenate one level and keep only the objects that carry a `seoId`.
#' @noRd
sk_flatten_members <- function(member) {
  if (is.null(member) || length(member) == 0L) {
    return(list())
  }
  flat <- do.call(
    c,
    lapply(member, function(b) {
      if (is.null(b)) {
        return(list())
      }
      # A record object is a named list with a `seoId`; a bucket is an unnamed
      # list of such objects. Wrap a bare record so `c()` flattens uniformly.
      if (is.list(b) && !is.null(b[["seoId"]])) {
        return(list(b))
      }
      if (is.list(b)) {
        return(b)
      }
      list()
    })
  )
  flat <- flat %||% list()
  Filter(function(x) is.list(x) && !is.null(x[["seoId"]]) && nzchar(as.character(x[["seoId"]])), flat)
}

#' Map record objects into lightweight listing entries.
#'
#' Each entry carries the keys needed to build the canonical URL and the
#' summary fields; the detail parser is sidecar-first, so the full record is
#' fetched only on a cache miss.
#' @noRd
sk_map_entries <- function(records) {
  out <- list()
  for (raw in records) {
    seo_id <- sk_field(raw, "seoId")
    if (is.null(seo_id)) {
      next
    }
    out[[length(out) + 1L]] <- list(
      seo_id = seo_id,
      id = sk_field(raw, "id"),
      url = sk_canonical_url(seo_id),
      raw = raw
    )
  }
  out
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper: read the sidecar if present, else fetch + parse detail.
#' @noRd
sk_load_or_fetch <- function(url, entry, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  detail <- sk_fetch_detail(entry$seo_id)
  sk_build_record(url, detail %||% entry$raw)
}

#' Fetch one record's detail JSON from `/api/eia_projects/{seoId}`.
#' @noRd
sk_fetch_detail <- function(seo_id) {
  req <- req_planscanr(sk_portal_base())
  req <- httr2::req_url_path_append(req, "api", "eia_projects", seo_id)
  req <- httr2::req_headers(req, Accept = "application/ld+json")
  perform_json(req)
}

#' Build a 1-row record tibble from a detail (or summary) record object.
#'
#' Conventional planscanR columns are filled from the API fields; English
#' snake_case extras keep Slovak values verbatim. Per-step attachment columns
#' come from `dokumenty$data`.
#' @noRd
sk_build_record <- function(url, raw) {
  id <- sk_field(raw, "id")
  document_id <- sk_document_id(id %||% sk_field(raw, "seoId") %||% "record")

  zbierka <- sk_field(raw, "zbierka")
  assessment_type <- sk_assessment_type_of(zbierka)

  per_section <- sk_parse_documents(raw[["dokumenty"]])
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  rec <- tibble::tibble(
    country = "sk",
    source_portal = sk_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = sk_field(raw, "name") %||% NA_character_,
    summary = sk_field(raw, "ucel") %||% NA_character_,
    competent_authority = sk_nested_name(raw[["prislusnyOrgan"]]) %||% NA_character_,
    proponent = sk_nested_name(raw[["navrhovatel"]]) %||% NA_character_,
    date_published = sk_parse_date(sk_field(raw, "datumPoslednejZmeny")),
    date_decision = as.Date(NA),
    native_type = sk_field(raw, "zbierka") %||% sk_field(raw, "proces") %||% NA_character_,
    status = sk_field(raw, "stav") %||% NA_character_,
    assessment_type = assessment_type,
    register = sk_register_label(),
    law_collection = zbierka %||% NA_character_,
    process = sk_field(raw, "proces") %||% NA_character_,
    region = sk_field(raw, "kraj") %||% NA_character_,
    district = sk_field(raw, "okres") %||% NA_character_,
    municipality = sk_field(raw, "obec") %||% NA_character_,
    affected_municipality = sk_field(raw, "dotknutaObec") %||% NA_character_,
    locality = sk_field(raw, "locality") %||% NA_character_,
    proponent_id = sk_nested_field(raw[["navrhovatel"]], "ico") %||% NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  rec
}

#' Parse the `dokumenty` object into a named list of URL vectors keyed by step.
#'
#' `dokumenty$data` is an array of step groups (`{step, number, items}`). Each
#' `items[]` element is either a document group (`{title, items:[ leaf ]}`) or a
#' text field (`{type:"text", …}`); we walk every leaf and collect those whose
#' `type` names a downloadable file, absolutising the `/eia/dokument/{id}`
#' `url`. URLs are grouped by the (transliterated, ASCII-folded) `step` name.
#' @noRd
sk_parse_documents <- function(dokumenty) {
  if (is.null(dokumenty) || !is.list(dokumenty)) {
    return(list())
  }
  data <- dokumenty[["data"]]
  if (is.null(data) || length(data) == 0L) {
    return(list())
  }
  per_section <- list()
  for (grp in data) {
    if (!is.list(grp)) {
      next
    }
    step <- sk_field(grp, "step")
    slug <- sk_section_slug(step)
    urls <- character(0)
    items <- grp[["items"]] %||% list()
    for (item in items) {
      urls <- c(urls, sk_collect_file_urls(item))
    }
    urls <- unique(urls[nzchar(urls)])
    if (length(urls) > 0L) {
      per_section[[slug]] <- unique(c(per_section[[slug]], urls))
    }
  }
  per_section
}

#' Collect downloadable file URLs from one `items[]` element.
#'
#' An element is either a document group (with a nested `items` list of leaves)
#' or a leaf itself. A leaf is downloadable when its `type` is a file type
#' (anything other than the `"text"` field marker) and it carries a `url`.
#' @noRd
sk_collect_file_urls <- function(item) {
  if (!is.list(item)) {
    return(character(0))
  }
  type <- sk_field(item, "type")
  # A text field carries no downloadable document.
  if (!is.null(type) && identical(tolower(type), "text")) {
    return(character(0))
  }
  out <- character(0)
  url <- sk_field(item, "url")
  if (!is.null(url) && !is.null(type)) {
    out <- c(out, sk_absolute_url(url))
  }
  nested <- item[["items"]]
  if (!is.null(nested) && length(nested) > 0L) {
    for (leaf in nested) {
      out <- c(out, sk_collect_file_urls(leaf))
    }
  }
  out
}

#' Slug a `step` (phase) string to an ASCII column-suffix slug.
#'
#' Transliterates the Slovak diacritics that show up in phase names, then folds
#' to an ASCII slug. Empty input gets `"dokumenty"` as a deterministic fallback.
#' @noRd
sk_section_slug <- function(step) {
  if (is.null(step) || !is.character(step) || length(step) != 1L || is.na(step) || !nzchar(step)) {
    return("dokumenty")
  }
  ascii_slug(sk_transliterate(step), "dokumenty")
}

#' Transliterate Slovak diacritics to ASCII (for slugs only).
#' @noRd
sk_transliterate <- function(s) {
  from <- c(
    "\u00e1",
    "\u00e4",
    "\u010d",
    "\u010f",
    "\u00e9",
    "\u00ed",
    "\u013a",
    "\u013e",
    "\u0148",
    "\u00f3",
    "\u00f4",
    "\u0155",
    "\u0161",
    "\u0165",
    "\u00fa",
    "\u00fd",
    "\u017e",
    "\u00f6",
    "\u00fc"
  )
  to <- c(
    "a",
    "a",
    "c",
    "d",
    "e",
    "i",
    "l",
    "l",
    "n",
    "o",
    "o",
    "r",
    "s",
    "t",
    "u",
    "y",
    "z",
    "o",
    "u"
  )
  for (i in seq_along(from)) {
    s <- gsub(from[i], to[i], s, fixed = TRUE)
    s <- gsub(toupper(from[i]), to[i], s, fixed = TRUE)
  }
  s
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed SK record: run downloads (if requested) and write sidecar.
#' @noRd
sk_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "sk"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "sk",
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

#' Apply post-fetch client-side filters (`assessment_type` + `query` + `date_range`).
#' @noRd
sk_record_matches <- function(rec, assessment_type = "All", query = NULL, date_range = NULL) {
  if (!identical(assessment_type, "All")) {
    if (is.na(rec$assessment_type) || !identical(rec$assessment_type, assessment_type)) {
      return(FALSE)
    }
  }
  if (!is.null(query) && nzchar(query)) {
    title <- rec$title
    if (is.na(title) || !grepl(tolower(query), tolower(title), fixed = TRUE)) {
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

# -----------------------------------------------------------------------------
# Tiny field-coercion helpers
# -----------------------------------------------------------------------------

#' Read a scalar field from a record object, returning NULL when absent.
#'
#' Nested objects (e.g. `navrhovatel`) are deliberately not surfaced here;
#' use `sk_nested_name()` / `sk_nested_field()` for those. Returns a trimmed
#' non-empty character or NULL.
#' @noRd
sk_field <- function(raw, key) {
  if (is.null(raw) || !is.list(raw)) {
    return(NULL)
  }
  v <- raw[[key]]
  if (is.null(v) || length(v) != 1L || is.list(v)) {
    return(NULL)
  }
  s <- trimws(as.character(v))
  if (is.na(s) || !nzchar(s)) NULL else s
}

#' Read the `name` of a nested object (e.g. `navrhovatel`, `prislusnyOrgan`).
#'
#' The portal occasionally pads the value with a leading space; trim it.
#' @noRd
sk_nested_name <- function(obj) {
  sk_nested_field(obj, "name")
}

#' Read a scalar key from a nested object, trimmed, NULL when absent.
#' @noRd
sk_nested_field <- function(obj, key) {
  if (is.null(obj) || !is.list(obj)) {
    return(NULL)
  }
  v <- obj[[key]]
  if (is.null(v) || length(v) != 1L || is.list(v)) {
    return(NULL)
  }
  s <- trimws(as.character(v))
  if (is.na(s) || !nzchar(s)) NULL else s
}

#' Tolerant parser for the Slovak datetime format `"YYYY-MM-DD HH:MM:SS"`.
#'
#' Extracts the leading `YYYY-MM-DD` date part. `NA` for NULL / non-scalar /
#' NA / empty / unparseable.
#' @noRd
sk_parse_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- trimws(as.character(x))
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  m <- regmatches(s, regexpr("[0-9]{4}-[0-9]{2}-[0-9]{2}", s))
  if (length(m) == 0L || !nzchar(m)) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(as.Date(m, format = "%Y-%m-%d"))
  if (length(d) == 0L) as.Date(NA) else d
}
