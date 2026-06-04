# Fetch environmental-assessment records from Ireland.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Ireland's **EIA Portal**
(<https://experience.arcgis.com/experience/a1a85d92623147b191dd25a14b2571da/>),
the gov.ie public map of Environmental Impact Assessment applications,
served by a public anonymous **Esri ArcGIS REST FeatureServer**
(`services.arcgis.com`, the `EIA_Location_Point` master layer, ≈5,100
records). This is the package's first ArcGIS REST handler: transport is
plain `GET` with `f=json`, pagination is `resultOffset` /
`resultRecordCount`, and Esri point geometry is converted to GeoJSON
in-house.

## Usage

``` r
get_assessments_ie(
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
  competent_authority = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Free-text query; sent server-side as a description `LIKE`.

- competent_authority:

  Optional competent-authority name (server-side equality on
  `Competent_Authority`), e.g. `"An Bord Pleanála"`. See
  `eia_portal_ie_facets()`.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## What this handler returns (IMPORTANT — EIA only, notices only)

The portal covers **EIA applications only** — there is **no SEA
register** here. For each application the portal hosts (at most) the
statutory **newspaper / public-notice PDF**; the full EIAR
(Environmental Impact Assessment Report) itself is **off-portal**, on
the relevant competent-authority website (An Bord Pleanála, the local
council, the EPA, ...). Those external case pages are surfaced as the
extras columns `url_link_application` / `url_link_secondary` (HTML
landing pages on heterogeneous third-party sites, *not* direct PDFs) and
are deliberately kept out of `attachment_urls`; treat them as a
discovery target. So plan for a corpus of public-notice PDFs plus
off-portal EIAR links, not the EIARs themselves.

## The OBJECTID_1 gotcha

The layer's unique object-id field is **`OBJECTID_1`**, *not* the plain
`OBJECTID` (which is non-unique on this layer and frequently `0`). All
attachment lookups and the internal id fallback key off `OBJECTID_1`.

## URL enumeration

Listing is `GET <layer>/query`, paginated with `resultOffset` /
`resultRecordCount` (page size 1000, the server's `maxRecordCount`),
looping while `exceededTransferLimit` is true. A stable
`orderByFields=OBJECTID_1 ASC` fixes the page ordering. Each feature
carries all its metadata inline in `attributes` (there is no separate
detail endpoint), plus an Esri point `geometry` requested in
`outSR=2157`.

The portal has **no per-record permalink**, so a unique, deterministic
`url` is synthesised per record: the record-specific query URL
`<layer>/query?where=Portal_Ref='<ref>'&outFields=*&f=json` (stable and
meaningful — it is the record's landing query). This keeps the
sidecar-first path keyed on a stable url.

Server-side `where` filters honoured here:

- `query` -\> `UPPER(Description__Max__256_character) LIKE '%<QUERY>%'`
  (free-text over the description).

- `competent_authority` -\> `Competent_Authority = '<value>'`.

- `date_range` -\> a `Date_of_receipt_of_application_` BETWEEN window
  (epoch-milliseconds), re-checked client-side as a guard.

## Geometry

Each record carries an Esri point `geometry` (`{x, y}`) in **Irish
Transverse Mercator (IRENET95 ITM / EPSG:2157)** — requested via
`outSR=2157`. It is converted in-house to a GeoJSON **Point**
(`{type:"Point", coordinates:[x,y]}`) and, when `write_sidecar = TRUE`,
written next to the sidecar as `<document_id>.geometry.geojson` in the
family FeatureCollection layout with the GeoJSON-2008 `crs` member
naming `urn:ogc:def:crs:EPSG::2157`. No reprojection happens —
coordinates stay in EPSG:2157. The sidecar carries `geometry_path` and
`geometry_crs` (`"EPSG:2157"`). Records with a null geometry leave the
geometry columns `NA`.

## Attachments

Portal-hosted attachments are ArcGIS feature attachments — the statutory
newspaper / public-notice PDF. Because the download URL needs both the
`OBJECTID_1` and the per-attachment id
(`<layer>/<OBJECTID_1>/attachments/<id>`), attachment metadata is
resolved in a batched **phase-2** `queryAttachments` call (keyed by
`OBJECTID_1`) — even when `download = FALSE`, this is needed to populate
`attachment_urls`. The single slug is `notice` (`attachment_urls_notice`
/ `local_path_notice`); the deduplicated union goes to `attachment_urls`
/ `local_path` (required by the schema). A record may carry **0**
attachments (still schema-valid).

## Filter coverage (v0.1)

- `query` — server-side description substring
  (`UPPER(Description__Max__256_character) LIKE`).

- `competent_authority` — server-side equality on `Competent_Authority`
  (see
  [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
  / `eia_portal_ie_facets()`).

- `date_range` — server-side window on `Date_of_receipt_of_application_`
  (the application-receipt date), re-checked client-side against
  `date_published`. `date_decision` is `NA` (the layer exposes no
  decision-date field).

## Performance

Enumeration is ≈6 paginated `query` calls (page size 1000) plus batched
`queryAttachments` lookups (many `OBJECTID_1`s per call). IE requests
are throttled to 5 requests per second by default; override via
`getOption("planscanR.ie_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test (EIA applications; portal hosts the notice PDF only)
get_assessments_ie(limit = 3, download = FALSE)

# Wind-themed slice (server-side description LIKE)
get_assessments_ie(query = "wind", limit = 20, download = FALSE)

# An Bord Pleanála applications only
get_assessments_ie(
  competent_authority = "An Bord Pleanála",
  limit = 20,
  download = FALSE
)
} # }
```
