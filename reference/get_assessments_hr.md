# Fetch environmental-assessment records from Croatia.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Croatia. Croatia has **no** machine-readable register or API: the
"register" is a small set of server-rendered ASP.NET CMS pages on the
Ministry of Environment and Green Transition portal (`mzozt.gov.hr`,
formerly `mingor.gov.hr` / `mingo.hr` — old links 30x-redirect to the
new host). Each procedure is an inlined
`<li><strong>PROJECT TITLE</strong> <ul>...document links...</ul></li>`
block with direct, anonymous `.pdf` (sometimes `.zip`) download links.

## Usage

``` r
get_assessments_hr(
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

  Free-text query matched client-side against the project/plan title.

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

Two "registers" are merged into a single result tibble; an
`assessment_type` column (`"EIA"` for PUO, `"SEA"` for SPUO) tags each
row and is preserved in the offline metadata cache so downstream tooling
can tell them apart without re-fetching anything. `document_id` is
prefixed with `"HR-PUO-"` / `"HR-SPUO-"` so the two registers never
collide on disk.

- **PUO** — *Procjena utjecaja zahvata na okoliš* (project-level EIA).
  One master archive page lists every procedure (years 2012–present)
  inline.

- **SPUO** — *Strateška procjena utjecaja na okoliš* (plan/programme
  SEA). Two pages: Ministry-competent procedures and
  other-competent-body procedures.

## URL enumeration

There is **no** pagination, no per-record detail endpoint, and no native
procedure id. The whole record (title + all documents, grouped by stage)
lives inline in one of three master pages. The handler fetches each
master page once and treats each `<li><strong>` block as one record.
Because there is no native id, `document_id` is a stable deterministic
hash of the title (`HR-PUO-<sha1(title)[1:10]>` / `HR-SPUO-...`),
folding in a cleanly-parseable year when present. `url` is the
master-page URL plus `#<document_id>` so each record has a unique
landing URL (required for sidecar reuse) while still pointing a human at
the right page.

## Geometry

The CMS pages expose **no** coordinates or GeoJSON. No geometry columns
are emitted. Spatial information, where present, is inside the PDFs.

## Attachments

Documents are grouped by the stage sub-heading they sit under (PUO
*informacija o zahtjevu* / *javni uvid* / *nacrt rješenja* / *rješenje*;
SPUO procedures often list their documents flat under the title with no
stage sub-heading, which fall under the `document` slug). Known stage
labels get a stable curated slug (see the internal `hr_stage_map()`);
anything else is auto-slugged from the heading (Croatian diacritics
transliterated to ASCII, lowercased, non-alphanumerics collapsed to
underscores). Each stage becomes an `attachment_urls_<slug>` /
`local_path_<slug>` list-column; the deduplicated union goes into
`attachment_urls` / `local_path` (required by the schema).

The `href` is captured verbatim as rendered (with its spaces and
Croatian diacritics). Those characters are percent-encoded for the
network request at download time; the original un-encoded href is what
the sidecar stores. Downloads are anonymous (no authentication). Some
attachments are `.zip`.

## Filter coverage (v0.1)

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (PUO only), or `"SEA"` (SPUO only).

- `query` — client-side substring match on the project/plan title (the
  CMS pages have no server-side search).

- `date_range` — matched client-side against `date_published` (the
  earliest document date in the block). `date_decision` is the
  *rješenje* / *odluka* (decision) date when present, else `NA`.

## Performance

The PUO master page is large (~550 procedures / ~2,500 documents in one
HTML fetch); SPUO is small. Enumeration is only ~3 HTML fetches plus N
PDF downloads, so HR requests are throttled to 5 requests per second by
default (politeness for the download phase). Override via
`getOption("planscanR.hr_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_hr(limit = 3, download = FALSE)

# Wind-themed slice (client-side title match)
get_assessments_hr(query = "vjetroelektrana", limit = 20, download = FALSE)

# SEA only
get_assessments_hr(assessment_type = "SEA", download = FALSE)
} # }
```
