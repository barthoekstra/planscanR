# Fetch environmental-assessment records from France.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for France, backed by the national *Projets-Environnement* portal
(<https://www.projets-environnement.gouv.fr/>), the public diffusion of
project-level environmental files (études d'impact, avis de l'Autorité
environnementale, résumés non techniques, etc.) compiled from the
préfectures' SICODEI workflow.

## Usage

``` r
get_assessments_fr(
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
  theme = NULL,
  native_type = NULL,
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

  Free-text query; sent server-side as `search("<query>")`.

- theme:

  Optional `dc_subject_theme` value (server-side equality), e.g.
  `"ÉNERGIE"`.

- native_type:

  Optional `dc_type` value (server-side equality), e.g.
  `"Permis de construire"`.

- status:

  Optional `vp_status` value (server-side equality); one of `"ouvert"`,
  `"clos"`, `"non defini"`.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## URL enumeration

Unlike the SPA-behind-a-private-API portals elsewhere in the family,
this one is an **OpenDataSoft Explore API v2.1** platform — a public,
anonymous, documented REST+JSON service. The whole register lives in a
single flat dataset (`projets-environnement-diffusion`, ~5,483 records,
~62 fields each). Every field is inline in each record, so there is no
separate detail call.

Enumeration uses the EXPORT endpoint
(`GET <base>/exports/json?limit=-1`), which has no offset cap and
returns the full filtered set in one JSON array. Server-side filters are
expressed in ODSQL via the `where` parameter: free-text `query` becomes
`search("<query>")`, `theme` / `status` / `native_type` become equality
clauses, and `date_range` becomes a `dc_date >= ... and dc_date <= ...`
window. The stable business key is `recordsid` (used as `document_id`);
the ODS internal hash (`record.id`) is deliberately ignored.

## Geometry

About 1,472 of the ~5,483 records carry a `localisation` field — a full
GeoJSON **Feature** (typically a `MultiPolygon`) returned inline.
OpenDataSoft always serves WGS84, so the CRS is **EPSG:4326**. When
`write_sidecar = TRUE` and a record has a geometry, it is saved next to
the sidecar as `<document_id>.geometry.geojson` (a `FeatureCollection`
wrapping the geometry, with the GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::4326`). The sidecar carries `geometry_path` and
`geometry_crs` (`"EPSG:4326"`). Records without `localisation` leave the
geometry columns `NA`.

## Attachments

Each record exposes a **fixed set of typed document fields**, each
holding a single URL. The handler maps the known fields to stable slugs
(DE-style curated map) and emits one `attachment_urls_<slug>` /
`local_path_<slug>` list-column per field that is populated:

- `dc_relation_expertise_etudeimpact` -\> `etude_impact` (the EIA study
  PDF).

- `dc_relation_synthesis` -\> `resume_non_technique` (résumé non
  technique).

- `dc_relation_expertise_avisae` -\> `avis_ae` (avis de l'Autorité
  environnementale).

- `dc_relation_expertise_reponseavisae` -\> `reponse_avis_ae` (réponse à
  l'avis AE).

- `dc_relation_officialdocument` -\> `dossier` (the `*_DCZIP.zip`
  dossier).

- `dc_relation_decision` -\> `decision`.

- `dc_relation_assessment` -\> `assessment`.

- `dc_relation_expertise_autredoc1..3` -\> `autre_doc_1..3`.

- `dc_relation_expertise_certifbiodiv` -\> `certif_biodiv`.

Only values whose host is `sicodei.projets-environnement.gouv.fr` (or
that end in `.pdf` / `.zip`) are treated as downloadable attachments —
many `dc_relation_*` values point at external préfecture web pages
(HTML), which are kept in extras columns but never enter the attachment
columns. `attachment_urls` / `local_path` are the deduplicated union of
the real document URLs, as required by the planscanR schema.

## Filter coverage (v0.1)

- `query` — server-side full-text (`search("<query>")` in ODSQL).

- `theme` — server-side equality on `dc_subject_theme` (e.g.
  `"ÉNERGIE"`; see
  [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)).

- `native_type` — server-side equality on `dc_type` (e.g. `"AENV"`,
  `"Permis de construire"`).

- `status` — server-side equality on `vp_status` (`"ouvert"`, `"clos"`,
  `"non defini"`).

- `date_range` — server-side window on `dc_date` (publication date).
  `date_decision` is `NA` because the dataset exposes no single decision
  timestamp.

## Performance

One export call enumerates the whole filtered register, so a cold crawl
is cheap. The per-attachment downloads (when `download = TRUE`) hit the
SICODEI blob host. Requests are throttled to 5 requests per second by
default; override via `getOption("planscanR.fr_throttle_rate")`
(requests/sec; falsy disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_fr(limit = 3, download = FALSE)

# Wind-themed slice (server-side full-text)
get_assessments_fr(query = "éolien", limit = 20, download = FALSE)

# Energy theme only
get_assessments_fr(theme = "ÉNERGIE", limit = 20, download = FALSE)
} # }
```
