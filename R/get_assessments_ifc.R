#' Fetch IFC project disclosures (explicit source `ifc`).
#'
#' Implementation of the explicit source `"ifc"` for [get_assessments()]:
#' `get_assessments("eg", source = "ifc")`. Backed by the public IFC project
#' disclosure portal (<https://disclosures.ifc.org/>), the private-sector arm of
#' the World Bank Group. One record per IFC project whose disclosure type is
#' `ESRS` (Environmental and Social Review Summary, policy 2012 onward). Other
#' disclosure types in the index (SII, SPI, AS, ERS, SCCP, ED, SIVP) are out of
#' scope.
#'
#' @section Listing:
#' The portal's own search API (`POST
#' https://webapi.worldbank.org/aemsite/ifc-disclosure-search`) is called with
#' the filter `Project_Type eq 'ESRS' and Country_Description eq '<name>'`,
#' ordered by `Project_Number` and paged with `top`/`skip` until the reported
#' `@odata.count`. The API needs a *public client subscription key* that the
#' portal prints in every project-detail page (`data-subscription-key`). It is
#' read from a detail page at runtime (once per R session, option
#' `planscanR.ifc_key_page` overrides the page) and never stored in the
#' package; if it cannot be found the call fails with an actionable
#' `planscanR_error_bad_response`. A malformed envelope is an error; failed,
#' short, repeated or growing pages emit `planscanR_warning_partial`.
#'
#' @section Geography:
#' IFC stores one free-text World-Bank style country name per project
#' (`Country_Description`, e.g. `"Egypt, Arab Republic of"`, `"Turkiye"`).
#' The ISO-2 `country` is mapped to that name with an internal table generated
#' from the distinct `Country_Description` facet values of the ESRS index
#' (`facets = "Country_Description,count:400"` with the filter above; keep the
#' non-region values and map them to ISO-2 by hand). A valid code that is not in
#' the table (for instance `"nl"`, `"de"`, `"dk"`, `"at"`: IFC has no ESRS
#' projects there) raises `planscanR_error_bad_input`; a mapped country with no
#' rows gives a typed empty result. Regional pseudo-countries ("Africa
#' Region", "World Region", "... Subregion") cannot be assigned to a country and
#' are never returned. The raw `Country_Description` and `Region_Description`
#' are kept as extras; output `country` is the requested code.
#'
#' @section Records and documents:
#' `document_id = "ifc_<Project_Number>"`. Every native search field is kept as
#' an extra column and the whole raw row as `listing_json`. The ESRS review text
#' (`Project_Description`, `Review_Scope` and the categorization rationale,
#' HTML-decoded) is the record `summary`; it is not an assessment report. The
#' project-detail page is fetched for every returned record (sidecar first,
#' bounded by `limit`) and its client documentation table is captured whole
#' (every row, with every native column and the file link) in `documents_json`;
#' the file links (`disclosuresservice.ifc.org/api/File/downloadfile`) go to
#' `attachment_urls_document`, the single section (the table has no native
#' grouping). **Roles are not labelled by IFC**: the only native label is the
#' file name, kept as `role` in `documents_json`; no classifier is applied, so
#' ESIA, ESMP, SEP, translations and summaries all appear. Older files often
#' return HTTP 404 and fail visibly per attachment. A record whose detail page
#' failed or lacked the documents table has `detail_fetched = FALSE` and is
#' retried instead of served from the cache.
#'
#' @param country Lower-case ISO-3166-1 alpha-2 code (supplied by
#'   [get_assessments()]).
#' @param date_range,limit,download,cache_dir,overwrite,max_file_size_mb,write_sidecar,topic,relevance_threshold,relevance_model
#'   See [get_assessments()]. `date_range` is applied to `Disclosed_Date`.
#' @param refresh If `TRUE`, ignore cached sidecars.
#' @param ... Reserved; unused arguments are warned about.
#' @return A tibble; see [get_assessments()] for the required schema.
#' @seealso [get_assessments_sources()]
#' @keywords internal
#' @noRd
get_assessments_ifc <- function(
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
  ...
) {
  dots <- list(...)
  if (length(dots) > 0L) {
    warn_partial("Unknown argument{?s} ignored: {.val {names(dots)}}")
  }
  assert_iso2_format(country)
  ifc_name <- ifc_country_names()[country]
  if (is.na(ifc_name)) {
    cli::cli_abort(
      c(
        "IFC has no ESRS project disclosures mapped for country code {.val {country}}.",
        i = "Supported codes: {.val {names(ifc_country_names())}}. Regional/global IFC projects cannot be assigned to a country."
      ),
      class = "planscanR_error_bad_input"
    )
  }
  date_range <- parse_date_range(date_range)
  if (!is.null(cache_dir)) {
    withr::local_options(list(planscanR.cache_dir = cache_dir))
  }
  rate <- getOption("planscanR.ifc_throttle_rate", 3)
  if (!is.null(rate) && is.finite(rate) && rate > 0) {
    withr::local_options(list(planscanR.throttle_rate = rate))
  }
  rel <- setup_relevance(topic, relevance_model, country = country)
  sidecar_index <- if (!refresh) {
    sidecar_url_index(country)
  } else {
    stats::setNames(character(0), character(0))
  }

  process_entry <- function(entry) {
    if (!identical(entry$Country_Description, unname(ifc_name))) {
      warn_partial("Dropped IFC row {.val {entry$Project_Number}} with country {.val {entry$Country_Description}}.")
      return(NULL)
    }
    disclosed <- parse_iso_date(substr(ifc_chr(entry$Disclosed_Date), 1, 10))
    if (!is.null(date_range) && (is.na(disclosed) || disclosed < date_range[1] || disclosed > date_range[2])) {
      return(NULL)
    }
    url <- ifc_detail_url(entry)
    hit <- sidecar_index[url]
    rec <- NULL
    if (length(hit) == 1L && !is.na(hit) && nzchar(hit) && file.exists(hit)) {
      rec <- read_record_sidecar(hit)
      if (!isTRUE(rec[["detail_fetched"]][1])) {
        rec <- NULL
      }
    }
    if (is.null(rec)) {
      docs <- tryCatch(
        ifc_fetch_documents(url),
        error = function(e) {
          warn_partial("IFC detail page {.url {url}} failed, keeping listing metadata only: {conditionMessage(e)}")
          NULL
        }
      )
      rec <- ifc_build_record(entry, docs, country, url)
    }
    if (!is.null(rel)) {
      rec <- apply_relevance(rec, rel)
    }
    should_download <- download && passes_download_gate(rec, rel, relevance_threshold)
    eib_finalise_record(rec, should_download, overwrite, max_file_size_mb, write_sidecar)
  }

  gen <- ifc_fetch_listing(ifc_name, limit = limit)
  records <- stream_crawl(gen, process_entry, limit = limit, label = country)
  if (length(records) == 0L) {
    return(empty_result_tibble())
  }
  bind_results(!!!records)
}

#' ISO-2 -> IFC `Country_Description` for the ESRS index.
#'
#' Regenerate: POST the search API with `filter = "Project_Type eq 'ESRS'"`,
#' `top = 0`, `facets = list("Country_Description,count:400")`, drop the values
#' ending in "Region"/"Subregion" and map the rest to ISO-2. Dated 2026-11-16
#' (150 facet values, 2929 ESRS rows).
#' @noRd
ifc_country_names <- function() {
  c(
    af = "Afghanistan",
    al = "Albania",
    dz = "Algeria",
    ao = "Angola",
    ar = "Argentina",
    am = "Armenia",
    az = "Azerbaijan",
    bd = "Bangladesh",
    bb = "Barbados",
    by = "Belarus",
    bj = "Benin",
    bt = "Bhutan",
    bo = "Bolivia",
    ba = "Bosnia and Herzegovina",
    bw = "Botswana",
    br = "Brazil",
    bg = "Bulgaria",
    bf = "Burkina Faso",
    bi = "Burundi",
    kh = "Cambodia",
    cm = "Cameroon",
    cv = "Cabo Verde",
    td = "Chad",
    cl = "Chile",
    cn = "China",
    co = "Colombia",
    km = "Comoros",
    cd = "Congo, Democratic Republic of",
    cr = "Costa Rica",
    ci = "Cote D'Ivoire",
    hr = "Croatia",
    cz = "Czechia",
    do = "Dominican Republic",
    ec = "Ecuador",
    eg = "Egypt, Arab Republic of",
    sv = "El Salvador",
    er = "Eritrea",
    ee = "Estonia",
    sz = "Eswatini",
    et = "Ethiopia",
    fj = "Fiji",
    ga = "Gabon",
    gm = "Gambia, The",
    ge = "Georgia",
    gh = "Ghana",
    gr = "Greece",
    gt = "Guatemala",
    gn = "Guinea",
    gy = "Guyana",
    ht = "Haiti",
    hn = "Honduras",
    hk = "Hong Kong SAR, China",
    hu = "Hungary",
    `in` = "India",
    id = "Indonesia",
    iq = "Iraq",
    ie = "Ireland",
    il = "Israel",
    jm = "Jamaica",
    jo = "Jordan",
    kz = "Kazakhstan",
    ke = "Kenya",
    xk = "Kosovo",
    kr = "Korea, Republic of",
    kw = "Kuwait",
    kg = "Kyrgyz Republic",
    la = "Lao People's Democratic Republic",
    lv = "Latvia",
    lb = "Lebanon",
    lr = "Liberia",
    lt = "Lithuania",
    mg = "Madagascar",
    mw = "Malawi",
    my = "Malaysia",
    mv = "Maldives",
    ml = "Mali",
    mr = "Mauritania",
    mu = "Mauritius",
    mx = "Mexico",
    md = "Moldova",
    mn = "Mongolia",
    me = "Montenegro",
    ma = "Morocco",
    mz = "Mozambique",
    mm = "Myanmar",
    na = "Namibia",
    np = "Nepal",
    ni = "Nicaragua",
    ng = "Nigeria",
    mk = "North Macedonia",
    om = "Oman",
    pk = "Pakistan",
    pa = "Panama",
    pg = "Papua New Guinea",
    py = "Paraguay",
    pe = "Peru",
    ph = "Philippines",
    pl = "Poland",
    ro = "Romania",
    ru = "Russian Federation",
    rw = "Rwanda",
    ws = "Samoa",
    sa = "Saudi Arabia",
    sn = "Senegal",
    rs = "Serbia",
    sc = "Seychelles",
    sl = "Sierra Leone",
    sg = "Singapore",
    sb = "Solomon Islands",
    za = "South Africa",
    ss = "South Sudan",
    lk = "Sri Lanka",
    sy = "Syrian Arab Republic",
    ch = "Switzerland",
    tj = "Tajikistan",
    tz = "Tanzania",
    th = "Thailand",
    tl = "Timor-Leste",
    tg = "Togo",
    tt = "Trinidad and Tobago",
    tn = "Tunisia",
    tr = "Turkiye",
    ug = "Uganda",
    ua = "Ukraine",
    ae = "United Arab Emirates",
    uy = "Uruguay",
    uz = "Uzbekistan",
    vu = "Vanuatu",
    ve = "Venezuela, Republica Bolivariana de",
    vn = "Viet Nam",
    ps = "West Bank and Gaza",
    ye = "Yemen, Republic of",
    zm = "Zambia",
    zw = "Zimbabwe"
  )
}

ifc_source_portal <- function() "disclosures.ifc.org"

ifc_search_url <- function() "https://webapi.worldbank.org/aemsite/ifc-disclosure-search"

ifc_chr <- function(x) wb_flat(x)

ifc_state <- new.env(parent = emptyenv())

#' Public subscription key printed in project-detail pages (cached per session).
#' @noRd
ifc_subscription_key <- function() {
  if (!is.null(ifc_state$key)) {
    return(ifc_state$key)
  }
  page <- getOption("planscanR.ifc_key_page", "https://disclosures.ifc.org/project-detail/ESRS/46568/africa-release")
  key <- tryCatch(
    {
      html <- perform_html(req_planscanr(page))
      rvest::html_attr(rvest::html_element(html, "[data-subscription-key]"), "data-subscription-key")
    },
    error = function(e) NA_character_
  )
  if (length(key) != 1L || is.na(key) || !nzchar(key)) {
    cli::cli_abort(
      c(
        "Could not read the IFC public search key from {.url {page}}.",
        i = "The portal may have changed; set {.code options(planscanR.ifc_key_page = <a project-detail URL>)} or retry later."
      ),
      class = "planscanR_error_bad_response"
    )
  }
  ifc_state$key <- key
  key
}

ifc_page_size <- function(limit = Inf) {
  v <- suppressWarnings(as.integer(getOption("planscanR.ifc_page_size", 200L)))
  if (length(v) != 1L || is.na(v) || v < 1L) {
    v <- 200L
  }
  as.integer(min(v, 1000L, max(1, ceiling(limit))))
}

#' Page generator over the IFC search API (stream_crawl `next_page` contract).
#' @noRd
ifc_fetch_listing <- function(ifc_name, limit = Inf) {
  top <- ifc_page_size(limit)
  filter <- sprintf(
    "Project_Type eq 'ESRS' and Country_Description eq '%s'",
    gsub("'", "''", ifc_name, fixed = TRUE)
  )
  skip <- 0L
  total <- NA_integer_
  seen <- character(0)
  pages <- 0L
  done <- FALSE
  function() {
    if (done) {
      return(NULL)
    }
    req <- req_planscanr(ifc_search_url())
    req <- httr2::req_headers(req, `Ocp-Apim-Subscription-Key` = ifc_subscription_key())
    req <- httr2::req_body_json(
      req,
      list(search = "*", filter = filter, orderby = "Project_Number asc", top = top, skip = skip, count = TRUE)
    )
    payload <- tryCatch(
      perform_json(req),
      error = function(e) {
        if (pages == 0L) {
          cli::cli_abort(
            c("Could not query the IFC disclosure search.", x = conditionMessage(e)),
            class = "planscanR_error_http",
            parent = e
          )
        }
        warn_partial("IFC listing stopped at offset {skip} ({conditionMessage(e)}); results are incomplete.")
        NULL
      }
    )
    if (is.null(payload)) {
      done <<- TRUE
      return(NULL)
    }
    cnt <- suppressWarnings(as.integer(payload[["@odata.count"]] %||% NA))
    if (!is.list(payload) || !is.list(payload$value) || is.na(cnt)) {
      cli::cli_abort(
        c(
          "The IFC disclosure search returned a malformed response (no {.field value} list or {.field @odata.count}).",
          i = "The API may have changed or be unavailable; retry later."
        ),
        class = "planscanR_error_bad_response"
      )
    }
    if (!is.na(total) && cnt != total) {
      warn_partial("IFC result count changed from {total} to {cnt} during the crawl; results may be incomplete.")
    }
    total <<- cnt
    pages <<- pages + 1L
    rows <- payload$value
    skip <<- skip + length(rows)
    if (length(rows) == 0L || skip >= total) {
      done <<- TRUE
    }
    if (length(rows) > 0L && length(rows) < top && skip < total) {
      warn_partial(
        "IFC listing returned a short page ({length(rows)} of {top}) before {total} rows; results may be incomplete."
      )
    }
    ids <- vapply(rows, function(r) as.character(r$Project_Number %||% NA_character_), character(1))
    fresh <- !is.na(ids) & !ids %in% seen & !duplicated(ids)
    seen <<- c(seen, ids[fresh])
    if (done && length(seen) < total) {
      warn_partial("IFC listing ended with {length(seen)} of {total} projects; results are incomplete.")
    }
    if (length(rows) > 0L && !any(fresh)) {
      done <<- TRUE
      warn_partial("IFC listing page repeated already-seen projects; stopping, results may be incomplete.")
    }
    unname(rows[fresh])
  }
}

ifc_detail_url <- function(entry) {
  slug <- gsub("[^\\w-]", "-", tolower(trimws(ifc_chr(entry$Project_Name))), perl = TRUE)
  paste0("https://disclosures.ifc.org/project-detail/ESRS/", ifc_chr(entry$Project_Number), "/", slug)
}

#' Documents table of a project-detail page: a list of native rows.
#'
#' Errors when the page has no documents table (so it is never cached as
#' complete); an empty table is a valid "no files disclosed" answer.
#' @noRd
ifc_fetch_documents <- function(url) {
  ifc_parse_documents(perform_html(req_planscanr(url)), url)
}

ifc_parse_documents <- function(html, url) {
  tab <- rvest::html_element(html, "table.es-client-document")
  if (inherits(tab, "xml_missing")) {
    cli::cli_abort("no documents table found", class = "planscanR_error_bad_response")
  }
  heads <- trimws(rvest::html_text2(rvest::html_elements(tab, "thead th")))
  rows <- rvest::html_elements(tab, "tbody tr")
  lapply(rows, function(tr) {
    tds <- rvest::html_elements(tr, "td")
    txt <- trimws(rvest::html_text2(tds))
    names(txt) <- if (length(heads) == length(txt)) heads else paste0("column_", seq_along(txt))
    href <- rvest::html_attr(rvest::html_elements(tr, "a"), "href")
    href <- xml2::url_absolute(href[!is.na(href) & nzchar(href)], url)
    nm <- as.list(txt[nzchar(txt)])
    names(nm)[1L] <- "file_name"
    c(nm, list(url = unname(href), role = nm$file_name))
  })
}

ifc_text <- function(x) {
  x <- ifc_chr(x)
  if (is.na(x)) {
    return(NA_character_)
  }
  trimws(rvest::html_text2(rvest::read_html(paste0("<body>", x, "</body>"))))
}

#' Build the 1-row record from a listing row and the (optional) detail docs.
#' @noRd
ifc_build_record <- function(entry, docs, country, url) {
  json <- function(x) as.character(jsonlite::toJSON(x, auto_unbox = TRUE, null = "null", na = "null"))
  urls <- unique(unlist(lapply(docs, `[[`, "url"), use.names = FALSE)) %||% character(0)
  parts <- Filter(
    function(p) !is.na(p),
    lapply(
      list(entry$Project_Description, entry$Review_Scope, entry$Environmental_Social_Categorization_Rationale),
      ifc_text
    )
  )
  rec <- tibble::tibble(
    country = country,
    source_portal = ifc_source_portal(),
    document_id = paste0("ifc_", ifc_chr(entry$Project_Number)),
    url = url,
    retrieved_at = as.POSIXct(Sys.time(), tz = "UTC"),
    attachment_urls = list(urls),
    local_path = list(character(0)),
    title = ifc_chr(entry$Project_Name),
    summary = if (length(parts)) paste(unlist(parts), collapse = "\n\n") else NA_character_,
    competent_authority = NA_character_,
    proponent = ifc_chr(entry$Company_Name),
    date_published = parse_iso_date(substr(ifc_chr(entry$Disclosed_Date), 1, 10)),
    date_decision = parse_iso_date(substr(ifc_chr(entry$Approval_Date), 1, 10)),
    native_type = ifc_chr(entry$Document_Type_Description),
    status = ifc_chr(entry$Status_Description),
    detail_fetched = !is.null(docs),
    documents_json = json(docs %||% list()),
    listing_json = json(entry),
    download_status = list(empty_download_status())
  )
  for (nm in setdiff(names(entry), c("@search.score", names(rec)))) {
    rec[[nm]] <- ifc_chr(entry[[nm]])
  }
  rec$attachment_urls_document <- list(urls)
  rec$local_path_document <- list(character(0))
  rec
}
