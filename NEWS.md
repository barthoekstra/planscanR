# planscanR 0.0.0.9000

First development version: a pure-R fetcher for environmental-assessment
records (Environmental Impact Assessments, Strategic Environmental Assessments,
and related advice) from European government portals.

## Fetching

* `get_assessments()` is the single entry point — it dispatches on a two-letter
  country code and returns a tidy table with a stable set of core columns
  (`country`, `source_portal`, `document_id`, `url`, `retrieved_at`, `title`,
  `summary`, `attachment_urls`, `local_path`, …). `bind_results()` stacks
  results from several countries.
* 19 countries are supported: Netherlands, Germany, France, Austria, Denmark,
  Belgium (Flanders), Estonia, Finland, Bulgaria, the Czech Republic, Croatia,
  Greece, Iceland, Ireland, Slovenia, Portugal, the United Kingdom, Italy, and
  Slovakia.
  Coverage, honoured filters, geometry, and per-portal quirks differ by
  country — see `vignette("supported_sources")` and
  `get_assessments_coverage()`.
* Slovenia (`get_assessments_si()`): fetches from the gov.si
  environmental-assessment registers via their bulk JSON exports — the EIA
  screening register plus the two SEA (CPVO) registers, merged with an
  `assessment_type` / `register` dual-register tag; attachments are scraped
  from each record's detail page.
* Portugal (`get_assessments_pt()`): fetches from the APA SIAIA register at
  `siaia.apambiente.pt` — the **AIA** (project-level EIA) register only (SEA/AAE
  lives in a separate APA register, so there is no `assessment_type`). Walks the
  paginated server-rendered HTML listing, reads each detail page, and groups the
  direct `AIADOC` PDFs/ZIPs into per-phase `attachment_urls_<slug>` columns
  (DIA / EIA / consulta pública / parecer / outros). No geometry (location is
  concelho text); `query` and `date_range` are matched client-side.
* United Kingdom (`get_assessments_gb()`): fetches from the Planning
  Inspectorate's National Infrastructure Consenting register at
  `planninginspectorate.gov.uk` — **NSIP only** (every Nationally Significant
  Infrastructure Project carries a statutory Environmental Statement, so there
  is no `assessment_type`; local-authority EIAs are out of scope). Enumerates
  the whole register from one bulk CSV export, scrapes each project's
  Environmental Statement PDFs from `nsip-documents.*`, and writes an OSGB
  (EPSG:27700) point geometry sidecar from each project's grid reference.
  `query`, `status`, and `date_range` are matched client-side; the portal's
  10 s `robots.txt` crawl-delay is honoured (0.1 req/s default).
* Italy (`get_assessments_it()`): fetches from the MASE *Valutazioni e
  Autorizzazioni Ambientali* portal at `va.mite.gov.it` — the VIA (project EIA)
  and VAS (plan SEA) registers, merged with an `assessment_type` / `register`
  dual-register tag. Walks each register's paginated server-rendered HTML
  listing, reads each Info detail page (proponent, procedure timeline, *Esito*,
  and the *Regioni* / *Province* / *Comuni* text), and groups the direct
  `/File/Documento` PDFs into per-*Sezione* `attachment_urls_<slug>` columns.
  No geometry (location is text); `query` and `date_range` are matched
  client-side.
* Slovakia (`get_assessments_sk()`): fetches from the Slovak EIA/SEA central
  information system **enviroportal.sk** — a React SPA over a Symfony API
  Platform JSON backend, reached with pure `httr2` plus the
  `Accept: application/ld+json` header. The single `eia_projects` collection
  mixes project EIA and plan/programme SEA records, tagged with an
  `assessment_type` / `register` dual-register flag derived from the `zbierka`
  law string (`"časť EIA"` / `"časť SEA"`). The list endpoint's `hydra:member`
  is an array of arrays, so the handler flattens one level and paginates until a
  page yields no records; per-record detail JSON groups the direct
  `/eia/dokument` PDFs by procedural step into per-section
  `attachment_urls_<slug>` columns. No geometry; `assessment_type`, `query`, and
  `date_range` are matched client-side.
* **Breaking:** `download` now defaults to `FALSE`. Fetching PDF documents is
  opt-in; pass `download = TRUE` to retrieve attachments.
* Portal-native fields are carried through as extra columns with English
  `snake_case` names. The guaranteed core columns and the on-disk shape are
  documented in `dev/spec/contract.md`.

## Offline cache

* Every fetched record is saved to an on-disk offline metadata cache;
  `index_cache()` reads it back without revisiting the portal, and
  `clear_cache()` removes downloaded files while keeping the cached metadata.
  The cache root resolves through `cache_dir_default()`.
* Public helpers `download_to_cache()`, `cache_path()`, and
  `resolve_cached_path()` fetch or locate a single attachment using the same
  cache layout as the fetcher, so downstream packages need no internals.
* On-disk metadata uses sidecar schema v3: file paths are stored relative to the
  cache root, so a relocated or synced cache still resolves.
  `migrate_sidecars_v3()` upgrades an existing cache in one pass, and older
  (v1/v2) sidecars are still read.

## Optional scoring

* Pass `topic` (and `relevance_threshold`) to `get_assessments()` to score
  records as they are fetched and gate PDF downloads on the score.
  `relevance_threshold` is a *download gate only* — every record still appears
  in the result and the cache, so re-running with a new threshold needs no
  network. The embedding work is delegated to the companion **planscanR.screen**
  package (an optional dependency); plain fetching needs no Python.

## Attachment discovery

* `discover_attachments()` finds and validates attachment PDFs for portals that
  do not expose them directly, through a pluggable web-search backend
  (`search_backend_tavily()`).
