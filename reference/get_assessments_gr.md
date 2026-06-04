# Fetch environmental-assessment records from Greece.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the Greek **ΗΠΜ / EPRM** (Ηλεκτρονικό Περιβαλλοντικό Μητρώο —
Electronic Environmental Registry), the Ministry of Environment &
Energy's (ΥΠΕΝ) public registry of environmental-permit decisions,
served by a public JSON:API at `api.eprm.ypen.gr`.

## Usage

``` r
get_assessments_gr(
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
  type = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Free-text query; sent server-side as `filter[text_search]`.

- type:

  Optional decision-type code (server-side `filter[type]`), e.g.
  `"aepo_creation"`. See `eprm_gr_facets()` for the enum.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## What this handler returns (IMPORTANT — decisions only)

The public registry exposes **AEPO decisions only** — *Αποφάσεις
Έγκρισης Περιβαλλοντικών Όρων* (decisions approving the environmental
terms of a project), i.e. the regulatory **output** of the EIA (ΜΠΕ)
process. The underlying **ΜΠΕ study files and all ΣΜΠΕ / SEA records are
behind the gov.gr login** on `platform.eprm.ypen.gr` and are **not**
reachable here. So each record carries the decision metadata plus (at
most) one decision PDF — never the EIA study itself, and the SEA
register is entirely out of scope. Plan for a decisions-only corpus when
using this handler.

## URL enumeration

The portal is a SPA backed by a public, no-auth **JSON:API**. Listing is
`GET /v1/license-decisions`, paginated via JSON:API page parameters
(`page[number]`, 1-based; `page[size]`, default 100). Each list row is
**already the full record** — there is no separate detail call needed
(though `GET /v1/license-decisions/{id}` exists). The walk follows
`meta.total` / `links.next` until the register is exhausted (≈19,800
records). Every request carries `Accept: application/json`.

Server-side JSON:API `filter[...]` parameters honoured here:

- `query` -\> `filter[text_search]` (free-text over project/decision
  fields).

- `type` -\> `filter[type]` (decision-type enum; see
  [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
  / `eprm_gr_facets()`).

- `date_range` -\> `filter[issued_after]` / `filter[issued_before]`
  (matched server-side on the decision issue date), re-checked
  client-side as a guard.

## Geometry

A record's `project_location` is an array of `{lat, lon}` pairs. When
present, the first pair is written as a **Point** geometry next to the
sidecar as `<document_id>.geometry.geojson`, in the family
FeatureCollection layout with the GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::4326`. The coordinates are already geographic
**WGS84 (EPSG:4326)** — *not* the Greek Grid (EPSG:2100) — so no
reprojection happens. The sidecar carries `geometry_path` and
`geometry_crs` (`"EPSG:4326"`). Records with no `project_location` leave
the geometry columns `NA`.

## Attachments

At most one document per decision — the AEPO decision PDF — taken
verbatim from `record.diavgeia_doc_url` (hosted on Διαύγεια / Diavgeia,
the Greek government transparency portal, form
`https://diavgeia.gov.gr/luminapi/api/decisions/{ADA}/document.pdf`; the
ADA contains Greek characters, left for `httr2` to percent-encode at
request time). It is emitted under the single slug
`attachment_urls_aepo` / `local_path_aepo`, with the deduplicated union
at `attachment_urls` / `local_path` (required by the schema). Records
whose `diavgeia_doc_url` is `null` yield zero attachments (still
schema-valid).

## Filter coverage (v0.1)

- `query` — server-side full-text (`filter[text_search]`).

- `type` — server-side decision-type enum (`filter[type]`), e.g.
  `"aepo_creation"`; see `eprm_gr_facets()`.

- `date_range` — server-side window on the issue date
  (`filter[issued_after]` / `filter[issued_before]`), re-checked
  client-side against `date_decision`. `date_published` is the registry
  publication timestamp.

## Performance

Enumeration is ≈200 paginated list calls (no per-record detail fetch).
GR requests are throttled to 5 requests per second by default; override
via `getOption("planscanR.gr_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test (AEPO decisions only)
get_assessments_gr(limit = 3, download = FALSE)

# Photovoltaic-themed slice (server-side full-text, Greek)
get_assessments_gr(query = "φωτοβολταϊκ", limit = 20, download = FALSE)

# New AEPO approvals only
get_assessments_gr(type = "aepo_creation", limit = 20, download = FALSE)
} # }
```
