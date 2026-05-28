# Walk a planscanR cache and reconstruct a tibble from every sidecar.

Lets you re-index a previously-populated cache without going back to any
portal. Useful when:

- you've downloaded a large slice and want a quick offline tibble of it,

- you've manually flattened or relocated files,

- you want to enumerate what's already on disk before deciding what else
  to fetch.

## Usage

``` r
index_cache(cache_dir = NULL, country = NULL)
```

## Arguments

- cache_dir:

  Optional cache root. Defaults to
  `tools::R_user_dir("planscanR", "cache")`.

- country:

  Optional ISO-2 country code to filter by. `NULL` returns all.

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
