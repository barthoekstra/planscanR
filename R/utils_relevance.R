# -----------------------------------------------------------------------------
# Shared relevance-scoring helpers used by every country handler.
#
# The NL/DE/AT handlers all score records the same way; only the country code
# differs. These helpers hold that shared logic so the handlers stay thin.
# -----------------------------------------------------------------------------

#' Set up the relevance-scoring context (or `NULL` when no `topic` was given).
#'
#' Validates the model, embeds each topic phrase once, and returns everything
#' `apply_relevance()` needs. Warns once per (model, country) if the model
#' doesn't cover the country's language.
#' @noRd
setup_relevance <- function(topic, model, country) {
  if (is.null(topic)) {
    return(NULL)
  }
  topics <- normalise_topics(topic)
  if (is.null(model)) {
    model <- embedding_model_minilm()
  }
  if (!inherits(model, "planscanR_embedding_model")) {
    cli::cli_abort(
      "{.arg relevance_model} must be a planscanR_embedding_model object."
    )
  }
  warn_country_language(country, model)
  list(
    model = model,
    topics = topics,
    topic_vecs = embed_text(model, unname(topics))
  )
}

#' Attach relevance score(s) to a single record.
#'
#' Embeds the record's title + summary ONCE, then computes cosine similarity
#' against every topic in `rel$topic_vecs`. Adds one `relevance_score_<slug>`
#' column per topic plus a shared `relevance_model` column.
#' @noRd
apply_relevance <- function(rec, rel) {
  text <- paste(rec$title %||% "", rec$summary %||% "", sep = "\n")
  doc_vec <- embed_text(rel$model, text)
  scores <- as.numeric(cosine_similarity_matrix(doc_vec, rel$topic_vecs))
  for (i in seq_along(rel$topics)) {
    rec[[paste0("relevance_score_", names(rel$topics)[i])]] <- scores[i]
  }
  rec$relevance_model <- model_name(rel$model)
  rec
}

#' Decide whether a record's PDFs should be downloaded under the threshold.
#'
#' The threshold only affects downloading: a record below it still gets a
#' sidecar written and still appears in the returned tibble — only its PDFs
#' stay off disk. This lets a researcher re-run with a different threshold (or
#' no threshold at all) without re-hitting the portal.
#'
#' * `threshold = NULL` → always passes (download everything that scored).
#' * No `rel` (no `topic` set) → always passes (nothing to filter on).
#' * Scalar threshold → pass if **any** topic score is `>= threshold`.
#' * Named vector threshold → pass if any named topic clears its own cutoff.
#' @noRd
passes_download_gate <- function(rec, rel, threshold) {
  if (is.null(threshold) || is.null(rel)) {
    return(TRUE)
  }
  if (is.null(names(threshold))) {
    scores <- vapply(
      names(rel$topics),
      function(nm) rec[[paste0("relevance_score_", nm)]],
      numeric(1)
    )
    return(any(!is.na(scores) & scores >= threshold[[1]]))
  }
  ok <- vapply(
    names(threshold),
    function(nm) {
      col <- paste0("relevance_score_", nm)
      if (is.null(rec[[col]])) {
        return(FALSE)
      }
      s <- rec[[col]]
      !is.na(s) && s >= threshold[[nm]]
    },
    logical(1)
  )
  any(ok)
}
