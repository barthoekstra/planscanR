# Per-country discovery config for Austria.
#
# This is the country-specific intelligence that drives [discover_attachments()]
# for AT: query templates, state-domain map, Aktenzahl regex, and a proponent
# extractor. The rest of the discovery pipeline is country-agnostic and consumes
# this configuration.

#' Discovery configuration for the Austrian UVP-DB.
#'
#' Returns a named list of inputs that [discover_attachments()] uses to
#' build queries for AT records and to validate candidate PDFs. AT-specific
#' rationale lives next to each field; the keys themselves are part of the
#' discovery-config contract that every country should provide.
#'
#' @return A list with the following named elements:
#'   * `query_templates` — list of function(record) -> character, each
#'     producing one search query (or NULL to skip).
#'   * `state_domains` — named list `bundesland -> character vector` of
#'     authority domains to scope queries to.
#'   * `aktenzahl_regex` — regex that detects the country's primary
#'     identifier in PDF text. For AT it matches the UBA-internal AZ
#'     `02 NNNN` plus a couple of dash/no-space variants.
#'   * `extract_proponent` — function(record) -> character, pulls the
#'     proponent name out of the record's summary (returns NA on failure).
#'   * `extra_signals` — character vector of additional patterns the
#'     validator will check for in PDF text (e.g. legal-basis strings).
#' @export
#' @examples
#' \dontrun{
#' cfg <- at_discovery_config()
#' rec <- index_cache(country = "at")[1, ]
#' lapply(cfg$query_templates, function(f) f(rec))
#' }
at_discovery_config <- function() {
  list(
    query_templates = list(
      title_bescheid_pdf = function(rec) {
        t <- at_clean_title(rec$title)
        if (is.null(t)) {
          return(NULL)
        }
        sprintf('"%s" Bescheid filetype:pdf', t)
      },
      title_uvp_scoped = function(rec) {
        # Scoped query — handled at call time by include_domains. The query
        # itself omits the site: operator so the backend's include_domains
        # is the authoritative scope.
        t <- at_clean_title(rec$title)
        if (is.null(t)) {
          return(NULL)
        }
        sprintf('"%s" UVP', t)
      },
      proponent_title_pdf = function(rec) {
        prop <- at_extract_proponent_from_summary(rec$summary)
        t <- at_clean_title(rec$title)
        # Skip this template when either the proponent regex failed or the
        # title is empty — quoting a literal "NA" into the query just burns
        # an API call on a guaranteed-empty result.
        if (is.null(prop) || is.na(prop) || !nzchar(prop) || is.null(t)) {
          return(NULL)
        }
        # Use a 2-3 word title stem so the AND combo with proponent is loose
        # enough for legitimate documents to surface.
        stem <- at_title_stem(t)
        sprintf('"%s" "%s" filetype:pdf', prop, stem)
      },
      title_stellungnahme_pdf = function(rec) {
        # Technical opinions / Umweltgutachten are often easier to find on
        # state portals than the Bescheid itself.
        t <- at_clean_title(rec$title)
        if (is.null(t)) {
          return(NULL)
        }
        sprintf('"%s" Stellungnahme filetype:pdf', t)
      }
    ),
    # State authority domains. Multi-state procedures get the union of every
    # listed state's domains; federal-led procedures (Bund, BMVIT, BMK) get
    # the federal domains via `_federal`.
    state_domains = list(
      Burgenland = c(
        "burgenland.at",
        "e-rechtsdb.bgld.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at",
        "ig-windkraft.at",
        "oekobuero.at"
      ),
      Kärnten = c(
        "ktn.gv.at",
        "verwaltung.ktn.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at"
      ),
      Niederösterreich = c(
        "noe.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at",
        "ig-windkraft.at",
        "oekobuero.at"
      ),
      Oberösterreich = c(
        "land-oberoesterreich.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at",
        "ig-windkraft.at",
        "oekobuero.at"
      ),
      Salzburg = c(
        "salzburg.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at"
      ),
      Steiermark = c(
        "verwaltung.steiermark.at",
        "ris.bka.gv.at",
        "bvwg.gv.at",
        "ig-windkraft.at",
        "oekobuero.at"
      ),
      Tirol = c(
        "tirol.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at"
      ),
      Vorarlberg = c(
        "vorarlberg.at",
        "ris.bka.gv.at",
        "bvwg.gv.at"
      ),
      Wien = c(
        "wien.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at"
      ),
      `_federal` = c(
        "bmk.gv.at",
        "bmimi.gv.at",
        "ris.bka.gv.at",
        "bvwg.gv.at",
        "oebb.at",
        "asfinag.at"
      )
    ),
    # UBA AZ `02 NNNN` (with optional dash or no space). Captured as a
    # whole-word match. Used by the validator to confirm a candidate PDF
    # actually references the record's Aktenzahl.
    aktenzahl_regex = "\\b02[ \\-]?\\d{4}\\b",
    extract_proponent = function(rec) at_extract_proponent_from_summary(rec$summary),
    # Patterns that, when present, raise the validator's confidence that a
    # PDF is a real UVP document. Loose substring matches.
    extra_signals = c(
      "UVP-G 2000",
      "Umweltvertr",
      "Bescheid",
      "Genehmigung"
    ),
    # Tokens that appear in many records' titles but don't distinguish
    # between projects. The validator excludes these when computing whether
    # the PDF's text matches the title — only **distinguishing** tokens
    # (place names, project-specific words) earn matches. Stored after
    # `normalise_text_for_match()` normalisation (lowercase, German digraph
    # collapse, diacritics stripped) so they line up with the title tokens
    # computed at validation time.
    #
    # Curated from a sweep of the 506 AT records' title vocabulary. Add new
    # entries here if a future smoke test reveals more generics leaking
    # through.
    title_stoplist = c(
      # subtype labels
      "windpark", "windparks", "windkraft", "windkraftanlage",
      "windkraftanlagen", "kraftwerk", "kraftwerks", "kraftwerke",
      "wasserkraftanlage", "wasserkraftwerk", "fernheizwerk", "fernheizwerks",
      "freileitung", "leitung", "leitungen", "anlage", "anlagen",
      # document-type words
      "bescheid", "bescheide", "antrag", "antrage", "genehmigung",
      "genehmigungsantrag", "stellungnahme", "vorhaben", "projekt",
      "kundmachung",
      # modifier words common across many projects
      "erweiterung", "neuerrichtung", "neubau", "ersatzneubau",
      "repowering", "anderung", "anderungsbescheid", "verlangerung",
      # legal frame
      "umwelt", "umweltvertraglichkeitsprufung", "umweltbericht",
      "umweltgutachten",
      # very common geography words
      "burgenland", "niederosterreich", "oberosterreich", "steiermark",
      "salzburg", "vorarlberg", "tirol", "karnten", "wien", "osterreich"
    )
  )
}

#' Strip noisy suffixes from an AT record title before using it in a query.
#' @noRd
at_clean_title <- function(title) {
  if (is.null(title) || is.na(title) || !nzchar(title)) {
    return(NULL)
  }
  s <- gsub("\\s+", " ", trimws(title))
  # Drop parenthesised aliases like "(WP NDWE)" — they hurt exact-phrase
  # matching on Tavily / Google.
  s <- sub("\\s*\\([^)]*\\)\\s*$", "", s)
  if (!nzchar(s)) NULL else s
}

#' First 3 content-bearing words of a cleaned title.
#' @noRd
at_title_stem <- function(s) {
  toks <- strsplit(s, "\\s+")[[1]]
  toks <- toks[nzchar(toks) & nchar(toks) >= 3L]
  paste(head(toks, 3L), collapse = " ")
}

#' Pull the proponent name out of an AT record's summary text.
#'
#' AT UVP summaries reliably open with the proponent + "plant/beabsichtigt/
#' projektiert" pattern, e.g. "Die Energie Burgenland Windkraft GmbH plant…".
#' We extract the noun phrase up to that verb.
#'
#' @return Character scalar, or `NA_character_` if no match.
#' @noRd
at_extract_proponent_from_summary <- function(summary) {
  if (is.null(summary) || is.na(summary) || !nzchar(summary)) {
    return(NA_character_)
  }
  # Match "Die <ProponentName> plant/beabsichtigt/projektiert…" — the
  # proponent runs from after "Die " up to (but not including) the verb.
  m <- regmatches(
    summary,
    regexpr(
      "\\bDie\\s+([A-ZÄÖÜ][^.]+?)\\s+(plant|beabsichtigt|projektiert|plante|beabsichtigte|ist|hat)\\b",
      summary,
      perl = TRUE
    )
  )
  if (length(m) == 0L) {
    return(NA_character_)
  }
  # Strip leading "Die " and the verb tail.
  raw <- sub("^Die\\s+", "", m, perl = TRUE)
  raw <- sub(
    "\\s+(plant|beabsichtigt|projektiert|plante|beabsichtigte|ist|hat)\\b.*$",
    "",
    raw,
    perl = TRUE
  )
  raw <- trimws(raw)
  if (!nzchar(raw)) NA_character_ else raw
}

#' Resolve the domains to scope a record's queries to.
#'
#' For multi-state procedures (jurisdiction like "Niederösterreich, Wien")
#' we union every listed state's domains plus the federal set. Returns
#' `character(0)` if the jurisdiction is unrecognised (caller then runs
#' unscoped).
#' @noRd
at_domains_for <- function(rec, cfg = at_discovery_config()) {
  j <- rec$jurisdiction %||% ""
  if (!nzchar(j) || is.na(j)) {
    return(cfg$state_domains[["_federal"]])
  }
  parts <- trimws(strsplit(j, ",")[[1]])
  hits <- unlist(cfg$state_domains[parts], use.names = FALSE)
  hits <- c(hits, cfg$state_domains[["_federal"]])
  unique(hits)
}
