# Audit attachment files under the local cache.

The audit identifies receipt-verified files, unverified legacy files,
interrupted `.part` files, and orphaned receipts. It never promotes
bytes or deletes anything; a later acquisition/synchronization run can
retry rows whose status is `partial` or `unverified`.

## Usage

``` r
audit_cache_downloads(cache_dir = NULL, country = NULL)
```

## Arguments

- cache_dir:

  Cache root. Defaults to
  [`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md).

- country:

  Optional ISO-2 country filter.

## Value

A tibble with `path`, `status`, `size_bytes`, `sha256`, `receipt_path`,
`reason`, `country`, and `document_id`.
