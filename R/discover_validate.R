# Validator for candidate PDFs discovered by web search.
#
# Given a candidate (record, URL) pair, the validator decides whether the PDF
# at the URL really belongs to that record. It downloads the PDF to a
# scratch path, extracts the first 10 pages of text via `pdftotext`, and
# checks a small stack of signals in order from strongest to weakest. The
# scratch download is reused as the eventual cache path on success; on
# failure it's left behind for inspection but not promoted to the sidecar.

#' Validate a candidate (record, URL) pair against a downloaded PDF.
#'
#' Runs four signals in order:
#'
#' 1. **Aktenzahl exact** — the country's primary identifier appears verbatim
#'    in the PDF text. Strongest signal.
#' 2. **Title overlap (hybrid count/density)** — all distinguishing title
#'    tokens (title tokens minus the country's stoplist) appear at least
#'    once in the PDF text, AND the project is mentioned substantively:
#'    either >= 5 total distinguishing-token occurrences, or (>= 2 total
#'    AND >= 0.4 occurrences per scanned page). The dual rule keeps short
#'    focused documents (1-page Kundmachungen with 3 mentions) while
#'    rejecting long documents that mention the project only in passing
#'    (97-page UVEs with 2 mentions buried in a comparative section).
#'    Also requires at least one generic title token in the text so that
#'    a PDF mentioning only a place name without any UVP language doesn't
#'    pass.
#' 3. **Extra-signal presence** — at least one of the country config's
#'    `extra_signals` (e.g. `"UVP-G 2000"`) is in the PDF, AND the hybrid
#'    count/density rule above holds.
#' 4. **Semantic backup** — cosine similarity between first-10-pages text
#'    and the record's title+summary clears `semantic_threshold` (default
#'    0.5), using the relevance model. Only fires if none of the above did.
#'
#' Any single signal passing is sufficient. The result reports which signal(s)
#' fired so calling code can apply stricter precision policies if it wants.
#'
#' @param record A 1-row tibble in the planscanR result shape.
#' @param pdf_path Path to a local copy of the candidate PDF.
#' @param cfg Country discovery config (e.g. [at_discovery_config()]).
#' @param relevance_model Optional embedding model for the semantic signal.
#'   When `NULL`, the semantic signal is skipped (which means signals 1-3
#'   must carry the validation).
#' @param semantic_threshold Cosine-similarity threshold for signal 4.
#' @return A list with: `passed` (logical), `signals` (named logical),
#'   `notes` (character), `text` (the extracted first-10-pages text, used
#'   downstream when the candidate is promoted to the sidecar).
#' @export
discover_validate <- function(
  record,
  pdf_path,
  cfg,
  relevance_model = NULL,
  semantic_threshold = 0.5
) {
  stopifnot(is.data.frame(record), nrow(record) == 1L)
  if (!file.exists(pdf_path) || file.info(pdf_path)$size == 0L) {
    return(list(
      passed = FALSE,
      signals = c(az = FALSE, title = FALSE, extra = FALSE, semantic = FALSE),
      notes = "pdf missing or empty",
      text = ""
    ))
  }

  text <- tryCatch(pdf_first_pages_text(pdf_path, 10L), error = function(e) "")
  if (!nzchar(text)) {
    return(list(
      passed = FALSE,
      signals = c(az = FALSE, title = FALSE, extra = FALSE, semantic = FALSE),
      notes = "pdftotext returned empty",
      text = ""
    ))
  }

  # Number of pages actually represented in the extracted text. Needed by
  # the density branch of the hybrid count/density rule. Falls back to 10
  # when pdfinfo isn't available — that's the cap pdftotext is called with,
  # so the worst case is treating a short document as if it were the full
  # 10-page window, which just makes the density harder to clear.
  pages_total <- pdf_page_count(pdf_path)
  pages_scanned <- if (is.null(pages_total) || pages_total <= 0L) {
    10L
  } else {
    as.integer(min(10L, pages_total))
  }

  norm_text <- normalise_text_for_match(text)
  norm_title <- normalise_text_for_match(record$title %||% "")

  signal_az <- FALSE
  if (!is.null(cfg$aktenzahl_regex) && nzchar(cfg$aktenzahl_regex)) {
    az <- (record$aktenzahl %||% NA_character_)
    if (!is.na(az) && nzchar(az)) {
      # Build a tolerant pattern: AT's "02 0515" matches "02 0515", "02-0515", "020515".
      az_compact <- gsub("\\s+", "", az)
      az_dash <- sub("(\\d{2})(\\d{4})", "\\1-\\2", az_compact)
      az_space <- sub("(\\d{2})(\\d{4})", "\\1 \\2", az_compact)
      candidates <- unique(c(az, az_compact, az_dash, az_space))
      pattern <- paste0("(", paste(vapply(candidates, function(x) gsub("([.|()\\^{}+?*\\\\])", "\\\\\\1", x), character(1)), collapse = "|"), ")")
      signal_az <- grepl(pattern, text, perl = TRUE)
    }
  }

  title_tokens <- tokenise_for_match(norm_title)
  stoplist <- cfg$title_stoplist %||% character(0)
  distinguishing_tokens <- setdiff(title_tokens, stoplist)
  generic_title_tokens <- intersect(title_tokens, stoplist)

  # Count *occurrences* of each distinguishing token, not just presence.
  # A PDF that mentions "Glinzendorf" once in a 200-page gazette is much
  # weaker evidence than one that mentions it ten times. Requiring >= 2
  # total occurrences across all distinguishing tokens filters out the
  # 1-mention false positives while still passing real project documents
  # (UVE summaries, Bescheide) which mention the project name many times.
  count_occurrences <- function(tok) {
    if (!nzchar(tok)) {
      return(0L)
    }
    m <- gregexpr(tok, norm_text, fixed = TRUE)[[1]]
    if (length(m) == 1L && m[1] == -1L) 0L else length(m)
  }
  dist_counts <- vapply(distinguishing_tokens, count_occurrences, integer(1))
  gen_counts <- vapply(generic_title_tokens, count_occurrences, integer(1))
  dist_present <- dist_counts > 0L
  gen_present <- gen_counts > 0L
  total_dist_hits <- as.integer(sum(dist_counts))
  total_gen_hits <- as.integer(sum(gen_counts))
  n_title_hits <- total_dist_hits + total_gen_hits

  # Hybrid count/density gate. Accepts a candidate as substantively about
  # the project if either:
  #   (a) the absolute number of distinguishing-token occurrences is >= 5
  #       (a long focused document — UVE Zusammenfassung, Antrag, etc.); or
  #   (b) the per-page density is >= 0.4 hits/page AND at least 2 total
  #       occurrences (a short focused document — 1-page Kundmachung with
  #       3 mentions, density 3.0, passes; a 1-page gazette with 1 mention,
  #       density 1.0 but only 1 hit, fails).
  # The two together filter both failure modes seen on the AT smoke test:
  # 97-page off-project UVEs (Dürnkrut IV with 2 spannberg mentions) and
  # multi-page gazettes that touch the project briefly.
  density <- if (pages_scanned > 0L) total_dist_hits / pages_scanned else 0
  hybrid_pass <- total_dist_hits >= 5L ||
    (total_dist_hits >= 2L && density >= 0.4)

  # Signal 2: ALL distinguishing tokens must appear (so "Schrick II" doesn't
  # match "Spannberg II" on the strength of "windpark" alone), AND the
  # hybrid count/density gate holds, AND at least one generic title token
  # must also appear (so a PDF only mentioning "Spannberg" the village
  # without any wind/UVP language doesn't pass).
  signal_title <- length(distinguishing_tokens) > 0L &&
    all(dist_present) &&
    hybrid_pass &&
    (length(generic_title_tokens) == 0L || any(gen_present))

  signal_extra <- FALSE
  if (length(cfg$extra_signals) > 0L) {
    extras_hit <- vapply(
      cfg$extra_signals,
      function(p) grepl(normalise_text_for_match(p), norm_text, fixed = TRUE),
      logical(1)
    )
    # Signal 3: a UVP-flavoured PDF that *substantively* mentions the project.
    # Same hybrid gate as signal_title.
    signal_extra <- any(extras_hit) && hybrid_pass
  }

  signal_semantic <- FALSE
  semantic_score <- NA_real_
  if (!signal_az && !signal_title && !signal_extra && !is.null(relevance_model)) {
    doc_vec <- tryCatch(embed_text(relevance_model, substr(text, 1L, 8000L)), error = function(e) NULL)
    ref <- paste(record$title %||% "", record$summary %||% "", sep = "\n")
    ref_vec <- tryCatch(embed_text(relevance_model, ref), error = function(e) NULL)
    if (!is.null(doc_vec) && !is.null(ref_vec)) {
      sim <- as.numeric(cosine_similarity_matrix(doc_vec, ref_vec))
      semantic_score <- sim[1]
      signal_semantic <- !is.na(semantic_score) && semantic_score >= semantic_threshold
    }
  }

  signals <- c(
    az = signal_az,
    title = signal_title,
    extra = signal_extra,
    semantic = signal_semantic
  )
  passed <- any(signals)
  notes <- paste0(
    "n_title_hits=", n_title_hits,
    if (!is.na(semantic_score)) sprintf(" sem=%.3f", semantic_score) else ""
  )

  list(
    passed = passed,
    signals = signals,
    notes = notes,
    text = text
  )
}

#' Total page count of a PDF via poppler's `pdfinfo`.
#'
#' Returns `NULL` if `pdfinfo` isn't on PATH or fails to parse the PDF.
#' Callers use this to pick the denominator for the validator's density
#' rule; a `NULL` return is handled by falling back to the 10-page cap.
#' @noRd
pdf_page_count <- function(pdf_path) {
  bin <- Sys.which("pdfinfo")
  if (!nzchar(bin)) {
    return(NULL)
  }
  out <- tryCatch(
    suppressWarnings(system2(bin, args = pdf_path, stdout = TRUE, stderr = FALSE)),
    error = function(e) character(0)
  )
  if (length(out) == 0L) {
    return(NULL)
  }
  m <- regmatches(out, regexpr("^Pages:\\s*([0-9]+)", out, perl = TRUE))
  m <- m[nzchar(m)]
  if (length(m) == 0L) {
    return(NULL)
  }
  n <- suppressWarnings(as.integer(sub("^Pages:\\s*", "", m[1])))
  if (is.na(n) || n < 0L) NULL else n
}

#' Extract first-N-page text from a PDF using poppler's `pdftotext`.
#'
#' The package depends on poppler being installed on the system. If
#' `pdftotext` isn't available, an error is raised; callers should treat
#' that as a fatal-but-reportable configuration issue.
#' @noRd
pdf_first_pages_text <- function(pdf_path, n_pages = 10L) {
  bin <- Sys.which("pdftotext")
  if (!nzchar(bin)) {
    cli::cli_abort(
      c(
        "{.code pdftotext} not found on PATH.",
        i = "Install poppler (e.g. `brew install poppler` on macOS, `apt install poppler-utils` on Debian/Ubuntu)."
      ),
      class = "planscanR_error_missing_tool"
    )
  }
  out <- tempfile(fileext = ".txt")
  on.exit(unlink(out), add = TRUE)
  status <- suppressWarnings(system2(
    bin,
    args = c("-f", "1", "-l", as.character(n_pages), "-enc", "UTF-8", pdf_path, out),
    stdout = FALSE,
    stderr = FALSE
  ))
  if (status != 0L || !file.exists(out)) {
    return("")
  }
  paste(readLines(out, warn = FALSE, encoding = "UTF-8"), collapse = "\n")
}

#' Normalise text for fuzzy matching: NFD strip + German vowel-digraph
#' collapse + lowercase + non-alphanumeric to space.
#'
#' This is the same normalisation used in the /tmp/austria-match prototype
#' so the validator behaves the same as the bulk matcher we used to score
#' the local document collection.
#' @noRd
normalise_text_for_match <- function(s) {
  if (is.null(s) || is.na(s) || !nzchar(s)) {
    return("")
  }
  # NFD + remove combining marks
  s <- gsub(
    "[̀-ͯ]",
    "",
    iconv(s, from = "UTF-8", to = "UTF-8")
  )
  # Manual umlaut + sharp-s expansion *before* casefold so we don't lose
  # information that iconv-stripping would have folded away.
  s <- chartr(
    "ÄÖÜäöüß",
    "AOUaous",
    s
  )
  s <- tolower(s)
  # Collapse vowel digraphs that German writers swap with diacritics.
  s <- gsub("oe", "o", s, fixed = TRUE)
  s <- gsub("ae", "a", s, fixed = TRUE)
  s <- gsub("ue", "u", s, fixed = TRUE)
  s <- gsub("ss", "s", s, fixed = TRUE)
  # Non-alphanumeric to space, collapse whitespace.
  s <- gsub("[^a-z0-9]+", " ", s, perl = TRUE)
  trimws(gsub("\\s+", " ", s))
}

#' Tokens (>= 5 chars) suitable for title-overlap matching.
#' @noRd
tokenise_for_match <- function(norm_text) {
  toks <- strsplit(norm_text, "\\s+")[[1]]
  toks <- toks[nzchar(toks) & nchar(toks) >= 5L]
  unique(toks)
}
