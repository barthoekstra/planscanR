# Inspect or repair a cached attachment's verification receipt.

A non-empty legacy file is deliberately left unverified unless both its
expected size and SHA-256 are supplied by a trusted publication outcome.
When those values match the bytes already on disk, `repair = TRUE`
publishes the receipt locally and avoids another HTTP request. A `.part`
path is always reported as an interrupted staging file.

## Usage

``` r
reconcile_cached_download(
  path,
  expected_size_bytes = NA_real_,
  expected_sha256 = NA_character_,
  url = NA_character_,
  content_type = NA_character_,
  repair = FALSE
)
```

## Arguments

- path:

  Canonical attachment path (or a staging `.part` path).

- expected_size_bytes:

  Trusted byte count from the publication outcome.

- expected_sha256:

  Trusted SHA-256 from the publication outcome.

- url:

  Original source URL to store in a repaired receipt.

- content_type:

  Optional response content type to store in a repaired receipt.

- repair:

  If `TRUE`, publish a receipt only after both trusted values match the
  existing bytes.

## Value

A one-row tibble with `path`, `status`, `size_bytes`, `sha256`,
`receipt_path`, and `reason`. Status is one of `missing`, `partial`,
`unverified`, `verified`, or `repaired`.
