# Getting started with planscanR

`planscanR` helps you find environmental-assessment records —
Environmental Impact Assessments (EIA), Strategic Environmental
Assessments (SEA), and related advice — across European government
portals. It fetches records into a tidy table, caches them on disk, and
(optionally) downloads their PDF documents.

It is a pure-R fetcher: scoring records by topic relevance lives in the
companion package **planscanR.screen**. This vignette covers planscanR
itself — fetching and the offline cache.

## Terminology

A few terms recur throughout planscanR and its documentation:

- **Record** — one result row: a single environmental-assessment case as
  returned by
  [`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
- **Assessment** — the case *type*: an Environmental Impact Assessment
  (EIA), a Strategic Environmental Assessment (SEA), or related advice.
- **Document** (or **attachment**) — a file belonging to a record,
  usually the assessment PDF, the decision, or a non-technical summary.
- **Offline metadata cache** — the on-disk store of fetched record
  metadata under the cache root, so records can be re-read without
  returning to the portal. Each record’s metadata is one JSON file (a
  *sidecar*);
  [`index_cache()`](https://barthoekstra.github.io/planscanR/reference/index_cache.md)
  reads them all back.

## Fetch records

A single function,
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
retrieves records from a portal. You choose the country with a
two-letter code:

``` r

records <- get_assessments("nl", limit = 20, download = FALSE)
records
```

Two arguments are worth knowing from the start:

- `limit` caps how many records come back. The portals hold thousands of
  records, so always start small while you are exploring.
- `download` controls whether the actual PDF documents are fetched to
  your computer. Leave it `FALSE` until you have narrowed down which
  records you want — then the documents for those records are a quick
  second call away.

Whichever country you ask for, the result is a table with the same core
columns (`country`, `url`, `title`, `summary`, the document links, and
so on), so you can fetch from several countries and stack the results:

``` r

nl <- get_assessments("nl", limit = 20, download = FALSE)
de <- get_assessments("de", limit = 20, download = FALSE)
both <- bind_results(nl, de)
```

To see which countries and search options are available, use:

``` r

get_assessments_coverage()
```

## Working offline

Every record you fetch is saved to the offline metadata cache under the
cache root, which you can read back later without going to the portal at
all:

``` r

records <- index_cache(country = "nl")
```

This is handy for picking up where you left off, or for re-scoring an
existing set of records against new topics. The cache root resolves
through
[`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md);
[`clear_cache()`](https://barthoekstra.github.io/planscanR/reference/clear_cache.md)
wipes the downloaded files but leaves the cached record metadata (and
any derived artefacts) in place.

## Scoring records (optional)

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
accepts an optional `topic` (and `relevance_threshold`) to score records
during the fetch and gate PDF downloads on the score:

``` r

records <- get_assessments(
  "nl",
  topic = c(wind = "wind energy", solar = "solar energy"),
  relevance_threshold = 0.5,
  limit = 20,
  download = FALSE
)
# One score column per topic, plus the model that produced them.
records[c("title", "relevance_score_wind", "relevance_score_solar", "relevance_model")]
```

Each topic adds a `relevance_score_<name>` column. `relevance_threshold`
only *gates downloads* — it never drops records, so every record still
appears in the table and the offline metadata cache, and re-running with
a different threshold needs no network. The scoring itself is delegated
to the **planscanR.screen** package: install it to enable `topic =`, and
see its “Scoring records” vignette for the walkthrough. Without it, omit
`topic` and planscanR fetches without scoring — no Python required.

## Where to go next

- [`?get_assessments`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  — every fetching option, including date and region filters.
- [`?get_assessments_nl`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md),
  [`?get_assessments_de`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md),
  [`?get_assessments_fr`](https://barthoekstra.github.io/planscanR/reference/get_assessments_fr.md),
  [`?get_assessments_at`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md),
  [`?get_assessments_dk`](https://barthoekstra.github.io/planscanR/reference/get_assessments_dk.md),
  [`?get_assessments_be`](https://barthoekstra.github.io/planscanR/reference/get_assessments_be.md),
  [`?get_assessments_ee`](https://barthoekstra.github.io/planscanR/reference/get_assessments_ee.md),
  [`?get_assessments_fi`](https://barthoekstra.github.io/planscanR/reference/get_assessments_fi.md),
  [`?get_assessments_bg`](https://barthoekstra.github.io/planscanR/reference/get_assessments_bg.md),
  [`?get_assessments_cz`](https://barthoekstra.github.io/planscanR/reference/get_assessments_cz.md),
  [`?get_assessments_hr`](https://barthoekstra.github.io/planscanR/reference/get_assessments_hr.md),
  [`?get_assessments_gr`](https://barthoekstra.github.io/planscanR/reference/get_assessments_gr.md),
  [`?get_assessments_is`](https://barthoekstra.github.io/planscanR/reference/get_assessments_is.md),
  [`?get_assessments_ie`](https://barthoekstra.github.io/planscanR/reference/get_assessments_ie.md)
  — the portal-specific details for each country.
- [**planscanR.screen**](https://barthoekstra.github.io/planscanR.screen/)
  — score records by topic relevance, classify them, and learn a
  selection model.
