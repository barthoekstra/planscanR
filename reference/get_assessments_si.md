# Fetch environmental-assessment records from Slovenia.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Slovenia. Backed by the Slovenian government portal gov.si
(<https://www.gov.si/>), which publishes the environmental-assessment
registers as bulk JSON exports under
<https://www.gov.si/podrocja/okolje-in-prostor/okolje/okoljske-presoje/>.
Three adjacent registers are merged into a single result tibble:

## Usage

``` r
get_assessments_si(
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
  assessment_type = "All",
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- assessment_type:

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Selects which
  register(s) to crawl.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

- **Predhodni postopek** — the EIA screening register
  (`predhodni-postopek`).

- **CPVO — državni prostorski načrti** — SEA decisions for state spatial
  plans (`cpvo-drzavni`).

- **CPVO — občinski prostorski načrti** — SEA decisions for municipal
  spatial plans (`cpvo-obcinski`).

An `assessment_type` column (`"EIA"` for the screening register, `"SEA"`
for the two CPVO registers) tags each row and is preserved in the
offline metadata cache so downstream tooling can tell them apart without
re-fetching anything; a `register` column carries the raw portal
register label. `document_id` is prefixed with `"PRED-"` / `"CPVO-DRZ-"`
/ `"CPVO-OBC-"` so the three registers never collide on disk.

## URL enumeration

Each register exposes a single bulk JSON export at
`<list base URL><list>/export/json/`, returning the whole register as
one JSON array (NOT paginated). The handler issues one GET per register
and parses every element of the array, respecting the global `limit`.
The canonical detail URL for each record is
`<list base URL><URLSegment>/`.

## Attachments

The bulk-export document ids do not map to filenames, so attachments are
scraped from each record's detail page (sidecar-first via the cache).
The handler fetches the detail HTML, collects every
`a[href^="/assets/seznami/"]` link, and absolutises it against
`https://www.gov.si`. These become `attachment_urls` (a flat list — no
per-section split). A record with no such links yields an empty
`attachment_urls` vector, which is valid.

## Filter coverage (v0.1)

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (screening only), or `"SEA"` (both CPVO registers).
  Applied here in R, not server-side (the bulk exports are unfiltered).

- `date_range` — matched client-side against `date_published` (the
  portal's *Datum objave* / *Datum* field). `date_decision` is always
  `NA` because the portal exposes no separate decision date as a date.

- `limit` — caps the total number of records returned across all crawled
  registers.

## Performance

The registers are small (a few hundred screening records, a few dozen
CPVO records). A cold crawl is one bulk-export GET per register plus one
detail-page fetch per record (sidecar-first, so repeat runs are fast).
To be polite to the shared government portal, SI requests are throttled
to 5 requests per second by default; override via
`getOption("planscanR.si_throttle_rate")` (requests/sec; falsy
disables). The register covers roughly 2021 onward.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_si(limit = 3, download = FALSE)

# SEA only (both CPVO registers)
get_assessments_si(assessment_type = "SEA", limit = 10, download = FALSE)

# Date range
get_assessments_si(
  date_range = c("2021-01-01", "2021-12-31"),
  limit = 20,
  download = FALSE
)
} # }
```
