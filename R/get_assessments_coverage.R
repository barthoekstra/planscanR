#' List supported countries and portals.
#'
#' Returns a tibble describing every country handler currently shipped, the
#' portal it targets, and the vocabularies of the search facets it accepts.
#' This is the canonical place to discover what values can be passed to
#' search parameters like `theme`, `advice_type`, `province`, `status`.
#'
#' @return A tibble with one row per supported country, columns:
#'   `country`, `source_portal`, `base_url`, `requires_auth`, `status`,
#'   plus a list-column `facets` of named lists giving the valid values for
#'   each search parameter the handler accepts.
#' @export
#' @examples
#' get_assessments_coverage()
get_assessments_coverage <- function() {
  tibble::tibble(
    country = c("nl", "de"),
    source_portal = c("commissiemer.nl", "uvp-verbund.de"),
    base_url = c("https://www.commissiemer.nl", "https://www.uvp-verbund.de"),
    requires_auth = c(FALSE, FALSE),
    status = c("supported", "supported"),
    facets = list(commissiemer_facets(), uvp_facets())
  )
}

#' Static lookup of the UVP-Verbund facet vocabularies.
#'
#' The portal exposes a `procedure=` facet (Zulassungsverfahren,
#' Bauleitplanung, Raumordnungsverfahren, Negative Vorprüfungen,
#' Linienbestimmungen, Ausländische Vorhaben) and an implicit federal-state
#' partner facet via search-result icons; neither is honoured yet in v0.1.
#' Captured for forward compatibility / documentation.
#' @noRd
uvp_facets <- function() {
  list(
    procedure = c(
      "obj_class_zv",
      "obj_class_nv",
      "obj_class_blp",
      "obj_class_ro",
      "obj_class_li",
      "obj_class_av"
    ),
    bundesland = c(
      "Baden-W\u00fcrttemberg",
      "Bayern",
      "Berlin",
      "Brandenburg",
      "Bremen",
      "Hamburg",
      "Hessen",
      "Mecklenburg-Vorpommern",
      "Niedersachsen",
      "Nordrhein-Westfalen",
      "Rheinland-Pfalz",
      "Saarland",
      "Sachsen",
      "Sachsen-Anhalt",
      "Schleswig-Holstein",
      "Th\u00fcringen",
      "Bund"
    )
  )
}

#' Static lookup of the Commissie m.e.r. facet vocabularies.
#'
#' Captured from the FacetWP preload at <https://www.commissiemer.nl/adviezen/>
#' on 2026-05-26. Used both for documenting valid search values and for
#' validating user input in [get_assessments_nl()].
#'
#' @return Named list of character vectors.
#' @noRd
commissiemer_facets <- function() {
  # fmt: skip
  list(
    advice_type = c(
      "toetsing", "richtlijnen", "reikwijdte-en-detailniveau", "beoordeling", "overig", "ontheffing", "evaluatie"
    ),
    status = c("afgerond", "lopend"),
    province = c(
      "provincie-noord-brabant", "provincie-zuid-holland", "provincie-gelderland", "provincie-noord-holland",
      "provincie-overijssel", "provincie-limburg", "landelijk", "provincie-groningen", "provincie-friesland",
      "provincie-utrecht", "provincie-zeeland", "provincie-drenthe", "provincie-flevoland", "belgium", "germany",
      "antarctica", "norway", "united-kingdom", "aruba", "georgia", "ukraine"
    ),
    theme = c(
      "afval", "bagger", "bedrijventerreinen", "buisleidingen", "cultuurhistorie", "delfstofwinning-en-ontgrondingen",
      "dijken", "duurzame-ontwikkeling", "energie", "externe-veiligheid", "fossiele-brandstoffen", "geluid",
      "gezondheid", "grensoverschrijdende-projecten", "hoogspanningsleidingen", "kernenergie", "klimaatadaptatie",
      "landelijk-gebied", "landschap", "luchthavens", "luchtkwaliteit", "mkba", "natuur", "omgevingsplannen",
      "participatie", "procesindustrie", "recreatie", "spoorwegen", "stedelijke-ontwikkeling", "structuurvisies",
      "tuinbouw", "uitnodigingsplanologie", "vaarwegen-en-havens", "veehouderij", "waddenzee", "waterbeheer",
      "waterwinning", "wegen", "windenergie"
    )
  )
}
