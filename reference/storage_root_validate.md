# Validate and resolve a local storage root.

Validate and resolve a local storage root.

## Usage

``` r
storage_root_validate(root = NULL, create = FALSE, writable = FALSE)
```

## Arguments

- root:

  Absolute directory path. `NULL` resolves the planscanR cache root.

- create:

  Create the directory when it does not exist.

- writable:

  Require write access.

## Value

A canonical absolute directory path.
