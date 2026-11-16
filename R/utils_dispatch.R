#' Countries supported by the current version of planscanR.
#'
#' Returns a character vector of ISO-3166-1 alpha-2 country codes (lowercase).
#'
#' @return Character vector.
#' @export
#' @examples
#' supported_countries()
supported_countries <- function() {
  c(
    "nl",
    "de",
    "fr",
    "at",
    "dk",
    "be",
    "ee",
    "fi",
    "bg",
    "cz",
    "hr",
    "gr",
    "is",
    "ie",
    "si",
    "pt",
    "gb",
    "it",
    "sk",
    "no",
    "lv",
    "es",
    "cy"
  )
}

#' Normalise a country code to lowercase ISO-2.
#'
#' Accepts any case; rejects non-character or non-scalar input.
#'
#' @param country Character scalar.
#' @return Lowercase character scalar.
#' @noRd
normalise_country <- function(country) {
  if (!is.character(country) || length(country) != 1L || is.na(country) || !nzchar(country)) {
    cli::cli_abort(
      "{.arg country} must be a single non-empty character string.",
      class = "planscanR_error_bad_input"
    )
  }
  tolower(country)
}

#' Assert that a country code is supported.
#'
#' @param country Country code (lowercase).
#' @noRd
assert_country <- function(country) {
  if (!country %in% supported_countries()) {
    abort_unsupported_country(country)
  }
  invisible(country)
}

#' Registry of explicit, opt-in assessment sources.
#'
#' Named list `source_id -> list(handler, name, granularity, geography, scope,
#' limitations, url)`. Source adapters register themselves here.
#' @noRd
assessment_sources <- function() {
  list(
    worldbank = list(
      handler = get_assessments_worldbank,
      name = "World Bank Documents & Reports",
      granularity = "document",
      geography = "ISO-2 country code mapped to the WDS countrycode filter; multi-country records included, global/regional-only records excluded; a code with no World Bank documents at all (e.g. \"uk\", the bank uses \"gb\") is an error",
      scope = "Disclosed World Bank project documents typed Environmental Assessment, Environmental and Social Assessment or Strategic Environmental Assessment/Analysis; all sectors, mostly 2000s to present; anonymous PDF access",
      limitations = "Document-level, bank-financed projects only; the type label also holds ESMP-grade site files, plans, volumes and annexes (no title heuristic applied)",
      url = "https://documents.worldbank.org/"
    ),
    eib = list(
      handler = get_assessments_eib,
      name = "European Investment Bank public register",
      granularity = "document (project_number kept)",
      geography = "ISO-2 country tags; any tag equal to the requested code matches; regional/non-ISO and untagged rows excluded",
      scope = "environmental and social documents of EIB-financed projects, all native document types (ESIA/EIA/SEA full reports, ESDS/ESCS/NTS summaries, permits, links), about 2011 onward",
      limitations = "not national completeness; some rows have no file; totalItems can exceed listed rows; reports over the size cap are skipped_size",
      url = "https://www.eib.org/en/registers/"
    ),
    be_dsi = list(
      handler = get_assessments_be_dsi,
      name = "Flanders DSI planning dossiers (Departement Omgeving)",
      granularity = "planning dossier (all phases and documents)",
      geography = "Flanders only (country = \"be\"); not Wallonia or Brussels",
      scope = "Flemish spatial plans (RUP, BPA, ...); plan-MER reports are a subset of the documents",
      limitations = "Document code PLNMER mixes plan-MER reports, screening and decision letters; native code/description/phase kept, no classification. No server-side pre-filter to report-bearing dossiers.",
      url = "https://dsi.omgeving.vlaanderen.be/"
    ),
    ifc = list(
      handler = get_assessments_ifc,
      name = "IFC project disclosures (ESRS)",
      granularity = "project (Environmental and Social Review Summary) with its client documents",
      geography = "ISO-2 code mapped to IFC's World-Bank-style country name (134 countries from the 150-value ESRS facet, 16 regional values dropped); regional/world pseudo-countries excluded; a code IFC has no ESRS projects for is an error",
      scope = "IFC private-sector investments, disclosure type ESRS only (other IFC types out of scope); projects 1999 to present, older files often 404 (2 of 2 sampled legacy cases); all sectors, mainly Category A/B; anonymous PDF access",
      limitations = "Document roles are not labelled by IFC (only file names; no classifier); older files often 404; pending projects list no files; relies on a public search key read from a detail page; no NL/DE/DK/AT projects",
      url = "https://disclosures.ifc.org/"
    )
  )
}

#' Validate a scalar ISO-2 format (two ASCII letters), independent of
#' [supported_countries()].
#' @noRd
assert_iso2_format <- function(country) {
  if (!grepl("^[a-z]{2}$", country)) {
    cli::cli_abort(
      "{.arg country} must be a two-letter ISO-3166-1 alpha-2 code when {.arg source} is set, not {.val {country}}.",
      class = "planscanR_error_bad_input"
    )
  }
  invisible(country)
}

#' Look up the handler for an explicit source.
#' @noRd
select_source_handler <- function(source) {
  if (!is.character(source) || length(source) != 1L || is.na(source) || !nzchar(source)) {
    cli::cli_abort(
      "{.arg source} must be a single non-empty, non-NA string.",
      class = "planscanR_error_bad_input"
    )
  }
  reg <- assessment_sources()
  if (!source %in% names(reg)) {
    cli::cli_abort(
      c(
        "Unknown {.arg source} {.val {source}}.",
        i = if (length(reg)) {
          "Available sources: {.val {names(reg)}}. See {.fn get_assessments_sources}."
        } else {
          "No explicit sources are registered yet. See {.fn get_assessments_sources}."
        }
      ),
      class = "planscanR_error_bad_input"
    )
  }
  reg[[source]]$handler
}

#' Explicit assessment sources.
#'
#' Lists the opt-in sources selectable with `get_assessments(source = )`, in
#' addition to the national portals reported by [get_assessments_coverage()].
#'
#' @return A tibble with columns `source`, `name`, `granularity`, `geography`,
#'   `scope`, `limitations`, `url` (zero rows when no source is registered).
#' @seealso [get_assessments()], [get_assessments_coverage()]
#' @export
#' @examples
#' get_assessments_sources()
get_assessments_sources <- function() {
  reg <- assessment_sources()
  cols <- c("name", "granularity", "geography", "scope", "limitations", "url")
  out <- tibble::tibble(source = names(reg) %||% character(0))
  for (col in cols) {
    out[[col]] <- vapply(
      reg,
      function(r) as.character(r[[col]] %||% NA_character_)[1L],
      character(1),
      USE.NAMES = FALSE
    )
  }
  out
}
