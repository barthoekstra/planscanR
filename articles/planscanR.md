# Getting started with planscanR

`planscanR` helps you find environmental-assessment records —
Environmental Impact Assessments (EIA), Strategic Environmental
Assessments (SEA), and related advice — across European government
portals. This vignette walks through the three steps you will use most:

1.  **Fetch** records from a portal.
2.  **Score** them by how relevant they are to topics you care about.
3.  **Select** the ones worth reading.

## 1. Fetch records

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

## 2. Score records by relevance

Portals return everything; usually you only want records about a
particular subject. Pass a `topic` and each record’s title and summary
are compared against it, producing a relevance score between -1 and 1
(higher means a closer match).

A topic is just a short phrase. You can pass one phrase, or several
named ones:

``` r

get_assessments(
  "nl",
  topic = c(wind = "wind energy", solar = "solar energy"),
  limit = 20,
  download = FALSE
)
```

This adds a `relevance_score_wind` and `relevance_score_solar` column to
the table. Because the comparison is done with a multilingual model, an
English topic phrase still matches Dutch or German text — you do not
need to translate your topics for each country.

The BIOGAIN project uses a standard set of six energy topics, returned
by
[`biogain_assessment_topics()`](https://barthoekstra.github.io/planscanR/reference/biogain_assessment_topics.md):

``` r

biogain_assessment_topics()
#>                                                        wind 
#>                                               "wind energy" 
#>                                                       solar 
#>                                              "solar energy" 
#>                                                  power_grid 
#> "power lines, distribution and transmission infrastructure" 
#>                                            renewable_energy 
#>                                          "renewable energy" 
#>                                  energy_transition_strategy 
#>          "regional energy transition strategy and planning" 
#>                                            renewable_zoning 
#>  "renewable energy zoning and designated development areas"
```

Pass that whole set as the topic, and optionally a
`relevance_threshold`. The threshold only affects **downloading**:
records below it still appear in your table (with their scores), but
their PDF documents are skipped. That means you can re-run later with a
different threshold without fetching from the portal again.

``` r

records <- get_assessments(
  "nl",
  topic = biogain_assessment_topics(),
  relevance_threshold = 0.5,
  limit = 50,
  download = FALSE
)
```

> **One-time setup.** Relevance scoring runs a small Python model
> through the reticulate package. Install it once per machine with
> `reticulate::py_install("sentence-transformers")`. Plain fetching (no
> `topic`) does not need this.

## 3. Select the records worth reading

Scoring gives you numbers;
[`select_assessments()`](https://barthoekstra.github.io/planscanR/reference/select_assessments.md)
turns them into a single keep-or-drop decision. It combines three
complementary signals — the relevance score above, a topic classifier,
and a count of energy-related keywords — and marks a record as selected
if any signal points to “relevant”, unless the record is clearly about
something off-topic (such as fossil power or nuclear).

``` r

selected <- select_assessments(records)
table(selected$selected)
```

The result adds a `selected` column you can filter on. Casting a wide
net here is deliberate: it is better to keep a few borderline records
than to miss a relevant one, and you can always tighten the decision
afterwards.

## Working offline

Every record you fetch is saved to a small file on disk (a “sidecar”).
You can read those back later without going to the portal at all:

``` r

records <- index_cache(country = "nl")
```

This is handy for re-scoring an existing set of records against new
topics, or for picking up where you left off. To re-score records you
already have, use
[`score_assessments()`](https://barthoekstra.github.io/planscanR/reference/score_assessments.md):

``` r

records <- score_assessments(records, topic = biogain_assessment_topics())
```

## Where to go next

- [`?get_assessments`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
  — every fetching option, including date and region filters.
- [`?get_assessments_nl`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md),
  [`?get_assessments_de`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md),
  [`?get_assessments_at`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md)
  — the portal-specific details for each country.
- [`run_biogain_review()`](https://barthoekstra.github.io/planscanR/reference/run_biogain_review.md)
  — a point-and-click app for inspecting how records flow through fetch
  → score → select, and for building a hand-checked benchmark.
