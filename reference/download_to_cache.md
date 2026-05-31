# Download one attachment URL into the planscanR cache.

Fetches a single URL into the planscanR cache, behaving exactly as
planscanR's own downloader does. In order, it:

## Usage

``` r
download_to_cache(
  url,
  country,
  document_id,
  cache_dir = cache_dir_default(),
  max_file_size_mb = getOption("planscanR.max_file_size_mb", 50),
  overwrite = FALSE
)
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

- max_file_size_mb:

  Per-file size ceiling in MiB. Defaults to
  `getOption("planscanR.max_file_size_mb", 50)`. `Inf`, `NULL`, or a
  non-positive value means no cap.

- overwrite:

  If `FALSE` (default) and a non-empty file is already cached, it is
  returned as-is with status `"exists"`. If `TRUE`, any pre-existing
  copy (placeholder or finalized) is swept and the URL is re-fetched.

## Value

A one-row tibble with columns: `url`, `local_path` (`NA` when
skipped/failed), `size_bytes`, `sha256` (`NA` when no local file),
`status`, `reason`. `status` is one of `"downloaded"`, `"exists"`,
`"skipped_size"`, or `"failed"`.

## Details

- resolves the destination path with
  [`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md);

- runs a cheap HEAD probe and skips the URL if its advertised
  `Content-Length` already exceeds the cap, so an over-size file is
  never transferred;

- downloads through the shared throttled, retrying httr2 client;

- re-checks the size cap after downloading and discards an over-cap
  file;

- finalizes the file extension (a URL with no extension lands at a `.x`
  placeholder, renamed from the response `Content-Type` or magic bytes);

- computes the SHA-256 of the result.

This is the public, single-URL counterpart to planscanR's internal batch
downloader; it is intended for downstream callers (e.g. mirroring to
external storage) that need one file in the canonical cache location
with a structured result.

## See also

[`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md),
[`resolve_cached_path()`](https://barthoekstra.github.io/planscanR/reference/resolve_cached_path.md)

## Examples

``` r
if (FALSE) { # \dontrun{
download_to_cache(
  "https://pas.commissiemer.nl/files/nl/3619/a3619ts.pdf",
  country = "nl",
  document_id = "3619"
)
} # }
```
