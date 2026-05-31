# Locate the on-disk file for a (possibly placeholder) cache path.

[`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md)
returns a `.x` placeholder path for URLs whose path carries no file
extension; the real file may have been renamed to e.g. `.pdf` after its
body was fetched and its type sniffed. Given the path
[`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md)
returned, this resolves the actual file on disk:

## Usage

``` r
resolve_cached_path(dest)
```

## Arguments

- dest:

  A path as returned by
  [`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md).

## Value

The resolved absolute path, or `NA_character_`.

## Details

- the path itself when a non-empty file already exists there;

- the single finalized sibling (same stem, real extension) when exactly
  one exists for a `.x` placeholder;

- `NA_character_` when nothing is cached yet (so the caller knows to
  download) or when the match is ambiguous.

## See also

[`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md),
[`download_to_cache()`](https://barthoekstra.github.io/planscanR/reference/download_to_cache.md)

## Examples

``` r
if (FALSE) { # \dontrun{
dest <- cache_path(url, "ee", "KMH-44")
resolve_cached_path(dest)
} # }
```
