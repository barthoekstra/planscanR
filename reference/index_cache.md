# Walk a planscanR cache and reconstruct a tibble from every sidecar.

Lets you re-index a previously-populated cache without going back to any
portal. Useful when:

- you've downloaded a large slice and want a quick offline tibble of it,

- you've manually flattened or relocated files,

- you want to enumerate what's already on disk before deciding what else
  to fetch.

## Usage

``` r
index_cache(
  cache_dir = NULL,
  country = NULL,
  row_transform = NULL,
  batch_size = 512L
)
```

## Arguments

- cache_dir:

  Optional cache root. Defaults to
  `tools::R_user_dir("planscanR", "cache")`.

- country:

  Optional ISO-2 country code to filter by. `NULL` returns all.

- row_transform:

  Optional function applied to each successfully decoded one-row record
  before rows are combined. It must accept one data-frame argument,
  retain the required planscanR schema columns and their types
  (`country`, `source_portal`, `document_id`, and `url` as character;
  `retrieved_at` as `POSIXct`; and `attachment_urls` and `local_path` as
  list columns), and return exactly one data-frame row. Read errors are
  still warned and skipped; transform errors and invalid returns abort
  the index operation so a partial projection cannot be mistaken for a
  complete cache.

- batch_size:

  Positive integer number of decoded rows combined at a time. Defaults
  to 512. It bounds the intermediate row list while preserving the
  existing result schema when `row_transform = NULL`.

## Value

A tibble in the planscanR schema, possibly with zero rows.

## Examples

``` r
if (FALSE) { # \dontrun{
# Re-index everything currently in the cache
index_cache()

# Re-index just the Dutch records
index_cache(country = "nl")
} # }
```
