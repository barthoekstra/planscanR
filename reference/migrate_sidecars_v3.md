# Upgrade every sidecar in a cache to the current schema (v3) in place.

Walks `<cache>/files/.../<id>.meta.json`, reads each record, and
rewrites it through
[`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md)
so on-disk paths become cache-relative, `schema_version` is bumped to 3,
and the v2 `relevance_score_*` `extras` duplication is dropped. The
merging writer already upgrades a sidecar lazily on the next write, so
this is only needed to upgrade a whole cache eagerly in one pass.
Idempotent — re-running on a v3 cache just rewrites it unchanged.

## Usage

``` r
migrate_sidecars_v3(cache_dir = NULL)
```

## Arguments

- cache_dir:

  Optional cache root. Defaults to
  [`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md).

## Value

The number of sidecars rewritten, invisibly.

## Examples

``` r
if (FALSE) { # \dontrun{
migrate_sidecars_v3()
} # }
```
