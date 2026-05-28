# Fetch environmental-assessment records from the Netherlands.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the Netherlands. Backed by the Commissie m.e.r. adviezenregister at
<https://www.commissiemer.nl/adviezen/>. URL enumeration uses the
portal's published sitemap (`advice-sitemap*.xml`); per-record metadata
is parsed from each detail page with rvest. Free-text and date-range
filters are applied client-side as records are parsed; taxonomy filters
(`theme`, `advice_type`, `status`) are accepted for forward
compatibility but **not yet honoured** in v0.1 — see the "Filter
coverage" section below.

## Usage

``` r
get_assessments_nl(
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
  theme = NULL,
  advice_type = NULL,
  status = NULL,
  province = NULL,
  query = NULL,
  ...
)
```

## Arguments

- date_range:

  Length-2 vector `c(from, to)` of dates or parseable strings. Filters
  by `date_decision`. `NULL` (default) returns all dates.

- limit:

  Integer. Maximum records to return. Defaults to `Inf`; you are
  strongly encouraged to set a small value (e.g. `50`) when exploring.

- download:

  Logical. Download PDF attachments? Default `TRUE`.

- cache_dir:

  Optional cache root. Defaults to
  `tools::R_user_dir("planscanR", "cache")`.

- overwrite:

  Logical. If `TRUE`, re-download attachments that are already cached.
  Cached files (non-empty, present on disk) are otherwise skipped and
  reported with `status = "cached"` in `download_status`.

- max_file_size_mb:

  Numeric cap (in MiB) on per-file download size. See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  for details.

- write_sidecar:

  Logical. Persist a `<document_id>.meta.json` per record alongside its
  attachments. Use
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
  to reread.

- refresh:

  Logical. If `FALSE` (default), records whose URL already has a sidecar
  JSON on disk are loaded directly from JSON — no detail-page HTTP
  fetch. Set `TRUE` to force a fresh fetch (e.g. after the portal
  actually changed something).

- topic, relevance_threshold, relevance_model:

  Forwarded from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
  When `topic` is supplied, each candidate record is scored, and every
  scored record is sidecar'd and returned regardless of threshold.
  `relevance_threshold` is a **download-gate only**: records below
  threshold keep their sidecar + tibble row but their PDFs are not
  downloaded.

- theme, advice_type, status, province:

  Character vectors. See "Filter coverage". For `theme`, `advice_type`,
  `status` the valid slugs are in
  `get_assessments_coverage()$facets[[1]]`.

- query:

  Free-text search string (substring match on title + URL slug).

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the schema.

## Filter coverage (v0.1)

The Commissie m.e.r. portal's taxonomy values (theme, advice type,
status) are driven by a JavaScript FacetWP layer that does not yield to
programmatic access without a browser session. As a result, this version
applies only the filters that are extractable from each detail page:

- `query` — case-insensitive substring match against the title and URL
  slug

- `date_range` — matches against `date_decision` (the "Laatste advies
  uitgebracht op" field)

- `province` — substring match against `competent_authority` (e.g.
  `province = "Groningen"` matches "Provincie Groningen")

The arguments `theme`, `advice_type`, and `status` are accepted (and
validated against the vocabularies in
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md))
but currently emit a one-shot warning when supplied. A future release
will wire these through to a working portal-side filter path.

## Performance

The portal hosts ~3600 advisory records. Each detail page is fetched
once and cached via httr2 for `getOption("planscanR.cache_ttl")` seconds
(default 1 h), so repeat runs are fast. **However**, on a cold cache,
enumerating the full register can take many minutes and downloading
every attachment can use significant disk space. Always start with a
`limit` (and ideally a `query`) when exploring.

To avoid stressing the server (commissiemer.nl returns HTTP 429 under a
sustained burst), NL requests are throttled to one per second by default
— i.e. a ~1 s delay between detail-page fetches. The rate is
configurable via `getOption("planscanR.nl_throttle_rate")`
(requests/sec); set it to a falsy value to disable. The throttle is
scoped to NL only.

## Attachments

per-page split: Each advice detail page on commissiemer.nl groups PDFs
into two on-page sections, which this handler exposes as separate
list-columns:

- `attachment_urls_source` / `local_path_source` — files in the
  **"Documenten waarop het advies is gebaseerd"** section. These are the
  underlying EIA/SEA reports submitted by the proponent and reviewed by
  the Commissie. **These are the substantive documents for downstream
  analysis** (e.g. for the future
  [`classify_assessments()`](https://barthoekstra.github.io/planscanR/reference/classify_assessments.md)
  LLM pipeline).

- `attachment_urls_advice` / `local_path_advice` — files in the
  **"Adviezen en persberichten"** section: the Commissie's own advisory
  reports and press releases.

- `attachment_urls` / `local_path` — the union of both (deduplicated),
  ordered with source documents first. Required by the planscanR schema.

When `download = TRUE`, all files in both sections are fetched.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_nl(limit = 3, download = FALSE)

# Free-text query: any advice with "wind" in the title or slug
get_assessments_nl(query = "wind", limit = 10, download = FALSE)

# Date range
get_assessments_nl(
  date_range = c("2024-01-01", "2024-12-31"),
  limit = 20,
  download = FALSE
)
} # }
```
