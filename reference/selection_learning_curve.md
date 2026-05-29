# Learning curve for the learned selection model.

Estimates how the model's held-out F1 / precision / recall improve as
the number of human keep/drop labels grows. For each repeat it makes one
stratified train/test split (the test set is FIXED across all training
sizes within that repeat, so the metric is comparable as the training
pool grows), then fits the learner on increasing stratified subsamples
of the training pool and scores the held-out test set. Repeating the
whole thing `repeats` times and averaging (see
[`learning_curve_summary()`](https://barthoekstra.github.io/planscanR/reference/learning_curve_summary.md))
smooths out the split noise and shows where the curve flattens.

## Usage

``` r
selection_learning_curve(
  records,
  reviews,
  learner = selection_learner_logistic(),
  sizes = NULL,
  test_frac = 0.25,
  repeats = 10,
  eval_source = "random",
  threshold = 0.5,
  seed = NULL
)
```

## Arguments

- records:

  A scored + classified tibble (from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md),
  or the review-app snapshot) carrying the
  [`selection_features()`](https://barthoekstra.github.io/planscanR/reference/selection_features.md)
  columns.

- reviews:

  The review-decision tibble (the app's `reviews.csv`), with
  `document_id`, `country`, `decision`, `source`, `reviewed_at`.

- learner:

  A
  [selection_learner](https://barthoekstra.github.io/planscanR/reference/selection_learner.md).
  Defaults to
  [`selection_learner_logistic()`](https://barthoekstra.github.io/planscanR/reference/selection_learners_builtin.md).

- sizes:

  Optional integer vector of training-label counts to evaluate. `NULL`
  builds a grid of ~10-12 increasing sizes from 30 up to the maximum
  train-pool size (always including that maximum). Supplied sizes larger
  than the train pool are dropped, but the pool maximum is always kept.

- test_frac:

  Fraction of the labelled data held out as the fixed test set (per
  repeat).

- repeats:

  Number of repeated held-out resamples.

- eval_source:

  Restrict labels to this review `source` (default `"random"` — the
  unbiased sample). `NULL` uses every keep/drop label.

- threshold:

  Probability cutoff for the keep decision when scoring.

- seed:

  Optional RNG seed for reproducible splits.

## Value

A long tibble with one row per (size, repeat), columns in order: `size`,
`n_train_used`, `rep`, `n_test`, `precision`, `recall`, `f1`.

## See also

[`learning_curve_summary()`](https://barthoekstra.github.io/planscanR/reference/learning_curve_summary.md)
to aggregate the curve.

## Examples

``` r
if (FALSE) { # \dontrun{
recs <- index_cache(country = "nl")
rev <- read.csv(file.path(cache_dir, "reviews.csv"), colClasses = "character")
curve <- selection_learning_curve(recs, rev, repeats = 10)
learning_curve_summary(curve)
} # }
```
