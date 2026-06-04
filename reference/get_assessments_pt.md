# Fetch environmental-assessment records from Portugal.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Portugal. Backed by the *SIAIA* portal of the Agência Portuguesa do
Ambiente (APA), <https://siaia.apambiente.pt/>, which publishes the
national register of **AIA** procedures (*Avaliação de Impacte
Ambiental* — project-level EIA).

## Usage

``` r
get_assessments_pt(
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
  ...
)
```

## Arguments

- date_range, limit, download, cache_dir, overwrite, max_file_size_mb,
  write_sidecar, refresh, topic, relevance_threshold, relevance_model:

  See
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).

- query:

  Optional free-text query. Applied as a client-side case-insensitive
  substring match on the project title.

- ...:

  Reserved for future extensions; unused arguments are warned about.

## Value

A tibble; see
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for the required schema.

## Details

Only the AIA register is in scope. APA runs a separate register for
**AAE** (*Avaliação Ambiental Estratégica* — plan/programme SEA) under a
different application; it is **not** covered here, so there is no
`assessment_type` argument (this is a single-register handler). Every
row is therefore an EIA-equivalent procedure.

SIAIA exposes the project location only as free-text *concelho*
(municipal) names — there is no machine-readable geometry — so no
GeoJSON sidecar is written (unlike the Estonian handler).

## URL enumeration

SIAIA is a server-rendered ASP.NET MVC application. The listing lives at
`https://siaia.apambiente.pt/ProcessoAIA?pagina=<n>` (1-based pages,
~100 rows/page). Each listing row links to a detail page
`/ProcessoAIA/Detalhes/{pro_id}` and a document list
`/ListaDocumentos?pro_id={pro_id}`. The handler walks pages with a page
generator (see `stream_crawl()`); an out-of-range page returns an empty
table body, which terminates the crawl. The canonical record URL is the
detail page `https://siaia.apambiente.pt/ProcessoAIA/Detalhes/{pro_id}`.

Per record, metadata is read from the detail page's *Campo / Conteúdo*
table (sidecar-first via the cache), and attachments from the document
list.

## Attachments

per-phase section split: SIAIA renders each document with a Portuguese
*type* label (e.g. *"DIA - Declaração Impacte Ambiental"*, *"EIA
Relatório Sintese (RS)"*, *"Parecer comissão de avaliação"*, *"Relatório
da consulta pública"*). The portal does not print explicit phase
headings, so the handler derives a coarse **phase** from each label and
groups by it. Phases:

- `dia` — *DIA* (Declaração de Impacte Ambiental — the decision).

- `eia` — *EIA* documents (relatório síntese, RNT, anexos, peças
  desenhadas, projeto, elementos adicionais — the substantive dossier).

- `consulta_publica` — *Consulta Pública* documents.

- `parecer` — *Parecer* documents (e.g. Parecer da Comissão de
  Avaliação).

- `outros` — anything that matches none of the above.

Each phase that carries documents becomes its own parallel list-column
`attachment_urls_<slug>` / `local_path_<slug>` (the slug is
`ascii_slug()` of the phase). `attachment_urls` / `local_path` are the
deduplicated union across all phases (required by the planscanR schema).
PDF URLs are direct and of the form
`https://siaia.apambiente.pt/AIADOC/AIA{n}/{file}.pdf` (some documents
are `.zip` archives — these are kept as attachments too).

## Filter coverage (v0.1)

SIAIA offers server-side authority/year filters, but for v1 every filter
is applied **client-side** for simplicity and predictability:

- `query` — case-insensitive substring match on `title` (the project
  designation).

- `date_range` — matched against `date_decision` when the detail page
  exposes a full *Data da decisão*; for records that only carry a
  decision *year* (the listing's *Ano Decisão*), the year is matched
  against the range instead.

- `limit` — caps the total number of records returned.

## Performance

The register holds a few thousand AIA procedures across a few dozen
listing pages. A cold crawl is one listing GET per page plus one detail
GET per record (sidecar-first, so repeat runs are fast). To be polite to
the shared government portal, PT requests are throttled to 5 requests
per second by default; override via
`getOption("planscanR.pt_throttle_rate")` (requests/sec; falsy
disables).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Quick smoke test
get_assessments_pt(limit = 3, download = FALSE)

# Substring query on the project designation
get_assessments_pt(query = "solar", limit = 20, download = FALSE)

# Date range (matched against the decision date / year)
get_assessments_pt(
  date_range = c("2023-01-01", "2023-12-31"),
  limit = 20,
  download = FALSE
)
} # }
```
