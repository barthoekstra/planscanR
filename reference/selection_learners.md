# Registry of the built-in learners.

Maps a stable key to a zero-argument constructor, for UIs that let the
user pick a learner. `available_only = TRUE` drops learners whose engine
package isn't installed.

## Usage

``` r
selection_learners(available_only = FALSE)
```

## Arguments

- available_only:

  If `TRUE`, return only learners whose engine package is installed.

## Value

A named list of constructor functions, keyed by learner key.

## Examples

``` r
names(selection_learners())
#> [1] "logistic" "glmnet"   "xgboost"  "ranger"  
```
