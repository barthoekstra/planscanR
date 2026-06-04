# Read a sidecar JSON back into a 1-row tibble matching the planscanR schema.

Part of the sidecar I/O contract: downstream family packages read a
single record's persisted columns via `planscanR::read_record_sidecar()`
rather than parsing the JSON themselves. Asserts the schema version on
read (see
[`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md)
for the cache-root contract).

## Usage

``` r
read_record_sidecar(path)
```

## Arguments

- path:

  Path to a `<document_id>.meta.json` file.

## Value

A 1-row tibble in the planscanR schema.

## Examples

``` r
if (FALSE) { # \dontrun{
# Read one record's cached metadata back into a 1-row tibble.
read_record_sidecar("path/to/<document_id>.meta.json")
} # }
```
