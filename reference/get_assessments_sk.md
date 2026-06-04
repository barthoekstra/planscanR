# Fetch environmental-assessment records from Slovakia.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Slovakia. Backed by the Slovak EIA/SEA central information system
*enviroportal.sk* (<https://www.enviroportal.sk/>), a React single-page
app served by a Symfony **API Platform** JSON backend. The handler talks
to that JSON API directly (pure `httr2`, no browser) with the
`Accept: application/ld+json` content negotiation header.

## Usage

``` r
get_assessments_sk(
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
  assessment_type = "All",
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

- assessment_type:

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Filters the mixed
  `eia_projects` list client-side by the `zbierka`-derived type.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

The portal publishes a single `eia_projects` collection that mixes
project-level EIA and plan/programme SEA records; the `zbierka` (law
collection) string carries the discriminator (`"časť EIA"` vs
`"časť SEA"`). The handler tags each row with an `assessment_type`
column (`"EIA"` / `"SEA"`, derived from `zbierka`) and filters
client-side when an `assessment_type` argument is supplied; a `register`
column carries the raw collection label (`"eia_projects"`).
`document_id` is the globally unique numeric portal `id`, prefixed
`"SK-"` (e.g. `"SK-171227"`), so records never collide on disk.

## URL enumeration

The list endpoint is `GET /api/eia_projects?page=N` (with
`Accept: application/ld+json`). Its `hydra:member` is an **array of
arrays**: a bucket of record objects, a pagination-metadata object, and
(sometimes) an empty bucket. The handler flattens one level and keeps
only the record objects (those with a `seoId`). `hydra:totalItems` /
`hydra:view` are unreliable or absent, so the page generator paginates
`page = 1, 2, 3, …` **until a page flattens to zero records** (the seam
`sk_fetch_search()`, parsed with `perform_json` after attaching the
`ld+json` Accept header). The canonical detail URL for each record is
the human SPA page `https://www.enviroportal.sk/eia/detail/{seoId}`; the
API detail path is `/api/eia_projects/{seoId}`.

## Attachments

Each record's detail JSON carries `dokumenty$data`, an array of **step
groups** (`{step, number, items}`) where the `step` names the procedural
phase. Each `items[]` element is either a document group
(`{title, items:[ {type, label, id, url, …} ]}`) or a plain text field
(`{type:"text", …}`). The handler collects every leaf whose `type` is a
downloadable file (`"PDF"`, etc.), absolutises its `url`
(`/eia/dokument/{id}` →
`https://www.enviroportal.sk/eia/dokument/{id}`), and groups the URLs by
the `step` (phase) name into per-section `attachment_urls_<slug>`
columns (the DE / IT pattern; the slug is the Slovak-transliterated,
ASCII-folded step) plus the deduplicated union in `attachment_urls`. A
record with no downloadable documents yields an empty `attachment_urls`
vector, which is valid.

## Filter coverage (v0.1)

- `assessment_type` — `"All"` (default), `"EIA"`, or `"SEA"`. The API
  serves one mixed list, so each record is tagged from `zbierka` and the
  filter is applied here in R.

- `query` — matched client-side as a case-insensitive substring of the
  record title.

- `date_range` — matched client-side against `date_published` (the date
  part of the portal's *datumPoslednejZmeny* / last-change timestamp).
  `date_decision` is always `NA` (the API exposes no separate decision
  date).

- `limit` — caps the total number of records returned.

## Performance

The register is large (~18 700 records across ~940 pages of 20). A cold
crawl is one list GET per page plus one detail GET per record
(sidecar-first, so repeat runs are fast). A `limit` keeps exploratory
runs bounded. To be polite to the shared government portal, SK requests
are throttled to 5 requests per second by default; override via
`getOption("planscanR.sk_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_sk(limit = 3, download = FALSE)

# SEA only
get_assessments_sk(assessment_type = "SEA", limit = 10, download = FALSE)

# Title substring
get_assessments_sk(query = "skladov", limit = 20, download = FALSE)
} # }
```
