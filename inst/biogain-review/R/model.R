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

# Human-readable label -> learner key, filtered to learners whose engine package
# is installed (logistic is always available; glmnet/xgboost/ranger optional).
selection_learner_choices <- function() {
  labels <- c(
    "Logistic regression" = "logistic",
    "Penalised logistic (glmnet)" = "glmnet",
    "Gradient boosting (xgboost)" = "xgboost",
    "Random forest (ranger)" = "ranger"
  )
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
    learner = learner,
    eval_source = eval_source
  )
  planscanR::save_selection_model(model, selection_model_path(data_dir))
  model
}

# Compute a held-out learning curve (F1 vs. number of labels) on the unbiased
# random sample with the chosen learner. Returns the long per-(size, repeat)
# tibble from the package; callers summarise it with learning_curve_summary().
compute_learning_curve <- function(snap, reviews, learner_key, eval_source = "random") {
  learner <- make_selection_learner(learner_key)
  planscanR::selection_learning_curve(
    snap,
    reviews,
    learner = learner,
    eval_source = eval_source
  )
}

# Learning-curve plot: mean held-out F1 vs. number of training labels with a
# +/-sd ribbon over the repeats. `summary_df` is a learning_curve_summary()
# tibble (size, n_train_used, n, f1_mean, f1_sd, ...). Empty -> placeholder.
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

  d <- summary_df[order(summary_df$n_train_used), , drop = FALSE]
  navy <- "#0e3c62"
  sd_lo <- pmax(0, d$f1_mean - ifelse(is.na(d$f1_sd), 0, d$f1_sd))
  sd_hi <- pmin(1, d$f1_mean + ifelse(is.na(d$f1_sd), 0, d$f1_sd))
  hover <- sprintf(
    "Labels: %d<br>F1: %.3f ± %.3f<br>repeats: %d",
    d$n_train_used,
    d$f1_mean,
    ifelse(is.na(d$f1_sd), 0, d$f1_sd),
    d$n
  )

  p <- plotly::plot_ly()
  # +/-sd ribbon: upper bound then lower bound with fill = "tonexty".
  p <- plotly::add_trace(
    p,
    x = d$n_train_used,
    y = sd_hi,
    type = "scatter",
    mode = "lines",
    line = list(width = 0),
    showlegend = FALSE,
    hoverinfo = "skip"
  )
  p <- plotly::add_trace(
    p,
    x = d$n_train_used,
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
    x = d$n_train_used,
    y = d$f1_mean,
    type = "scatter",
    mode = "lines+markers",
    line = list(color = navy, width = 2),
    marker = list(color = navy, size = 7),
    hovertext = hover,
    hoverinfo = "text",
    showlegend = FALSE
  )
  p <- plotly::layout(
    p,
    paper_bgcolor = "rgba(0,0,0,0)",
    plot_bgcolor = "rgba(0,0,0,0)",
    xaxis = list(title = "Number of training labels", zeroline = FALSE),
    yaxis = list(title = "F1 (held-out)", range = c(0, 1), zeroline = FALSE),
    margin = list(l = 50, r = 20, t = 10, b = 40)
  )
  plotly::config(p, displayModeBar = FALSE)
}
