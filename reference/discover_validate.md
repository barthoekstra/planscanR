# Validate a candidate (record, URL) pair against a downloaded PDF.

Runs four signals in order:

## Usage

``` r
discover_validate(
  record,
  pdf_path,
  cfg,
  relevance_model = NULL,
  semantic_threshold = 0.5
)
```

## Arguments

- record:

  A 1-row tibble in the planscanR result shape.

- pdf_path:

  Path to a local copy of the candidate PDF.

- cfg:

  Country discovery config (e.g.
  [`at_discovery_config()`](https://barthoekstra.github.io/planscanR/reference/at_discovery_config.md)).

- relevance_model:

  Optional embedding model for the semantic signal. When `NULL`, the
  semantic signal is skipped (which means signals 1-3 must carry the
  validation).

- semantic_threshold:

  Cosine-similarity threshold for signal 4.

## Value

A list with: `passed` (logical), `signals` (named logical), `notes`
(character), `text` (the extracted first-10-pages text, used downstream
when the candidate is promoted to the sidecar).

## Details

1.  **Aktenzahl exact** — the country's primary identifier appears
    verbatim in the PDF text. Strongest signal.

2.  **Title overlap** — at least 2 content-bearing tokens (\>= 5 chars)
    from the record title appear in the PDF text after diacritic +
    German digraph normalisation.

3.  **Extra-signal presence** — at least one of the country config's
    `extra_signals` (e.g. `"UVP-G 2000"`) is in the PDF, AND the title
    overlap signal also triggered with at least 1 token.

4.  **Semantic backup** — cosine similarity between first-10-pages text
    and the record's title+summary clears `semantic_threshold` (default
    0.5), using the relevance model. Only fires if none of the above
    did.

Any single signal passing is sufficient. The result reports which
signal(s) fired so calling code can apply stricter precision policies if
it wants.
