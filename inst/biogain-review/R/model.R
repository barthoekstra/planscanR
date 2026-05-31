# Learned selection model — app glue around the package's train/predict API.
#
# The app stays a CONSUMER of the package: training, CV, and prediction all live
# in planscanR (train_selection_model / predict_selection / selection_*). This
# file only (a) maps the UI dropdown to learner constructors, (b) persists the
# fitted model next to reviews.csv so it travels with a cache sync, and (c)
# offers a thin train wrapper for the Train button.

# Where the fitted model is cached (alongside reviews.csv / corpus_snapshot.rds,
# at the data-dir root — NOT under files/, so clear_cache() leaves it intact).
selection_model_path <- function(data_dir) {
  file.path(data_dir, "selection_model.rds")
}

# Human-readable label -> learner key, restricted to learners that can actually
# be trained (the tidymodels packages are installed).
selection_learner_choices <- function() {
  labels <- c("Logistic regression" = "logistic")
  avail <- names(planscanR::selection_learners(available_only = TRUE))
  labels[labels %in% avail]
}

# Construct a learner from its registry key.
make_selection_learner <- function(key) {
  reg <- planscanR::selection_learners()
  ctor <- reg[[key]]
  if (is.null(ctor)) {
    ctor <- reg[["logistic"]]
  }
  ctor()
}

# Load the persisted model (NULL if none trained yet). Tolerant of a stale /
# unreadable artifact (e.g. saved by an older package version).
load_app_model <- function(data_dir) {
  tryCatch(
    planscanR::load_selection_model(selection_model_path(data_dir)),
    error = function(e) NULL
  )
}

# Out-of-fold metrics at a threshold, guarded so a malformed model can't crash
# the dashboard render.
selection_cv_metrics_safe <- function(model, threshold = NULL, by_country = FALSE) {
  tryCatch(
    planscanR::selection_cv_metrics(model, threshold, by_country = by_country),
    error = function(e) NULL
  )
}

# Combined per-country performance table. `heur` and `mdl` are by-country
# metric tibbles (country, n_reviewed, precision, recall, f1, ...) from
# selection_vs_human(by_country=TRUE) and selection_cv_metrics(by_country=TRUE);
# `mdl` may be NULL (no model trained). Returns a compact reactable.
performance_by_country_table <- function(heur, mdl = NULL) {
  if (is.null(heur) || nrow(heur) == 0L) {
    return(NULL)
  }
  fmt <- function(p, r, f) {
    ifelse(is.na(f), "—", sprintf("%.2f / %.2f / %.2f", p, r, f))
  }
  df <- data.frame(
    country = heur$country,
    n = heur$n_reviewed,
    heuristic = fmt(heur$precision, heur$recall, heur$f1),
    stringsAsFactors = FALSE
  )
  if (!is.null(mdl) && nrow(mdl) > 0L) {
    i <- match(df$country, mdl$country)
    df$model <- fmt(mdl$precision[i], mdl$recall[i], mdl$f1[i])
  } else {
    df$model <- "—"
  }
  # "all" first, then countries alphabetically.
  df <- df[order(df$country != "all", df$country), , drop = FALSE]
  df$country <- ifelse(df$country == "all", "All", toupper(df$country))

  reactable::reactable(
    df,
    columns = list(
      country = reactable::colDef(name = "Country", width = 90),
      n = reactable::colDef(name = "Labels", width = 90, align = "right"),
      heuristic = reactable::colDef(name = "Heuristic  P / R / F1"),
      model = reactable::colDef(name = "Model  P / R / F1")
    ),
    defaultColDef = reactable::colDef(headerStyle = list(whiteSpace = "normal")),
    highlight = TRUE,
    compact = TRUE,
    sortable = FALSE,
    pagination = FALSE
  )
}

# Train on the snapshot + reviews and persist. Returns the fitted model.
# `eval_source = "random"` keeps the CV metrics on the unbiased sample.
train_app_model <- function(snap, reviews, learner_key, data_dir, eval_source = "random") {
  learner <- make_selection_learner(learner_key)
  model <- planscanR::train_selection_model(
    snap,
    reviews,
    topics = planscanR::biogain_assessment_topics(),
    labels = planscanR::biogain_classification_labels(),
    learner = learner,
    eval_source = eval_source
  )
  planscanR::save_selection_model(model, selection_model_path(data_dir))
  model
}

# Compute a held-out learning curve (F1 vs. number of labels) on the unbiased
# random sample with the chosen learner. Returns the long per-(size, repeat)
# tibble from the package; callers summarise it with learning_curve_summary().
# `by_country = TRUE` adds a `country` column and one row per country slice of
# the held-out test (plus an "all" overall row) at every (size, repeat).
compute_learning_curve <- function(
  snap,
  reviews,
  learner_key,
  eval_source = "random",
  by_country = FALSE
) {
  learner <- make_selection_learner(learner_key)
  planscanR::selection_learning_curve(
    snap,
    reviews,
    topics = planscanR::biogain_assessment_topics(),
    labels = planscanR::biogain_classification_labels(),
    learner = learner,
    eval_source = eval_source,
    by_country = by_country
  )
}

# Learning-curve plot: mean held-out F1 vs. number of training labels with a
# +/-sd ribbon over the repeats. `summary_df` is a learning_curve_summary()
# tibble (size, n_train_used, n, f1_mean, f1_sd, ...). When the summary carries
# a `country` column (per-country slicing of the held-out test), the "all" row
# is drawn as the thick navy line with the ±sd ribbon and each country is added
# as a thinner colored line (no ribbon — would clutter). Empty -> placeholder.
learning_curve_plot <- function(summary_df) {
  if (is.null(summary_df) || nrow(summary_df) == 0L) {
    p <- plotly::plot_ly(type = "scatter", mode = "lines")
    p <- plotly::layout(
      p,
      paper_bgcolor = "rgba(0,0,0,0)",
      plot_bgcolor = "rgba(0,0,0,0)",
      xaxis = list(visible = FALSE),
      yaxis = list(visible = FALSE),
      annotations = list(
        text = "Click<br>\"Compute learning<br>curve\"",
        showarrow = FALSE,
        xref = "paper",
        yref = "paper",
        x = 0.5,
        y = 0.5,
        font = list(size = 13, color = "#666666")
      )
    )
    return(plotly::config(p, displayModeBar = FALSE))
  }

  navy <- "#0e3c62"
  has_country <- "country" %in% names(summary_df)

  order_df <- function(d) d[order(d$n_train_used), , drop = FALSE]
  hover_for <- function(d, label = NULL) {
    sprintf(
      "%sLabels: %d<br>F1: %.3f ± %.3f<br>repeats: %d",
      if (is.null(label)) "" else paste0(label, "<br>"),
      d$n_train_used,
      d$f1_mean,
      ifelse(is.na(d$f1_sd), 0, d$f1_sd),
      d$n
    )
  }

  p <- plotly::plot_ly()

  d_all <- if (has_country) {
    summary_df[summary_df$country == "all", , drop = FALSE]
  } else {
    summary_df
  }
  d_all <- order_df(d_all)

  if (nrow(d_all) > 0L) {
    sd_lo <- pmax(0, d_all$f1_mean - ifelse(is.na(d_all$f1_sd), 0, d_all$f1_sd))
    sd_hi <- pmin(1, d_all$f1_mean + ifelse(is.na(d_all$f1_sd), 0, d_all$f1_sd))
    p <- plotly::add_trace(
      p,
      x = d_all$n_train_used,
      y = sd_hi,
      type = "scatter",
      mode = "lines",
      line = list(width = 0),
      showlegend = FALSE,
      hoverinfo = "skip"
    )
    p <- plotly::add_trace(
      p,
      x = d_all$n_train_used,
      y = sd_lo,
      type = "scatter",
      mode = "lines",
      line = list(width = 0),
      fill = "tonexty",
      fillcolor = "rgba(14, 60, 98, 0.18)",
      showlegend = FALSE,
      hoverinfo = "skip"
    )
    p <- plotly::add_trace(
      p,
      x = d_all$n_train_used,
      y = d_all$f1_mean,
      type = "scatter",
      mode = "lines+markers",
      line = list(color = navy, width = 2.5),
      marker = list(color = navy, size = 7),
      name = "All",
      hovertext = hover_for(d_all, "All"),
      hoverinfo = "text",
      showlegend = has_country
    )
  }

  if (has_country) {
    countries <- sort(setdiff(unique(summary_df$country), "all"))
    # Qualitative palette (Plotly's "Set2"/"D3" feel); recycled if >8 countries.
    palette <- c(
      "#e15759", "#59a14f", "#f28e2b", "#b07aa1",
      "#76b7b2", "#edc948", "#ff9da7", "#9c755f"
    )
    for (i in seq_along(countries)) {
      cc <- countries[i]
      d <- order_df(summary_df[summary_df$country == cc, , drop = FALSE])
      if (nrow(d) == 0L) next
      col <- palette[((i - 1L) %% length(palette)) + 1L]
      p <- plotly::add_trace(
        p,
        x = d$n_train_used,
        y = d$f1_mean,
        type = "scatter",
        mode = "lines+markers",
        line = list(color = col, width = 1.4, dash = "dot"),
        marker = list(color = col, size = 5),
        name = toupper(cc),
        hovertext = hover_for(d, toupper(cc)),
        hoverinfo = "text",
        showlegend = TRUE
      )
    }
  }

  p <- plotly::layout(
    p,
    paper_bgcolor = "rgba(0,0,0,0)",
    plot_bgcolor = "rgba(0,0,0,0)",
    xaxis = list(title = "Number of training labels", zeroline = FALSE),
    yaxis = list(title = "F1 (held-out)", range = c(0, 1), zeroline = FALSE),
    legend = list(
      orientation = "h",
      x = 0,
      xanchor = "left",
      y = 1.02,
      yanchor = "bottom",
      font = list(size = 10)
    ),
    margin = list(l = 50, r = 20, t = if (has_country) 40 else 10, b = 40)
  )
  plotly::config(p, displayModeBar = FALSE)
}
