# Changelog

## planscanR 0.0.0.9000

First development version: a pure-R fetcher for environmental-assessment
records (Environmental Impact Assessments, Strategic Environmental
Assessments, and related advice) from European government portals.

### Fetching

- [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  is the single entry point — it dispatches on a two-letter country code
  and returns a tidy table with a stable set of core columns (`country`,
  `source_portal`, `document_id`, `url`, `retrieved_at`, `title`,
  `summary`, `attachment_urls`, `local_path`, …).
  [`bind_results()`](https://barthoekstra.github.io/planscanR/reference/bind_results.md)
  stacks results from several countries.
- 22 countries are supported: Netherlands, Germany, France, Austria,
  Denmark, Belgium (Flanders), Estonia, Finland, Bulgaria, the Czech
  Republic, Croatia, Greece, Iceland, Ireland, Slovenia, Portugal, the
  United Kingdom, Italy, Slovakia, Norway, Latvia, and Spain. Coverage,
  honoured filters, geometry, and per-portal quirks differ by country —
  see
  [`vignette("supported_sources")`](https://barthoekstra.github.io/planscanR/articles/supported_sources.md)
  and
  [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).
- Slovenia
  ([`get_assessments_si()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_si.md)):
  fetches from the gov.si environmental-assessment registers via their
  bulk JSON exports — the EIA screening register plus the two SEA (CPVO)
  registers, merged with an `assessment_type` / `register` dual-register
  tag. EIA attachments are scraped from each record’s detail page;
  SEA/CPVO attachments are joined from the register’s paginated listing
  table (see Bug fixes).

### Bug fixes

- Slovenia SEA/CPVO attachments are now complete
  ([\#17](https://github.com/barthoekstra/planscanR/issues/17)). The two
  CPVO registers have no per-record detail page — every record is a row
  in a listing table paginated by `?start=` — so the previous code only
  ever read listing page 1 and stapled the same page-1 files onto every
  record. CPVO attachments are now crawled across all listing pages and
  joined to each record by title, so every record gets its own files
  (`/assets/seznami/` **and** `/assets/ministrstva/`). Caches built
  before this fix hold incorrect CPVO `attachment_urls`; re-run the
  affected records once with `refresh = TRUE` to heal them — no download
  is needed, since the corrected URLs are written to the sidecar even at
  `download = FALSE`.
- Portugal
  ([`get_assessments_pt()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_pt.md)):
  fetches from the APA SIAIA register at `siaia.apambiente.pt` — the
  **AIA** (project-level EIA) register only (SEA/AAE lives in a separate
  APA register, so there is no `assessment_type`). Walks the paginated
  server-rendered HTML listing, reads each detail page, and groups the
  direct `AIADOC` PDFs/ZIPs into per-phase `attachment_urls_<slug>`
  columns (DIA / EIA / consulta pública / parecer / outros). No geometry
  (location is concelho text); `query` and `date_range` are matched
  client-side.
- United Kingdom
  ([`get_assessments_gb()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_gb.md)):
  fetches from the Planning Inspectorate’s National Infrastructure
  Consenting register at `planninginspectorate.gov.uk` — **NSIP only**
  (every Nationally Significant Infrastructure Project carries a
  statutory Environmental Statement, so there is no `assessment_type`;
  local-authority EIAs are out of scope). Enumerates the whole register
  from one bulk CSV export, scrapes each project’s Environmental
  Statement PDFs from `nsip-documents.*`, and writes an OSGB
  (EPSG:27700) point geometry sidecar from each project’s grid
  reference. `query`, `status`, and `date_range` are matched
  client-side; the portal’s 10 s `robots.txt` crawl-delay is honoured
  (0.1 req/s default).
- Italy
  ([`get_assessments_it()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_it.md)):
  fetches from the MASE *Valutazioni e Autorizzazioni Ambientali* portal
  at `va.mite.gov.it` — the VIA (project EIA) and VAS (plan SEA)
  registers, merged with an `assessment_type` / `register` dual-register
  tag. Walks each register’s paginated server-rendered HTML listing,
  reads each Info detail page (proponent, procedure timeline, *Esito*,
  and the *Regioni* / *Province* / *Comuni* text), and groups the direct
  `/File/Documento` PDFs into per-*Sezione* `attachment_urls_<slug>`
  columns. No geometry (location is text); `query` and `date_range` are
  matched client-side.
- Slovakia
  ([`get_assessments_sk()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_sk.md)):
  fetches from the Slovak EIA/SEA central information system
  **enviroportal.sk** — a React SPA over a Symfony API Platform JSON
  backend, reached with pure `httr2` plus the
  `Accept: application/ld+json` header. The single `eia_projects`
  collection mixes project EIA and plan/programme SEA records, tagged
  with an `assessment_type` / `register` dual-register flag derived from
  the `zbierka` law string (`"časť EIA"` / `"časť SEA"`). The list
  endpoint’s `hydra:member` is an array of arrays, so the handler
  flattens one level and paginates until a page yields no records;
  per-record detail JSON groups the direct `/eia/dokument` PDFs by
  procedural step into per-section `attachment_urls_<slug>` columns. No
  geometry; `assessment_type`, `query`, and `date_range` are matched
  client-side.
- Norway
  ([`get_assessments_no()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_no.md)):
  fetches from the NVE (*Norges vassdrags- og energidirektorat*)
  energy/water concession-case register (`konsesjonssaker`) at
  **nve.no** — a plain JSON list API plus server-rendered detail HTML,
  reached with pure `httr2`. The getall list endpoint returns a
  `Licenses` array (and inline filter-vocab facets); the handler sends
  `type=0` (“Alle typer”) so the crawl spans **all** licensed
  technologies — hydropower, wind, solar, offshore wind, grid, district
  heating and others (a record’s code is kept in `case_type_code`) — and
  paginates a wide `pageSize` until a page returns no records. There is
  one concession register (no `assessment_type` split — every case
  carries the *konsekvensutredning* EIA among its documents).
  Attachments are scraped from the detail page’s `div.n-filelist`
  sections — `webfileservice.nve.no` PDFs grouped by section heading
  into per-section `attachment_urls_<slug>` columns; EIA docs are
  identified by filename. No geometry; `query` is forwarded server-side
  as the API `filterText` param, `date_range` matched client-side.
  Conservatively throttled to ~20 s between requests, honouring NVE’s
  `robots.txt` crawl-delay (overridable via
  `getOption("planscanR.no_throttle_rate")`).
- Latvia
  ([`get_assessments_lv()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_lv.md)):
  fetches from the Environmental State Bureau (*Vides pārraudzības
  valsts birojs*) Drupal portal at **eva.gov.lv** — an **asymmetric dual
  register** reached with pure `httr2`. The EIA half (*Ietekmes uz vidi
  novērtējums*) is a Drupal Views listing
  (`/lv/ietekmes-uz-vidi-novertejumu-projekti?page=N`, **0-indexed**,
  full crawl until an empty page) whose per-project detail pages are
  **metadata-only** — they carry no document attachments, so EIA records
  leave `attachment_urls` empty and documents are filled in downstream
  by
  [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md).
  The SEA half (*Stratēģiskais IVN*) is three flat sub-pages —
  `/lv/atzinumi` (opinions), `/lv/lemumi` (decisions), `/lv/monitorings`
  (monitoring) — each listing documents as **direct
  `/lv/media/{id}/download?attachment` PDF links** that become the
  record’s attachment. The `assessment_type` argument (`"All"` / `"EIA"`
  / `"SEA"`) selects which half to crawl; `document_id` is prefixed per
  register (`IVN-` / `ATZ-` / `LEM-` / `MON-`). No geometry; `query` and
  `date_range` are matched client-side (the portal’s own filters are
  POST/AJAX). Latvian. Throttled to 5 req/s by default
  (`getOption("planscanR.lv_throttle_rate")`).
- Spain
  ([`get_assessments_es()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_es.md)):
  fetches the national-competence environmental assessments from the
  MITECO/SABIA *Consulta pública de evaluaciones ambientales* portal at
  **sede.miteco.gob.es**. This is the first handler that needs the
  **optional [chromote](https://rstudio.github.io/chromote/)
  headless-browser transport**: the portal *TLS-fingerprints* the client
  and rejects `libcurl`’s handshake outright, so it is reachable only
  through a real headless Chrome (clearing the TLS gate and riding
  Chrome’s TLS + session cookies for the portal’s own in-page requests).
  The dependency is strictly optional — the handler gates on
  `browser_available()` and aborts with an actionable message (class
  `planscanR_error_browser_unavailable`) when
  [chromote](https://rstudio.github.io/chromote/) or a Chrome binary is
  absent; **every other country still works without a browser**. It is a
  **dual register** (`assessment_type` = `"All"` / `"EIA"` / `"SEA"`):
  EIA via the *proyectos* origin, SEA via the *planes* origin.
  Enumeration is one bulk `proy_resultados` POST per register (the full
  `tablaResultados` listing); the per-record ficha PDFs (DIA / EsIA /
  resolución / BOE) are reached by two in-page form submits and
  downloaded in-session (their portal URLs are session-bound), grouped
  per *Tipo de documento*. `document_id` is prefixed `EIA-` / `SEA-`.
  National-competence procedures only (most Spanish EIA is regional →
  out of scope); no public geometry. Spanish.
- **Breaking:** `download` now defaults to `FALSE`. Fetching PDF
  documents is opt-in; pass `download = TRUE` to retrieve attachments.
- Portal-native fields are carried through as extra columns with English
  `snake_case` names. The guaranteed core columns and the on-disk shape
  are documented in `dev/spec/contract.md`.

### Offline cache

- Every fetched record is saved to an on-disk offline metadata cache;
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
  reads it back without revisiting the portal, and
  [`clear_cache()`](https://barthoekstra.github.io/planscanR/reference/clear_cache.md)
  removes downloaded files while keeping the cached metadata. The cache
  root resolves through
  [`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md).
- Public helpers
  [`download_to_cache()`](https://barthoekstra.github.io/planscanR/reference/download_to_cache.md),
  [`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md),
  and
  [`resolve_cached_path()`](https://barthoekstra.github.io/planscanR/reference/resolve_cached_path.md)
  fetch or locate a single attachment using the same cache layout as the
  fetcher, so downstream packages need no internals.
- On-disk metadata uses sidecar schema v3: file paths are stored
  relative to the cache root, so a relocated or synced cache still
  resolves.
  [`migrate_sidecars_v3()`](https://barthoekstra.github.io/planscanR/reference/migrate_sidecars_v3.md)
  upgrades an existing cache in one pass, and older (v1/v2) sidecars are
  still read.

### Optional scoring

- Pass `topic` (and `relevance_threshold`) to
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  to score records as they are fetched and gate PDF downloads on the
  score. `relevance_threshold` is a *download gate only* — every record
  still appears in the result and the cache, so re-running with a new
  threshold needs no network. The embedding work is delegated to the
  companion **planscanR.screen** package (an optional dependency); plain
  fetching needs no Python.

### Attachment discovery

- [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
  finds and validates attachment PDFs for portals that do not expose
  them directly, through a pluggable web-search backend
  ([`search_backend_tavily()`](https://barthoekstra.github.io/planscanR/reference/search_backend_tavily.md)).

### Bug fixes

- [`get_assessments_gb()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_gb.md)
  now paginates the full Environmental Statement document list for each
  UK NSIP project instead of capturing only the first page. Large
  projects (e.g. `EN010098`, with over a thousand ES documents)
  previously yielded only a handful of `attachment_urls`; the handler
  now walks every page (`itemsPerPage = 100`) and returns the
  deduplicated union
  ([\#6](https://github.com/barthoekstra/planscanR/issues/6)).
- [`get_assessments_no()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_no.md)
  now incorporates the NVE detail-page case summary into the `summary`
  column. Norwegian records previously always carried `summary = NA`
  even when the `konsesjonssak` page rendered a summary; the handler now
  extracts it from the main content column
  ([\#5](https://github.com/barthoekstra/planscanR/issues/5)).
- [`get_assessments_fi()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_fi.md)
  now falls back to the ymparisto.fi landing-page project description
  for `summary` when the Elasticsearch index omits it. Records whose
  index `description` was blank (e.g. `YVA-1013`) previously carried
  `summary = NA` even though the portal rendered a description; the
  handler now reads it from the page content region
  (`.page-content__content .text-long`), excluding the footer
  boilerplate
  ([\#11](https://github.com/barthoekstra/planscanR/issues/11)).
- [`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md)
  now captures the `summary` on commissiemer.nl detail pages whose intro
  block opens with an empty placeholder paragraph, and on older pages
  that render no intro block at all (falling back to the main content
  block). These layouts previously yielded `summary = NA` even though
  the portal showed a project description
  ([\#12](https://github.com/barthoekstra/planscanR/issues/12)).
