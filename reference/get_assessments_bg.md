# Fetch environmental-assessment records from Bulgaria.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Bulgaria. Backed by the Ministry of Environment and Water (МОСВ)
public registers hosted at `registers.moew.government.bg`, which publish
two adjacent registers:

## Usage

``` r
get_assessments_bg(
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

  Free-text query forwarded as `projectName` (project/plan name
  substring match).

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

- **ОВОС** — *Оценка на въздействието върху околната среда*
  (project-level EIA), `https://registers.moew.government.bg/ovos/`.

- **ЕО** — *Екологична оценка* (plan/programme SEA),
  `https://registers.moew.government.bg/eo/`.

Both registers are merged into a single result tibble; an
`assessment_type` column (`"EIA"` for ОВОС, `"SEA"` for ЕО) tags each
row and is round-tripped to the sidecar so downstream tooling can tell
them apart without re-fetching anything. `document_id` is prefixed with
`"OVOS-"` / `"EO-"` (e.g. `"OVOS-21617"`, `"EO-44841"`) so the two
registers never collide on disk.

## URL enumeration

The registers are server-rendered ASP.NET MVC pages (no SPA, no
viewstate). Index listings paginate via a numeric `offset` plus a
`limit` query parameter (`?offset=<n>&limit=<k>`); each page is one HTML
GET listing the dossier number, incoming number, project/plan name,
proponent, applicable procedure, and status. The page text *Намерени
досиета.* ("Found N dossiers") is the authoritative total. Detail pages
live at `/ovos/lot/<id>` (ОВОС) and `/eo/lot/<id>` (ЕО) and carry every
field a downstream classifier needs.

## Geometry

The МОСВ registers expose **no** coordinates or GeoJSON anywhere —
location is administrative text only (Област / Община / Населено място).
No geometry columns are emitted.

## Attachments

Detail pages render document links inline inside the lot table's value
cells, of the form
`https://registers.moew.government.bg/ovos/file?fileKey=<uuid>&fileName=<name>`
(and `/eo/file?...`). The `fileName` query parameter is required by the
server, so the handler captures the full href as rendered rather than
reconstructing it. Downloads are anonymous (no authentication).
Documents are typed only by the table-row label they sit under
(Уведомление, Описание, Писмо, …); the handler slugs that label into an
`attachment_urls_<slug>` / `local_path_<slug>` list-column. The
deduplicated union goes into `attachment_urls` / `local_path` (required
by the schema).

## Filter coverage (v0.1)

- `query` — server-side substring match on the project/plan name,
  forwarded as `projectName`.

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (ОВОС only), or `"SEA"` (ЕО only). Applied here in
  R.

- `date_range` — matched client-side against `date_published` (the
  dossier submission date). `date_decision` is the termination-decision
  date (*Дата на решението за прекратяване*) when present, else `NA`.

## Performance

The two registers are ~35,000 (ОВОС) + ~10,000 (ЕО) records, so callers
almost always pass `limit` and/or `query`. Detail fetches are slow (~4 s
server-side), so BG requests are throttled to 2 requests per second by
default to stay polite to a government host. Override via
`getOption("planscanR.bg_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_bg(limit = 3, download = FALSE)

# Wind-themed slice
get_assessments_bg(query = "вятър", limit = 20, download = FALSE)

# SEA only
get_assessments_bg(assessment_type = "SEA", limit = 5, download = FALSE)
} # }
```
