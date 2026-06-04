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
* 14 countries are supported: Netherlands, Germany, France, Austria, Denmark,
  Belgium (Flanders), Estonia, Finland, Bulgaria, the Czech Republic, Croatia,
  Greece, Iceland, and Ireland. Coverage, honoured filters, geometry, and
  per-portal quirks differ by country — see `vignette("supported_sources")` and
  `get_assessments_coverage()`.
* **Breaking:** `download` now defaults to `FALSE`. Fetching PDF documents is
  opt-in; pass `download = TRUE` to retrieve attachments.
* Portal-native fields are carried through as extra columns with English
  `snake_case` names. The guaranteed core columns and the on-disk shape are
  documented in `docs/spec/contract.md`.

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
