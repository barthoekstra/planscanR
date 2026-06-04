# Fetch environmental-assessment records from Iceland.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Iceland. Backed by **Skipulagsgátt**
(<https://www.skipulagsgatt.is/>), Skipulagsstofnun's (the National
Planning Agency's) public planning- and environmental- assessment portal
— a Vue SPA over an anonymous **GraphQL** API. This is the package's
first GraphQL-backed handler: the transport is a single HTTP
`POST .../graphql` with a JSON body `{"query": ..., "variables": ...}`,
parsed via the shared JSON seam.

## Usage

``` r
get_assessments_is(
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

  Free-text query forwarded as the GraphQL `search` field.

- assessment_type:

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Selects which
  process(es) to crawl.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Coverage horizon (IMPORTANT)

Skipulagsgátt only carries cases from **roughly June 2023 onward** (the
portal went live then). The older `skipulag.is` / `island.is`
"gagnagrunnur umhverfismats" is dead and is **not** crawled. So this
handler yields a *recent-cases-only* corpus (~235
environmental-assessment issues total at the time of writing). Plan
accordingly.

## Three processes merged (assessment_type)

The portal models every dossier as a unified `Issue`; environmental
assessment lives in three of its `process`es, selected server-side by
`processId`:

- `15` — *Tilkynning til ákvörðunar um matsskyldu* (EIA-track
  screening), tagged `assessment_type = "EIA"`.

- `16` — *Mat á umhverfisáhrifum* (full EIA), tagged
  `assessment_type = "EIA"`.

- `501` — *Umhverfismat áætlana* (SEA), tagged
  `assessment_type = "SEA"`.

The three are merged into one result tibble. `assessment_type`
(`"EIA"`/`"SEA"`) tags each row and round-trips to the sidecar; the
finer distinction is kept in `process_type` / `native_type`. Because the
three processes share the same `Issue.id` space, `document_id` is
prefixed with the process id (`IS-15-<id>`, `IS-16-<id>`, `IS-501-<id>`)
so they never collide on disk. The `assessment_type` argument
(`"All"`/`"EIA"`/`"SEA"`) selects which processes to crawl: `"EIA"` -\>
`{15, 16}`, `"SEA"` -\> `{501}`.

## URL enumeration

The listing is the GraphQL `issueConnection(input, first, after)` cursor
connection
(`{ totalCount, pageInfo{hasNextPage,endCursor}, edges{node} }`),
paginated with `after: endCursor`. `processId` is single-valued per
query, so the handler loops the selected processes. Free-text `query` is
forwarded as the server-side `search` field; `date_range` as `fromDate`
/ `toDate`. Each record's detail is fetched once via
`singleIssue(input:{issueId})`, sidecar-first (a URL already on disk is
read from JSON, never re-fetched). The canonical `url` is
`https://www.skipulagsgatt.is/issues/<id>`.

## Status field gotcha

Record status is read from the plain-string `lifecycle` field (e.g.
`"done"`, `"in_progress"`). The handler deliberately does **not**
request the `issueStatus` enum — it has a server-side serialization bug
that returns HTTP 500 for the whole query on some records.

## Geometry

`Issue.hasGeography` flags whether a record has a footprint;
`Issue.geographies` returns a GraphQL `FeatureCollection` whose
per-feature `geometry` arrives as a **GeoJSON string** needing a second
[`jsonlite::fromJSON`](https://jeroen.r-universe.dev/jsonlite/reference/fromJSON.html)
parse. Point / LineString / Polygon are all observed. Coordinates are
already geographic **WGS84 (EPSG:4326 lon/lat)** — *not* the projected
ISN93 grid — so no reprojection happens. When `write_sidecar = TRUE`,
the (re-parsed) geometry is saved next to the sidecar as
`<document_id>.geometry.geojson` in the family FeatureCollection layout
(GeoJSON-2008 `crs` member naming `urn:ogc:def:crs:EPSG::4326`); the
sidecar carries `geometry_path` and `geometry_crs` (`"EPSG:4326"`).
Records with `hasGeography = false` / an empty collection leave the
geometry columns `NA`.

## Attachments

Documents live under `phases[].files[]`, each an `IssuePhaseFile` with a
semantic-role `type` and a nested `data` `File { path, name, ... }`.
Only files with `published == true` are emitted. They are grouped by
their `IssuePhaseFile.type` into lowercase slugs — `almennt` (general;
incl. the matsskýrsla / EIA report and matsáætlun), `vidbrogd`
(developer responses), and `afgreidsla` (the decision / álit) — one
`attachment_urls_<slug>` / `local_path_<slug>` list-column each, with
the deduplicated union in `attachment_urls` / `local_path` (required by
the schema). The download URL is
`https://www.skipulagsgatt.is/<File.path>` (path of the form
`files/<uuid>`), anonymous. The top-level `Issue.files` collection is
usually empty and is ignored. PDFs are large (often 10-16 MB) — set
`max_file_size_mb` accordingly.

## Filter coverage (v0.1)

- `query` — server-side full-text (GraphQL `search` field).

- `assessment_type` — selects which process(es) to crawl: `"All"`
  (default), `"EIA"` (processes 15 + 16), or `"SEA"` (process 501).
  Applied here by choosing the process loop.

- `date_range` — forwarded server-side as `fromDate` / `toDate`, and
  re-checked client-side against `date_published` (the `publishedDate`).

## Performance

Enumeration is a handful of cursor pages per process plus one
`singleIssue` call per record. IS requests are throttled to 5 requests
per second by default; override via
`getOption("planscanR.is_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test (recent cases only — June 2023 onward)
get_assessments_is(limit = 3, download = FALSE)

# Wind-themed slice (server-side full-text, Icelandic)
get_assessments_is(query = "vindorku", limit = 20, download = FALSE)

# SEA only (umhverfismat áætlana)
get_assessments_is(assessment_type = "SEA", download = FALSE)
} # }
```
