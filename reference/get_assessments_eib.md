# Fetch records from the European Investment Bank public register.

Implementation of the explicit source `"eib"` for
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md):
`get_assessments("de", source = "eib")`. Backed by the EIB public
register of environmental and social documents
(<https://www.eib.org/en/registers/>) for EIB-financed projects. This is
an organisation source, not a national portal: it is not in
[`supported_countries()`](https://barthoekstra.github.io/planscanR/reference/supported_countries.md)
and not in
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md);
see
[`get_assessments_sources()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_sources.md).

## Usage

``` r
get_assessments_eib(
  country,
  date_range = NULL,
  limit = Inf,
  download = FALSE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  document_type = NULL,
  ...
)
```

## Arguments

- country:

  Lowercase ISO-2 code (supplied by
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)).

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
  `date_range` filters `date_published`.

- document_type:

  Optional character vector of native document types, matched
  case-insensitively against the full label or its bracketed
  abbreviation (e.g. `"ESIA"`).

- ...:

  Unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Granularity and scope

One record per register **document** (`document_id = "eib_<id>"`); one
project has many documents sharing `project_number`. ALL document types
the register holds for the country are kept, with the native type label
in `role` / `native_type` and one `attachment_urls_<type-slug>` section
each. The types are not reclassified. Labels such as `ESIA`,
`Environmental Impact Assessment` and `SEA` identify full reports
(although the `ESIA` bucket also holds permits, decisions and
placeholder rows); `ESDS`, `ESCS` and `NTS` are summaries. A
`Link to promoter website` row may have no file; whether a file exists
is only known after download, when a missing file is recorded as a
failure in `download_status`. The record `url` is the register page.
Coverage is EIB-financed projects only (publication from about 2011),
not national completeness.

## Geography

The register tags documents with ISO-2 country codes (plus non-ISO tags
such as `C7` "EU Countries" and regional `A1`-`A9`). A record matches
when ANY of its tags equals the requested code (multi-country records
appear under each requested country with the same `document_id`).
Regional/non-ISO-only and untagged rows are excluded. The complete
native tag list is kept in `country_codes` / `country_labels`.

## Listing and completeness

One request to `/provider-eib-plr/app/registers/list?countries=<ISO2>`
returns the whole filtered list. When the response's `totalItems`
differs from the returned row count a `planscanR_warning_partial` states
both numbers (the register itself shows such gaps). Per-record metadata
comes from `/registers/item/{id}`; files from
`/attachments/registers/{id}.pdf`. Files over `max_file_size_mb` are not
silently dropped: they stay in the record and get `skipped_size` in
`download_status`.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_sources()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_sources.md)

## Examples

``` r
if (FALSE) { # \dontrun{
get_assessments("de", source = "eib", document_type = "ESIA", limit = 5)
} # }
```
