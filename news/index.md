# Changelog

## planscanR 0.0.0.9000

- Initial development scaffold.
- Austria handler
  [`get_assessments_at()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md)
  fetches record metadata from the Umweltbundesamt UVP-DB
  (`secure.umweltbundesamt.at/uvpdb`). Metadata-only: the portal’s
  documents sit behind a login, so `attachment_urls` are empty.
- Topic relevance scoring. Pass `topic` to
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  (or use
  [`score_assessments()`](https://barthoekstra.github.io/planscanR/reference/score_assessments.md)
  on existing records) to rank each record by how closely its title and
  summary match one or more topics, via a multilingual text-similarity
  model.
  [`biogain_assessment_topics()`](https://barthoekstra.github.io/planscanR/reference/biogain_assessment_topics.md)
  returns the six energy topics the BIOGAIN project uses. The embedding
  model is pluggable through
  [`embedding_model()`](https://barthoekstra.github.io/planscanR/reference/embedding_model.md).
- Lexical keyword scoring
  ([`score_keywords()`](https://barthoekstra.github.io/planscanR/reference/score_keywords.md),
  [`biogain_keyword_lexicon()`](https://barthoekstra.github.io/planscanR/reference/biogain_keyword_lexicon.md))
  counts energy-related terms as a complementary signal.
- Classification.
  [`classify_assessments()`](https://barthoekstra.github.io/planscanR/reference/classify_assessments.md)
  assigns each record a canonical class via a pluggable zero-shot
  classifier
  ([`classify_model_zeroshot()`](https://barthoekstra.github.io/planscanR/reference/classify_model_zeroshot.md)).
- Selection.
  [`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)
  combines the relevance, classifier, and keyword signals into a single
  keep/drop decision. A model learned from human keep/drop labels
  ([`train_selection_model()`](https://barthoekstra.github.io/planscanR/reference/train_selection_model.md)
  /
  [`predict_selection()`](https://barthoekstra.github.io/planscanR/reference/predict_selection.md))
  is also available; the built-in learner is logistic regression.
- Attachment discovery. For portals that don’t expose documents
  directly,
  [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
  finds and validates PDFs through a pluggable web-search backend
  ([`search_backend_tavily()`](https://barthoekstra.github.io/planscanR/reference/search_backend_tavily.md)).
- Review app.
  [`run_biogain_review()`](https://barthoekstra.github.io/planscanR/reference/run_biogain_review.md)
  launches a bundled Shiny app for inspecting how records flow through
  the pipeline and building a human ground-truth selection to benchmark
  the automated decision against.
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
- Denmark handler
  [`get_assessments_dk()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_dk.md)
  fetches from Danmarks Miljøportal’s EA-Hub (`eahub.miljoeportal.dk`).
  One `POST /assessments/search` call returns the entire register
  (~2,700 records); each row already carries title, year range, status,
  authorities, EIA-Directive Annex I/II categories, plan
  types/categories, and a `hasGeometry` flag, so no detail call is
  needed during the scan phase. Records with geometry get a
  `<document_id>.geometry.geojson` file written alongside the sidecar in
  EPSG:25832 (ETRS89-UTM32N), and the record exposes `geometry_path` /
  `geometry_crs` for downstream consumption with `sf`. Metadata-only in
  v0.1: `attachment_urls = character(0)` for every record — document
  downloads are deferred to a future release. Filter surface: `query`
  (server-side `freeText`), `assessment_type` (`"All"` / `"Plans"` /
  `"Project"`), and `date_range` (matched against each record’s
  `fromYear` / `toYear`; `date_decision` is `NA` because the API only
  exposes year fields).
- Belgium (Flanders) handler
  [`get_assessments_be()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_be.md)
  fetches from the Departement Omgeving’s MER-register
  (`merregister.omgeving.vlaanderen.be`). Enumeration paginates a public
  REST API (`/api/v1/dossier`, 25 records/page); detail records carry an
  inline GeoJSON geometry in EPSG:31370 (Belgian Lambert 72), which is
  persisted next to the sidecar as `<document_id>.geometry.geojson`
  (same pattern as DK). Documents are exposed as direct download URLs,
  so unlike DK the handler downloads PDFs from day one.
  Per-document-type attachment splits emit `attachment_urls_<type>`
  columns dynamically (`aanmelding`, `ontheffingsaanvraag`,
  `verslag_toekenning_ontheffing`, …). Filter surface: `query`
  (client-side substring on title + nummer), `niscode` / `nummer`
  (server-side), `dossier_type` (`"PROJECT_MER"` /
  `"VERZOEK_TOT_ONTHEFFING"`, client-side), and `date_range` (matched
  against the earliest document creation date as `date_published`;
  `date_decision` is `NA`).
