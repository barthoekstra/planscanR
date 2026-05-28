# Invalidate (delete) part or all of the planscanR cache.

Use this when you actually want to force a refresh — for example after a
portal's HTML layout changes, or to free disk space. By default the
function asks for interactive confirmation before deleting anything, and
refuses to operate on directories outside the resolved cache root.

## Usage

``` r
clear_cache(cache_dir = NULL, country = NULL, confirm = TRUE)
```

## Arguments

- cache_dir:

  Optional cache root. Defaults to the
  `getOption("planscanR.cache_dir")` value (which itself falls back to
  `tools::R_user_dir("planscanR", "cache")`).

- country:

  Optional ISO-2 country code. If supplied, only that country's subtree
  (`<root>/files/<country>/`) is removed. Otherwise the whole
  `<root>/files/` tree is removed.

- confirm:

  If `TRUE` (default) and the session is interactive, print a summary
  (path, file count, size) and ask for explicit y/n before deleting. Set
  to `FALSE` for scripted/automated use.

## Value

Invisibly, a tibble describing what was removed (`path`, `n_files`,
`bytes`, `removed`).

## Details

The cache is a single tree under `<root>/files/<country>/<doc_id>/`
containing per-record sidecar JSON files plus any downloaded
attachments. `clear_cache()` removes that tree (or a country-scoped
subset).

## Examples

``` r
if (FALSE) { # \dontrun{
# Wipe everything under the default cache root, with confirmation prompt
clear_cache()

# Wipe only NL files (sidecars + attachments)
clear_cache(country = "nl")

# Scripted use (no prompt)
clear_cache(confirm = FALSE)
} # }
```
