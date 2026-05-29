# The BIOGAIN selection procedure: combine the three relevance signals
# (embedding cosine, zero-shot classifier, lexical keywords) into a single
# `selected` flag that decides which records to carry into downstream
# acquisition/analysis.

#' Apply the BIOGAIN selection rule to scored + classified records.
#'
#' Combines the three relevance signals into one decision. A record is
#' **selected** when any one of the signals fires —
#'
#' * the embedding cosine score clears the relevance threshold, OR
#' * the classifier labels it as a relevant (renewable-energy) type, OR
#' * it contains at least `kw_min` keyword hits —
#'
#' *and* it is not confidently off-target (not classified as fossil power,
#' oil/gas extraction, or nuclear above `nonrenewable_score`).
#'
#' Rationale (from the NL analysis): the three signals are complementary — the
#' cosine score misses some near-threshold energy records, the classifier
#' mislabels some into negative classes, and the keyword layer catches explicit
#' mentions the other two dilute. Taking their union favours recall (this step
#' runs before acquisition; precision can still be improved downstream), while
#' the fossil/oil-gas/nuclear trim drops records that are clearly off-target for
#' BIOGAIN.
#'
#' @param records A tibble that has been scored (`relevance_score_<slug>`
#'   columns) and classified (`class_label`, `class_relevant`, `class_score`).
#'   Keyword columns (`kw_total`) are computed via [score_keywords()] if absent.
#' @param topics Named topic vector whose slugs name the cosine columns to
#'   consider. Defaults to [biogain_assessment_topics()].
#' @param relevance_threshold Cosine cutoff; a record is cosine-relevant if any
#'   topic clears it. Default `0.5`.
#' @param kw_min Minimum `kw_total` for the keyword arm to fire. Default `2`.
#' @param nonrenewable Classifier labels treated as confidently-off-target when
#'   their `class_score` clears `nonrenewable_score`.
#' @param nonrenewable_score Confidence cutoff for the non-renewable trim.
#' @return `records` with a logical `selected` column added (and `cosine_max`,
#'   `cosine_relevant`, and keyword columns if they were not already present).
#' @export
#' @examples
#' \dontrun{
#' recs <- classify_assessments(index_cache(country = "nl"))
#' sel <- select_assessments(recs)
#' table(sel$selected)
#' }
select_assessments <- function(
  records,
  topics = biogain_assessment_topics(),
  relevance_threshold = 0.5,
  kw_min = 2L,
  nonrenewable = c("fossil_power", "oil_gas_extraction", "nuclear"),
  nonrenewable_score = 0.5
) {
  if (!is.data.frame(records)) {
    cli::cli_abort("{.arg records} must be a data frame.")
  }
  n <- nrow(records)

  # --- cosine signal: any BIOGAIN topic >= threshold ---
  slugs <- names(topics)
  cols <- paste0("relevance_score_", slugs)
  cols <- cols[cols %in% names(records)]
  if (length(cols) == 0L) {
    cosine_max <- rep(NA_real_, n)
  } else {
    mats <- lapply(cols, function(cn) {
      v <- as.numeric(records[[cn]])
      v[is.na(v)] <- -Inf
      v
    })
    cosine_max <- do.call(pmax, mats)
    cosine_max[!is.finite(cosine_max)] <- NA_real_
  }
  records$cosine_max <- cosine_max
  cosine_relevant <- !is.na(cosine_max) & cosine_max >= relevance_threshold
  records$cosine_relevant <- cosine_relevant

  # --- classifier signal ---
  class_relevant <- if ("class_relevant" %in% names(records)) {
    records$class_relevant %in% TRUE
  } else {
    rep(FALSE, n)
  }

  # --- keyword signal (compute if missing) ---
  if (!"kw_total" %in% names(records)) {
    records <- score_keywords(records)
  }
  kw_ok <- !is.na(records$kw_total) & records$kw_total >= kw_min

  # --- non-renewable trim (only when confidently classified) ---
  trim <- rep(FALSE, n)
  if (all(c("class_label", "class_score") %in% names(records))) {
    trim <- records$class_label %in%
      nonrenewable &
      !is.na(records$class_score) &
      as.numeric(records$class_score) >= nonrenewable_score
  }

  records$selected <- (cosine_relevant | class_relevant | kw_ok) & !trim
  records
}
