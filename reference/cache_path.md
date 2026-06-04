# Compute the local cache path an attachment URL would land at.

Returns the deterministic destination path for an attachment without
downloading anything. The layout is
`<cache_dir>/files/<country>/<document_id>/<slug>`, where the slug is a
flatten-safe, lowercase ASCII basename derived from the URL (see the
package download docs). Computing this up front lets a caller decide
whether to fetch a URL — e.g. checking whether the file already exists
locally or remotely — before spending a request on it.

## Usage

``` r
cache_path(url, country, document_id, cache_dir = cache_dir_default())
```

## Arguments

- url:

  Source URL (character scalar).

- country:

  ISO-2 country code.

- document_id:

  Portal-native document ID.

- cache_dir:

  Cache root. Defaults to
  [`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md).

## Value

Absolute path (character scalar). The parent directory is created as a
side effect.

## Details

For URLs whose path carries no file extension, the returned path uses a
`.x` placeholder extension; the real extension is only known after the
body has been fetched (see
[`resolve_cached_path()`](https://barthoekstra.github.io/planscanR/reference/resolve_cached_path.md)
and
[`download_to_cache()`](https://barthoekstra.github.io/planscanR/reference/download_to_cache.md)).

## See also

[`resolve_cached_path()`](https://barthoekstra.github.io/planscanR/reference/resolve_cached_path.md),
[`download_to_cache()`](https://barthoekstra.github.io/planscanR/reference/download_to_cache.md)

## Examples

``` r
cache_path(
  "https://pas.commissiemer.nl/files/nl/3619/a3619ts.pdf",
  country = "nl",
  document_id = "3619",
  cache_dir = tempdir()
)
#> [1] "/tmp/RtmpNgPnQN/files/nl/3619/nl_3619_a3619ts.pdf"
```
