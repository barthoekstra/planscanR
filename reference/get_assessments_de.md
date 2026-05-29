# Fetch environmental-assessment records from Germany.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Germany. Backed by the UVP-Verbund portal at
<https://www.uvp-verbund.de/>, a federated catalogue of UVP
(Umweltverträglichkeitsprüfung) procedures published by all
federal-state authorities. URL enumeration uses the portal's own
server-side full-text search (`/freitextsuche`) — there is no XML
sitemap. Per-record metadata is parsed from each detail page with rvest.

## Usage

``` r
get_assessments_de(
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
  jurisdiction = NULL,
  ...
)
```

## Arguments

- date_range:

  Length-2 vector `c(from, to)` of dates or parseable strings. Filters
  by `date_decision`.

- limit:

  Integer. Maximum records to return. Defaults to `Inf`; you are
  strongly encouraged to set a small value (e.g. `50`) when exploring,
  because a cold-cache full crawl enumerates all ~2,258 search pages.

- download, cache_dir, overwrite, max_file_size_mb, write_sidecar,
  refresh:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- topic, relevance_threshold, relevance_model:

  Forwarded from
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
  `relevance_threshold` **only affects downloading**: records below it
  keep their sidecar and their tibble row, only their PDFs are skipped.

- query:

  Free-text search string. Sent server-side as `q=<query>`. When `NULL`,
  the broad fallback `q=uvp` is used (matches ~93% of the register). The
  portal's own `q=*:*` wildcard is unusable because page 2+ never
  renders — see the *URL enumeration* section.

- jurisdiction:

  Character vector. Substring match on the federal-state partner
  displayed on each detail page (e.g. `jurisdiction = "Bayern"` keeps
  Bavarian records).

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the schema.

## URL enumeration

The portal exposes no sitemap, no OAI-PMH, and no CSW endpoint. The only
enumeration route is the search interface itself:

    https://www.uvp-verbund.de/freitextsuche?q=<query>&toggle_procedure=&ranking=score&page=<n>

The portal is Solr-backed but its `q=*:*` wildcard is broken for
pagination: page 1 renders, every subsequent page returns the header but
no results. As a "match-most" fallback when `query` is `NULL` we use
`q=uvp`, which paginates correctly and covers ~93% of the register
(~22,574 of ~24,270 records). For full coverage, run the scan against
multiple seed queries and union the results. `toggle_procedure=` (empty
value) is set explicitly: the portal's default (`toggle_procedure=on`)
restricts results to currently-running plus last-year-modified
procedures and silently drops ~80% of historical records.

On a cold cache, a full enumeration over ~2,258 pages is slow; users are
strongly encouraged to set `limit` (and ideally `query`) when exploring.

## Filter coverage (v0.1)

Only filters that map cleanly to portal-side parameters or to
extractable detail-page fields are active in this version:

- `query` — passed straight through as the server-side `q` parameter
  (real full-text search, not a client-side substring match).

- `date_range` — matches against `date_decision`, which on this portal
  carries the **"Zuletzt geaendert"** date (last-modified timestamp
  shown in the detail page header).

- `jurisdiction` — substring match against the federal-state partner
  (from `div.teaser-logo-partner img[alt]`, e.g. `"Baden-Württemberg"`).

The portal's `procedure=` facet (Zulassungsverfahren, Bauleitplanung,
etc.) is reserved for a future release.

## Attachments

per-page section split: UVP detail pages group documents under
`h4.title-font` headings. The set of headings is **open-ended and
discovered per page** rather than fixed: every heading that carries
documents becomes its own parallel list-column `attachment_urls_<slug>`
/ `local_path_<slug>`, and the per-file `section` tag is persisted in
the sidecar JSON. Known headings get a stable, curated slug; any other
heading is auto-slugged from its title (German digraphs transliterated
to ASCII), so a newly-appearing section type is captured without a code
change.

Curated slugs (see the internal `de_section_map()`):

- `uvp_bericht` — *"UVP-Bericht, ggf. Antragsunterlagen"* (the UVP
  report itself plus the applicant's project documents — the substantive
  documents for downstream analysis).

- `berichte` — *"Berichte und Empfehlungen"* (technical reports and
  recommendations).

- `entscheidung` — *"Entscheidung"* (the decision / Bescheid documents).

- `auslegung` — *"Auslegungsinformationen"* (public-consultation
  notices).

- `weitere` — *"Weitere Unterlagen"* (catch-all section; often very
  large).

`attachment_urls` / `local_path` are the deduplicated union across all
discovered sections, ordered curated-first (in the order above) then any
auto-slugged sections in page order. Required by the planscanR schema.

When `download = TRUE`, files in **all** discovered sections are fetched
— subject to `max_file_size_mb` and the relevance threshold. (The
`data-raw/biogain_acquire.R` runbook can restrict downloads to a chosen
subset of sections; the handler itself always captures them all.)

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_de(limit = 3, download = FALSE)

# Wind-energy search
get_assessments_de(query = "windenergie", limit = 20, download = FALSE)

# Date range
get_assessments_de(
  date_range = c("2024-01-01", "2024-12-31"),
  limit = 20,
  download = FALSE
)
} # }
```
