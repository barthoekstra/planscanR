# Fetch environmental-assessment records from Norway.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Norway. Backed by the *Norges vassdrags- og energidirektorat* (NVE —
Norwegian Water Resources & Energy Directorate) concession-case register
(`konsesjonssaker`, <https://www.nve.no/konsesjon/konsesjonssaker>).
Each case is an energy/water concession application that carries the
application itself, the *konsekvensutredning* (environmental impact
assessment / EIA), and the hearing documents as downloadable PDFs. The
handler talks to NVE's JSON list API and server-rendered detail HTML
directly (pure `httr2`, no browser).

## Usage

``` r
get_assessments_no(
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

  Optional free-text query, forwarded server-side as the API
  `filterText` parameter.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

NVE publishes a single concession-case register (there is no separate
EIA/SEA split), so there is no `assessment_type` argument — these are
energy-concession cases that carry EIA documents. `document_id` is the
globally unique numeric `SoknadId`, prefixed `"NVE-"` (e.g.
`"NVE-8934"`), so records never collide on disk.

## URL enumeration

The list endpoint is
`GET /umbraco/api/license/getall?caseType=00&county=00&filterText=&municipality=00&pageNumber=N`
(JSON). Its `Licenses` array carries the case records; `Counties`,
`Municipalities`, `CaseTypes`, and `LicenseStatuses` are filter-vocab
facets returned inline, and `TotalCount` is the unfiltered count. The
defaults `caseType=00&county=00&municipality=00&filterText=` mean "all".
The page generator (`no_fetch_search()`) paginates
`pageNumber = 1, 2, …` until a page returns no `Licenses` (parsed with
`perform_json`). The canonical detail URL for each record is the human
page
`https://www.nve.no/konsesjon/konsesjonssaker/konsesjonssak?id={SoknadId}&type={Type}`.

## Attachments

Each detail page renders the case documents in one or more
`div.n-filelist` sections, each with an `<h2>` section heading (e.g.
*Konsesjon*) and a list of `<a>` links to downloadable PDFs at
`https://webfileservice.nve.no/API/PublishedFiles/Download/<saksnummer>/<fileId>`
(and a UUID variant `.../Download/<uuid>/<saksnummer>/<fileId>`); no
authentication is needed. The handler scrapes those links
(sidecar-first), grouping the URLs by the section heading into
per-section `attachment_urls_<slug>` columns (the DE / IT / SK pattern;
the slug is the ASCII-folded Norwegian heading) plus the deduplicated
union in `attachment_urls`. EIA documents are **not** type-flagged in
the markup, so every case document is collected; the document
label/title is kept verbatim (in the link's `<h3>`) so downstream can
identify "konsekvensutredning" / "KU" / "melding" by filename. A case
with no published files yields an empty `attachment_urls` vector, which
is valid.

## Summary

The detail page renders a human-readable case summary in the main
content column (`div.n-col-7`) as a `div.n-mb-5` block. The handler
extracts it into the conventional `summary` column
(whitespace-collapsed). The `n-mb-5` utility class is reused by the
sidebar and the file list, but those sit in the sidebar column
(`div.n-col-5`), so the selector is scoped to `div.n-col-7` to isolate
the summary. Cases that render no summary yield `NA` (valid).

## Filter coverage (v0.1)

- `query` — forwarded **server-side** as the API `filterText` parameter
  (the getall API matches it against the case title/proponent and
  returns a filtered list + `TotalCount`).

- `date_range` — matched client-side against `date_published` (the case
  `Dato`). `date_decision` is always `NA` (the API exposes no separate
  decision date).

- `limit` — caps the total number of records returned.

The getall API also accepts server-side `caseType` / `county` /
`municipality` filters (via the facet codes in `CaseTypes` / `Counties`
/ `Municipalities`, returned inline by the API); these are documented
for reference but are not first-class arguments in v0.1.

## Geometry

No geometry is exposed in v0.1. NVE's spatial concession layers live in
a separate keyed ArcGIS service that is out of scope for this handler.

## Performance

The register is ~7 300 cases (~730 pages of 10). A cold crawl is one
list GET per page plus one detail GET per record (sidecar-first, so
repeat runs are fast). A `limit` keeps exploratory runs bounded. NVE's
`robots.txt` requests a `Crawl-delay: 20`, so NO requests are throttled
to **0.05 requests per second (~20 s between requests)** by default —
intentionally conservative. Override via
`getOption("planscanR.no_throttle_rate")` (requests/sec; falsy
disables). The *konsekvensutredning* (EIA) documents are identified by
their filename / label, not a type flag.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_no(limit = 3, download = FALSE)

# Wind-themed slice (server-side filterText)
get_assessments_no(query = "vind", limit = 20, download = FALSE)
} # }
```
