# biogain-review — pipeline funnel & human-review app

A Shiny app bundled with **planscanR** (under `inst/biogain-review/`) for the
BIOGAIN project. It answers two questions:

1. **What proportion of documents survive each pipeline gate?** (indexed →
   embedding cosine / zero-shot classifier / keyword → ensemble selection →
   attachments → downloaded), with the cosine and keyword thresholds adjustable
   live, shown as an interactive funnel + per-country breakdown.
2. **How well does the automated pre-selection match a human review?** Triage
   records by hand (keep / drop / unsure); the app reports precision / recall /
   F1 and a confusion matrix of `select_assessments()` against your decisions —
   most meaningfully on an unbiased, country-balanced random sample.

It reads the sidecar cache **read-only** via the exported `index_cache()`,
`score_keywords()`, and `select_assessments()`, and never mutates package
functions. Review decisions and offline translations are stored separately.

## Running

```r
planscanR::run_biogain_review()                       # package cache + user data dir
planscanR::run_biogain_review(cache_dir = "/path/to/plans", port = 7654)
```

- **Cache** (where the sidecars live): `cache_dir` arg → `PLANSCANR_CACHE` env →
  `getOption("planscanR.cache_dir")` → the package default user cache.
- **App data** (snapshot + `reviews.csv` + reviewers list): `data_dir` arg →
  `BIOGAIN_REVIEW_DATA` env → `tools::R_user_dir("planscanR", "data")`.

Optional R packages: shiny, bslib, reactable, plotly, htmltools, jsonlite.
Translation uses the Python `argostranslate` package via reticulate (models
download once on first use).

## How it works

- **Snapshot.** On first launch the app walks the sidecar cache via
  `index_cache()`, enriches each record with scalar helper columns (cosine max,
  keyword total, attachment / download counts), and caches the result to
  `<data_dir>/corpus_snapshot.rds`. Later launches load that instantly; use the
  **Rebuild snapshot** button after a new pipeline run.
- **Selection** is recomputed live by calling `select_assessments()` with the
  slider thresholds — so the funnel always reflects the real selection rule.
- **Review decisions** persist to `<data_dir>/reviews.csv` (one row per record:
  decision, source, reviewer, note, timestamp, and the cache-relative
  `sidecar_path`). A reviewer name is required before classifying.
- **Translations** are cached non-destructively into each record's sidecar
  (`extras` → `translation_*`), so they survive pipeline rescans.

## Files

| File | Role |
|---|---|
| `app.R` | UI + server (Funnel, Review, Random review tabs) |
| `R/data.R` | snapshot build/load, selection wrapper, random sampling |
| `R/funnel.R` | per-stage counts, interactive plotly funnel, agreement metrics |
| `R/store.R` | review-decision + reviewers persistence (CSV) |
| `R/table.R` | styled reactable, fold-down + single-record views |
| `R/translate.R` | offline Argos translation + sidecar translation cache |

The launcher lives in the package at `R/biogain_review_app.R`
(`run_biogain_review()`).
