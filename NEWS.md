# planscanR 0.0.0.9000

* Initial development scaffold.
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
