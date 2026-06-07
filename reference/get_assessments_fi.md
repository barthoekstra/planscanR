# Fetch environmental-assessment records from Finland.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Finland, backed by the national environmental-administration portal
**ymparisto.fi** (<https://www.ymparisto.fi/>), a Drupal + React site
whose site-search is served by an Elasticsearch index exposed through a
same-origin proxy. The register filtered to `type = yva_project` holds
the country's *ympäristövaikutusten arviointi* (YVA) project dossiers —
i.e. project-level environmental impact assessments (EIA).

## Usage

``` r
get_assessments_fi(
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

  Free-text query; sent server-side as a `match` on the ES `content` +
  `title` fields.

- assessment_type:

  One of `"All"` (default) or `"EIA"`. The Finnish register is
  YVA/EIA-only, so both select the same single `yva_project` register;
  `"SEA"` is rejected.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Scope — EIA / YVA only (no SEA)

**This handler delivers EIA (YVA) records only.** The ymparisto.fi
search index has no SOVA / SEA (*suunnitelmien ja ohjelmien vaikutusten
arviointi*) content type — `yva_project` is the only project type in the
register — so there is no plan/programme-level strategic assessment to
fetch here. The `assessment_type` argument therefore accepts only
`"All"` / `"EIA"` (both meaning the same thing); there is no `"SEA"`
path. If a Finnish SOVA/SEA register surfaces later it would be a
separate handler.

## URL enumeration

The portal proxies raw Elasticsearch Query DSL: a `POST` to
`https://www.ymparisto.fi/fi/app/search/query` with a JSON body. The
handler filters to `{"query":{"term":{"type":"yva_project"}}}` and
paginates with ES `from` / `size` against a stable `sort`
(`[{"id":"asc"}]`). The ~1,334 YVA records sit comfortably under the
10,000 `max_result_window`, so simple from-paging covers the whole
register. `hits.total.value` carries the count; each result is a
`hits.hits[]._source` object. A free-text `query` is added as a
`bool.must` `match` on `content` + `title`. The proxy is an open
passthrough that returns a Drupal HTTP 500 on a malformed body, so only
read-shaped queries (`query` / `from` / `size` / `sort`) are sent and
every parse is defensive.

## Geometry

None. Neither the search index nor the landing page exposes coordinates,
so no geometry columns are emitted.

## Attachments

Attachment URLs are **not** in the Elasticsearch index — they live only
on the HTML landing page. For each kept record the handler GETs the
record's `url` (the `link` page) and scrapes every `<a href>` under
`/sites/default/files/` (restricted to that path to skip CSS/JS noise),
resolving them to absolute
`https://www.ymparisto.fi/sites/default/files/documents/<file>.{pdf,doc,docx}`
URLs. Files are anonymous (no auth). Because the URLs come from the
HTML, this detail fetch runs even when `download = FALSE` (to *populate*
`attachment_urls`); it is skipped only when a sidecar already exists for
the URL (sidecar-first).

Documents are typed by their **anchor text** (the page has no structured
section markup) via a curated keyword map with an auto-slug fallback:
`arviointiohjelma` → `programme`, `arviointiselostus` → `report`,
`lausunto` → `statement`, `kuulutus` → `notice`, `tiivistelma` →
`summary`; anything else is auto-slugged from the anchor text. Each
discovered type becomes one `attachment_urls_<slug>` /
`local_path_<slug>` list-column. `attachment_urls` / `local_path` remain
the deduplicated union (required by the schema).

## Summary

`summary` is taken from the Elasticsearch index `description` when
present. Some records leave that field blank even though the landing
page renders a project description; for those the handler falls back to
the prose in `div.page-content__content div.text-long` on the same
detail fetch already made for attachments (issue \#11). A *second*
`div.text-long` in the page footer holds site boilerplate and is
deliberately excluded by scoping the selector to the content region.
Records with neither an index `description` nor a landing-page
description keep `summary = NA` (valid).

## Filter coverage (v0.1)

- `query` — server-side free-text (`bool.must` `match` on `content` +
  `title` in the ES body).

- `assessment_type` — `"All"` (default) or `"EIA"`; both crawl the
  single `yva_project` register. No `"SEA"` (none in the register).

- `date_range` — matched client-side against `date_published`
  (`publishTime`, a unix-seconds epoch). `date_decision` is always `NA`:
  the index has no structured decision timestamp.

## Performance

One ES page enumerates 100 records; the ~1,334 per-record HTML
landing-page GETs (needed to harvest attachment URLs) dominate a cold
crawl. To avoid disrupting the service, FI requests are throttled to 5
requests per second by default; override via
`getOption("planscanR.fi_throttle_rate")` (requests/sec; falsy
disables). A Swedish `/sv/` index exists but is ignored in v0.1 — the
handler defaults to the Finnish `/fi/` index.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_fi(limit = 3, download = FALSE)

# Wind-themed slice (server-side full-text)
get_assessments_fi(query = "tuulivoima", limit = 20, download = FALSE)
} # }
```
