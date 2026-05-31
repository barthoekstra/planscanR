# Write a sidecar JSON for a single record.

Atomic write: data is serialised to a temp file in the target dir and
then renamed over the destination, so a crash mid-write cannot leave a
half-written sidecar in place.

## Usage

``` r
write_record_sidecar(record, downloads = NULL, root = NULL)
```

## Arguments

- record:

  A 1-row tibble in the planscanR result shape.

- downloads:

  The structured download-status tibble produced by
  `download_attachments()`. May be empty when `download = FALSE`.

- root:

  Cache root (or `NULL` to use the default).

## Value

Path to the written sidecar, invisibly.

## Details

This is part of the sidecar I/O contract between `planscanR` (the cache
owner) and the downstream family packages: `planscanR.screen` and
`planscanR.biogain` persist their derived columns (relevance / class
scores, review translations) by calling
`planscanR::write_record_sidecar()`. The merge logic that preserves
existing `files[]` / `relevance_scores[]` / `class_*` arrays lives here,
so adding a new score family never wipes existing ones.
