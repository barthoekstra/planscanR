# Fetch environmental-assessment records from Georgia.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Georgia. Backed by the **recent environmental decision portal** of
the Ministry of Environmental Protection and Agriculture
(<https://ei.gov.ge/>, Georgian-language `/ka` pages). The legacy
archive is out of scope, and the portal's own historical horizon is not
documented (cases from 2024-08 onward were observed): only what the
listing returns is covered, so results are **not national
completeness**. Native Georgian values are kept verbatim.

## Usage

``` r
get_assessments_ge(
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
  procedure = NULL,
  query = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- procedure:

  Optional character vector of procedure keys (see *Procedures*); `NULL`
  (default) enumerates all six.

- query:

  Optional free-text query, matched client-side as a case-insensitive
  substring of the record title.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Records

The listing (`POST /ka/Home/Table`, anonymous JSON body, 5 rows per
page, a finite page count) holds procedure *events*; the stable case key
is the `/ka/info/<GUID>` link. One output record is returned per case
(deduplicated across pages and procedures) with
`document_id = "ge_<GUID>"`. The case detail JSON
(`GET /ka/record?id=<GUID>`) is captured in full in `detail_json`;
`title` (project name), `proponent` (implementer), `jurisdiction`
(activity address, free text "region/municipality"), `date_published`
(earliest procedure publication date, else the listing date), `status` /
`status_date` (of the procedure that surfaced the case; a listing row
that is a nested-document event is resolved to its enclosing procedure,
and an unmatched row falls back to the listing-row cells),
`procedure_native`, `category_native` and `procedures_native` (all
procedures of the case) are columns. `competent_authority` is not
exposed (`NA`). The cells of the listing row that surfaced the case are
kept as `listing_row_id`, `listing_municipality`,
`listing_comment_deadline` and `listing_public_hearing`; later event
rows of the same case are not merged. An empty procedure grid is an
error (`planscanR_error_bad_response`); no sidecar is written, so the
case is retried on the next run. `assessment_type` comes from the
procedure filter that found the case (`"EIA"` or `"SEA"`); no title
heuristic is used.

## Procedures

`procedure` selects which procedure types to enumerate: `"eia"`,
`"eia_screening"`, `"eia_scoping"`, `"sea_screening"`, `"sea_scoping"`,
`"sea_report_review"`. The default is all six; exemption and
permit-change procedures are not covered.

## Attachments

Files are listed from the detail JSON for every procedure and nested
document, never guessed: `attachment_urls_main_document` holds
`/download/files/?file=<GUID>&accompany=false` PDFs (application
letters, decisions) where `HasDocument` is true;
`attachment_urls_accompanying_bundle` holds `accompany=true` downloads
only where the record says `HasAccompanyingDocument`. **The EIA report
itself lives inside the RAR5 accompanying bundle.** Bundles are
downloaded as-is (no extraction, no new dependency). **Where the report
is:** the EIA report sits in the accompanying bundle of the EIA
procedure's application/annex entry (for SEA, of the report-review
procedure); screening and scoping bundles hold screening and scoping
material only. Accompanying files can also be PDFs, not only RAR. SEA
report-review bundles are often 500+ MB and some EIA bundles are over
the default 50 MB cap too (e.g. a 75 MB gas-pipeline bundle); both are
`skipped_size`. `attachment_labels_native` is a JSON object mapping each
URL to `"<native procedure name> | <native category name>"`.

## Filter coverage

`procedure` is applied server-side. `query` (case-insensitive title
substring) and `date_range` (against `date_published`) are client-side,
so a selective filter still pages through the listing. Requests are
throttled to 2 req/s (`getOption("planscanR.ge_throttle_rate")`). Page
failures or empty pages give a `planscanR_warning_partial`; a response
without the expected table is an error.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
get_assessments_ge(limit = 3, download = FALSE, procedure = "eia")
} # }
```
