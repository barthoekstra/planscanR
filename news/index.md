# Changelog

## planscanR 0.0.0.9000

- Initial development scaffold.
- Unified entry function
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  dispatches on country code.
- Netherlands handler
  [`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md)
  fetches from the Commissie m.e.r. adviezenregister (`commissiemer.nl`)
  via sitemap-based URL discovery and detail-page parsing. Supports
  `query`, `date_range`, and `province` filters client-side; `theme`,
  `advice_type`, and `status` arguments are accepted with a warning that
  taxonomy filtering is not yet honoured.
- Required-columns return schema, validated by
  `validate_result_schema()`: `country`, `source_portal`, `document_id`,
  `url`, `retrieved_at`, `attachment_urls`, `local_path`. Additional
  columns are encouraged and free-form.
- Attachments are downloaded into
  `tools::R_user_dir("planscanR", "cache")` under
  `files/<country>/<document_id>/`.
- [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
  lists supported countries, portals, and the search-facet vocabularies
  each handler accepts.
- Germany handler
  [`get_assessments_de()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md)
  fetches from the federated UVP-Verbund portal (`uvp-verbund.de`). URL
  enumeration uses the portal’s Solr-backed `/freitextsuche` search
  (`q=*:*` for everything); detail-page parsing pulls title, summary,
  `competent_authority`, `jurisdiction` (federal-state partner),
  `native_type` (UVP-Kategorie) and last-modified date. Attachments are
  split into four list-columns mirroring the on-page section headings:
  `attachment_urls_uvp_bericht`, `_berichte`, `_auslegung`, `_weitere`
  (plus the deduplicated `attachment_urls` union).
- **`relevance_threshold` is now a download-gate only.** Records that
  score below the threshold still get a sidecar JSON on disk and still
  appear in the returned tibble — only their PDF attachments are
  skipped. This makes re-runs with a different threshold free of
  network. Applies to both NL and DE handlers.
- Sidecar JSONs now carry the URL list (and per-URL section tags) even
  when `download = FALSE` — each known but not-yet-fetched URL gets a
  `pending` row in `download_status`. `read_record_sidecar()` /
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
  fan per-section URLs back out into the same
  `attachment_urls_<section>` / `local_path_<section>` columns
  regardless of country, and now also restores country-specific extras
  (e.g. DE’s `native_type`).
