# Fetch environmental-assessment records from Latvia.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Latvia. Backed by the Environmental State Bureau (*Vides
pārraudzības valsts birojs*) portal at <https://www.eva.gov.lv/>, a
server-rendered Drupal site. The portal exposes two **structurally
different** halves, merged into a single result tibble and selected via
an `assessment_type` argument:

## Usage

``` r
get_assessments_lv(
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

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Selects which half
  (Views listing / SEA sub-pages) to crawl.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

- **EIA** — *Ietekmes uz vidi novērtējums* (project-level EIA). A Drupal
  Views listing at
  `https://www.eva.gov.lv/lv/ietekmes-uz-vidi-novertejumu-projekti?page=N`
  whose rows each link to a per-project detail page.

- **SEA** — *Stratēģiskais ietekmes uz vidi novērtējums* (plan/programme
  SEA). Three flat sub-pages — `/lv/atzinumi` (opinions), `/lv/lemumi`
  (decisions), `/lv/monitorings` (monitoring) — each listing documents
  as direct `/lv/media/{id}/download?attachment` PDF links.

An `assessment_type` column (`"EIA"` / `"SEA"`) tags each row and is
preserved in the offline metadata cache so downstream tooling can tell
them apart without re-fetching anything; a `register` column carries the
raw sub-register label (`"ivn-projekti"` for EIA; `"atzinumi"` /
`"lemumi"` / `"monitorings"` for SEA). `document_id` is prefixed per
register (`"IVN-"`, `"ATZ-"`, `"LEM-"`, `"MON-"`) so the registers never
collide on disk.

## URL enumeration

The portal is server-rendered HTML (no JSON API). The two halves are
enumerated differently:

- **EIA** — the Views listing paginates via a **0-indexed** `?page=N`
  query parameter (~20 records per page). The portal's exposed-form
  filters are POST/AJAX (a GET `?combine=` is ignored), so this handler
  does a full crawl `?page=0,1,2,…`, stopping when a page yields no
  records. Each row links to a per-project detail page (sidecar-first).

- **SEA** — each of the three flat sub-pages is fetched once. They are
  year-grouped HTML tables (no pagination, no detail pages) whose rows
  carry a direct `/lv/media/{id}/download?attachment` PDF link, a
  document number, a date, and the planning-document title.

## Geometry

None. The portal exposes location only as Latvian prose (cadastral
numbers, parishes, municipalities), surfaced for EIA records in the
`location` extra column. No coordinate geometry is available, so
`geometry_path` / `geometry_crs` are never set.

## Attachments

The two halves differ fundamentally:

- **EIA — metadata-only.** EIA detail pages carry metadata but **no
  downloadable document attachments** (decisions are referenced as prose
  / numbers). Every EIA record therefore has
  `attachment_urls = character(0)`; documents are filled in downstream
  by
  [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
  (`discover = TRUE`).

- **SEA — direct PDFs.** Each SEA sub-page row links to a public PDF at
  `https://www.eva.gov.lv/lv/media/{id}/download?attachment` (no
  authentication; the server returns `application/pdf`). One attachment
  per record.

Because the EIA half is metadata-only, the country's
`get_assessments_coverage()$status` starts with
`"supported (metadata-only`, which is the marker
[`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
keys on.

## Filter coverage (v0.1)

- `assessment_type` — selects which half to crawl: `"All"` (default),
  `"EIA"` (the Views listing), or `"SEA"` (the three sub-pages). Applied
  here in R; the portal's own filters are POST/AJAX and not honoured.

- `query` — matched client-side as a case-insensitive substring of the
  record title.

- `date_range` — matched client-side against `date_published` /
  `date_decision`. A record whose date is `NA` is dropped only when a
  `date_range` is explicitly set (matching the other handlers); SEA
  monitoring entries that carry no date are kept when no `date_range` is
  given.

- `limit` — caps the total number of records returned across all crawled
  registers.

## Performance

The EIA register is a few hundred projects across ~20-record pages; the
three SEA sub-pages are single fetches each. To be polite to the shared
government portal, LV requests are throttled to 5 requests per second by
default; override via `getOption("planscanR.lv_throttle_rate")`
(requests/sec; falsy disables). A `limit` keeps cold runs bounded;
repeat runs are sidecar-first.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_lv(limit = 3, download = FALSE)

# SEA only (the three flat sub-pages, with direct PDFs)
get_assessments_lv(assessment_type = "SEA", limit = 10, download = TRUE)

# Title substring
get_assessments_lv(query = "veja", limit = 20, download = FALSE)
} # }
```
