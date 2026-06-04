# AGENTS.md — planscanR project orientation

Written for AI agents and human contributors landing in the repo cold. For the
family-level picture (dependency direction, the sidecar-schema contract shared
across all three packages), see the parent-folder `CLAUDE.md`.

## 1. What this package is

`planscanR` is an R package that provides a single, unified R API
(`get_assessments()`) for fetching environmental-assessment records (EIA, SEA,
follow-up advice) from European national portals — modelled on
[`aloftdata/getRad`](https://github.com/aloftdata/getRad). It is pure-R: no
Python, no Shiny, no project-specific scoring config.

**v0.1 scope.** Ten country handlers ship:
- Netherlands (`get_assessments_nl()`) — Commissie m.e.r. adviezenregister
  at `commissiemer.nl`.
- Germany (`get_assessments_de()`) — UVP-Verbund federated portal at
  `uvp-verbund.de`.
- France (`get_assessments_fr()`) — national Projets-Environnement portal at
  `projets-environnement.gouv.fr`, backed by a public **OpenDataSoft Explore
  API v2.1** (a documented anonymous REST+JSON service — the cleanest backend
  in the family). One export call enumerates the whole flat dataset (~5,483
  records, every field inline; no detail call). Server-side ODSQL `where`
  filters: `query` (`search()`), `theme` (`dc_subject_theme`), `native_type`
  (`dc_type`), `status` (`vp_status`), `date_range` (`dc_date`). Attachments
  come from a fixed set of typed `dc_relation_*` fields mapped to curated slugs
  (`etude_impact`, `resume_non_technique`, `avis_ae`, `reponse_avis_ae`,
  `dossier`, ...), restricted to real SICODEI document URLs (external
  préfecture HTML pages are dropped). Records with a `localisation` Feature get
  a `<document_id>.geometry.geojson` in **EPSG:4326** (WGS84; ODS always serves
  4326).
- Denmark (`get_assessments_dk()`) — Danmarks Miljøportal EA-Hub at
  `eahub.miljoeportal.dk`. **Metadata-only** in v0.x (records carry full
  metadata + polygon geometry; document downloads deferred). Geometry is
  persisted as `<document_id>.geometry.geojson` next to the sidecar
  (EPSG:25832).
- Belgium (Flanders) (`get_assessments_be()`) — Departement Omgeving
  MER-register at `merregister.omgeving.vlaanderen.be`. Project-MER and
  ontheffingsaanvragen only (Plan-MER is a separate Flemish register).
  Full metadata, polygon geometry (EPSG:31370, persisted in the same
  GeoJSON layout as DK), and direct anonymous document downloads. The
  geometry sidecar's CRS is the only thing that distinguishes it from a
  DK file.
- Estonia (`get_assessments_ee()`) — Keskkonnaamet KOTKAS at
  `kotkas.envir.ee`. Merges both Estonian registers — **KMH** (EIA) and
  **KSH** (SEA) — into one result tibble; each row carries an
  `assessment_type` column (`"EIA"` / `"SEA"`) and `document_id` is
  prefixed `"KMH-"` / `"KSH-"` so the two registers never collide on disk.
  Server-rendered (jQuery / Bootstrap) portal: index pages paginate via a
  numeric `qs=` offset, detail pages are scraped with `rvest`. Detail
  records carry an inline GeoJSON geometry (hidden form input) in
  **EPSG:3301** (L-EST97), persisted as `<document_id>.geometry.geojson`
  next to the sidecar in the same layout as DK / BE. Direct anonymous
  document downloads, grouped per `Liik` (document type) into
  `attachment_urls_<slug>` columns dynamically.
- Bulgaria (`get_assessments_bg()`) — Ministry of Environment and Water
  (МОСВ) registers at `registers.moew.government.bg`. Merges both
  registers — **ОВОС** (EIA) and **ЕО** (SEA) — into one result tibble;
  each row carries an `assessment_type` column (`"EIA"` / `"SEA"`) and
  `document_id` is prefixed `"OVOS-"` / `"EO-"` so the two registers never
  collide on disk. Server-rendered (ASP.NET MVC) portal: listings paginate
  via `?offset=<n>&limit=<k>`, detail pages (`/ovos/lot/<id>`,
  `/eo/lot/<id>`) are scraped with `rvest` from a nested row-group
  `table.table-lot`. **No geometry** (location is administrative text only).
  Direct anonymous document downloads (`/ovos/file?fileKey=...&fileName=...`;
  the `fileName` param is required, so the full href is kept verbatim),
  grouped per row label into `attachment_urls_<slug>` columns dynamically
  (Bulgarian labels transliterated to ASCII). Throttled to 2 req/s by
  default (`getOption("planscanR.bg_throttle_rate")`).
- Czech Republic (`get_assessments_cz()`) — CENIA *Informační systém
  EIA/SEA* at `portal.cenia.cz/eiasea`. **Domestic CZ only**: merges just the
  two in-scope registers — `eia100_cr` (*Záměry na území ČR*, EIA) and
  `SEA100_koncepce` (*Posuzování koncepcí*, SEA) — into one result tibble and
  **never** crawls the cross-border / foreign (`eia100_mimo_cr`,
  `sea100_mezistatni`) or special sub-registers (`eia100_podlimitni` / `_pdz`
  / `_vzvp` / `eia244`, `sea100_pur*` / `zur*` / `up*`); ministry-coded
  records (`EIA_MZP*` / `SEA_MZP*`) inside the two domestic registers stay in
  scope. Each row carries an `assessment_type` column (`"EIA"` / `"SEA"`) and
  `document_id` is the register-namespaced detail code (`"EIA_JHC1237"`,
  `"SEA_HKK015K"`) so the two never collide on disk. Server-rendered (JSP /
  Tomcat) portal: listings paginate via a 1-based `?p=<n>` query (out-of-range
  pages clamp to the last page, so stop when a page adds no new codes), detail
  pages (`/eiasea/detail/EIA_<CODE>`, `/eiasea/detail/SEA_<CODE>`) are scraped
  with `rvest` from a `table.detail` of label/value rows interspersed with
  bold stage headings. **No geometry** (location is administrative text only:
  Kraj / Okres / Obec / Katastr). Direct anonymous document downloads
  (`/eiasea/download/<token>/<file>`; token + filename kept verbatim from the
  href), grouped per process stage into `attachment_urls_<slug>` columns
  (Czech labels transliterated to ASCII); some attachments are very large ZIPs,
  bounded by `max_file_size_mb`. Throttled to 2 req/s by default
  (`getOption("planscanR.cz_throttle_rate")`).
- Croatia (`get_assessments_hr()`) — Ministry of Environment and Green
  Transition CMS pages at `mzozt.gov.hr`. **No API / no machine-readable
  register**: the register is a small set of server-rendered ASP.NET CMS pages
  where each procedure is an inlined `<li><strong>TITLE</strong> <ul>...document
  links...</ul></li>` block. The handler fetches the master page(s) once and
  parses each block as one record — no pagination, no per-record detail
  endpoint. Merges both registers — **PUO** (EIA) and **SPUO** (SEA) — into one
  result tibble; each row carries an `assessment_type` column (`"EIA"` /
  `"SEA"`). No native id: `document_id` is a stable SHA-1 hash of the title
  (`HR-PUO-<hash>` / `HR-SPUO-<hash>`, year folded in) and `url` is the
  master-page URL plus `#<document_id>` for a unique landing URL. **No
  geometry** (spatial info is inside the PDFs; a county/grad is heuristically
  pulled from the title into `jurisdiction`). Direct anonymous `.pdf` / `.zip`
  downloads grouped by stage sub-heading into `attachment_urls_<slug>` columns
  via a DE-style curated-map + auto-slug fallback (Croatian diacritics
  transliterated to ASCII; flat SPUO docs fall under `document`); the original
  href (with spaces / diacritics) is kept verbatim and percent-encoded only at
  download time. Filters: `assessment_type`, a client-side `query` title
  substring, and client-side `date_range`. Throttled to 5 req/s by default
  (`getOption("planscanR.hr_throttle_rate")`).
- Austria (`get_assessments_at()`) — Umweltbundesamt UVP-DB at
  `secure.umweltbundesamt.at/uvpdb`. **Metadata-only**: the portal's HTML
  pages and document attachments sit behind a Keycloak login wall; only
  three open JSON service handlers (`mapsdata`, `mapsgeom`, `vorhabenInfo`)
  expose record metadata anonymously. The handler returns rich tibble
  rows but `attachment_urls` and `local_path` are always empty, and
  `date_decision` is always `NA` (the portal only exposes a `year`).
  Reflected in `get_assessments_coverage()$status` as `"supported
  (metadata-only)"`.

The architecture is multi-country from day one — adding DK / etc. is a
pure additive change.

**Out of scope.** Spatial output (`sf`), zoning/plan documents,
LLM-based classification & normalisation. Topic scoring, classification, and
selection all live in the sibling packages now (see *The planscanR family*
below). Whatever remains flagged on the roadmap (§6) is here so it doesn't get
prematurely wedged in.

## The planscanR family

`planscanR` is the **leaf** of a three-package family, each its own git repo
under this parent folder:

```
planscanR             ←─── planscanR.screen ←─── planscanR.biogain
(this package)              (scoring/select)      (BIOGAIN config + app)
```

- **planscanR** (here): fetches environmental-assessment records from the EU
  portals, owns the **cache** and the **sidecar JSON schema**, and does
  attachment **discovery**. Pure-R — no Python — and it Imports **neither**
  sibling. The outward-facing entry point.
- **planscanR.screen** — general-purpose scoring/classification/selection
  framework (embedding cosine, zero-shot classify, keyword lexicon, learned
  selection). Brings Python in via `reticulate`. Imports planscanR. See
  [../planscanR.screen/AGENTS.md](../planscanR.screen/AGENTS.md).
- **planscanR.biogain** — the BIOGAIN-specific config (topics / labels /
  lexicon), the ensemble `select` rule, the human review Shiny app, the
  Yoda / iRODS sync helpers, and the acquisition runbook. Imports both. See
  [../planscanR.biogain/AGENTS.md](../planscanR.biogain/AGENTS.md).

**Fetch-time relevance scoring is an optional, soft-dependency feature.** You
can pass `topic` to `get_assessments()` to score records as they're fetched —
but the embedding work is delegated to **planscanR.screen** (a Suggests
dependency, called through a `requireNamespace()` guard in
`R/utils_relevance.R`). Without planscanR.screen installed, passing `topic`
aborts with an install hint (`planscanR_error_screen_missing`); **omit `topic`
to fetch without any scoring** and planscanR stays a pure-R fetcher. The
slug / sidecar conventions are shared because both packages write the
planscanR-owned schema; the scoring *logic* is not here.

## 1a. The acquisition runbook (lives in planscanR.biogain)

The canonical, top-to-bottom acquisition pipeline — scan + score → classify →
select → download / discover → report — is **no longer in this repo**. It now
ships with **planscanR.biogain** at `inst/runbook/biogain_acquire.R`,
reachable via:

```r
system.file("runbook", "biogain_acquire.R", package = "planscanR.biogain")
```

It is the BIOGAIN package's runbook, not planscanR's: planscanR provides the
fetch / cache / discovery primitives it calls, but the selection rule,
thresholds, and phase orchestration live over there. When the question is "how
is BIOGAIN data processed end-to-end?", that file is the answer — see
[../planscanR.biogain/AGENTS.md](../planscanR.biogain/AGENTS.md).

## 2. Architecture in one diagram

```
get_assessments(country, ...)
  ├── normalise_country() / assert_country()
  ├── select_assessments_handler(country)    # switch() returning a function
  │     ├── get_assessments_nl(...)          # commissiemer.nl
  │     ├── get_assessments_de(...)          # uvp-verbund.de
  │     ├── get_assessments_fr(...)          # projets-environnement.gouv.fr
  │     ├── get_assessments_at(...)          # secure.umweltbundesamt.at/uvpdb
  │     ├── get_assessments_dk(...)          # eahub.miljoeportal.dk
  │     ├── get_assessments_be(...)          # merregister.omgeving.vlaanderen.be
  │     ├── get_assessments_ee(...)          # kotkas.envir.ee
  │     ├── get_assessments_bg(...)          # registers.moew.government.bg
  │     └── get_assessments_cz(...)          # portal.cenia.cz/eiasea
  ├── validate_result_schema()               # invariant gate before returning
  └── discover_attachments()                 # optional, when discover = TRUE
```

Every per-country handler is a self-contained file at `R/get_assessments_<cc>.R`
and is selected purely by the `switch` in `R/get_assessments.R`. There is no
S3 / class hierarchy — explicit functional dispatch only.

When `topic` is supplied, `get_assessments()` also runs fetch-time relevance
scoring through `R/utils_relevance.R`, which delegates the embedding to
planscanR.screen (soft dependency). **Score / classify / select as a pipeline
are sibling-package concerns** — the runbook in planscanR.biogain orchestrates
them on top of the tibble this package returns; planscanR itself only fetches
(and, optionally, scores by topic).

## 3. Return schema rules

**Required columns** (validated by `validate_result_schema()`, every handler
MUST emit them with the right types):

| Column | Type |
|---|---|
| `country` | chr (ISO-2, lowercase) |
| `source_portal` | chr |
| `document_id` | chr (unique within `source_portal`) |
| `url` | chr (canonical landing URL) |
| `retrieved_at` | POSIXct (UTC) |
| `attachment_urls` | list<chr> |
| `local_path` | list<chr> (parallel to `attachment_urls`; `character(0)` if `download = FALSE`) |

**Conventional columns** (use these names when the portal exposes the concept,
so cross-country tibbles can be `bind_rows()`-ed cleanly):

`title`, `summary`, `native_type`, `jurisdiction`, `status`, `date_published`,
`date_decision`, `competent_authority`, `proponent`, `file_sha256`,
`relevance_score`, `relevance_model`, `download_status`.

**Per-handler attachment splits.** A portal that groups its attachments into
named sections may add parallel list-columns. NL uses two:

- `attachment_urls_source` / `local_path_source` — files in
  *"Documenten waarop het advies is gebaseerd"* (the underlying EIA/SEA
  reports — the substantive documents for downstream analysis).
- `attachment_urls_advice` / `local_path_advice` — files in
  *"Adviezen en persberichten"* (Commissie advice + press releases).

DE uses four:

- `attachment_urls_uvp_bericht` / `local_path_uvp_bericht` —
  *"UVP-Bericht, ggf. Antragsunterlagen"* (substantive UVP report + applicant
  docs).
- `attachment_urls_berichte` / `local_path_berichte` —
  *"Berichte und Empfehlungen"*.
- `attachment_urls_auslegung` / `local_path_auslegung` —
  *"Auslegungsinformationen"* (public-consultation notices).
- `attachment_urls_weitere` / `local_path_weitere` —
  *"Weitere Unterlagen"* (other materials; often the biggest section).

`attachment_urls` / `local_path` remain the deduplicated **union** (source /
substantive sections first), so the required-columns schema is always
satisfied. `read_record_sidecar()` is country-agnostic: any
`attachment_urls_<section>` list-column a handler emits flows through the
sidecar and back out without changes here.

**`download_status` list-column** (when `download = TRUE`): one tibble per
record with columns `url, local_path, status, size_bytes, sha256, reason`.
Values for `status`: `"downloaded"`, `"cached"`, `"skipped_size"`, `"failed"`.

**No normalisation at fetch time.** Status, type, jurisdiction strings stay in
the portal's own vocabulary (Dutch / German / Danish / …). Cross-portal
normalisation and classification are a **planscanR.screen** concern that
consumes this tibble downstream — not the fetcher's job.

**Extra columns are encouraged.** Handlers can add any country-specific column
they like — `validate_result_schema()` only enforces the required set. New
conventional columns can be promoted in a later minor release.

**Derived score columns are owned by the siblings, not by the fetcher.**
`relevance_score_<slug>` (and, downstream, `class_*` / `kw_*` columns) describe
the *schema* planscanR persists, but the values are produced by
planscanR.screen / planscanR.biogain. They reach disk through
`planscanR::write_record_sidecar()` and fan back out through
`planscanR::read_record_sidecar()`: planscanR owns the schema and the **merge
logic** (union-by-slug, so re-scoring a slice never clobbers other topics'
scores), not the scoring that fills these columns. The one exception is
`relevance_score_<slug>` written during a `get_assessments(topic = ...)` call —
even there the embedding is delegated to planscanR.screen.

## 4. Conventions

- **License**: GPL-3.
- **Formatter**: [Air](https://posit-dev.github.io/air/) with
  `line-width = 120` (see `air.toml`). Run `air format .` before pushing.
- **HTTP**: every outbound call goes through `req_planscanr()` in
  `R/utils_http.R` so user-agent, retry, and HTTP-cache behaviour stay
  consistent.
- **Caching**: file cache root is `tools::R_user_dir("planscanR", "cache")`,
  overridable via the `cache_dir` argument or `options(planscanR.cache_dir)`.
  Layout:
  ```
  <root>/
    files/<country>/<document_id>/
      <document_id>.meta.json                          # sidecar (see §4b)
      <country>_<document_id>_<slug>.<ext>             # flatten-safe basename
  ```
  When a portal's attachment URLs don't expose an extension in the path
  (e.g. Kotkas: `?attachment_id=...`), the slug carries an 8-char SHA-1
  of the full URL for per-attachment uniqueness, and the final `<ext>`
  is assigned post-download from the `Content-Type` header (with a
  magic-byte fallback for `application/octet-stream`).
  There is no separate HTTP cache — the sidecar JSONs ARE the cache, and
  per-country handlers consult them via `sidecar_url_index()` before going
  to the network. [clear_cache()] removes the `files/` tree (optionally
  scoped by `country`); pair with `refresh = TRUE` on the next call if you
  want fresh fetches afterwards. The download
  layer pre-flights every URL with HEAD; files exceeding
  `getOption("planscanR.max_file_size_mb", 50)` are skipped and recorded in
  `download_status`. Already-on-disk non-empty files become `status = "cached"`
  unless `overwrite = TRUE`.
- **Errors** carry classed conditions (`planscanR_error_unsupported_country`,
  `planscanR_error_bad_input`, `planscanR_error_bad_schema`,
  `planscanR_warning_partial`) so tests can target them cleanly.
- **Tests**: `testthat` (edition 3). HTTP is intercepted with
  `testthat::local_mocked_bindings()` against recorded fixtures under
  `tests/testthat/fixtures/<cc>/` (each handler exposes an internal
  `perform_*` seam — e.g. `perform_json`, `perform_html` — that the tests
  rebind); **no live HTTP in CI**. Live tests, if any, live under
  `tests/manual/` and are git-ignored.
- **Secrets**: portal handlers remain anonymous-access in v0.x and don't need
  credentials. The discovery backend (`R/discover_backend_tavily.R`) reads a
  `TAVILY_API_KEY` from the environment. Credentialed sync (Yoda / iRODS) is a
  planscanR.biogain concern, not this package's.

## 4b. Persistence and offline indexing

Every successfully processed record is persisted to a sidecar JSON at
`files/<country>/<document_id>/<document_id>.meta.json` — written **atomically
inside the per-record loop**, so an interrupted run leaves N fully-indexable
records on disk (not N orphan dirs). The sidecar carries the full record
(country, source_portal, document_id, url, title, summary, dates, competent
authority, proponent, relevance_score, etc.) plus a per-file `files[]` array
mirroring the `download_status` columns (status, size_bytes, sha256, reason,
section). Schema version: `2`.

**The cache + sidecar are the family's load-bearing contract, and the I/O is
exported.** `cache_dir_default()` (the cache-root resolver), plus
`read_record_sidecar()` / `write_record_sidecar()` (the sidecar reader/writer
with the merge logic) are **exported** so the sibling packages read and write
the same cache without reaching into internals. planscanR.screen and
planscanR.biogain call `write_record_sidecar()` to persist their
`relevance_scores[]` / `class_*` / `kw_*` results into the schema this package
owns; the merge here keeps those arrays intact across re-scans.

**The sidecar is the authoritative cache.** Per-country handlers consult
`sidecar_url_index(country)` at the start of every call to build a
`url -> sidecar-path` lookup; any URL with an on-disk sidecar is loaded
**from JSON** rather than re-fetched over HTTP. This makes re-scoring an
already-scanned slice against a new topic essentially free (only the
embedding compute — done in planscanR.screen — and zero network). Pass
`refresh = TRUE` to bypass the sidecar lookup and force fresh detail-page
fetches.

Sidecar writes **merge** the `relevance_scores` array (this merge logic is
planscanR-owned, in `R/utils_sidecar.R`): prior topic entries whose slug isn't
present in the current run are preserved. So running with `topic = c(wind =
"...")` after a multi-topic scan doesn't wipe the solar / power_grid scores
from disk — only the wind entry is replaced. The same merge protects the
`class_*` arrays a sibling writes through `write_record_sidecar()`.

`index_cache(cache_dir = NULL, country = NULL)` walks every sidecar under the
root and reconstructs a tibble matching the planscanR schema — no portal
calls. Use it to:
- re-read a previously-downloaded slice offline;
- enumerate what's on disk before deciding what else to fetch;
- recover after manually relocating or flattening files (because the basenames
  are globally unique, `find files/ -exec mv {} flat/` is safe).

> **Yoda / iRODS sync moved out.** Pushing the cache to a Yoda iRODS server
> (`sync_cache_to_yoda()`, `fetch_attachments_via_yoda()`, the cache-resident
> `yoda/` config, and the `keyring`-based credential resolution) now lives in
> **planscanR.biogain**. It is a consumer of this package's cache layout — the
> local sidecars remain the authoritative index here. See
> [../planscanR.biogain/AGENTS.md](../planscanR.biogain/AGENTS.md).

## 5. Adding a country

1. Create `R/get_assessments_<cc>.R` with the same signature surface as
   `get_assessments_nl()`. The handler must return a tibble that passes
   `validate_result_schema()`.
2. Add one line to the `switch` in `R/get_assessments.R`:
   `<cc> = get_assessments_<cc>,`.
3. Update `supported_countries()` in `R/utils_dispatch.R` and the
   `get_assessments_coverage()` tibble accordingly.
4. Save the portal's responses as fixture files under
   `tests/testthat/fixtures/<cc>/` and add
   `tests/testthat/test-get_assessments_<cc>.R`, intercepting the network by
   rebinding the handler's `perform_*` seam(s) with
   `testthat::local_mocked_bindings()` (see the existing handler tests).
5. Document portal-specific search-facet vocabularies (`status`, `native_type`,
   etc.) in the handler's roxygen.

That's the whole recipe — no edits to the core dispatcher are needed.

## 5a. Topics, scoring, classification, selection — moved to the siblings

These all left planscanR when the family split:

- **Topic defaults** (`biogain_assessment_topics()` and the canonical
  six-topic set) → **planscanR.biogain**.
- **Relevance scoring** (the pluggable embedding-model interface,
  `embedding_model_minilm()`, the cosine scorer, batch `score_records()`,
  zero-shot classification, the keyword lexicon, and the learned selection
  model) → **planscanR.screen**.
- **The BIOGAIN ensemble `select` rule**, the **review Shiny app**
  (`run_biogain_review()`), and the **acquisition runbook** →
  **planscanR.biogain**.

What planscanR keeps is the *fetch-time* slice only: pass `topic` to
`get_assessments()` and it delegates the embedding to planscanR.screen
(soft dependency; see *The planscanR family* and §3), writing
`relevance_score_<slug>` columns into the sidecar schema it owns. For
everything past scoring — classify, select, review, sync, report — see
[../planscanR.screen/AGENTS.md](../planscanR.screen/AGENTS.md) and
[../planscanR.biogain/AGENTS.md](../planscanR.biogain/AGENTS.md).

## 6. Roadmap (informational; not actionable in v0.1)

- **Additional country handlers** — beyond the current six. Order not committed.
  Adding one is a pure additive change (§5).
- **`keyring`-based secrets for portal handlers** — when a portal grows to
  require API keys, add `keyring` as a Suggests dep and use the slot
  convention `planscanR_<country>_<portal>`. Handlers are anonymous-access for
  now.
- **`derived/` subdir under the cache root** — leave room for downstream
  artefacts (e.g. PDF-to-markdown chunks). The contract is: never mutate
  downloaded PDFs in place. The actual classification / normalisation work
  (docling chunking, LLM type assignment, cross-portal vocabulary
  normalisation) is a **planscanR.screen** concern that consumes the tibble
  this package returns — the fetcher stays raw. See
  [../planscanR.screen/AGENTS.md](../planscanR.screen/AGENTS.md).

## 7. Pointers

- Sibling packages (scoring / classification / selection, BIOGAIN config +
  review app + Yoda sync + runbook):
  [../planscanR.screen/AGENTS.md](../planscanR.screen/AGENTS.md),
  [../planscanR.biogain/AGENTS.md](../planscanR.biogain/AGENTS.md).
- Family-level orientation, dependency direction, and the sidecar-schema
  contract: the parent-folder `CLAUDE.md`.
- Architectural reference: <https://github.com/aloftdata/getRad>
- Adding a new country, end to end: `ADDING_A_COUNTRY.md`.
- Cache contract (exported): `cache_dir_default()`, `read_record_sidecar()`,
  `write_record_sidecar()`; schema + merge logic in `R/utils_sidecar.R`.
- Attachment discovery: `R/discover_attachments.R` (+ `discover_validate()`,
  `discover_backend*`); the AT escape hatch is `at_discovery_config()`.
- Per-portal documentation lives in `vignettes/supported_sources.Rmd`; the
  runtime-accessible equivalent (including the valid search-facet
  vocabularies) is `get_assessments_coverage()`.
