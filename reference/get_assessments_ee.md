# Fetch environmental-assessment records from Estonia.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Estonia. Backed by the Keskkonnaamet's *KOTKAS* portal
(<https://kotkas.envir.ee/>), which publishes two adjacent public
registers:

## Usage

``` r
get_assessments_ee(
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
  proceeding_status = NULL,
  activity_area = NULL,
  activity = NULL,
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Free-text query forwarded as `s__search_keyword`.

- assessment_type:

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Selects which
  register(s) to crawl.

- proceeding_status:

  Optional procedural-status enum (server-side filter); one of
  `"INITIATED"`, `"ONGOING"`, `"SUSPENDED"`, `"FINISHED"`.

- activity_area:

  Optional maakond (county) code (server-side filter).

- activity:

  Optional activity-sector code (server-side filter).

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

- **KMH** — *Keskkonnamõju hindamine* (project-level EIA),
  `https://kotkas.envir.ee/kmh/kmh_index?tab=KMH`.

- **KSH** — *Keskkonnamõju strateegiline hindamine* (plan/programme
  SEA), `https://kotkas.envir.ee/kmh/ksh_index?tab=KSH`.

Both registers are merged into a single result tibble; an
`assessment_type` column (`"EIA"` for KMH, `"SEA"` for KSH) tags each
row and is round-tripped to the sidecar so downstream tooling can tell
them apart without re-fetching anything. `document_id` is prefixed with
`"KMH-"` / `"KSH-"` (e.g. `"KMH-478"`, `"KSH-319"`) so the two registers
never collide on disk.

## URL enumeration

KOTKAS is a server-rendered (jQuery / Bootstrap, not a SPA) Django-style
application. Index listings paginate via a numeric offset on the `qs=`
query parameter (page size = 40, server-controlled); each page is one
HTML GET that lists titles, regions, initiation dates, statuses, and
developers/organisers. Detail pages live at `/kmh/kmh_view?kmh_id=<id>`
(KMH) and `/kmh/ksh_view?ksh_id=<id>` (KSH); every field a downstream
classifier needs (full title, narrative summary, developer/proponent,
decider/competent authority, KOV municipality, geometry, attachment
URLs) is on that page already.

## Geometry

Every detail record carries its activity area as an inline GeoJSON
geometry, embedded in a hidden form input (`#activity_area_geojson`).
Coordinates are in **EPSG:3301** (Estonian Coordinate System of 1997 /
L-EST97), the standard projected CRS for Estonia. When
`write_sidecar = TRUE`, the geometry is saved next to the sidecar as
`<document_id>.geometry.geojson`. The sidecar carries `geometry_path`
(absolute path to the .geojson) and `geometry_crs` (`"EPSG:3301"`).

The GeoJSON is written with the GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::3301`; tools like QGIS / `sf::read_sf()` read
this fine, even though RFC 7946 deprecated the field. Coordinates are
kept in the source CRS — reproject downstream with `sf` if you need
WGS84.

## Attachments

Each detail page exposes a *Dokumendid* table whose rows have a direct,
public download URL of the form
`https://kotkas.envir.ee/kmh/<kmh|ksh>_file_download?<kmh_id|ksh_id>=<id>&attachment_id=<aid>`
(no authentication needed). Documents are grouped by their portal *Liik*
(type) column — common ones include *Algatamise otsus* (initiation
decision), *Programm* (assessment programme), *Programmi otsus*
(programme decision), *Aruanne* (report), *Aruande otsus* (report
decision). The set is open-ended; the handler discovers whatever types a
record has and emits one `attachment_urls_<slug>` / `local_path_<slug>`
list-column per discovered type. The slug is the *Liik* string with
Estonian diacritics transliterated, lowercased, and non-alphanumerics
collapsed to underscores. `attachment_urls` / `local_path` remain the
deduplicated union (required by the schema).

## Filter coverage (v0.1)

- `query` — server-side substring match (forwarded as
  `s__search_keyword`, against title / code / related-person).

- `proceeding_status` — server-side enum: one of `"INITIATED"`,
  `"ONGOING"`, `"SUSPENDED"`, `"FINISHED"`. Forwarded as
  `s__proceeding_status`.

- `activity_area` — server-side maakond (county) code, e.g. `"0037"`
  (Harju) or the special tokens `"ESTONIA"`, `"SEA"`, `"CROSSBORDER"`.
  Forwarded as `s__activity_area`.

- `activity` — server-side sector code (e.g. `"1300"` = *Energeetika ja
  energiakandjate tootmine*). Forwarded as `s__activity`.

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (KMH only), or `"SEA"` (KSH only). Applied here in
  R, not server-side.

- `date_range` — matched client-side against `date_published` (the
  portal's *Algatamise kpv* / initiation date). `date_decision` is
  always `NA` because the portal does not expose a separate decision
  timestamp on the detail page (only per-document dates inside the
  *Dokumendid* table).

## Performance

The two registers are ~500 (KMH) + ~750 (KSH) records, so a cold full
crawl is ~30 index-page fetches plus one detail fetch per record. To
avoid disrupting other users of the service, EE requests are throttled
to 2 requests per second by default — the portal pushes back with a 300
s retry-backoff at 5 req/s under sustained load. Override via
`getOption("planscanR.ee_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_ee(limit = 3, download = FALSE)

# Wind-themed slice
get_assessments_ee(query = "tuulepark", limit = 20, download = FALSE)

# SEA only
get_assessments_ee(assessment_type = "SEA", download = FALSE)
} # }
```
