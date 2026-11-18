# Fetch environmental-assessment records from Cyprus.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Cyprus. Backed by the Department of Environment **EIA register**
(<https://eia.moa.gov.cy/public/>), a server-rendered HTML portal;
records are parsed with `rvest`. Language is Greek (`el`); portal-native
values are kept verbatim.

## Usage

``` r
get_assessments_cy(
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
  query = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Optional free-text query, matched client-side as a case-insensitive
  substring of the record title.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Coverage window

The portal has no archive or year selector. The only enumerable listing
is the **current-year view** (`/public/currentYearView.html`, one finite
unpaginated table; completion dates seen 2024-2026). The handler reads
that whole table once and never guesses `no=` identifiers, so results
are a current-year window, **not national completeness**. The separate
SEA register (`/public/sea/`) is not covered (too few enumerable plans
with accessible reports).

## Records

Each listing row links to `/public/eiaview.html?no=<id>`. The detail
page supplies every key/value metadata row (all kept verbatim in the
`native_fields` JSON column) and the "Related files" file table.
`document_id` is `"cy_"` plus the native `no`. Both full EIA studies
(native listing label *ΜΕΕΠ* ("MEEP"), kept in `listing_type`) and
*Screening* rows are returned; no eligibility rule is applied beyond the
native labels (`listing_type`, and `native_type` = the detail type
field). `date_published` is the letter date and `date_decision` the
completion date, both `DD-MM-YYYY`. The project number
(`project_number`), file number (`file_number`), `no` (`native_no`),
category, district, area and town are extras. The proponent is not a
separate field and is `NA`.

## Attachments

Files are grouped by the portal's server folder in the download path
(`Meep`, `Gnomatevseis`, `oikologiki axiologisi`,
`Bebaiwseis Simmorfwsis`, `Ekthesis Pliroforion`, ...) into
`attachment_urls_<slug>` columns (ASCII slugs, e.g. `meep`); the native
Greek row labels per slug (study, opinion, ...) are kept in
`attachment_labels_native`. Main EIA studies are often `.zip` archives;
they are downloaded as-is, never extracted, and are bounded by
`max_file_size_mb`. Anonymous downloads. No geometry (coordinates are
normally `...`; kept as text in `native_fields`).

## Filter coverage

`query` (case-insensitive title substring) and `date_range` (against
`date_published`) are applied client-side; `limit` caps the result.
Requests are throttled to 5 req/s
(`getOption("planscanR.cy_throttle_rate")`).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
get_assessments_cy(limit = 3, download = FALSE)
} # }
```
