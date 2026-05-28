# Apply the BIOGAIN selection rule to scored + classified records.

Combines the three relevance signals into one decision:

## Usage

``` r
select_assessments(
  records,
  topics = biogain_assessment_topics(),
  relevance_threshold = 0.5,
  kw_min = 2L,
  nonrenewable = c("fossil_power", "oil_gas_extraction", "nuclear"),
  nonrenewable_score = 0.5
)
```

## Arguments

- records:

  A tibble that has been scored (`relevance_score_<slug>` columns) and
  classified (`class_label`, `class_relevant`, `class_score`). Keyword
  columns (`kw_total`) are computed via
  [`score_keywords()`](https://barthoekstra.github.io/planscanR/reference/score_keywords.md)
  if absent.

- topics:

  Named topic vector whose slugs name the cosine columns to consider.
  Defaults to
  [`biogain_assessment_topics()`](https://barthoekstra.github.io/planscanR/reference/biogain_assessment_topics.md).

- relevance_threshold:

  Cosine cutoff; a record is cosine-relevant if any topic clears it.
  Default `0.5`.

- kw_min:

  Minimum `kw_total` for the keyword arm to fire. Default `2`.

- nonrenewable:

  Classifier labels treated as confidently-off-target when their
  `class_score` clears `nonrenewable_score`.

- nonrenewable_score:

  Confidence cutoff for the non-renewable trim.

## Value

`records` with a logical `selected` column added (and `cosine_max`,
`cosine_relevant`, and keyword columns if they were not already
present).

## Details

\$\$selected = (cosine\\relevant \lor class\\relevant \lor kw\\total \ge
kw\\min) \land \lnot\\confident\\nonrenewable\$\$

Rationale (from the NL analysis): the three signals are complementary —
the cosine gate misses near-threshold energy records, the classifier
mislabels some into negative classes, and the keyword layer catches
explicit mentions both dilute. Taking their union maximises recall (this
is a pre-acquisition gate; precision is recoverable downstream), while
the fossil/oil-gas/nuclear trim removes confidently non-renewable
records that are off-target for BIOGAIN.

## Examples

``` r
if (FALSE) { # \dontrun{
recs <- classify_assessments(index_cache(country = "nl"))
sel <- select_assessments(recs)
table(sel$selected)
} # }
```
