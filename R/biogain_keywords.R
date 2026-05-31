# BIOGAIN keyword lexicon (multilingual).
#
# The curated NL / DE / EN term lists for the lexical keyword signal
# (`score_keywords()`). Extracted from `score_keywords.R` so the generic
# substring-scoring framework can live without the BIOGAIN-specific config.

#' BIOGAIN keyword lexicon (multilingual).
#'
#' A named list mapping each BIOGAIN topic to a vector of search terms across
#' Dutch, German, and English. Terms are matched as **substrings** of text
#' normalised with the package's diacritic/digraph folding — substring rather
#' than word-boundary matching because German/Dutch put the key term mid-word
#' in compounds (`Höchst`**spannung**`sfreileitung`, `wind`-anything). The
#' folding means the ASCII terms here align with accented source text
#' (`spannung` matches `Höchstspannung`; `biomas` matches `Biomasse`).
#'
#' @return A named list of character vectors, one per topic.
#' @export
#' @examples
#' biogain_keyword_lexicon()$wind
biogain_keyword_lexicon <- function() {
  list(
    wind = c("wind", "repowering"),
    solar = c("solar", "zonne", "fotovolta", "photovolta"),
    power_grid = c(
      "hoogspann",
      "spannung",
      "freileitung",
      "umspann",
      "stromnetz",
      "netaansluiting",
      "transformator",
      "trafostation"
    ),
    other_renewable = c(
      "biogas",
      "biomass",
      "geotherm",
      "aardwarmte",
      "waterkracht",
      "wasserkraft",
      "vergisting"
    ),
    energy_strategy = c(
      "energiestrategie",
      "energietransitie",
      "energieperspectief",
      "energievisie",
      "klimaat",
      "klimaschutz"
    ),
    renewable_zoning = c("zoekgebied", "opwek", "vorranggebiet", "vorrangzone")
  )
}
