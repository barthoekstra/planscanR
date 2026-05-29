# Apply the BIOGAIN selection rule to scored + classified records.

Combines the three relevance signals into one decision. A record is
**selected** when any one of the signals fires —

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

- the embedding cosine score clears the relevance threshold, OR

- the classifier labels it as a relevant (renewable-energy) type, OR

- it contains at least `kw_min` keyword hits —

*and* it is not confidently off-target (not classified as fossil power,
oil/gas extraction, or nuclear above `nonrenewable_score`).

Rationale (from the NL analysis): the three signals are complementary —
the cosine score misses some near-threshold energy records, the
classifier mislabels some into negative classes, and the keyword layer
catches explicit mentions the other two dilute. Taking their union
favours recall (this step runs before acquisition; precision can still
be improved downstream), while the fossil/oil-gas/nuclear trim drops
records that are clearly off-target for BIOGAIN.

## Examples

``` r
if (FALSE) { # \dontrun{
recs <- classify_assessments(index_cache(country = "nl"))
sel <- select_assessments(recs)
table(sel$selected)
} # }
```
