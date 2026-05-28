# BIOGAIN keyword lexicon (multilingual).

A named list mapping each BIOGAIN topic to a vector of search terms
across Dutch, German, and English. Terms are matched as **substrings**
of text normalised with the package's diacritic/digraph folding —
substring rather than word-boundary matching because German/Dutch put
the key term mid-word in compounds (`Höchst`**spannung**`sfreileitung`,
`wind`-anything). The folding means the ASCII terms here align with
accented source text (`spannung` matches `Höchstspannung`; `biomas`
matches `Biomasse`).

## Usage

``` r
biogain_keyword_lexicon()
```

## Value

A named list of character vectors, one per topic.

## Examples

``` r
biogain_keyword_lexicon()$wind
#> [1] "wind"       "repowering"
```
