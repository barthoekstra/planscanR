# Funnel: turn a selected snapshot into a per-stage count table and a plot.
# Stages mirror the BIOGAIN pipeline gates in data-raw/biogain_acquire.R.

# Ordered stage definitions. Each predicate takes the selection-applied snapshot
# and returns a logical vector of records that reach that stage.
funnel_stages <- function(has_model = FALSE) {
  stages <- list(
    list(key = "indexed", label = "Indexed", fn = function(d) rep(TRUE, nrow(d))),
    list(key = "cosine", label = "Cosine-relevant", fn = function(d) d$cosine_relevant %in% TRUE),
    list(key = "classifier", label = "Classifier-relevant", fn = function(d) d$class_relevant %in% TRUE),
    list(key = "keyword", label = "Keyword-relevant", fn = function(d) !is.na(d$kw_total) & d$kw_total >= 1L),
    list(key = "selected", label = "Selected (ensemble)", fn = function(d) d$selected %in% TRUE),
    list(key = "attachments", label = "Has attachments", fn = function(d) d$has_attachments %in% TRUE),
    list(key = "downloaded", label = "Downloaded", fn = function(d) d$has_downloaded %in% TRUE)
  )
  if (has_model) {
    # Insert the model-selection stage right after the heuristic "selected" one.
    model_stage <- list(
      key = "selected_model",
      label = "Selected (model)",
      fn = function(d) d$selected_model %in% TRUE
    )
    sel_i <- which(vapply(stages, function(s) s$key == "selected", logical(1)))
    stages <- append(stages, list(model_stage), after = sel_i)
  }
  stages
}

# Compute the funnel table. `by_country = TRUE` returns one row per stage per
# country; otherwise an overall roll-up. pct is relative to the indexed total
# (of that country, or overall).
compute_funnel <- function(sel, by_country = FALSE, has_model = FALSE) {
  stages <- funnel_stages(has_model)
  one <- function(d) {
    total <- nrow(d)
    dplyr::bind_rows(lapply(seq_along(stages), function(i) {
      st <- stages[[i]]
      n <- sum(st$fn(d))
      tibble::tibble(
        order = i,
        stage = st$label,
        key = st$key,
        n = n,
        pct = if (total > 0) 100 * n / total else NA_real_
      )
    }))
  }
  if (!by_country || nrow(sel) == 0L) {
    out <- one(sel)
    out$country <- "all"
    return(out)
  }
  dplyr::bind_rows(lapply(split(sel, sel$country), function(d) {
    o <- one(d)
    o$country <- d$country[1]
    o
  }))
}

# Horizontal funnel bar chart as an interactive plotly object. Bars ordered top
# (indexed) to bottom (downloaded), labelled with count + percent of the indexed
# total, with hover tooltips. Responsive width; height left to the app.
funnel_plot <- function(funnel_df) {
  if (nrow(funnel_df) == 0L) {
    p <- plotly::plot_ly(type = "bar")
    p <- plotly::layout(
      p,
      xaxis = list(visible = FALSE),
      yaxis = list(visible = FALSE),
      annotations = list(
        text = "No data",
        showarrow = FALSE,
        xref = "paper",
        yref = "paper",
        x = 0.5,
        y = 0.5,
        font = list(size = 16, color = "#666666")
      )
    )
    return(plotly::config(p, displayModeBar = FALSE))
  }

  d <- funnel_df
  # Reverse stage order so "Indexed" sits at the top of the (horizontal) chart.
  d$stage <- factor(d$stage, levels = rev(unique(d$stage[order(d$order)])))
  count_lab <- format(d$n, big.mark = ",", trim = TRUE)
  d$lab <- sprintf("%s (%.1f%%)", count_lab, d$pct)
  d$hover <- sprintf("<b>%s</b><br>Count: %s<br>Percent: %.1f%%", d$stage, count_lab, d$pct)

  p <- plotly::plot_ly(
    d,
    x = ~n,
    y = ~stage,
    type = "bar",
    orientation = "h",
    marker = list(color = "#0e3c62"), # BIOGAIN brand navy
    text = ~lab,
    textposition = "outside",
    cliponaxis = FALSE,
    hovertext = ~hover,
    hoverinfo = "text"
  )
  p <- plotly::layout(
    p,
    xaxis = list(title = "records", zeroline = FALSE),
    yaxis = list(title = "", automargin = TRUE),
    margin = list(l = 10, r = 60, t = 10, b = 10),
    showlegend = FALSE,
    bargap = 0.3
  )
  plotly::config(p, displayModeBar = FALSE)
}

# Confusion of automated selection vs. human review (ground truth). Considers
# only records with an AGREED keep/drop decision: a multiply-reviewed record is
# used only when its reviewers unanimously agree (planscanR::consensus_reviews),
# so a disagreement is excluded rather than silently resolved by recency.
# Returns a one-row tibble of counts + precision/recall/F1 of `selected` against
# human "keep".
# Precision/recall/F1 + confusion for one merged frame (auto `selected` vs human
# `decision`). Factored out so the overall and per-country paths share it.
prf_one <- function(d) {
  human_keep <- d$decision == "keep"
  auto_keep <- d$selected %in% TRUE
  tp <- sum(auto_keep & human_keep)
  fp <- sum(auto_keep & !human_keep)
  fn <- sum(!auto_keep & human_keep)
  tn <- sum(!auto_keep & !human_keep)
  precision <- if ((tp + fp) > 0) tp / (tp + fp) else NA_real_
  recall <- if ((tp + fn) > 0) tp / (tp + fn) else NA_real_
  f1 <- if (!is.na(precision) && !is.na(recall) && (precision + recall) > 0) {
    2 * precision * recall / (precision + recall)
  } else {
    NA_real_
  }
  tibble::tibble(
    n_reviewed = nrow(d),
    tp = tp,
    fp = fp,
    fn = fn,
    tn = tn,
    precision = precision,
    recall = recall,
    f1 = f1
  )
}

selection_vs_human <- function(sel, reviews, by_country = FALSE) {
  decided <- planscanR::consensus_reviews(reviews)
  if (nrow(decided) == 0L) {
    return(NULL)
  }
  d <- merge(
    sel[, c("document_id", "country", "selected")],
    decided[, c("document_id", "country", "decision")],
    by = c("document_id", "country")
  )
  if (nrow(d) == 0L) {
    return(NULL)
  }
  if (!by_country) {
    return(prf_one(d))
  }
  rows <- lapply(split(d, d$country), function(dd) {
    m <- prf_one(dd)
    m$country <- dd$country[1]
    m
  })
  allm <- prf_one(d)
  allm$country <- "all"
  out <- dplyr::bind_rows(c(list(allm), rows))
  out[, c("country", setdiff(names(out), "country")), drop = FALSE]
}

# Cross-reviewer agreement over records that >=2 distinct reviewers have decided
# (decision in keep/drop/unsure). For each such record, "agree" means all those
# reviewers gave the identical decision. Returns a one-row tibble or NULL.
inter_reviewer_summary <- function(reviews) {
  if (is.null(reviews) || nrow(reviews) == 0L) {
    return(NULL)
  }
  decided <- reviews[reviews$decision %in% c("keep", "drop", "unsure"), , drop = FALSE]
  if (nrow(decided) == 0L) {
    return(NULL)
  }
  per_record <- dplyr::summarise(
    dplyr::group_by(decided, country, document_id),
    n_rev = dplyr::n_distinct(reviewer),
    n_dec = dplyr::n_distinct(decision),
    .groups = "drop"
  )
  multi <- per_record[per_record$n_rev >= 2L, , drop = FALSE]
  n_multi <- nrow(multi)
  if (n_multi == 0L) {
    return(NULL)
  }
  n_agree <- sum(multi$n_dec == 1L)
  tibble::tibble(
    n_multi = n_multi,
    n_agree = n_agree,
    agreement_rate = n_agree / n_multi
  )
}
