#' Fetch environmental-assessment records from Iceland.
#'
#' Implementation of [get_assessments()] for Iceland. Backed by
#' **Skipulagsgátt** (<https://www.skipulagsgatt.is/>), Skipulagsstofnun's
#' (the National Planning Agency's) public planning- and environmental-
#' assessment portal — a Vue SPA over an anonymous **GraphQL** API. This is
#' the package's first GraphQL-backed handler: the transport is a single
#' HTTP `POST .../graphql` with a JSON body `{"query": ..., "variables": ...}`,
#' parsed via the shared JSON seam.
#'
#' @section Coverage horizon (IMPORTANT):
#' Skipulagsgátt only carries cases from **roughly June 2023 onward** (the
#' portal went live then). The older `skipulag.is` / `island.is`
#' "gagnagrunnur umhverfismats" is dead and is **not** crawled. So this
#' handler yields a *recent-cases-only* corpus (~235 environmental-assessment
#' issues total at the time of writing). Plan accordingly.
#'
#' @section Three processes merged (assessment_type):
#' The portal models every dossier as a unified `Issue`; environmental
#' assessment lives in three of its `process`es, selected server-side by
#' `processId`:
#' * `15` — *Tilkynning til ákvörðunar um matsskyldu* (EIA-track screening),
#'   tagged `assessment_type = "EIA"`.
#' * `16` — *Mat á umhverfisáhrifum* (full EIA), tagged
#'   `assessment_type = "EIA"`.
#' * `501` — *Umhverfismat áætlana* (SEA), tagged `assessment_type = "SEA"`.
#'
#' The three are merged into one result tibble. `assessment_type`
#' (`"EIA"`/`"SEA"`) tags each row and round-trips to the sidecar; the finer
#' distinction is kept in `process_type` / `native_type`. Because the three
#' processes share the same `Issue.id` space, `document_id` is prefixed with
#' the process id (`IS-15-<id>`, `IS-16-<id>`, `IS-501-<id>`) so they never
#' collide on disk. The `assessment_type` argument (`"All"`/`"EIA"`/`"SEA"`)
#' selects which processes to crawl: `"EIA"` -> `{15, 16}`, `"SEA"` -> `{501}`.
#'
#' @section URL enumeration:
#' The listing is the GraphQL `issueConnection(input, first, after)` cursor
#' connection (`{ totalCount, pageInfo{hasNextPage,endCursor}, edges{node} }`),
#' paginated with `after: endCursor`. `processId` is single-valued per query,
#' so the handler loops the selected processes. Free-text `query` is forwarded
#' as the server-side `search` field; `date_range` as `fromDate` / `toDate`.
#' Each record's detail is fetched once via `singleIssue(input:{issueId})`,
#' sidecar-first (a URL already on disk is read from JSON, never re-fetched).
#' The canonical `url` is `https://www.skipulagsgatt.is/issues/<id>`.
#'
#' @section Status field gotcha:
#' Record status is read from the plain-string `lifecycle` field (e.g.
#' `"done"`, `"in_progress"`). The handler deliberately does **not** request
#' the `issueStatus` enum — it has a server-side serialization bug that returns
#' HTTP 500 for the whole query on some records.
#'
#' @section Geometry:
#' `Issue.hasGeography` flags whether a record has a footprint;
#' `Issue.geographies` returns a GraphQL `FeatureCollection` whose per-feature
#' `geometry` arrives as a **GeoJSON string** needing a second
#' `jsonlite::fromJSON` parse. Point / LineString / Polygon are all observed.
#' Coordinates are already geographic **WGS84 (EPSG:4326 lon/lat)** — *not* the
#' projected ISN93 grid — so no reprojection happens. When
#' `write_sidecar = TRUE`, the (re-parsed) geometry is saved next to the
#' sidecar as `<document_id>.geometry.geojson` in the family FeatureCollection
#' layout (GeoJSON-2008 `crs` member naming `urn:ogc:def:crs:EPSG::4326`); the
#' sidecar carries `geometry_path` and `geometry_crs` (`"EPSG:4326"`). Records
#' with `hasGeography = false` / an empty collection leave the geometry columns
#' `NA`.
#'
#' @section Attachments:
#' Documents live under `phases[].files[]`, each an `IssuePhaseFile` with a
#' semantic-role `type` and a nested `data` `File { path, name, ... }`. Only
#' files with `published == true` are emitted. They are grouped by their
#' `IssuePhaseFile.type` into lowercase slugs — `almennt` (general; incl. the
#' matsskýrsla / EIA report and matsáætlun), `vidbrogd` (developer responses),
#' and `afgreidsla` (the decision / álit) — one `attachment_urls_<slug>` /
#' `local_path_<slug>` list-column each, with the deduplicated union in
#' `attachment_urls` / `local_path` (required by the schema). The download URL
#' is `https://www.skipulagsgatt.is/<File.path>` (path of the form
#' `files/<uuid>`), anonymous. The top-level `Issue.files` collection is usually
#' empty and is ignored. PDFs are large (often 10-16 MB) — set
#' `max_file_size_mb` accordingly.
#'
#' @section Filter coverage (v0.1):
#' * `query` — server-side full-text (GraphQL `search` field).
#' * `assessment_type` — selects which process(es) to crawl: `"All"` (default),
#'   `"EIA"` (processes 15 + 16), or `"SEA"` (process 501). Applied here by
#'   choosing the process loop.
#' * `date_range` — forwarded server-side as `fromDate` / `toDate`, and
#'   re-checked client-side against `date_published` (the `publishedDate`).
#'
#' @section Performance:
#' Enumeration is a handful of cursor pages per process plus one `singleIssue`
#' call per record. IS requests are throttled to 5 requests per second by
#' default; override via `getOption("planscanR.is_throttle_rate")`
#' (requests/sec; falsy disables).
#'
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,refresh,topic,relevance_threshold,relevance_model
#'   See [get_assessments()].
#' @param query Free-text query forwarded as the GraphQL `search` field.
#' @param assessment_type One of `"All"` (default), `"EIA"`, or `"SEA"`.
#'   Selects which process(es) to crawl.
#' @param ... Reserved for future extensions; unused arguments are warned about.
#'
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments()], [get_assessments_coverage()].
#' @export
#' @examples
#' \dontrun{
#' # Quick smoke test (recent cases only — June 2023 onward)
#' get_assessments_is(limit = 3, download = FALSE)
#'
#' # Wind-themed slice (server-side full-text, Icelandic)
#' get_assessments_is(query = "vindorku", limit = 20, download = FALSE)
#'
#' # SEA only (umhverfismat áætlana)
#' get_assessments_is(assessment_type = "SEA", download = FALSE)
#' }
get_assessments_is <- function(
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
  assessment_type <- is_normalise_assessment_type(assessment_type)

  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.is_throttle_rate", 5)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }

  rel <- setup_relevance(topic, relevance_model, country = "is")

  sidecar_index <- if (!refresh) {
    sidecar_url_index("is")
  } else {
    stats::setNames(character(0), character(0))
  }

  process_ids <- is_processes_for(assessment_type)

  # Per-entry processing: sidecar-first detail fetch, client-side date filter,
  # relevance scoring, optional download, and the sidecar write. Returns the
  # 1-row record or NULL to drop the entry. Shared across every process's stream
  # and called once per listing entry by stream_crawl().
  process_entry <- function(entry) {
    u <- is_canonical_url(entry$id)
    rec <- tryCatch(
      is_load_or_fetch(u, entry, sidecar_index, write_sidecar = write_sidecar),
      error = function(e) {
        warn_partial("Failed to load/parse {.url {u}}: {conditionMessage(e)}")
        NULL
      }
    )
    if (is.null(rec)) {
      return(NULL)
    }
    if (!is_record_matches(rec, date_range = date_range)) {
      return(NULL)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    is_finalise_record(
      rec,
      download = should_download,
      overwrite = overwrite,
      max_file_size_mb = max_file_size_mb,
      write_sidecar = write_sidecar
    )
  }

  # Stream each process's cursor connection page-by-page, persisting records as
  # they are parsed instead of enumerating every process first. `limit` is
  # global across processes, so a full process-15 crawl can consume all of it
  # before 16 / 501.
  records <- list()
  for (pid in process_ids) {
    remaining <- if (is.finite(limit)) limit - length(records) else Inf
    if (remaining <= 0L) {
      break
    }
    gen <- tryCatch(
      is_fetch_listing(
        process_id = pid,
        query = query,
        date_range = date_range
      ),
      error = function(e) {
        warn_partial(
          "Failed to enumerate Skipulagsg\u00e1tt process {.val {pid}}: {conditionMessage(e)}"
        )
        function() NULL
      }
    )
    block <- stream_crawl(gen, process_entry, limit = remaining, label = "is")
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
is_source_portal <- function() "skipulagsgatt.is"

#' Public base URL for the portal.
#' @noRd
is_portal_base <- function() "https://www.skipulagsgatt.is"

#' GraphQL endpoint for Skipulagsgátt.
#' @noRd
is_graphql_endpoint <- function() "https://www.skipulagsgatt.is/graphql"

#' Server-side listing page size for the cursor connection.
#' @noRd
is_page_size <- function() 50L

#' EPSG code of the geometry payloads served by Skipulagsgátt.
#'
#' Skipulagsgátt returns WGS84 lon/lat (EPSG:4326), *not* the projected ISN93
#' grid. Recorded on every geojson sidecar and on the record's `geometry_crs`.
#' @noRd
is_geometry_crs <- function() "EPSG:4326"

#' Competent authority is constant — the National Planning Agency.
#' @noRd
is_competent_authority <- function() "Skipulagsstofnun"

#' Canonical landing URL for an Issue (the human-facing SPA detail route).
#' @noRd
is_canonical_url <- function(id) {
  sprintf("%s/issues/%s", is_portal_base(), id)
}

#' Document-ID prefix per process so the shared Issue id space never collides.
#' @noRd
is_document_id <- function(process_id, id) {
  sprintf("IS-%s-%s", process_id, id)
}

#' Map our `assessment_type` argument to a normalised value.
#' @noRd
is_normalise_assessment_type <- function(x) {
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

#' Environmental-assessment process ids per assessment_type.
#'
#' 15 = EIA-track screening (matsskylda), 16 = full EIA, 501 = SEA.
#' @noRd
is_processes_for <- function(assessment_type) {
  switch(
    assessment_type,
    All = c("15", "16", "501"),
    EIA = c("15", "16"),
    SEA = "501"
  )
}

#' Map an environmental-assessment process id to the standard assessment_type.
#' @noRd
is_assessment_type_of <- function(process_id) {
  if (identical(as.character(process_id), "501")) "SEA" else "EIA"
}

# -----------------------------------------------------------------------------
# GraphQL transport (single network seam)
# -----------------------------------------------------------------------------

#' Execute one GraphQL query against the Skipulagsgátt endpoint.
#'
#' The single network seam for this handler: an HTTP POST with a JSON body
#' `{"query": ..., "variables": ...}`. Returns the parsed JSON list; the
#' payload of interest is under `$data`. Tests mock this binding to replay
#' recorded fixtures instead of hitting the network.
#' @noRd
is_graphql <- function(query, variables = NULL) {
  req <- req_planscanr(is_graphql_endpoint())
  req <- httr2::req_body_json(
    req,
    list(query = query, variables = variables %||% structure(list(), names = character(0)))
  )
  perform_json(req)
}

# -----------------------------------------------------------------------------
# Index enumeration
# -----------------------------------------------------------------------------

#' GraphQL query for the issueConnection listing.
#' @noRd
is_listing_query <- function() {
  paste(
    "query Listing($input: IssueSpecificationInput!, $first: Int, $after: String) {",
    "  issueConnection(input: $input, first: $first, after: $after) {",
    "    totalCount",
    "    pageInfo { hasNextPage endCursor }",
    "    edges {",
    "      cursor",
    "      node {",
    "        id issueNumber title publishedDate closedDate lifecycle",
    "        hasGeography process { type } currentPhase { name }",
    "        communities { name }",
    "      }",
    "    }",
    "  }",
    "}",
    sep = "\n"
  )
}

#' Build a page generator for one process's issueConnection.
#'
#' Returns a zero-arg closure (the [stream_crawl()] `next_page` contract): each
#' call fetches the next cursor page and returns its listing entries, or `NULL`
#' once the connection is exhausted. Cursor pagination state (`after` cursor +
#' a done flag) lives in the closure, so the streaming driver pulls only as many
#' pages as the limit needs and records are persisted page-by-page.
#'
#' Each entry is a small named list carrying the process id (so we can build the
#' prefixed `document_id` and the `assessment_type` tag) plus the listing node
#' fields. The detail parser is sidecar-first, so this is the minimum needed to
#' build the canonical URL.
#'
#' Termination preserves the original logic: stop when the connection is null,
#' a page has no edges, `pageInfo.hasNextPage` is false, or there is no
#' `endCursor` to follow.
#' @noRd
is_fetch_listing <- function(process_id, query = NULL, date_range = NULL) {
  after <- NULL
  size <- is_page_size()
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    input <- list(processId = process_id)
    if (!is.null(query) && nzchar(query)) {
      input$search <- as.character(query)
    }
    if (!is.null(date_range)) {
      input$fromDate <- format(date_range[1], "%Y-%m-%dT00:00:00.000Z")
      input$toDate <- format(date_range[2], "%Y-%m-%dT23:59:59.999Z")
    }
    variables <- list(input = input, first = size)
    if (!is.null(after)) {
      variables$after <- after
    }
    payload <- is_graphql(is_listing_query(), variables)
    conn <- (((payload %||% list())$data %||% list())$issueConnection) %||% NULL
    if (is.null(conn)) {
      done <<- TRUE
      return(NULL)
    }
    edges <- conn$edges %||% list()
    if (length(edges) == 0L) {
      done <<- TRUE
      return(NULL)
    }
    out <- list()
    for (edge in edges) {
      node <- edge$node %||% NULL
      if (is.null(node) || is.null(node$id)) {
        next
      }
      out[[length(out) + 1L]] <- list(
        process_id = process_id,
        id = is_text(node$id),
        issue_number = is_text(node$issueNumber),
        title = is_text(node$title),
        published_date = is_text(node$publishedDate),
        closed_date = is_text(node$closedDate),
        lifecycle = is_text(node$lifecycle),
        has_geography = isTRUE(node$hasGeography),
        process_type = is_text((node$process %||% list())$type),
        current_phase = is_text((node$currentPhase %||% list())$name)
      )
    }
    # Decide whether a further page exists before handing this one back.
    page_info <- conn$pageInfo %||% list()
    next_cursor <- is_text(page_info$endCursor)
    if (!isTRUE(page_info$hasNextPage) || is.null(next_cursor)) {
      done <<- TRUE
    } else {
      after <<- next_cursor
    }
    out
  }
}

# -----------------------------------------------------------------------------
# Detail-record parsing
# -----------------------------------------------------------------------------

#' GraphQL query for a single issue's detail.
#'
#' Deliberately omits the `issueStatus` enum (server-side serialization bug
#' that 500s the whole query for some records); status comes from `lifecycle`.
#' @noRd
is_detail_query <- function() {
  paste(
    "query Single($input: IssueSpecificationInput!) {",
    "  singleIssue(input: $input) {",
    "    id issueNumber title description",
    "    publishedDate closedDate lifecycle hasGeography",
    "    process { title type }",
    "    currentPhase { name }",
    "    communities { name }",
    "    postalCodes { number city region }",
    "    geographies { type features { type geometry } }",
    "    phases {",
    "      name state publishedDate closedDate",
    "      files { type published publishedAt data { id path name description type } }",
    "    }",
    "  }",
    "}",
    sep = "\n"
  )
}

#' Sidecar-first wrapper: read the sidecar if present, else fetch detail.
#'
#' When the sidecar is missing, fetches the `singleIssue` detail, parses it,
#' and saves the (double-parsed) geometry to a sibling `.geometry.geojson` so
#' subsequent runs pick it up offline.
#' @noRd
is_load_or_fetch <- function(url, entry, sidecar_index, write_sidecar) {
  hit <- sidecar_index[url]
  if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
    return(read_record_sidecar(hit))
  }
  detail <- is_fetch_detail(entry$id)
  parsed <- is_parse_issue(url, entry, detail)
  rec <- parsed$record
  if (write_sidecar && !is.null(parsed$geometry)) {
    geo_path <- is_save_geometry_to_geojson(
      country = "is",
      document_id = rec$document_id,
      title = rec$title,
      created_iso = if (is.na(rec$date_published)) NULL else format(rec$date_published, "%Y-%m-%d"),
      geometry = parsed$geometry
    )
    if (!is.null(geo_path)) {
      rec$geometry_path <- geo_path
      rec$geometry_crs <- is_geometry_crs()
    }
  }
  rec
}

#' Fetch one issue's detail via the `singleIssue` GraphQL query.
#'
#' Returns the `singleIssue` object (the contents of `$data$singleIssue`).
#' @noRd
is_fetch_detail <- function(id) {
  payload <- is_graphql(is_detail_query(), list(input = list(issueId = as.character(id))))
  (((payload %||% list())$data %||% list())$singleIssue) %||% NULL
}

#' Parse one `singleIssue` object into a 1-row tibble + a GeoJSON geometry.
#'
#' Returns `list(record = <tibble>, geometry = <list or NULL>)`. The geometry
#' is the double-parsed GeoJSON value (`geographies.features[].geometry` is a
#' JSON *string* that needs a second parse); the caller persists it next to the
#' sidecar.
#' @noRd
is_parse_issue <- function(url, entry, issue) {
  issue <- issue %||% list()
  process_id <- entry$process_id
  id <- entry$id %||% is_text(issue$id)
  document_id <- is_document_id(process_id, id)

  title <- is_text(issue$title) %||% entry$title %||% NA_character_
  summary_text <- is_text(issue$description)
  status <- is_text(issue$lifecycle) %||% entry$lifecycle %||% NA_character_
  current_phase <- is_text((issue$currentPhase %||% list())$name) %||% entry$current_phase
  process_title <- is_text((issue$process %||% list())$title)
  process_type <- is_text((issue$process %||% list())$type) %||% entry$process_type
  native_type <- process_title %||% process_type %||% NA_character_

  date_published <- is_parse_iso_date(issue$publishedDate %||% entry$published_date)
  date_decision <- is_parse_iso_date(issue$closedDate %||% entry$closed_date)

  jurisdiction <- is_jurisdiction(issue$communities, issue$postalCodes)

  per_section <- is_parse_phase_files(issue$phases)
  union_urls <- unique(unlist(per_section, use.names = FALSE)) %||% character(0)

  geometry <- is_parse_geographies(issue$geographies)

  rec <- tibble::tibble(
    country = "is",
    source_portal = is_source_portal(),
    document_id = document_id,
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(union_urls),
    local_path = list(character(0)),
    title = title,
    summary = summary_text %||% NA_character_,
    competent_authority = is_competent_authority(),
    # No framkvæmdaraðili (proponent) field; it only appears in free text.
    proponent = NA_character_,
    date_published = date_published,
    date_decision = date_decision,
    native_type = native_type %||% NA_character_,
    jurisdiction = jurisdiction %||% NA_character_,
    status = status %||% NA_character_,
    assessment_type = is_assessment_type_of(process_id),
    process_id = as.character(process_id),
    process_type = process_type %||% NA_character_,
    lifecycle = status %||% NA_character_,
    current_phase = current_phase %||% NA_character_,
    issue_number = is_text(issue$issueNumber) %||% entry$issue_number %||% NA_character_,
    geometry_path = NA_character_,
    geometry_crs = NA_character_,
    download_status = list(empty_download_status())
  )
  for (slug in names(per_section)) {
    rec[[paste0("attachment_urls_", slug)]] <- list(per_section[[slug]])
    rec[[paste0("local_path_", slug)]] <- list(character(0))
  }
  list(record = rec, geometry = geometry)
}

#' Compose a `jurisdiction` string from communities (+ postal-code regions).
#' @noRd
is_jurisdiction <- function(communities, postal_codes) {
  comm <- character(0)
  for (c in communities %||% list()) {
    nm <- is_text(c$name)
    if (!is.null(nm)) {
      comm <- c(comm, nm)
    }
  }
  regions <- character(0)
  for (p in postal_codes %||% list()) {
    rg <- is_text(p$region)
    if (!is.null(rg)) {
      regions <- c(regions, rg)
    }
  }
  parts <- unique(c(comm, regions))
  if (length(parts) == 0L) {
    return(NULL)
  }
  paste(parts, collapse = "; ")
}

#' Group published phase files by their semantic `type` into URL vectors.
#'
#' Each `IssuePhaseFile` has a role `type` (ALMENNT / VIDBROGD / AFGREIDSLA /
#' ...) and a nested `data` `File { path, ... }`. Only `published == true`
#' files are kept; the download URL is `<base>/<File.path>`. Slugs are the
#' lowercased role; unknown / empty roles fall back to `"document"`.
#' @noRd
is_parse_phase_files <- function(phases) {
  per_section <- list()
  for (phase in phases %||% list()) {
    for (f in phase$files %||% list()) {
      if (!isTRUE(f$published)) {
        next
      }
      data <- f$data %||% list()
      path <- is_text(data$path)
      if (is.null(path)) {
        next
      }
      url <- is_file_url(path)
      slug <- is_section_slug(is_text(f$type))
      per_section[[slug]] <- unique(c(per_section[[slug]], url))
    }
  }
  per_section
}

#' Resolve a `File.path` (form `files/<uuid>`) to an absolute download URL.
#' @noRd
is_file_url <- function(path) {
  if (startsWith(path, "http")) {
    return(path)
  }
  if (!startsWith(path, "/")) {
    path <- paste0("/", path)
  }
  paste0(is_portal_base(), path)
}

#' Slug an `IssuePhaseFile.type` role to an ASCII column-suffix slug.
#' @noRd
is_section_slug <- function(type) {
  if (is.null(type) || !is.character(type) || length(type) != 1L || is.na(type) || !nzchar(type)) {
    return("document")
  }
  s <- tolower(type)
  # Icelandic diacritics that can show up in role labels.
  s <- gsub("\u00e1", "a", s)
  s <- gsub("\u00e9", "e", s)
  s <- gsub("\u00ed", "i", s)
  s <- gsub("\u00f3", "o", s)
  s <- gsub("\u00fa", "u", s)
  s <- gsub("\u00fd", "y", s)
  s <- gsub("\u00f0", "d", s)
  s <- gsub("\u00fe", "th", s)
  s <- gsub("\u00e6", "ae", s)
  s <- gsub("\u00f6", "o", s)
  s <- gsub("[^a-z0-9]+", "_", s)
  s <- gsub("(^_+|_+$)", "", s)
  if (!nzchar(s)) "document" else s
}

#' Pull a GeoJSON geometry from the `geographies` FeatureCollection.
#'
#' Each feature's `geometry` arrives as a GeoJSON **string** that needs a
#' second `jsonlite::fromJSON` parse. Returns the first parseable geometry (a
#' list with `type` + `coordinates`), or NULL when none is present.
#' @noRd
is_parse_geographies <- function(geographies) {
  if (is.null(geographies)) {
    return(NULL)
  }
  features <- geographies$features %||% list()
  for (feat in features) {
    raw <- feat$geometry
    if (is.null(raw)) {
      next
    }
    parsed <- if (is.character(raw) && length(raw) == 1L) {
      tryCatch(jsonlite::fromJSON(raw, simplifyVector = FALSE), error = function(e) NULL)
    } else if (is.list(raw)) {
      raw
    } else {
      NULL
    }
    if (is.list(parsed) && !is.null(parsed$type) && !is.null(parsed$coordinates)) {
      return(parsed)
    }
  }
  NULL
}

# -----------------------------------------------------------------------------
# Geometry -> linked GeoJSON file
# -----------------------------------------------------------------------------

#' Save the (double-parsed) geometry next to its sidecar as GeoJSON.
#'
#' Wraps the geometry in a `FeatureCollection`, tags the CRS via the
#' GeoJSON-2008 `crs` member (`urn:ogc:def:crs:EPSG::4326`), and persists it as
#' `<sidecar_dir>/<document_id>.geometry.geojson`. Coordinates are kept in the
#' source EPSG:4326 (WGS84 lon/lat).
#' @noRd
is_save_geometry_to_geojson <- function(country, document_id, title = NULL, created_iso = NULL, geometry = NULL) {
  if (is.null(geometry) || !is.list(geometry)) {
    return(NULL)
  }
  if (is.null(geometry$type) || !nzchar(geometry$type)) {
    return(NULL)
  }
  out_path <- is_geometry_path(country, document_id)
  if (file.exists(out_path)) {
    return(out_path)
  }
  feature <- list(
    type = "FeatureCollection",
    crs = list(
      type = "name",
      properties = list(
        name = paste0("urn:ogc:def:crs:EPSG::", sub("^EPSG:", "", is_geometry_crs()))
      )
    ),
    features = list(
      list(
        type = "Feature",
        geometry = geometry,
        properties = list(
          document_id = document_id,
          source_portal = is_source_portal(),
          title = title %||% NULL,
          created = created_iso %||% NULL,
          crs = is_geometry_crs()
        )
      )
    )
  )
  tmp <- tempfile(tmpdir = dirname(out_path), fileext = ".geojson")
  on.exit(if (file.exists(tmp)) unlink(tmp), add = TRUE)
  writeLines(
    jsonlite::toJSON(feature, auto_unbox = TRUE, digits = NA, null = "null"),
    con = tmp,
    useBytes = TRUE
  )
  file.rename(tmp, out_path)
  out_path
}

#' Path to a record's geometry geojson (always alongside its sidecar JSON).
#' @noRd
is_geometry_path <- function(country, document_id, root = NULL) {
  file.path(
    cache_dir(file.path("files", country, document_id), create = TRUE, root = root),
    paste0(document_id, ".geometry.geojson")
  )
}

# -----------------------------------------------------------------------------
# Per-record finalise (download + sidecar)
# -----------------------------------------------------------------------------

#' Finalise a parsed IS record: run downloads (if requested) and write sidecar.
#' @noRd
is_finalise_record <- function(rec, download, overwrite, max_file_size_mb, write_sidecar) {
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
      inform_download(length(urls), cache_dir(file.path("files", "is"), create = TRUE))
    }
    ds <- download_attachments(
      urls,
      country = "is",
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

#' Apply post-fetch client-side filters to a parsed IS record.
#'
#' `query` / `date_range` are honoured server-side via the GraphQL `search` /
#' `fromDate` / `toDate` fields; `date_range` is re-checked client-side here as
#' a belt-and-braces guard (so the sidecar-first path, which never sees the
#' filters, still honours the window). The window is matched against
#' `date_published` (the `publishedDate`).
#' @noRd
is_record_matches <- function(rec, date_range) {
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
is_text <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(NULL)
  }
  if (is.na(x)) {
    return(NULL)
  }
  s <- trimws(as.character(x))
  if (!nzchar(s)) NULL else s
}

#' Parse an ISO-8601 timestamp (e.g. "2023-06-01T09:31:55.254Z") into a Date.
#' @noRd
is_parse_iso_date <- function(x) {
  if (is.null(x) || length(x) != 1L) {
    return(as.Date(NA))
  }
  s <- as.character(x)
  if (is.na(s) || !nzchar(s)) {
    return(as.Date(NA))
  }
  d <- suppressWarnings(as.Date(substr(s, 1L, 10L)))
  if (length(d) == 0L) as.Date(NA) else d
}
