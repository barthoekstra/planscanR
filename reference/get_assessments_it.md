# Fetch environmental-assessment records from Italy.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Italy. Backed by the Ministero dell'Ambiente e della Sicurezza
Energetica (MASE) portal *Valutazioni e Autorizzazioni Ambientali*
(<https://va.mite.gov.it>), which publishes two adjacent public
registers:

## Usage

``` r
get_assessments_it(
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

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Selects which
  register(s) to crawl.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

- **VIA** — *Valutazione di Impatto Ambientale* (project-level EIA),
  `https://va.mite.gov.it/it-IT/Ricerca/ViaProcedura`.

- **VAS** — *Valutazione Ambientale Strategica* (plan/programme SEA),
  `https://va.mite.gov.it/it-IT/Ricerca/VasProcedura`.

Both registers are merged into a single result tibble; an
`assessment_type` column (`"EIA"` for VIA, `"SEA"` for VAS) tags each
row and is preserved in the offline metadata cache so downstream tooling
can tell them apart without re-fetching anything; a `register` column
carries the raw portal label (`"VIA"` / `"VAS"`). `document_id` is
prefixed with `"VIA-"` / `"VAS-"` (e.g. `"VIA-7917"`, `"VAS-12037"`) so
the two registers never collide on disk.

## URL enumeration

The portal is server-rendered HTML (no JSON API). Each register's search
listing paginates via a 1-based `?pagina=N` query parameter; every page
is one HTML GET that lists the project/plan title, proponent, procedure
type, a detail (*Info*) link and a documentation (*Doc*) link. The page
footer carries a `"Pagina X di Y"` counter. The generator advances
page-by-page until it has passed the last page or a page yields no rows.
Detail pages live at `/it-IT/Oggetti/Info/{id}`; the detail-page parser
is sidecar-first.

## Geometry

None. The portal exposes location only as named Italian text lists
(*Regioni* / *Province* / *Comuni*), surfaced as the `regions`,
`provinces`, and `municipalities` extra columns. No coordinate geometry
is available, so `geometry_path` / `geometry_crs` are never set.

## Attachments

Each record's *Documentazione* index lives at
`/it-IT/Oggetti/Documentazione/{id}/{grp}` (the `{grp}` raggruppamento
id comes from the listing's Doc link or the Info page's procedure
table). It is a paginated `?pagina=N` HTML table whose rows carry a
*Sezione* (category) and a direct, public download link
`https://va.mite.gov.it/File/Documento/{fileId}` (no authentication; the
server returns `application/pdf`). Documents are grouped by their
*Sezione*; the handler emits one `attachment_urls_<slug>` /
`local_path_<slug>` list-column per discovered section (the slug is the
ASCII-folded *Sezione* string) plus the deduplicated union in
`attachment_urls` / `local_path` (required by the schema), following the
DE per-section pattern.

## Filter coverage (v0.1)

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (VIA only), or `"SEA"` (VAS only). Applied here in
  R.

- `query` — matched client-side as a case-insensitive substring of the
  record title. (The portal's own free-text / Procedura search is
  server-side, but client-side filtering is sufficient for v0.1.)

- `date_range` — matched client-side against `date_published` (the
  procedure's *Data avvio* / start date). `date_decision` is the *Data
  Decreto VIA* / decision date parsed from the Info page's procedure
  timeline when present, else `NA`.

- `limit` — caps the total number of records returned across both
  crawled registers.

## Performance

The VIA register is large (~10 600 projects across ~1 060 listing
pages); VAS is far smaller (~270 plans). A cold full crawl is therefore
dominated by VIA listing-page fetches plus one Info + one Documentazione
fetch per record. To be polite to the shared government portal, IT
requests are throttled to 5 requests per second by default; override via
`getOption("planscanR.it_throttle_rate")` (requests/sec; falsy
disables). A `limit` keeps cold runs bounded; repeat runs are
sidecar-first.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_it(limit = 3, download = FALSE)

# SEA only (VAS register)
get_assessments_it(assessment_type = "SEA", limit = 10, download = FALSE)

# Title substring
get_assessments_it(query = "autostrada", limit = 20, download = FALSE)
} # }
```
