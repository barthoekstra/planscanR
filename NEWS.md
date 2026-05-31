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
