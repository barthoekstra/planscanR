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
- 14 countries are supported: Netherlands, Germany, France, Austria,
  Denmark, Belgium (Flanders), Estonia, Finland, Bulgaria, the Czech
  Republic, Croatia, Greece, Iceland, and Ireland. Coverage, honoured
  filters, geometry, and per-portal quirks differ by country — see
  [`vignette("supported_sources")`](https://barthoekstra.github.io/planscanR/articles/supported_sources.md)
  and
  [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).
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
