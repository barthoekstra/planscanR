# Classify assessment records with a zero-shot model.

Offline pass (no portal calls): for each record, classifies title +
summary + category against `labels` and adds the verdict as new columns.
Pairs with
[`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
and
[`score_assessments()`](https://barthoekstra.github.io/planscanR/reference/score_assessments.md)
— same harvest-broad-classify-later workflow.

## Usage

``` r
classify_assessments(
  records,
  classifier = NULL,
  labels = biogain_classification_labels(),
  multi_label = FALSE,
  batch_size = 64L,
  write_sidecar = FALSE
)
```

## Arguments

- records:

  A tibble (from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  /
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md));
  must have at least `title` (and ideally `summary`, `native_type`).

- classifier:

  A `planscanR_classifier`. Defaults to
  [`classify_model_zeroshot()`](https://barthoekstra.github.io/planscanR/reference/classify_model_zeroshot.md).

- labels:

  Named character vector of candidate labels (see
  [`biogain_classification_labels()`](https://barthoekstra.github.io/planscanR/reference/biogain_classification_labels.md),
  the default). A `relevant` attribute marks which slugs are
  BIOGAIN-relevant; if absent, every label is treated as relevant.

- multi_label:

  If `FALSE` (default) labels are mutually exclusive (softmax); the
  negative classes then compete with the positive ones, which is the
  point. `TRUE` scores each label independently.

- batch_size:

  Number of records handed to the classifier per call — controls
  progress granularity and R-Python round trips. This is distinct from
  the model's GPU `batch_size` (set on
  [`classify_model_zeroshot()`](https://barthoekstra.github.io/planscanR/reference/classify_model_zeroshot.md)),
  which controls how the NLI pairs are batched through the device.

- write_sidecar:

  If `TRUE`, persist the verdict into each record's sidecar JSON.
  Default `FALSE` (in-memory only).

## Value

`records` with the `class_*` columns added.

## Details

Added columns:

- `class_label` — best label slug.

- `class_score` — probability of the best label.

- `class_relevant` — `TRUE` if the best label is in the `relevant`
  attribute of `labels` (i.e. an energy class, not a negative class).

- `class_model` — the classifier's name.

- `class_score_<slug>` — one column per label with its probability.

## Examples

``` r
if (FALSE) { # \dontrun{
recs <- index_cache(country = "de")
classified <- classify_assessments(recs, write_sidecar = TRUE)
table(classified$class_label, classified$class_relevant)
} # }
```
