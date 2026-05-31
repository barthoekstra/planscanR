# Package index

## Fetching assessments

The unified entry point and the per-country handlers it dispatches to,
plus portal coverage and result helpers.

- [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  : Retrieve environmental-assessment records from a national portal.
- [`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md)
  : Fetch environmental-assessment records from the Netherlands.
- [`get_assessments_de()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md)
  : Fetch environmental-assessment records from Germany.
- [`get_assessments_at()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md)
  : Fetch environmental-assessment records from Austria.
- [`get_assessments_dk()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_dk.md)
  : Fetch environmental-assessment records from Denmark.
- [`get_assessments_be()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_be.md)
  : Fetch environmental-assessment records from Belgium (Flanders).
- [`get_assessments_ee()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_ee.md)
  : Fetch environmental-assessment records from Estonia.
- [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
  : List supported countries and portals.
- [`supported_countries()`](https://barthoekstra.github.io/planscanR/reference/supported_countries.md)
  : Countries supported by the current version of planscanR.
- [`bind_results()`](https://barthoekstra.github.io/planscanR/reference/bind_results.md)
  : Tolerant row-bind across result tibbles with differing extra
  columns.

## Attachment discovery (web search)

Locate and validate document attachments via a pluggable web-search
backend, for portals that don’t expose them directly.

- [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
  : Discover attachments for records the portal returned empty.
- [`discover_validate()`](https://barthoekstra.github.io/planscanR/reference/discover_validate.md)
  : Validate a candidate (record, URL) pair against a downloaded PDF.
- [`at_discovery_config()`](https://barthoekstra.github.io/planscanR/reference/at_discovery_config.md)
  : Discovery configuration for the Austrian UVP-DB.
- [`search_backend()`](https://barthoekstra.github.io/planscanR/reference/search_backend.md)
  : Build a custom search backend.
- [`search_backend_tavily()`](https://barthoekstra.github.io/planscanR/reference/search_backend_tavily.md)
  : Build a Tavily search backend.
- [`search_backend_mock()`](https://barthoekstra.github.io/planscanR/reference/search_backend_mock.md)
  : Build an in-memory mock search backend.
- [`web_search()`](https://barthoekstra.github.io/planscanR/reference/web_search.md)
  : Run a single web-search query through a backend.
- [`backend_name()`](https://barthoekstra.github.io/planscanR/reference/backend_name.md)
  : Printable name of a search backend.

## Cache & offline indexing

Read previously-downloaded slices offline and manage the file cache.

- [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
  : Walk a planscanR cache and reconstruct a tibble from every sidecar.
- [`clear_cache()`](https://barthoekstra.github.io/planscanR/reference/clear_cache.md)
  : Invalidate (delete) part or all of the planscanR cache.
- [`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md)
  : Resolve the planscanR cache root.
- [`cache_path()`](https://barthoekstra.github.io/planscanR/reference/cache_path.md)
  : Compute the local cache path an attachment URL would land at.
- [`resolve_cached_path()`](https://barthoekstra.github.io/planscanR/reference/resolve_cached_path.md)
  : Locate the on-disk file for a (possibly placeholder) cache path.
- [`download_to_cache()`](https://barthoekstra.github.io/planscanR/reference/download_to_cache.md)
  : Download one attachment URL into the planscanR cache.
- [`read_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/read_record_sidecar.md)
  : Read a sidecar JSON back into a 1-row tibble matching the planscanR
  schema.
- [`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md)
  : Write a sidecar JSON for a single record.

## Package

- [`planscanR`](https://barthoekstra.github.io/planscanR/reference/planscanR-package.md)
  [`planscanR-package`](https://barthoekstra.github.io/planscanR/reference/planscanR-package.md)
  : planscanR: retrieve environmental-assessment records from European
  portals
