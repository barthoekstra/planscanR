# Fetch environmental-assessment records from the United Kingdom.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the United Kingdom. Backed by the Planning Inspectorate's **National
Infrastructure Consenting** service
(<https://national-infrastructure-consenting.planninginspectorate.gov.uk/>),
the register of **Nationally Significant Infrastructure Projects
(NSIPs)**. Every NSIP application carries a statutory **Environmental
Statement (ES)**, so the register is an EIA-equivalent source; each row
is therefore an EIA-equivalent procedure and there is no
`assessment_type` selector (this is a single-register handler).

## Usage

``` r
get_assessments_gb(
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
  status = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Optional free-text query. Applied as a client-side case-insensitive
  substring match on the project name.

- status:

  Optional project *Stage* (client-side, case-insensitive).

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

Scope is **NSIP only**. Local-authority / Town-and-Country-Planning EIAs
(the much larger body of smaller English/Welsh consents) are *not* in
this register and are out of scope here.

## URL enumeration

The whole register is published as a single bulk CSV export at
`…/api/applications-download` (≈540 rows). One GET fetches the entire
register; it is parsed with base
[`utils::read.csv()`](https://rdrr.io/r/utils/read.table.html) (no new
package dependency). The handler's page generator returns every row on
its first call and then signals exhausted, respecting the global
`limit`. The canonical record URL is the project landing page
`…/projects/{REF}` where `{REF}` is the *Project reference* (e.g.
`EN010001`), which is the clean, path-safe, unique `document_id`.

## Attachments

Per record (sidecar-first via the cache) the handler fetches the
project's Environmental Statement document list
(`…/projects/{REF}/documents?type=Environmental Statement`) and scrapes
the published-document PDF hrefs, which live on
`https://nsip-documents.planninginspectorate.gov.uk/published-documents/{REF}-{NNNNNN}-{title}.pdf`.
These become `attachment_urls` (a flat list — no per-section split). A
project with no ES documents yet yields an empty `attachment_urls`
vector, which is valid.

## Geometry (point)

Each row carries an Ordnance Survey National Grid point (*Grid
reference - Easting* / *Northing*). When both are present, a point
`.geometry.geojson` is written next to the sidecar (GeoJSON `Point`,
OSGB36 **EPSG:27700**, with the GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::27700`). `geometry_path` (relative to the cache
root, per schema v3) and `geometry_crs` (`"EPSG:27700"`) are recorded on
the sidecar. Coordinates are kept in the source CRS — reproject
downstream with `sf` if you need WGS84. The raw easting/northing and the
portal's WGS84 *GPS co-ordinates* string are also surfaced as extras.

## Filter coverage (v0.1)

Every filter is applied **client-side** (the bulk export is unfiltered):

- `query` — case-insensitive substring match on `title` (the project
  name).

- `date_range` — matched against `date_decision` when present, otherwise
  `date_published` (the application-accepted date).

- `status` — case-insensitive match on the portal *Stage* (e.g.
  `"Pre-application"`, `"Examination"`, `"Post-decision"`,
  `"Withdrawn"`).

- `limit` — caps the total number of records returned.

## Performance

Enumeration is a single bulk-CSV GET plus one document-list fetch per
record (sidecar-first, so repeat runs are fast). To honour the portal's
`robots.txt` `Crawl-delay: 10`, GB requests are throttled to 0.1
requests per second by default (one request every 10 s); override via
`getOption("planscanR.gb_throttle_rate")` (requests/sec; falsy
disables). The package's neutral `planscanR/…` User-Agent is allowed by
the portal's `robots.txt` (AI-crawler agents such as ClaudeBot / GPTBot
/ CCBot are `Disallow: /`).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_gb(limit = 3, download = FALSE)

# Substring query on the project name
get_assessments_gb(query = "solar", limit = 20, download = FALSE)

# Only projects at the Examination stage
get_assessments_gb(status = "Examination", limit = 20, download = FALSE)

# Date range (matched against the decision / acceptance date)
get_assessments_gb(
  date_range = c("2020-01-01", "2020-12-31"),
  limit = 20,
  download = FALSE
)
} # }
```
