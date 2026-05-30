# Fetch environmental-assessment records from Belgium (Flanders).

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the Flemish *MER-register*
(<https://merregister.omgeving.vlaanderen.be/>), the Departement
Omgeving's public register of Project-MER dossiers (project-level EIA)
and dossier-MER-plicht ontheffingsaanvragen (exemption requests).
Plan-MER (SEA) lives in a separate Flemish register and is out of scope
for this handler.

## Usage

``` r
get_assessments_be(
  date_range = NULL,
  limit = Inf,
  download = TRUE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  query = NULL,
  niscode = NULL,
  nummer = NULL,
  dossier_type = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Free-text query, substring-matched client-side against `title` +
  `document_id`.

- niscode:

  Optional NIS-code (5-digit municipality code, e.g. `"11024"` =
  Kontich). Forwarded server-side.

- nummer:

  Optional dossier number (e.g. `"PR4037"`). Forwarded server-side.

- dossier_type:

  Optional character; one of `"PROJECT_MER"` or
  `"VERZOEK_TOT_ONTHEFFING"`. Applied client-side.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## URL enumeration

The portal is a Vue SPA backed by a public REST API. The SPA reads the
backend host from `GET /rest/configuratie` (which exposes a `dmvbURL`
field pointing at `https://dmvb.omgeving.vlaanderen.be/`) and then
paginates `GET /api/v1/dossier?page=<n>&size=<k>` to enumerate the
register. Page size is capped server-side at 25; this handler walks
every page until `totalElements` is reached. The search index already
carries `nummer`, `dossierType`, `titel`, and `initiatiefnemer`; the
full record (locatie, coordinator, domeinen, documenten) is one
`GET /api/v1/dossier/{nummer}` away.

## Geometry

Every detail record carries a `locatie` field in GeoJSON-style
(typically `MultiPolygon`) directly inline — no separate geometry call
is needed. Coordinates are in **EPSG:31370** (Belgian Lambert 72), the
standard Flemish projection. When `write_sidecar = TRUE`, the geometry
is saved next to the sidecar as `<document_id>.geometry.geojson`. The
sidecar carries `geometry_path` (absolute path to the .geojson) and
`geometry_crs` (`"EPSG:31370"`).

The GeoJSON is written with the GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::31370`; tools like QGIS / `sf::read_sf()` read
this fine, even though RFC 7946 deprecated the field. Coordinates are
kept in the source CRS — reproject downstream with `sf` if you need
WGS84.

## Attachments

Each `documenten[]` entry has a direct, public download URL
(`https://dmvb.omgeving.vlaanderen.be/api/v1/dossier/{nummer}/document/{uuid}`)
that requires no authentication. Documents are grouped by their portal
`type` (e.g. *"Aanmelding"*, *"Ontheffingsaanvraag"*, *"Verslag
toekenning ontheffing"*); the set is open-ended, so the handler
discovers whatever types a record has and emits one
`attachment_urls_<slug>` / `local_path_<slug>` list-column per
discovered type. The slug is the `type` string lowercased with
non-alphanumerics collapsed to underscores; `aanmelding`,
`ontheffingsaanvraag`, and `verslag_toekenning_ontheffing` are the
common ones. `attachment_urls` / `local_path` remain the deduplicated
union (required by the schema).

## Filter coverage (v0.1)

- `query` — case-insensitive substring match on `title` + `document_id`
  (the `PR####` `nummer`). Client-side.

- `niscode` — server-side NIS-code municipality filter (forwarded as the
  API's `niscode` parameter). The list of municipalities + niscodes is
  served at `https://dmvb.omgeving.vlaanderen.be/api/v1/locatie`.

- `nummer` — server-side exact / prefix match (forwarded as `nummer`).

- `dossier_type` — client-side filter on
  `administratieveGegevens.dossierType` (`"PROJECT_MER"` or
  `"VERZOEK_TOT_ONTHEFFING"`). The portal API ignores this filter
  server-side, so it has to be applied after the fact.

- `date_range` — matched client-side against `date_published` (the
  earliest `aanmaakdatum` across the record's documents).
  `date_decision` is always `NA` because the API does not expose a
  separate decision timestamp.

## Performance

The register is ~3,000 records. A cold full crawl is a single search
enumeration (~120 paginated calls) plus one detail call per record. To
avoid hammering the backend, BE requests are throttled to 5 requests per
second by default; override via
`getOption("planscanR.be_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_be(limit = 3, download = FALSE)

# Wind-themed slice
get_assessments_be(query = "wind", limit = 20, download = FALSE)

# All dossiers for Kontich (NIS 11024)
get_assessments_be(niscode = "11024", download = FALSE)
} # }
```
