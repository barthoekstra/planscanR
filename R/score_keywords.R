# Lexical keyword layer: a transparent, multilingual term-frequency signal
# complementary to the embedding cosine scores and the zero-shot classifier.
#
# Where the two semantic signals dilute an explicit mention (a "Windturbines
# Amsterdam-Noord" siting plan buried in planning prose) or confuse it with a
# generic-planning lookalike (a "Woningbouw" housing plan), a keyword count
# separates them cleanly: the former contains wind terms, the latter contains
# none. This is deliberately lexical — it needs curated multilingual term
# lists (NL / DE / EN) rather than generalising semantically.

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

#' Score records against the keyword lexicon.
#'
#' Adds one `kw_<topic>` integer column per lexicon topic (the number of term
#' occurrences in the record's title + summary + category) plus a `kw_total`
#' column. Matching is on normalised text (lowercased, diacritics stripped,
#' German vowel digraphs collapsed), with terms anchored at a word start so
#' compounds match their stem.
#'
#' @param records A tibble; uses `title`, `summary`, and (if present)
#'   `native_type`.
#' @param lexicon Named list of term vectors. Defaults to
#'   [biogain_keyword_lexicon()].
#' @param text_fn Optional `function(record) -> character` building the text to
#'   scan. Default concatenates title + summary + native_type.
#' @return `records` with `kw_<topic>` and `kw_total` columns added.
#' @export
#' @examples
#' \dontrun{
#' recs <- index_cache(country = "nl")
#' scored <- score_keywords(recs)
#' scored[scored$kw_total == 0, "title"] # likely non-energy
#' }
score_keywords <- function(records, lexicon = biogain_keyword_lexicon(), text_fn = NULL) {
  if (!is.data.frame(records)) {
    cli::cli_abort("{.arg records} must be a data frame.")
  }
  topics <- names(lexicon)
  n <- nrow(records)
  if (n == 0L) {
    for (tp in topics) {
      records[[paste0("kw_", tp)]] <- integer(0)
    }
    records$kw_total <- integer(0)
    return(records)
  }
  if (is.null(text_fn)) {
    text_fn <- function(rec) {
      parts <- c(rec$title, rec$summary, rec[["native_type"]])
      parts <- parts[!is.na(parts) & nzchar(parts)]
      if (length(parts) == 0L) "" else paste(parts, collapse = ". ")
    }
  }
  norm <- vapply(
    seq_len(n),
    function(i) normalise_text_for_match(text_fn(records[i, ])),
    character(1)
  )
  # Normalised term lists per topic (so ASCII terms align with accented text).
  term_lists <- lapply(topics, function(tp) {
    terms <- unique(vapply(lexicon[[tp]], normalise_text_for_match, character(1)))
    terms[nzchar(terms)]
  })
  names(term_lists) <- topics

  # Total substring occurrences of any of a topic's terms in the text.
  count_hits <- function(t, terms) {
    if (!nzchar(t) || length(terms) == 0L) {
      return(0L)
    }
    sum(vapply(
      terms,
      function(term) {
        m <- gregexpr(term, t, fixed = TRUE)[[1]]
        if (length(m) == 1L && m[1] == -1L) 0L else length(m)
      },
      integer(1)
    ))
  }
  for (tp in topics) {
    records[[paste0("kw_", tp)]] <- vapply(
      norm,
      count_hits,
      integer(1),
      terms = term_lists[[tp]]
    )
  }
  records$kw_total <- as.integer(rowSums(as.matrix(records[paste0("kw_", topics)])))
  records
}
