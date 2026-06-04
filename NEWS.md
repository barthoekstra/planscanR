# planscanR 0.0.0.9000

* New public download helpers: `download_to_cache()`, `cache_path()`, and
  `resolve_cached_path()`. `download_to_cache()` fetches a single attachment URL
  into the cache the same way the fetcher does internally — same throttled
  client, same size cap, same `files/<country>/<document_id>/` layout — and
  returns the local path, size, and SHA-256. `cache_path()` tells you where a
  URL will land before you fetch it, and `resolve_cached_path()` finds the file
  once it has, so callers can skip a download when a copy already exists. With
  these, downstream packages no longer need to call `planscanR:::` internals.
* Breaking: `download` now defaults to `FALSE` across `get_assessments()` and
  all per-country handlers (`get_assessments_nl()`, `_de()`, `_at()`, `_dk()`,
  `_be()`, `_ee()`). Downloading attachments is computationally intensive, so
  it is now opt-in — pass `download = TRUE` explicitly to fetch PDFs.
* Initial development scaffold.
* Austria handler `get_assessments_at()` fetches record metadata from the
  Umweltbundesamt UVP-DB (`secure.umweltbundesamt.at/uvpdb`). Metadata-only:
  the portal's documents sit behind a login, so `attachment_urls` are empty.
* **Scoring, classification, and selection moved out.** planscanR is now a
  pure-R *fetcher*. Topic relevance scoring, the keyword lexicon, zero-shot
  classification, and the learned selection model now live in the companion
  **planscanR.screen** package. Functions that left planscanR include
  `score_assessments()`, `score_keywords()`, `classify_assessments()`, and
  `select_assessments()`.
* Optional fetch-time relevance scoring stays. Pass `topic` (and, to gate
  downloads, `relevance_threshold`) to `get_assessments()` to score records as
  they are fetched, adding one `relevance_score_<slug>` column per topic plus a
  shared `relevance_model`. The embedding work is delegated to
  **planscanR.screen** (a soft `Suggests` dependency); without it installed,
  passing `topic` aborts with an install hint, and plain fetching needs no
  Python.
* Attachment discovery. For portals that don't expose documents directly,
  `discover_attachments()` finds and validates PDFs through a pluggable
  web-search backend (`search_backend_tavily()`).
* Unified entry function `get_assessments()` dispatches on country code.
* Netherlands handler `get_assessments_nl()` fetches from the Commissie m.e.r.
  adviezenregister (`commissiemer.nl`) via sitemap-based URL discovery and
  detail-page parsing. Supports `query`, `date_range`, and `province` filters
  client-side; `theme`, `advice_type`, and `status` arguments are accepted
  with a warning that taxonomy filtering is not yet honoured.
* Required-columns return schema, validated by `validate_result_schema()`:
  `country`, `source_portal`, `document_id`, `url`, `retrieved_at`,
  `attachment_urls`, `local_path`. Additional columns are encouraged and free-form.
* Attachments are downloaded into `tools::R_user_dir("planscanR", "cache")`
  under `files/<country>/<document_id>/`.
* `get_assessments_coverage()` lists supported countries, portals, and the
  search-facet vocabularies each handler accepts.
* Germany handler `get_assessments_de()` fetches from the federated
  UVP-Verbund portal (`uvp-verbund.de`). URL enumeration uses the portal's
  Solr-backed `/freitextsuche` search (`q=*:*` for everything); detail-page
  parsing pulls title, summary, `competent_authority`, `jurisdiction`
  (federal-state partner), `native_type` (UVP-Kategorie) and last-modified
  date. Attachments are split into four list-columns mirroring the on-page
  section headings: `attachment_urls_uvp_bericht`, `_berichte`, `_auslegung`,
  `_weitere` (plus the deduplicated `attachment_urls` union).
* France handler `get_assessments_fr()` fetches from the national
  Projets-Environnement portal (`projets-environnement.gouv.fr`), backed by a
  public OpenDataSoft Explore API v2.1 — a single export call enumerates the
  whole flat dataset (~5,483 records), every field inline (no detail call).
  Maps `dc_title`/`descriptif_du_projet`/`dc_date`/`dc_type`/`vp_status` onto
  the conventional columns and keeps `dc_subject_theme`/`dc_subject_category`
  as extras. Server-side filters: `query` (ODSQL `search()`), `theme`
  (`dc_subject_theme`), `native_type` (`dc_type`), `status` (`vp_status`), and
  `date_range` (`dc_date`). Attachments come from a fixed set of typed
  `dc_relation_*` fields mapped to curated slugs — `attachment_urls_etude_impact`
  (étude d'impact PDF), `_resume_non_technique` (RNT), `_avis_ae`,
  `_reponse_avis_ae`, `_dossier` (the `*_DCZIP.zip`), and others — restricted to
  real SICODEI document URLs (external préfecture HTML pages are kept only as
  extras). Records with a `localisation` Feature get a sibling
  `.geometry.geojson` in WGS84 (`geometry_crs = "EPSG:4326"`).
* **`relevance_threshold` is now a download-gate only.** Records that score
  below the threshold still get a sidecar JSON on disk and still appear in
  the returned tibble — only their PDF attachments are skipped. This makes
  re-runs with a different threshold free of network. Applies to both NL
  and DE handlers.
* Sidecar JSONs now carry the URL list (and per-URL section tags) even when
  `download = FALSE` — each known but not-yet-fetched URL gets a `pending`
  row in `download_status`. `read_record_sidecar()` / `index_cache()` fan
  per-section URLs back out into the same `attachment_urls_<section>` /
  `local_path_<section>` columns regardless of country, and now also
  restores country-specific extras (e.g. DE's `native_type`).
* Denmark handler `get_assessments_dk()` fetches from Danmarks Miljøportal's
  EA-Hub (`eahub.miljoeportal.dk`). One `POST /assessments/search` call returns
  the entire register (~2,700 records); each row already carries title, year
  range, status, authorities, EIA-Directive Annex I/II categories, plan
  types/categories, and a `hasGeometry` flag, so no detail call is needed
  during the scan phase. Records with geometry get a `<document_id>.geometry.geojson`
  file written alongside the sidecar in EPSG:25832 (ETRS89-UTM32N), and the
  record exposes `geometry_path` / `geometry_crs` for downstream consumption
  with `sf`. Metadata-only in v0.1: `attachment_urls = character(0)` for every
  record — document downloads are deferred to a future release. Filter
  surface: `query` (server-side `freeText`), `assessment_type` (`"All"` /
  `"Plans"` / `"Project"`), and `date_range` (matched against each record's
  `fromYear` / `toYear`; `date_decision` is `NA` because the API only exposes
  year fields).
* Estonia handler `get_assessments_ee()` fetches from the Keskkonnaamet's
  KOTKAS portal (`kotkas.envir.ee`), merging both Estonian registers — KMH
  (project-level EIA, *Keskkonnamõju hindamine*) and KSH (plan/programme
  SEA, *Keskkonnamõju strateegiline hindamine*) — into one result tibble.
  Each row is tagged via the `assessment_type` column (`"EIA"` for KMH,
  `"SEA"` for KSH) and round-tripped to the sidecar so downstream tooling
  can tell them apart without re-fetching anything; `document_id` is
  prefixed `"KMH-"` / `"KSH-"` so the two registers never collide on disk.
  KOTKAS is a server-rendered (jQuery / Bootstrap) portal: index pages
  paginate via a numeric `qs=` offset and detail pages are scraped with
  `rvest`. Detail records carry an inline GeoJSON geometry (hidden form
  input) in EPSG:3301 (L-EST97), persisted next to the sidecar as
  `<document_id>.geometry.geojson` (same pattern as DK / BE). Per-document
  `Liik` (type) attachment splits emit `attachment_urls_<slug>` columns
  dynamically (e.g. `algatamise_otsus`, `programm`, `programmi_otsus`,
  `aruanne`, ...). Filter surface: `query` (server-side
  `s__search_keyword`), `assessment_type` (`"All"` / `"EIA"` / `"SEA"`),
  `proceeding_status` (`"INITIATED"` / `"ONGOING"` / `"SUSPENDED"` /
  `"FINISHED"`), `activity_area` (maakond code), and `activity`
  (sector code) — all forwarded server-side; `date_range` is matched
  client-side against `date_published` (the portal's *Algatamise kpv* /
  initiation date; `date_decision` is `NA` because the portal exposes no
  dossier-level decision timestamp).
* Czech Republic handler `get_assessments_cz()` fetches from CENIA's
  *Informační systém EIA/SEA* (`portal.cenia.cz/eiasea`), a server-rendered
  JSP application. **Domestic CZ only:** it crawls just the two in-scope
  registers — `eia100_cr` (*Záměry na území ČR*, project-level EIA, tagged
  `assessment_type = "EIA"`) and `SEA100_koncepce` (*Posuzování koncepcí*,
  concept/plan SEA, tagged `"SEA"`) — and deliberately never enumerates the
  cross-border / foreign (`eia100_mimo_cr`, `sea100_mezistatni`), sub-limit,
  priority-transport, large-project, or territorial-planning sub-registers.
  Ministry-coded records (`EIA_MZP*` / `SEA_MZP*`) inside the two domestic
  registers stay in scope. Both registers merge into one result tibble;
  `document_id` is the register-namespaced detail code (`"EIA_JHC1237"`,
  `"SEA_HKK015K"`), so they never collide on disk. Listings paginate via a
  1-based `?p=<n>` query (10 records/page); out-of-range pages are clamped to
  the last page by the server, so pagination stops when a page adds no new
  detail codes. Detail pages (`/eiasea/detail/EIA_<CODE>`,
  `/eiasea/detail/SEA_<CODE>`) are scraped with `rvest` from a
  `table.detail` of label/value rows interspersed with bold process-stage
  headings. Documents are exposed as direct anonymous download URLs
  (`/eiasea/download/<token>/<file>`), so the handler downloads PDFs from day
  one; both the token and the trailing filename are captured verbatim from the
  href. Per-stage attachment splits emit `attachment_urls_<slug>` columns
  (the Czech stage heading / field label is transliterated to ASCII, e.g.
  `oznameni`, `zjistovaci_rizeni`). Some attachments are very large ZIP
  bundles (e.g. a 79 MB `oznameni.zip`); the `max_file_size_mb` cap skips
  oversized files rather than fetching them. No geometry is exposed — location
  is administrative text only (`jurisdiction` = Kraj / Okres / Obec /
  Katastr). Filter surface: `assessment_type` (`"All"` / `"EIA"` / `"SEA"`)
  and `date_range` (matched client-side against `date_published` — the EIA
  last-modified date or the SEA *Datum zveřejnění* publication date;
  `date_decision` is always `NA`). Record content is Czech (`cs`); dates are
  parsed from the Java `Date.toString()` form (e.g.
  `Thu Jun 04 07:28:50 CEST 2026`). Throttled to 2 req/s by default
  (`getOption("planscanR.cz_throttle_rate")`).
* Croatia handler `get_assessments_hr()` fetches from the Ministry of
  Environment and Green Transition CMS pages (`mzozt.gov.hr`). Croatia has
  **no** machine-readable register or API: the "register" is a small set of
  server-rendered ASP.NET CMS pages, where each procedure is an inlined
  `<li><strong>TITLE</strong> <ul>...document links...</ul></li>` block. The
  handler fetches the master page(s) once and treats each block as one record
  — there is no pagination and no per-record detail endpoint. Merges both
  registers — **PUO** (*Procjena utjecaja zahvata na okoliš*, project-level
  EIA, tagged `assessment_type = "EIA"`) and **SPUO** (*Strateška procjena
  utjecaja na okoliš*, plan-level SEA, tagged `"SEA"`) — into one result
  tibble. Because there is no native procedure id, `document_id` is a stable
  deterministic SHA-1 hash of the title (`HR-PUO-<hash>` / `HR-SPUO-<hash>`,
  with a parseable year folded in), and `url` is the master-page URL plus
  `#<document_id>` so each record has a unique landing URL. Documents are
  direct anonymous `.pdf` / `.zip` links grouped by stage sub-heading (PUO
  *informacija o zahtjevu* / *javni uvid* / *nacrt rješenja* / *rješenje*; flat
  SPUO procedures fall under `document`); known stages get a curated slug,
  others are auto-slugged (Croatian diacritics transliterated to ASCII),
  emitting `attachment_urls_<slug>` columns. Per-document `DD.MM.YYYY.` date
  prefixes feed `date_published` (earliest) and `date_decision` (the
  *rješenje* / *odluka* date). No geometry. Filter surface: `assessment_type`
  (`"All"` / `"EIA"` / `"SEA"`), a client-side `query` title substring match,
  and `date_range` (client-side against `date_published`). Record content is
  Croatian (`hr`). Throttled to 5 req/s by default
  (`getOption("planscanR.hr_throttle_rate")`).
* Bulgaria handler `get_assessments_bg()` fetches from the Ministry of
  Environment and Water (МОСВ) public registers
  (`registers.moew.government.bg`), merging both registers — ОВОС
  (project-level EIA, *Оценка на въздействието върху околната среда*) and ЕО
  (plan/programme SEA, *Екологична оценка*) — into one result tibble. Each
  row is tagged via the `assessment_type` column (`"EIA"` for ОВОС, `"SEA"`
  for ЕО) and round-tripped to the sidecar; `document_id` is prefixed
  `"OVOS-"` / `"EO-"` so the two registers never collide on disk. The
  registers are server-rendered ASP.NET MVC pages: listings paginate via
  `?offset=<n>&limit=<k>` and detail pages (`/ovos/lot/<id>`, `/eo/lot/<id>`)
  are scraped with `rvest` from a nested row-group `table.table-lot`.
  Documents are exposed as direct anonymous download URLs
  (`/ovos/file?fileKey=<uuid>&fileName=<name>`), so the handler downloads
  PDFs from day one; the `fileName` parameter is required by the server, so
  the full href is captured verbatim. Per-row-label attachment splits emit
  `attachment_urls_<slug>` columns dynamically (the Bulgarian label is
  transliterated to ASCII, e.g. `uvedomlenie`, `opisanie`, `pismo`). No
  geometry is exposed by the portal — location is administrative text only
  (`jurisdiction` = Област / Община / Населено място). Filter surface:
  `query` (server-side `projectName`), `assessment_type` (`"All"` / `"EIA"` /
  `"SEA"`), and `date_range` (matched client-side against `date_published`,
  the dossier submission date; `date_decision` is the termination-decision
  date when present, else `NA`). Throttled to 2 req/s by default
  (`getOption("planscanR.bg_throttle_rate")`).
* Belgium (Flanders) handler `get_assessments_be()` fetches from the
  Departement Omgeving's MER-register
  (`merregister.omgeving.vlaanderen.be`). Enumeration paginates a public
  REST API (`/api/v1/dossier`, 25 records/page); detail records carry an
  inline GeoJSON geometry in EPSG:31370 (Belgian Lambert 72), which is
  persisted next to the sidecar as `<document_id>.geometry.geojson` (same
  pattern as DK). Documents are exposed as direct download URLs, so unlike
  DK the handler downloads PDFs from day one. Per-document-type attachment
  splits emit `attachment_urls_<type>` columns dynamically (`aanmelding`,
  `ontheffingsaanvraag`, `verslag_toekenning_ontheffing`, ...). Filter
  surface: `query` (client-side substring on title + nummer),
  `niscode` / `nummer` (server-side), `dossier_type`
  (`"PROJECT_MER"` / `"VERZOEK_TOT_ONTHEFFING"`, client-side), and
  `date_range` (matched against the earliest document creation date as
  `date_published`; `date_decision` is `NA`).
