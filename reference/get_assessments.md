# Retrieve environmental-assessment records from a national portal.

Unified entry point that dispatches on `country` to a per-country
handler. Returns a tibble of records. The shape of the returned tibble
follows the planscanR schema: a small required-columns set is guaranteed
across countries, and any additional columns exposed by the portal are
appended freely. See **Return value** for details.

## Usage

``` r
get_assessments(
  country,
  date_range = NULL,
  limit = Inf,
  download = TRUE,
  cache_dir = NULL,
  overwrite = FALSE,
  max_file_size_mb = NULL,
  write_sidecar = TRUE,
  refresh = FALSE,
  topic = NULL,
  relevance_threshold = NULL,
  relevance_model = NULL,
  discover = FALSE,
  search_backend = NULL,
  ...
)
```

## Arguments

- country:

  Character scalar, ISO-3166-1 alpha-2 country code (any case). v0.1
  supports `"nl"`, `"de"`, and `"at"`. See
  [`supported_countries()`](https://barthoekstra.github.io/planscanR/reference/supported_countries.md).

- date_range:

  Optional length-2 vector `c(from, to)` of `Date`, `POSIXct`, or
  character. Filters by `date_published` / `date_decision` semantics
  decided per handler.

- limit:

  Maximum number of records to return (default `Inf`).

- download:

  Logical. If `TRUE` (default), attachment files referenced by each
  record are downloaded into the local cache. If `FALSE`, only metadata
  is returned; `local_path` is `character(0)` in every row.

- cache_dir:

  Optional cache root. Defaults to
  `tools::R_user_dir("planscanR", "cache")`.

- overwrite:

  Logical. If `TRUE`, re-download attachments even when a cached copy
  exists.

- max_file_size_mb:

  Numeric cap (in MiB) on per-file download size. URLs whose announced
  or actual size exceeds the cap are skipped and recorded in the
  `download_status` column with status `"skipped_size"`. `NULL`
  (default) defers to `getOption("planscanR.max_file_size_mb", 50)`;
  `Inf` disables the cap.

- write_sidecar:

  Logical. If `TRUE` (default), every returned record is persisted to a
  `<document_id>.meta.json` file alongside its attachments so the cache
  can be re-indexed offline via
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md).

- refresh:

  Logical. If `FALSE` (default), records for URLs that already have a
  sidecar JSON on disk are loaded directly from the sidecar — no
  detail-page HTTP request at all. This makes re-scoring against new
  topics essentially free once a slice has been cached. Set to `TRUE` to
  force fresh detail-page fetches (useful if the portal genuinely
  changed).

- topic:

  Optional character vector of topic phrases. Pass a single string (e.g.
  `"wind energy infrastructure"`) or a named vector like
  `c(wind = "wind energy", solar = "solar energy", res = "regional energy transition strategy")`.
  Each candidate record's title+summary is embedded **once** per call
  and scored by cosine similarity against every topic, **before** any
  attachments are downloaded. Adds one `relevance_score_<slug>` column
  per topic plus a shared `relevance_model`. Unnamed topics get
  auto-slugified from the phrase. Adding extra topics costs essentially
  nothing — the per-record embed is the expensive step and runs once.
  Every scored record is sidecar'd and returned regardless of its score.

- relevance_threshold:

  Optional cutoff in `[-1, 1]`. This **only affects downloading**:
  records that score below the threshold still appear in the returned
  tibble and still get a sidecar JSON on disk — only their PDF
  attachments are skipped. This lets you re-run with a different
  threshold (or no threshold) later without re-hitting the portal.
  Scalar threshold: PDFs are downloaded if **any** topic clears it.
  Named numeric vector (e.g. `c(wind = 0.5, solar = 0.4)`): per-topic
  cutoffs, downloads happen if **any** named topic clears its own
  cutoff. `NULL` (default) is score-only; every record's PDFs are
  downloaded (when `download = TRUE`).

- relevance_model:

  A `planscanR_embedding_model`. Defaults to
  [`embedding_model_minilm()`](https://barthoekstra.github.io/planscanR/reference/embedding_model_minilm.md)
  (sentence-transformers `paraphrase-multilingual-MiniLM-L12-v2` via
  reticulate). Pass a custom one built with
  [`embedding_model()`](https://barthoekstra.github.io/planscanR/reference/embedding_model.md)
  to plug in a different backend.

- discover:

  Logical. If `TRUE`, after the portal handler returns, records that
  came back with no attachments (`length(attachment_urls) == 0`) are
  passed through
  [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
  to find PDFs via a web-search backend. Off by default in v0.x —
  metadata-only handlers like AT emit a one-shot informational message
  pointing at this flag. See
  [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
  for backend / config controls.

- search_backend:

  Optional
  [`search_backend()`](https://barthoekstra.github.io/planscanR/reference/search_backend.md)
  for the discovery pass. Defaults to
  [`search_backend_tavily()`](https://barthoekstra.github.io/planscanR/reference/search_backend_tavily.md)
  when `discover = TRUE`.

- ...:

  Forwarded to the country handler. Common search parameters are
  documented in
  [`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md).

## Value

A tibble with at least these required columns:

- `country`:

  Character (ISO-2, lowercase).

- `source_portal`:

  Character (e.g. `"commissiemer.nl"`).

- `document_id`:

  Character. Portal-native ID, unique within the portal.

- `url`:

  Character. Canonical portal landing URL.

- `retrieved_at`:

  POSIXct (UTC).

- `attachment_urls`:

  List-column of character vectors.

- `local_path`:

  List-column of character vectors (parallel to `attachment_urls`).

Handlers may add further columns such as `title`, `native_type`,
`status`, `date_published`, `competent_authority`, `proponent`,
`jurisdiction`, etc. No cross-portal normalisation is applied to these —
values stay in the source portal's vocabulary.

## Details

Per-country search parameters are forwarded through `...`. Some are
implemented by every handler that supports them (e.g. `theme`,
`advice_type`, `province`, `status`, `query`); consult the per-country
handler's documentation (e.g.
[`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md))
for the exact parameter surface and the vocabulary of valid values.

## See also

[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md),
[`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md),
[`supported_countries()`](https://barthoekstra.github.io/planscanR/reference/supported_countries.md).
