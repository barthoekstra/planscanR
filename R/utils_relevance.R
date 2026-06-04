# -----------------------------------------------------------------------------
# Fetch-time relevance scoring, used by every country handler.
#
# planscanR is the leaf of the family and carries no Python toolchain. The
# actual embedding work is delegated to planscanR.screen (a soft dependency:
# Suggests, called via planscanR.screen::). When a caller passes `topic` to
# get_assessments() but planscanR.screen is not installed, setup_relevance()
# aborts with a clear install hint.
#
# The pure pieces — topic-slug normalisation, cosine, and the download gate —
# live here so the per-record fetch loop scores without re-embedding the topics
# for every record (setup_relevance() embeds the topics once; apply_relevance()
# cosines each record against them). planscanR.screen carries its own copies of
# normalise_topics()/cosine for its batch score_records() path; the slug
# convention is shared because both write the planscanR-owned sidecar schema.
# -----------------------------------------------------------------------------

#' Abort unless planscanR.screen (the scoring engine) is installed.
#' @noRd
require_screen <- function() {
  if (!requireNamespace("planscanR.screen", quietly = TRUE)) {
    cli::cli_abort(
      c(
        "Relevance scoring needs the {.pkg planscanR.screen} package.",
        i = "Install it, or omit {.arg topic} to fetch without scoring."
      ),
      class = "planscanR_error_screen_missing"
    )
  }
}

#' Normalise the `topic` argument into a named character vector.
#'
#' Accepts `NULL`, a single string (auto-slugged name), a named vector
#' (names are the slugs), or an unnamed vector (names auto-slugged from values).
#' @noRd
normalise_topics <- function(topic) {
  if (is.null(topic)) {
    return(NULL)
  }
  if (!is.character(topic) || length(topic) == 0L || any(!nzchar(topic))) {
    cli::cli_abort(
      "{.arg topic} must be a non-empty character vector (optionally named).",
      class = "planscanR_error_bad_input"
    )
  }
  nms <- names(topic)
  if (is.null(nms) || any(!nzchar(nms))) {
    auto <- vapply(topic, slugify_topic, character(1))
    if (is.null(nms)) {
      nms <- auto
    } else {
      nms[!nzchar(nms)] <- auto[!nzchar(nms)]
    }
  }
  if (anyDuplicated(nms) > 0L) {
    cli::cli_abort(
      "{.arg topic} slugs must be unique; got duplicates {.val {nms[duplicated(nms)]}}.",
      class = "planscanR_error_bad_input"
    )
  }
  names(topic) <- nms
  topic
}

#' Slugify a topic phrase into a column-safe suffix.
#' @noRd
slugify_topic <- function(s) {
  ascii_slug(s, "topic")
}

#' Cosine similarity between every row of `m` and every row of `topics`.
#' Returns an `[nrow(m), nrow(topics)]` numeric matrix.
#' @noRd
cosine_similarity_matrix <- function(m, topics) {
  if (!is.matrix(m) || !is.matrix(topics)) {
    cli::cli_abort("cosine_similarity_matrix expects matrix inputs.")
  }
  m_norm <- sqrt(rowSums(m * m))
  t_norm <- sqrt(rowSums(topics * topics))
  num <- m %*% t(topics)
  denom <- outer(m_norm, t_norm)
  out <- num / denom
  out[m_norm == 0, ] <- NA_real_
  out[, t_norm == 0] <- NA_real_
  out
}

#' Set up the relevance-scoring context (or `NULL` when no `topic` was given).
#'
#' Validates the model, embeds each topic phrase once (via planscanR.screen),
#' and returns everything `apply_relevance()` needs. `country` is accepted for
#' call-site symmetry across handlers; the model's language-coverage warning is
#' emitted by planscanR.screen on its own scoring paths.
#' @noRd
setup_relevance <- function(topic, model, country) {
  if (is.null(topic)) {
    return(NULL)
  }
  require_screen()
  topics <- normalise_topics(topic)
  if (is.null(model)) {
    model <- planscanR.screen::embedding_model_minilm()
  }
  if (!inherits(model, "planscanR_embedding_model")) {
    cli::cli_abort(
      "{.arg relevance_model} must be a planscanR_embedding_model object."
    )
  }
  list(
    model = model,
    topics = topics,
    topic_vecs = planscanR.screen::embed_text(model, unname(topics))
  )
}

#' Attach relevance score(s) to a single record.
#'
#' Embeds the record's title + summary ONCE (via planscanR.screen), then
#' computes cosine similarity against every topic in `rel$topic_vecs`. Adds one
#' `relevance_score_<slug>` column per topic plus a shared `relevance_model`
#' column.
#' @noRd
apply_relevance <- function(rec, rel) {
  text <- paste(rec$title %||% "", rec$summary %||% "", sep = "\n")
  doc_vec <- planscanR.screen::embed_text(rel$model, text)
  scores <- as.numeric(cosine_similarity_matrix(doc_vec, rel$topic_vecs))
  for (i in seq_along(rel$topics)) {
    rec[[paste0("relevance_score_", names(rel$topics)[i])]] <- scores[i]
  }
  rec$relevance_model <- planscanR.screen::model_name(rel$model)
  rec
}

#' Decide whether a record's PDFs should be downloaded under the threshold.
#'
#' The threshold only affects downloading: a record below it still gets a
#' sidecar written and still appears in the returned tibble — only its PDFs
#' stay off disk.
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
