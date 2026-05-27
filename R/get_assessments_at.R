#' Fetch environmental-assessment records from Austria.
#'
#' Implementation of [get_assessments()] for Austria. Backed by the UVP-DB
#' run by Umweltbundesamt at <https://secure.umweltbundesamt.at/uvpdb/public>.
#' Compared to the NL and DE handlers, the AT portal is **metadata-only**:
#' the procedure register and per-procedure summary are exposed via open
#' JSON service handlers, but every document attachment lives behind a
#' Keycloak login and is therefore **not retrievable** by this version.
#'
#' @section URL enumeration:
#' The public HTML pages of the portal sit behind a Keycloak login wall.
#' Three JSON service handlers, however, are open:
#'
#' ```
#' https://secure.umweltbundesamt.at/uvpdb/?servicehandler=mapsdata
#' https://secure.umweltbundesamt.at/uvpdb/?servicehandler=mapsgeom
#' https://secure.umweltbundesamt.at/uvpdb/?servicehandler=vorhabenInfo&v2id=<id>
#' ```
#'
#' Enumeration is a single `mapsdata` call that returns ~500 records keyed
#' by Aktenzahl (AZ), each carrying `v2id`, `province`, `year`, `title`,
#' and `type`. Per-record detail comes from one `vorhabenInfo` call per
#' `v2id`. There is no pagination, CSRF, or session requirement; the
#' typology mapping (`type` integer → German legend) is captured as a
#' static constant in this file because the portal rarely changes it.
#'
#' @section Filter coverage (v0.1):
#' * `query` — case-insensitive substring match against `title` + `summary`.
#' * `date_range` — matched against `year`, treating each record's year as
#'   the full January 1 – December 31 window. `date_decision` is **always
#'   NA** because the portal does not expose a decision or last-modified
#'   timestamp to anonymous callers; a synthetic mid-year date would
#'   pretend to a precision the source lacks.
#' * `jurisdiction` — substring match against `bundeslaender` (the comma-
#'   joined Austrian federal-state list, e.g. `jurisdiction = "Bayern"`
#'   never matches; `jurisdiction = "Wien"` keeps Viennese records).
#'
#' @section Attachments: not available:
#' The Austrian portal does not expose document URLs to anonymous callers.
#' For every record this handler returns `attachment_urls = character(0)`,
#' `local_path = character(0)`, and an empty `download_status` tibble.
#' The `download` argument is accepted for API symmetry but has no effect.
#' Authenticated access (UBA Keycloak) is out of scope for v0.1.
#'
#' @param date_range Length-2 vector `c(from, to)` of dates or parseable
#'   strings. Compared against the record's `year`; see *Filter coverage*.
#' @param limit Integer. Maximum records to return. Defaults to `Inf`.
#'   The full register is small (~500 records), so a cold-cache full
#'   crawl completes in a few minutes.
#' @param download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh
#'   See [get_assessments()]. `download`, `overwrite`, and
#'   `max_file_size_mb` are accepted but ignored — no PDFs are reachable.
#' @param topic,relevance_threshold,relevance_model Forwarded from
#'   [get_assessments()]. `relevance_threshold` is documented as a
#'   download-gate; on AT it has no observable effect because there are
#'   no downloads to gate.
#' @param query Free-text substring match on `title` + `summary` (client-
#'   side). The portal has no server-side full-text search.
#' @param jurisdiction Character vector. Substring match against
#'   `bundeslaender` (the comma-joined Austrian federal-state list).
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test
#' get_assessments_at(limit = 3, download = FALSE)
#'
#' # Windkraft-only slice
#' get_assessments_at(query = "Windpark", limit = 20, download = FALSE)
#'
#' # All Burgenland records from a given year window
#' get_assessments_at(
#'   date_range = c("2016-01-01", "2018-12-31"),
#'   jurisdiction = "Burgenland",
#'   download = FALSE
#' )
#' }
get_assessments_at <- function(
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

  rel <- at_setup_relevance(topic, relevance_model, country = "at")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("at")
  } else {
    stats::setNames(character(0), character(0))
  }

  index <- tryCatch(at_fetch_mapsdata(), error = function(e) {
    warn_partial("Failed to fetch UVP-DB index: {conditionMessage(e)}")
    list()
  })

  # Cheap pre-filter: when a date_range is set, drop entries whose `year`
  # cannot overlap the window before paying for any vorhabenInfo call. The
  # post-fetch filter still runs on the parsed record (which carries the
  # authoritative year copied through from this entry).
  if (!is.null(date_range)) {
    index <- Filter(
      function(e) at_year_in_range(e$year, date_range),
      index
    )
  }

  records <- list()
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} crawling AT  ",
      "records {length(records)}",
      if (is.finite(limit)) paste0("/", limit) else paste0("/", length(index)),
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = if (is.finite(limit)) limit else length(index),
    clear = FALSE
  )
  on.exit(cli::cli_progress_done(), add = TRUE)

  for (entry in index) {
    if (length(records) >= limit) {
      break
    }
    u <- at_canonical_url(entry$v2id)
    rec <- tryCatch(at_load_or_fetch(u, entry, sidecar_index), error = function(e) {
      warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
      NULL
    })
    if (is.null(rec)) {
      next
    }
    if (!at_record_matches(rec, query = query, date_range = date_range, jurisdiction = jurisdiction)) {
      next
    }
    if (!is.null(rel)) {
      rec <- at_apply_relevance(rec, rel)
    }
    rec <- at_finalise_record(rec, write_sidecar = write_sidecar)
    records[[length(records) + 1L]] <- rec
    cli::cli_progress_update()
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
at_source_portal <- function() "umweltbundesamt.at/uvpdb"

#' Base URL for the UVP-DB service handlers.
#'
#' The trailing slash matters: `…/uvpdb?servicehandler=…` returns HTTP 302
#' to `…/uvpdb/` (without preserving the query string), so the JSON response
#' is only reachable when the slash is part of the request URL.
#' @noRd
at_base_url <- function() "https://secure.umweltbundesamt.at/uvpdb/"

#' Canonical landing URL for a v2id.
#'
#' The portal has no anonymous HTML detail page — this deep-link into the
#' map SPA is the closest stable permalink. Lands behind the login wall,
#' but the URL is stable and used as the sidecar lookup key.
#' @noRd
at_canonical_url <- function(v2id) {
  sprintf("%smaps/?v2id=%s", at_base_url(), v2id)
}

#' Hard-coded UVP-DB typology mapping.
#'
#' Captured from `https://secure.umweltbundesamt.at/uvpdb/maps/resources/data/typology.js`
#' on 2026-05-27. The portal's `type` integer in `mapsdata` is a 1-based
#' index into this table (1 = Abfallwirtschaft, …, 23 = Windkraftanlagen).
#' Updates are rare; if the portal adds a category, append it here.
#' @noRd
at_typology_legend <- function() {
  c(
    "Abfallwirtschaft (Abfallbehandlung und -verwertung)",
    "Bergbauvorhaben",
    "Einkaufszentrum/Gewerbepark",
    "Energiewirtschaft (KW außer Wasserkraft)",
    "Flugplatz",
    "Freizeitanlage (z.B. Stadium, Reitsportanlage)",
    "Gasleitung",
    "Golfplatz",
    "Beherbergungsbetrieb",
    "Industrieanlage",
    "Parkplatz",
    "Umgang mit radioaktiven Stoffen (MedAustron)",
    "Renn- und Teststrecke",
    "Rodung",
    "Schigebiet",
    "Eisenbahnvorhaben",
    "Schutz- und Regulierungsbau (inkl. Renaturierung)",
    "Starkstromfreileitung",
    "Straßenbauvorhaben",
    "Städtebauvorhaben",
    "Tierhaltung",
    "Wasserkraftanlage",
    "Windkraftanlagen",
    "nicht gefunden",
    "sonstige Anlagen"
  )
}

#' Hard-coded grouping of types into UVP-DB typegroups (Energie / Infrastruktur / ...).
#'
#' Captured from the same `typology.js` source as `at_typology_legend()`.
#' Maps a 1-based `type` integer to its named group.
#' @noRd
at_typology_groups <- function() {
  groups <- list(
    Energie = c(23L, 22L, 18L, 4L, 7L),
    Infrastruktur = c(17L, 5L, 19L, 16L, 20L, 11L),
    Freizeit = c(3L, 6L, 8L, 9L, 15L, 13L),
    Agrar = c(21L, 14L),
    Industrie = c(1L, 2L, 12L, 10L),
    Fehler = 24L,
    Sonstige = 25L
  )
  out <- character(25)
  for (nm in names(groups)) {
    out[groups[[nm]]] <- nm
  }
  out
}

#' Look up the typology legend for a 1-based type index.
#' @noRd
at_type_legend <- function(type) {
  if (is.null(type) || is.na(type)) {
    return(NA_character_)
  }
  legend <- at_typology_legend()
  i <- suppressWarnings(as.integer(type))
  if (is.na(i) || i < 1L || i > length(legend)) {
    return(NA_character_)
  }
  legend[i]
}

#' Look up the typology group ("Energie", "Infrastruktur", ...) for a type index.
#' @noRd
at_type_group <- function(type) {
  if (is.null(type) || is.na(type)) {
    return(NA_character_)
  }
  groups <- at_typology_groups()
  i <- suppressWarnings(as.integer(type))
  if (is.na(i) || i < 1L || i > length(groups)) {
    return(NA_character_)
  }
  g <- groups[i]
  if (!nzchar(g)) NA_character_ else g
}

# -----------------------------------------------------------------------------
# URL enumeration
# -----------------------------------------------------------------------------

#' Fetch and parse the UVP-DB index ("mapsdata" service handler).
#'
#' Returns a list of entries; each entry is `list(az, v2id, title, year,
#' province, type)`. The mapsdata response is an object keyed by Aktenzahl
#' (AZ); we lift the key into the entry so the streaming loop carries it
#' through without going back to the index.
#'
#' @return List of entries (possibly empty on failure — the caller logs).
#' @noRd
at_fetch_mapsdata <- function() {
  req <- req_planscanr(at_base_url())
  req <- httr2::req_url_query(req, servicehandler = "mapsdata")
  payload <- perform_json(req)
  if (!is.list(payload) || length(payload) == 0L) {
    return(list())
  }
  azs <- names(payload)
  lapply(seq_along(payload), function(i) {
    e <- payload[[i]]
    list(
      az = azs[i],
      v2id = e$v2id,
      title = e$title %||% NA_character_,
      year = e$year,
      province = e$province %||% NA_character_,
      type = e$type
    )
  })
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' Sidecar-first wrapper around the vorhabenInfo parser.
#' @noRd
at_load_or_fetch <- function(url, entry, sidecar_index) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  at_parse_detail(url, entry)
}

#' Fetch and parse one vorhabenInfo response into a 1-row tibble.
#'
#' The vorhabenInfo handler returns a JSON array whose first element carries
#' the rich fields. We also pull `az`, `year`, `province`, and `type` from the
#' caller-supplied `entry` (lifted from mapsdata) because those are not
#' duplicated in the vorhabenInfo payload.
#' @noRd
at_parse_detail <- function(url, entry) {
  req <- req_planscanr(at_base_url())
  req <- httr2::req_url_query(req, servicehandler = "vorhabenInfo", v2id = entry$v2id)
  payload <- perform_json(req)

  detail <- if (is.list(payload) && length(payload) > 0L) payload[[1L]] else list()

  title <- at_text(detail$titel) %||% at_text(entry$title)
  summary <- at_text(detail$zusammenFassung)
  status <- at_text(detail$status)
  art <- at_text(detail$art)
  typ <- at_text(detail$typ)

  bundeslaender <- at_collect_chr(detail$bundeslaender)
  jurisdiction <- if (length(bundeslaender) == 0L) NA_character_ else paste(bundeslaender, collapse = ", ")

  standort <- at_collect_chr(detail$standortGemeinden)
  standort_str <- if (length(standort) == 0L) NA_character_ else paste(standort, collapse = "; ")

  rechtsgrundlagen <- at_collect_chr(detail$rechtsGrundlagen)
  rechtsgrundlagen_str <- if (length(rechtsgrundlagen) == 0L) {
    NA_character_
  } else {
    paste(rechtsgrundlagen, collapse = "; ")
  }

  # `year` is authoritative from mapsdata; vorhabenInfo sometimes echoes it,
  # sometimes omits it. Prefer the entry value.
  year_val <- entry$year %||% detail$year
  year_int <- if (is.null(year_val) || is.na(year_val)) NA_integer_ else as.integer(year_val)

  type_int <- entry$type
  native_type <- at_type_legend(type_int)
  if (is.na(native_type)) {
    # Fall back to vorhabenInfo's free-text `typ` field if the typology
    # lookup failed (e.g. portal added a category we haven't seen yet).
    native_type <- typ %||% NA_character_
  }
  type_group <- at_type_group(type_int)

  tibble::tibble(
    country = "at",
    source_portal = at_source_portal(),
    document_id = as.character(entry$v2id),
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(character(0)),
    local_path = list(character(0)),
    title = title %||% NA_character_,
    summary = summary %||% NA_character_,
    competent_authority = NA_character_,
    proponent = NA_character_,
    date_decision = as.Date(NA),
    native_type = native_type,
    jurisdiction = jurisdiction,
    status = status %||% NA_character_,
    aktenzahl = entry$az %||% NA_character_,
    art = art %||% NA_character_,
    type_group = type_group,
    standort_gemeinden = standort_str,
    rechtsgrundlagen = rechtsgrundlagen_str,
    year = year_int,
    download_status = list(empty_download_status())
  )
}

#' Coerce a single field into a non-empty trimmed character or NULL.
#' @noRd
at_text <- function(x) {
  if (is.null(x)) {
    return(NULL)
  }
  if (length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Coerce a JSON array (jsonlite list) into a non-empty character vector.
#' @noRd
at_collect_chr <- function(x) {
  if (is.null(x)) {
    return(character(0))
  }
  v <- vapply(
    if (is.list(x)) x else as.list(x),
    function(e) if (is.null(e) || is.na(e)) NA_character_ else as.character(e),
    character(1)
  )
  v <- trimws(v[!is.na(v)])
  v[nzchar(v)]
}

# -----------------------------------------------------------------------------
# Per-record finalise
# -----------------------------------------------------------------------------

#' Finalise a parsed record by writing the sidecar (no downloads on AT).
#'
#' Mirrors the NL/DE finalise helpers but with the download path stripped
#' out — the AT portal exposes no anonymous attachment URLs.
#' @noRd
at_finalise_record <- function(rec, write_sidecar) {
  ds <- empty_download_status()
  rec$download_status <- list(ds)
  rec$local_path <- list(character(0))
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

#' Apply client-side filters to a single parsed AT record.
#' @noRd
at_record_matches <- function(rec, query, date_range, jurisdiction) {
  if (!is.null(query)) {
    haystack <- tolower(paste(rec$title %||% "", rec$summary %||% "", sep = " | "))
    if (!grepl(tolower(query), haystack, fixed = TRUE)) {
      return(FALSE)
    }
  }
  if (!is.null(date_range)) {
    if (!at_year_in_range(rec$year, date_range)) {
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

#' Does the record's `year` overlap the given date window?
#'
#' Treats the year as the Jan 1 – Dec 31 span (the source does not record
#' a finer-grained timestamp anonymously). A NULL/NA year fails the test.
#' @noRd
at_year_in_range <- function(year, date_range) {
  if (is.null(year) || is.na(year)) {
    return(FALSE)
  }
  yr_int <- suppressWarnings(as.integer(year))
  if (is.na(yr_int)) {
    return(FALSE)
  }
  yr_start <- as.Date(sprintf("%04d-01-01", yr_int))
  yr_end <- as.Date(sprintf("%04d-12-31", yr_int))
  !(yr_end < date_range[1] || yr_start > date_range[2])
}

# -----------------------------------------------------------------------------
# Relevance gate
# -----------------------------------------------------------------------------

#' Set up the relevance-scoring context (or NULL when no `topic` was given).
#' @noRd
at_setup_relevance <- function(topic, model, country) {
  if (is.null(topic)) {
    return(NULL)
  }
  topics <- normalise_topics(topic)
  if (is.null(model)) {
    model <- embedding_model_minilm()
  }
  if (!inherits(model, "planscanR_embedding_model")) {
    cli::cli_abort(
      "{.arg relevance_model} must be a planscanR_embedding_model object."
    )
  }
  langs <- languages_for_country(country)
  supp <- supported_languages(model)
  if (length(langs) > 0L && !any(langs %in% supp)) {
    key <- paste(model_name(model), country, sep = ":")
    if (!key %in% get_warned_languages(model_name(model))) {
      warn_partial(c(
        "Country {.val {country}} uses language{?s} {.val {langs}}, which {?is/are} not in the supported set of model {.val {model_name(model)}}.",
        i = "Records will still be scored, but quality may be reduced."
      ))
      mark_warned_language(key)
    }
  }
  list(
    model = model,
    topics = topics,
    topic_vecs = embed_text(model, unname(topics))
  )
}

#' Attach relevance score(s) to a single record.
#' @noRd
at_apply_relevance <- function(rec, rel) {
  text <- paste(rec$title %||% "", rec$summary %||% "", sep = "\n")
  doc_vec <- embed_text(rel$model, text)
  scores <- as.numeric(cosine_similarity_matrix(doc_vec, rel$topic_vecs))
  for (i in seq_along(rel$topics)) {
    rec[[paste0("relevance_score_", names(rel$topics)[i])]] <- scores[i]
  }
  rec$relevance_model <- model_name(rel$model)
  rec
}
