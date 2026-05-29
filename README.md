# planscanR

`planscanR` collects environmental-assessment records — Environmental Impact
Assessments (EIA), Strategic Environmental Assessments (SEA), and related
advice — from European government portals, and gives you one consistent table
to work with no matter which country a record came from.

It was built for the [BIOGAIN](https://www.biodiversa.eu/) project, which studies
how to achieve a net gain in biodiversity when planning where energy
infrastructure goes. To do that, the project needs to find the relevant
assessments scattered across national portals — which is what this package
automates.

## What it does

1. **Fetch.** One function, `get_assessments()`, retrieves records from a
   national portal and returns them as a tidy table. The same columns come back
   for every country, so you can stack results together.
2. **Score.** Optionally rank each record by how closely it matches topics you
   care about (e.g. wind, solar, power grids), using a multilingual text-similarity
   model so a German record and a Dutch one are judged on the same footing.
3. **Select.** Combine the relevance signals into a single keep/drop decision,
   so you can narrow thousands of records down to the ones worth reading.

Supported portals:

| Country | Portal | Notes |
|---|---|---|
| Netherlands (`"nl"`) | Commissie m.e.r. adviezenregister | full records + document downloads |
| Germany (`"de"`) | UVP-Verbund | full records + document downloads |
| Austria (`"at"`) | Umweltbundesamt UVP-DB | record details only (no documents) |
| Denmark (`"dk"`) | Danmarks Miljøportal EA-Hub | record metadata + polygon geometry + document downloads|

See `vignette("supported_sources")` for per-portal details: how each portal
is accessed, what filters are honoured, and what data comes back.

## A word of caution

> [!WARNING]
> `planscanR` is only as stable as the portals it pulls from. None of the
> target sites expose a contractually stable API; most are scraped from HTML
> detail pages, and the rest sit on undocumented JSON endpoints that the portal
> operators can change at will. A tiny redesign on any of these sites — a
> renamed CSS class, a moved field, a new login wall — is enough to break the
> corresponding handler, sometimes silently. Treat results with a healthy dose
> of scepticism, sanity-check them against the portal's own UI when something
> looks off, and please file an issue when you spot drift.

> [!CAUTION]
> Because we are often not talking to real APIs, we have no formal rate-limit
> contract with these servers. The package throttles requests where we know it
> matters (e.g. NL is capped at ~1 request per second, DK at 5), but you can
> override those, and a careless full-register crawl can put real load on a
> small government portal. Use `limit` and `query` while exploring, keep the
> throttle on for production runs, and don't scan everything in parallel from
> many machines.

## Installation

```r
# install.packages("pak")
pak::pak("barthoekstra/planscanR")
```

The relevance-scoring step uses a Python model through
[reticulate](https://rstudio.github.io/reticulate/). Install it once with:

```r
reticulate::py_install("sentence-transformers")
```

You only need this if you pass a `topic` to `get_assessments()`; plain fetching
works without it.

## Quick start

```r
library(planscanR)

# Grab 20 records from the Netherlands (no documents downloaded yet).
records <- get_assessments("nl", limit = 20, download = FALSE)

# Score them against the BIOGAIN energy topics and keep the relevant ones.
records <- get_assessments(
  "nl",
  topic = biogain_assessment_topics(),
  relevance_threshold = 0.5,
  limit = 20,
  download = FALSE
)
records$relevance_score_wind
```

See `vignette("planscanR")` for an end-to-end walkthrough (fetch → score →
select), and `get_assessments_coverage()` for the portals and search options
available at runtime.

## License

GPL (>= 3).
