# planscanR

`planscanR` collects environmental-assessment records — Environmental Impact
Assessments (EIA), Strategic Environmental Assessments (SEA), and related
advice — from European government portals, and gives you one consistent table
to work with no matter which country a record came from.

It was built for the [BIOGAIN](https://www.github.com/BIOGAIN) project, which studies
how to achieve a net gain in biodiversity when planning where energy
infrastructure goes. To do that, the project needs to find the relevant
assessments scattered across national portals — which is what this package
automates.

## What it does

One function, `get_assessments()`, retrieves records from a national portal and
returns them as a tidy table. The same columns come back for every country, so
you can stack results together, cache them on disk, and (optionally) download
their PDF documents.

`planscanR` only fetches. Scoring, classification, and selection live in its
companion package
**[planscanR.screen](https://github.com/barthoekstra/planscanR.screen)** — score
records by topic relevance, classify them, and learn a selection model.

As a convenience, `get_assessments()` can score records *during* the fetch (pass
a `topic`) and gate PDF downloads on the score — but the embedding work is
delegated to planscanR.screen, which is an optional dependency (see
[Scoring](#scoring-optional) below). Omit `topic` and no Python is required.

Supported portals:

| Country | Portal | Notes |
|---|---|---|
| Netherlands (`"nl"`) | Commissie m.e.r. adviezenregister | full records + document downloads |
| Germany (`"de"`) | UVP-Verbund | full records + document downloads |
| France (`"fr"`) | Projets-Environnement (OpenDataSoft API) | full records + WGS84 geometry + document downloads (étude d'impact, RNT, avis AE) |
| Austria (`"at"`) | Umweltbundesamt UVP-DB | record details only (no documents) |
| Denmark (`"dk"`) | Danmarks Miljøportal EA-Hub | record metadata + polygon geometry (document downloads deferred) |
| Belgium (Flanders) (`"be"`) | Departement Omgeving MER-register | full records + polygon geometry + document downloads |
| Estonia (`"ee"`) | Keskkonnaamet KOTKAS (KMH + KSH) | EIA + SEA in one handler, full records + polygon geometry + document downloads |
| Finland (`"fi"`) | ymparisto.fi (Elasticsearch proxy + HTML attachment scrape) | **EIA/YVA only** (no SEA in register), full records + document downloads (no geometry) |
| Bulgaria (`"bg"`) | МОСВ registers (ОВОС + ЕО) | EIA + SEA in one handler, full records + document downloads (no geometry) |
| Czech Republic (`"cz"`) | CENIA EIA/SEA (eia100_cr + SEA100_koncepce) | EIA + SEA in one handler, domestic CZ only, full records + document downloads (no geometry) |
| Croatia (`"hr"`) | mzozt.gov.hr CMS pages (PUO + SPUO) | EIA + SEA in one handler, scraped CMS pages (no API), full records + document downloads (no geometry) |
| Greece (`"gr"`) | ΗΠΜ / EPRM JSON:API (`eprm.ypen.gr`) | **AEPO decisions only** (EIA studies + SEA are login-gated), full records + WGS84 point geometry + one Diavgeia decision PDF |
| Iceland (`"is"`) | Skipulagsgátt GraphQL API (`skipulagsgatt.is`) | EIA (screening + full) + SEA in one handler, **cases from ~June 2023 onward**, full records + WGS84 geometry + phase-file document downloads |
| Ireland (`"ie"`) | gov.ie EIA Portal (Esri ArcGIS REST FeatureServer) | **EIA only** (no SEA register), full records + ITM (EPSG:2157) point geometry; portal hosts only the newspaper-notice PDF — the **full EIAR is off-portal** on the competent-authority sites |

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
> looks off, and please file an issue when you spot differences.

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

Plain fetching needs nothing else — `planscanR` is pure R, no Python. Topic
scoring is optional and provided by the sibling package, which pulls in a
multilingual text-similarity model through
[reticulate](https://rstudio.github.io/reticulate/):

```r
pak::pak("barthoekstra/planscanR.screen")
reticulate::py_install("sentence-transformers")
```

You only need this if you pass a `topic` to `get_assessments()`.

## Quick start

```r
library(planscanR)

# Grab 20 records from the Netherlands (no documents downloaded yet).
records <- get_assessments("nl", limit = 20, download = FALSE)
```

### Scoring (optional)

With **planscanR.screen** installed, pass a `topic` to score each record as it
is fetched, and use `relevance_threshold` to gate which records' PDFs are
downloaded:

```r
records <- get_assessments(
  "nl",
  topic = c(wind = "wind energy", solar = "solar energy"),
  relevance_threshold = 0.5,
  limit = 20,
  download = FALSE
)
records$relevance_score_wind
```

See `vignette("planscanR")` for an end-to-end walkthrough, and
`get_assessments_coverage()` for the portals and search options available at
runtime.

## License

GPL (>= 3).
