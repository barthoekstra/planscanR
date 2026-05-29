# Aggregate a learning curve to mean +/- sd per training size.

Aggregate a learning curve to mean +/- sd per training size.

## Usage

``` r
learning_curve_summary(curve)
```

## Arguments

- curve:

  The long tibble returned by
  [`selection_learning_curve()`](https://barthoekstra.github.io/planscanR/reference/selection_learning_curve.md).

## Value

A tibble with one row per `size`: `size`, `n_train_used`, `n` (number of
repeats contributing), and the mean/sd of `f1`, `precision`, `recall`.

## Examples

``` r
if (FALSE) { # \dontrun{
learning_curve_summary(selection_learning_curve(recs, rev))
} # }
```
