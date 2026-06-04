# Fetch environmental-assessment records from the Czech Republic.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the Czech Republic. Backed by CENIA's *Informační systém EIA/SEA*
(<https://portal.cenia.cz/eiasea/>), a server-rendered JSP application
(Apache Tomcat — not a SPA). Two **domestic** registers are crawled:

## Usage

``` r
get_assessments_cz(
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
  assessment_type = "All",
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- assessment_type:

  One of `"All"` (default), `"EIA"`, or `"SEA"`. Selects which domestic
  register(s) to crawl.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

- **EIA** — *Záměry na území ČR* (project-level EIA on Czech territory),
  `https://portal.cenia.cz/eiasea/view/eia100_cr`.

- **SEA** — *Posuzování koncepcí* (concept / plan SEA),
  `https://portal.cenia.cz/eiasea/view/SEA100_koncepce`.

Both registers are merged into a single result tibble; an
`assessment_type` column (`"EIA"` for *Záměry na území ČR*, `"SEA"` for
*Posuzování koncepcí*) tags each row and is preserved in the offline
metadata cache so downstream tooling can tell them apart without
re-fetching anything. `document_id` is the portal's register-namespaced
detail code, e.g. `"EIA_JHC1237"` / `"SEA_HKK015K"`, so the two
registers never collide on disk (no extra prefix is added).

## Scope (domestic CZ only)

This handler deliberately crawls **only** the two domestic registers
above. The portal also hosts cross-border / foreign registers and
several special sub-registers (`eia100_mimo_cr` — projects outside CZ,
`sea100_mezistatni` — cross-border SEA, the sub-limit /
priority-transport / large-project EIA sub-registers `eia100_podlimitni`
/ `_pdz` / `_vzvp` / `eia244`, and the territorial-planning SEA
sub-registers `sea100_pur*` / `zur*` / `up*`). Those are **never**
enumerated. Note that ministry-coded records (`EIA_MZP*`, `SEA_MZP*`)
inside the two domestic registers *are* in scope — they are domestic
projects/plans assessed by the Ministry, not foreign ones. The two
in-scope view codes are hard-coded.

## URL enumeration

Index listings paginate via a **1-based** `p` query parameter (10
records per page); each page is one HTML GET listing the detail code,
project/plan title, competent authority (*Příslušný úřad*), annex
category (*Zařazení*), last-modified timestamp (*Změněno*), and status
(*Stav*). Detail pages live at `/eiasea/detail/EIA_<CODE>` and
`/eiasea/detail/SEA_<CODE>` and carry every field a downstream
classifier needs. Out-of-range page indices are **clamped to the last
page** by the server (they return the last page's rows again rather than
an empty page), so pagination stops when a page contributes no detail
codes that were not already seen.

## Geometry

The CENIA detail pages expose **no** coordinates or GeoJSON — location
is administrative text only (*Kraj* / *Okres* / *Obec* / *Katastr*). No
geometry columns are emitted.

## Attachments

Detail pages render document links inline inside the detail table's
value cells as
`<a class="entity_field" href="/eiasea/download/<token>/<file>">`. Both
the base64-ish token and the trailing human filename come straight out
of the rendered href, so the handler captures the full href verbatim
rather than reconstructing the token. Downloads are anonymous (no
authentication). Documents are grouped by process-stage headings
(OZNÁMENÍ, ZJIŠŤOVACÍ ŘÍZENÍ, DOKUMENTACE, POSUDEK, VEŘEJNÉ PROJEDNÁNÍ,
STANOVISKO for EIA; the oznámení / vyhodnocení / návrh koncepce /
stanovisko / schválená koncepce fields for SEA). The handler slugs the
nearest stage heading / field label into an `attachment_urls_<slug>` /
`local_path_<slug>` list-column (Czech diacritics transliterated to
ASCII). The deduplicated union goes into `attachment_urls` /
`local_path` (required by the schema).

Some attachments are very large ZIP bundles (e.g. a 79 MB
`oznameni.zip`);
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)'s
`max_file_size_mb` cap is honoured during download, so oversized files
are skipped and recorded as `"skipped_size"` rather than fetched.

## Filter coverage (v0.1)

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (*Záměry na území ČR* only), or `"SEA"`
  (*Posuzování koncepcí* only). Applied here in R.

- `date_range` — matched client-side against `date_published` (the EIA
  *Datum a čas posledních úprav* last-modified date, or the SEA *Datum
  zveřejnění* publication date). `date_decision` is `NA` — the portal
  exposes no single clean decision-date field.

## Performance

The two registers are ~22,780 (EIA) + ~640 (SEA) records, so callers
almost always pass `limit`. To stay polite to the single Tomcat instance
under a large crawl, CZ requests are throttled to 2 requests per second
by default. Override via `getOption("planscanR.cz_throttle_rate")`
(requests/sec; falsy disables).

## Language

Record content is Czech (ISO-639-1 `cs`; note the country code `cz`
differs from the language code). The portal's `lang=en` switch only
flips UI chrome, not record content, so the handler fetches with
`lang=cs`.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_cz(limit = 3, download = FALSE)

# SEA only
get_assessments_cz(assessment_type = "SEA", limit = 5, download = FALSE)
} # }
```
