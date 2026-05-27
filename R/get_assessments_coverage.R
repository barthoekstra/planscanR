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
    country = "nl",
    source_portal = "commissiemer.nl",
    base_url = "https://www.commissiemer.nl",
    requires_auth = FALSE,
    status = "supported",
    facets = list(commissiemer_facets())
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
