# Built-in selection learners.

Built-in selection learners.

## Usage

``` r
selection_learner_logistic()

selection_learner_glmnet(penalty = 0.01, mixture = 0)

selection_learner_xgboost(trees = 500, tree_depth = 4, learn_rate = 0.05)

selection_learner_ranger(trees = 500, mtry = NULL, min_n = NULL)
```

## Arguments

- penalty, mixture:

  glmnet regularisation: total penalty and the elastic-net mixing
  parameter (`0` = ridge, `1` = lasso).

- trees, tree_depth, learn_rate:

  xgboost hyperparameters.

- mtry, min_n:

  ranger hyperparameters.

## Value

A `planscanR_selection_learner`.

## Examples

``` r
selection_learner_logistic()
#> <planscanR_selection_learner> logistic_glm
```
