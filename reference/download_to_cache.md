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
  overwrite = FALSE,
  content_addressed = FALSE,
  storage_root_id = "cache",
  storage_guard = NULL
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

  If `FALSE` (default) and a verified file is already cached, it is
  returned as-is with status `"exists"`. If `TRUE`, the URL is
  re-fetched; a failed attempt leaves an existing verified copy in
  place.

- content_addressed:

  Place a verified copy under `objects/sha256/ab/cd/<sha256>` and return
  its portable location. The legacy per-project copy and its
  URL-specific receipt are retained. Defaults to `FALSE` for backward
  compatibility.

- storage_root_id:

  Stable root ID to include in the returned location; defaults to the
  built-in `cache` root.

- storage_guard:

  Optional callback used by an acquisition coordinator to authorize
  bytes before they are written. It receives cumulative bytes already
  written, the advertised size (or `NA`), and may accept `phase` and
  `pending_bytes` arguments. A guard error or `FALSE` result fails
  closed. When omitted, the historical `max_file_size_mb` behavior is
  unchanged.

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

- streams through the shared throttled, retrying httr2 client into a
  same-filesystem staging path, enforcing the size cap while receiving;

- checks the GET length and rejects empty bodies or clear
  HTML/login/error pages before publication; MIME and magic bytes are
  identification hints, so arbitrary nonempty attachment bytes are
  retained;

- finalizes the file extension (a URL with no extension lands at a `.x`
  placeholder, renamed from the URL, magic bytes, response
  `Content-Type`, or a stable `.bin` fallback);

- computes the SHA-256, publishes its verification receipt, and
  atomically renames the completed file.

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
