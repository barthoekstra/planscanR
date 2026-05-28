# Discover attachments for records the portal returned empty.

For each input record, this function:

## Usage

``` r
discover_attachments(
  records,
  backend = NULL,
  country_config = NULL,
  relevance_model = NULL,
  queries_per_record = 3L,
  max_pdfs_per_record = 100L,
  max_results_per_query = 20L,
  cache_dir = NULL,
  max_file_size_mb = NULL,
  dry_run = FALSE,
  skip_if_attached = TRUE,
  semantic_threshold = 0.5
)
```

## Arguments

- records:

  A tibble of records (e.g. from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  or
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)).
  All rows must share the same `country`.

- backend:

  A
  [`search_backend()`](https://barthoekstra.github.io/planscanR/reference/search_backend.md).
  Defaults to
  [`search_backend_tavily()`](https://barthoekstra.github.io/planscanR/reference/search_backend_tavily.md)
  (requires `TAVILY_API_KEY`).

- country_config:

  Per-country discovery config (e.g.
  [`at_discovery_config()`](https://barthoekstra.github.io/planscanR/reference/at_discovery_config.md)).
  When `NULL`, resolved from `records$country`.

- relevance_model:

  Optional embedding model for the validator's semantic backup signal.
  When `NULL`, the validator runs without semantic check.

- queries_per_record:

  Cap on the number of templates fired per record. Lower = cheaper, less
  recall.

- max_pdfs_per_record:

  Cap on the number of validated PDFs kept per record.

- max_results_per_query:

  Pass-through to the backend's `max_results`.

- cache_dir:

  Optional cache root. Defaults to `getOption("planscanR.cache_dir")`.

- max_file_size_mb:

  Per-PDF size cap. Defaults to the package option.

- dry_run:

  If `TRUE`, runs phases 1-2 but skips ingest (no sidecar writes, no
  PDFs copied into the cache). The returned tibble carries the would-be
  discoveries in its `discovery_log` column for inspection.

- skip_if_attached:

  If `TRUE` (default), records that already have
  `length(attachment_urls) > 0` are skipped — discovery is only for
  records the portal returned empty.

- semantic_threshold:

  Cosine-similarity threshold for the validator's semantic backup
  signal.

## Value

The input tibble with `attachment_urls` and `local_path` augmented for
records that got new validated PDFs, plus a `discovery_log` list-column
with one entry per (record, query) attempt.

## Details

1.  **Discovers** — generates a small set of search queries from the
    record's metadata and runs them through a
    [`search_backend()`](https://barthoekstra.github.io/planscanR/reference/search_backend.md).

2.  **Validates** — for each candidate URL that points at a PDF,
    downloads a copy and runs
    [`discover_validate()`](https://barthoekstra.github.io/planscanR/reference/discover_validate.md)
    against the record. Failed candidates are discarded from disk.

3.  **Ingests** — for PDFs that pass, copies them into the canonical
    cache layout (`<cache>/files/<country>/<document_id>/`) and appends
    to the record's sidecar JSON with `source = "discovery"` plus a
    `discovery_log[]` audit entry.

This is the package's escape hatch for portals that do not expose
document URLs to anonymous callers. The Austrian UVP-DB is the canonical
example — see
[`get_assessments_at()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md)
— but the function is portal-agnostic once a country supplies a
discovery config.

## See also

[`search_backend_tavily()`](https://barthoekstra.github.io/planscanR/reference/search_backend_tavily.md),
[`discover_validate()`](https://barthoekstra.github.io/planscanR/reference/discover_validate.md),
[`at_discovery_config()`](https://barthoekstra.github.io/planscanR/reference/at_discovery_config.md).
