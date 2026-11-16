# Resolve the attachment-inventory outcome for cached records.

This resolver is deliberately conservative. A record with captured
generic or section URLs is a successful inventory; a timestamped
explicit `empty` status is an authoritative successful-empty inventory.
A legacy sidecar with no URLs, no timestamped outcome, or an unknown
status is `retryable`, because an old or swallowed fetch error must not
become a terminal `no_documents` result. Unsupported country codes are
`blocked`.

## Usage

``` r
resolve_attachment_inventory(
  records,
  resolver = NULL,
  supported = supported_countries(),
  refresh = FALSE
)
```

## Arguments

- records:

  A data frame with at least `country` and `document_id`.

- resolver:

  Optional function called with one record row to perform a fresh portal
  inventory. It may return a list with `status`, `reason`, and optional
  `urls`; resolver errors become `retryable`.

- supported:

  Character vector of enabled country codes.

- refresh:

  Logical; when `TRUE` and `resolver` is `NULL`, refresh only the exact
  NL, DE, or DK source identity through its existing detail helper. The
  refresh never crawls listings, downloads files, or writes sidecars.

## Value

A tibble with `country`, `document_id`, `status`, `reason`, and
`authoritative` columns plus UTC `checked_at` and attachment URL
columns.
