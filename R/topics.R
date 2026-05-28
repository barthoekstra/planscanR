#' BIOGAIN-default topic phrases for relevance scoring.
#'
#' Returns the canonical set of search topics used by the BIOGAIN project
#' (Net Biodiversity Gain in spatial energy planning) when scoring
#' environmental-assessment records. The names of the returned vector are
#' the column-suffix slugs that will appear in the result tibble (e.g.
#' `relevance_score_wind`); the values are the English phrases embedded by
#' the multilingual model.
#'
#' These topics are an **opt-in default** — pass the return value as `topic`
#' to [get_assessments()] (or `score_assessments()`) when you want the
#' BIOGAIN set. Other use-cases should pass their own topic vector.
#'
#' Cross-country notes:
#' * `energy_transition_strategy` is intended to bridge NL `Regionale Energie
#'   Strategie` (RES), DE `Klimaschutzkonzept` / regional energy plans,
#'   FR `SRADDET` / `PCAET`, AT `Energiestrategie`, and similar instruments.
#' * `renewable_zoning` is intended to bridge spatial-designation instruments
#'   like NL `zoekgebieden`, DE `Vorrangzonen`, and EU RED III "renewable
#'   acceleration areas".
#' * The English phrases are deliberately generic so the multilingual
#'   embedding model can semantically bridge to each portal's vocabulary
#'   without translation.
#'
#' @return A named character vector. Names are stable slugs used as column
#'   suffixes; values are the topic phrases passed to the embedding model.
#' @export
#' @examples
#' biogain_assessment_topics()
#'
#' \dontrun{
#' # Score a small slice of the NL register against the BIOGAIN topic set
#' res <- get_assessments(
#'   "nl",
#'   topic = biogain_assessment_topics(),
#'   limit = 5,
#'   download = FALSE
#' )
#' }
biogain_assessment_topics <- function() {
  c(
    wind = "wind energy",
    solar = "solar energy",
    power_grid = "power lines, distribution and transmission infrastructure",
    renewable_energy = "renewable energy",
    energy_transition_strategy = "regional energy transition strategy and planning",
    renewable_zoning = "renewable energy zoning and designated development areas"
  )
}
