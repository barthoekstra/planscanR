# Fetch environmental-assessment records from Denmark.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Denmark. Backed by Danmarks Miljøportal's EA-Hub
(<https://eahub.miljoeportal.dk/>), the national register for both EIA
("miljøvurdering af projekter", the old VVM / *Miljøkonsekvensrapport*)
and SEA ("miljøvurdering af planer", *miljørapport*).

## Usage

``` r
get_assessments_dk(
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

  Free-text query; forwarded to the API's `freeText`.

- assessment_type:

  One of `"All"`, `"Plans"`, `"Project"`.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## URL enumeration

EA-Hub is a Vue SPA sitting on a public REST API at
`https://eahub.miljoeportal.dk/api/` (Swagger lives at
`/api/swagger/v1/swagger.json`). One `POST /assessments/search` call
returns the entire register (~2700 records at the time of writing); each
row already carries title, year range, status, authorities,
EIA-Directive Annex I/II categories, plan types/categories, and a
`hasGeometry` flag. No detail call is needed during the scan phase —
every field a downstream classifier needs is present in the search
response.

## Geometry

Records with `hasGeometry == TRUE` carry a polygon (typically a
MULTIPOLYGON in EPSG:25832 / ETRS89-UTM32N — the standard Danish
projection). When `write_sidecar = TRUE`, the geometry is fetched from
`GET /assessments/{id}/geometry` and saved next to the sidecar as
`<document_id>.geometry.geojson`. The sidecar carries `geometry_path`
(absolute path to the .geojson) and `geometry_crs` (`"EPSG:25832"`).

The GeoJSON is written with the GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::25832`; tools like QGIS / `sf::read_sf()` read
this fine, even though RFC 7946 deprecated the field. Coordinates are
kept in the source CRS — reproject downstream with `sf` if you need
WGS84.

## Attachments

EA-Hub exposes each document's PDF at a public Azure blob URL. When
`download = TRUE`, the handler fetches the record's document list from
`GET /assessments/{id}`, resolves each document's blob URL via
`GET /assessments/{id}/documents/{docId}/links`, and downloads it into
the cache, tagging each file with its da-DK document type as the sidecar
`section`. A pure scan (`download = FALSE`) stays metadata-only and
makes no per-document calls.

## Filter coverage (v0.1)

- `query` — forwarded to the API's server-side `freeText` field.

- `assessment_type` — one of `"All"` (default), `"Plans"`, or
  `"Project"`. API-defined values; client API accepts these only.

- `date_range` — matched client-side against each record's `fromYear` /
  `toYear` (treated as Jan 1 – Dec 31 spans). `date_decision` is always
  `NA` because EA-Hub exposes only year fields, no decision timestamp.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_dk(limit = 3, download = FALSE)

# Wind-themed slice
get_assessments_dk(query = "vindmølle", limit = 20, download = FALSE)

# Plans only
get_assessments_dk(assessment_type = "Plans", download = FALSE)
} # }
```
