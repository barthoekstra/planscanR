# Atomically update one record sidecar from its latest on-disk value.

This is the compound-operation counterpart to
[`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md).
A caller such as a translation worker can read, add one extra field, and
write while holding the same per-record lock as download/classification
workers. The callback must return the one-row record to persist; the
existing merge rules still protect fields it does not touch.

## Usage

``` r
update_record_sidecar(country, document_id, update_fn, root = NULL)
```

## Arguments

- country:

  ISO-2 country code.

- document_id:

  Portal-native document ID.

- update_fn:

  A function accepting the current one-row sidecar tibble and returning
  its updated one-row tibble.

- root:

  Cache root (or `NULL` to use the default).

## Value

Path to the written sidecar, invisibly.
