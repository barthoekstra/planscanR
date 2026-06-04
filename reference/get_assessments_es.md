# Fetch environmental-assessment records from Spain.

Implementation of
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
for Spain. Backed by the **MITECO / SABIA** public consultation portal
*Consulta pública de evaluaciones ambientales* on the electronic
headquarters (<https://sede.miteco.gob.es>). It covers the
**national-competence** environmental assessments only — most Spanish
EIA is decided by the autonomous communities and lives in their regional
registers, which are out of scope here.

## Usage

``` r
get_assessments_es(
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
  codigo = NULL,
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

  Optional free-text title query (server-side + client-side).

- codigo:

  Optional exact expediente code filter (server-side + client-side).

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

The portal publishes two adjacent registers behind the same Liferay
backend, merged into a single result tibble and selected via an
`assessment_type` argument:

- **EIA** — *Evaluación de Impacto Ambiental de proyectos*, reached
  through the `navServicioContenido` origin (`register = "proyectos"`).

- **SEA** — *Evaluación Ambiental Estratégica de planes y programas*,
  reached through the `navSabiaPlanes` origin (`register = "planes"`).

An `assessment_type` column (`"EIA"` / `"SEA"`) tags each row and is
preserved in the offline metadata cache; a `register` column carries the
raw register label (`"proyectos"` / `"planes"`). `document_id` is
prefixed `"EIA-"` / `"SEA-"` (e.g. `"EIA-20210330"`) so the two
registers never collide on disk.

## Requires the optional {chromote} headless-browser transport

**This is the only handler in the family that cannot run on a pure-R
install.** The SABIA portal *TLS-fingerprints* the client: `libcurl`'s
ClientHello is rejected before any HTTP is exchanged, so `httr2` cannot
even complete the handshake. The handler therefore reaches the portal
exclusively through the optional headless-browser transport (a real
headless Chrome driven by the **{chromote}** package, listed in
`Suggests`). The browser navigates to the portal origin — clearing the
TLS gate the way a real browser does and establishing the Liferay
session cookie — and then runs the portal's own `fetch()` / form
submissions in-page so every request rides Chrome's TLS stack and
cookies. All parsing stays in R.

If {chromote} or a Chrome/Chromium binary is not available the handler
aborts up front with an actionable message (class
`planscanR_error_browser_unavailable`). Install {chromote} and Google
Chrome (or set `options(planscanR.chrome_path=)` / the `CHROMOTE_CHROME`
environment variable) to enable it. **Every other country works without
a browser.**

## URL enumeration

One session per register. The handler opens the register's origin (which
clears the TLS gate and sets the session cookie), harvests the
per-session `datosPropios` token from the search form, and issues a
single bulk `accion=proy_resultados` POST. The response is a
multi-megabyte page whose `<table id="tablaResultados">` carries
**every** record as a row of
`expediente code | title | estado de tramitación`. The handler parses
all rows in R, respecting the global `limit`, and reuses the same
session for the per-record document-panel (*ficha*) navigation.

## Attachments

The portal's document URLs are **session-bound and ephemeral** — a
`BINARYPORTLET resource.process` URL is valid only inside the live
session that rendered the *Acceso a la Documentación* panel (it carries
per-render `javax.portlet.sync` tokens), and the PDFs are themselves on
the TLS-fingerprinted host. So the handler does **not** persist those
live URLs. Instead it stores a stable synthetic identity URL per
document (`<origin>#<code>/<NOMBRE_SABIA>`) in `attachment_urls`,
grouped by the portal's *Tipo de documento* into
`attachment_urls_<slug>` columns (the slug is the ASCII-folded
document-type label). When `download = TRUE`, the handler navigates the
live session to the record's *listadoDocumentacion* page, resolves each
synthetic URL to the live resource URL in the DOM, and pulls the bytes
in-session via the browser (`browser_download()`), honouring
`max_file_size_mb`. A record whose ficha exposes no documents yields an
empty `attachment_urls` vector, which is valid.

## Geometry

None. SABIA exposes no public per-record geometry (no WMS/WFS), so
`geometry_path` / `geometry_crs` are never set.

## Filter coverage (v0.1)

- `assessment_type` — selects which register(s) to crawl: `"All"`
  (default), `"EIA"` (proyectos), or `"SEA"` (planes).

- `query` — a free-text title substring. Forwarded into the server-side
  `xml` *Buscador* `<Titulo>` filter, and also re-checked client-side.

- `codigo` — an exact expediente code, forwarded into the `xml`
  `<Codigo>` filter (and re-checked client-side).

- `date_range` — matched client-side; the listing carries no dates, so
  this drops every record unless a ficha-derived date is present (rare),
  matching the other metadata-light handlers.

- `limit` — caps the total number of records returned across both
  registers.

## Performance

The list is one bulk POST per register (the full ~7,760-project page).
The per-record ficha navigation is several in-page form submissions, so
it is slow; a `Sys.sleep` of
`getOption("planscanR.es_throttle_rate", 2)` seconds is inserted between
ficha fetches. Repeat runs are sidecar-first, so the ficha navigation is
skipped for records already cached.

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Examples

``` r
if (FALSE) { # \dontrun{
# Requires {chromote} + a Chrome/Chromium binary.
get_assessments_es(limit = 3, download = FALSE)

# SEA only (planes register)
get_assessments_es(assessment_type = "SEA", limit = 10, download = FALSE)

# Title substring + download the national-competence PDFs through the browser
get_assessments_es(query = "eólica", limit = 5, download = TRUE)
} # }
```
