# Tolerant row-bind across result tibbles with differing extra columns.

Wraps
[`dplyr::bind_rows()`](https://dplyr.tidyverse.org/reference/bind_rows.html),
which already pads missing columns with `NA`. Validates the result
schema before returning.

## Usage

``` r
bind_results(...)
```

## Arguments

- ...:

  Tibbles.

## Value

A single tibble.
