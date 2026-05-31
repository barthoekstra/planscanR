# Resolve the planscanR cache root.

The cache root is owned by `planscanR`: it is
`getOption("planscanR.cache_dir")` when set, otherwise
[`tools::R_user_dir()`](https://rdrr.io/r/tools/userdir.html)`("planscanR", "cache")`.
This is the same resolution as the internal `cache_dir()` but without
auto-creating the directory, so it is safe in read-only paths. Exported
so the downstream `planscanR.screen` package reads and writes through
the one cache root without reimplementing the resolution chain.

## Usage

``` r
cache_dir_default()
```

## Value

A single path string (the cache root; not guaranteed to exist).

## Examples

``` r
cache_dir_default()
#> [1] "/home/runner/.cache/R/planscanR"
```
