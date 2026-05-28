# Discovery configuration for the Austrian UVP-DB.

Returns a named list of inputs that
[`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
uses to build queries for AT records and to validate candidate PDFs.
AT-specific rationale lives next to each field; the keys themselves are
part of the discovery-config contract that every country should provide.

## Usage

``` r
at_discovery_config()
```

## Value

A list with the following named elements:

- `query_templates` — list of function(record) -\> character, each
  producing one search query (or NULL to skip).

- `state_domains` — named list `bundesland -> character vector` of
  authority domains to scope queries to.

- `aktenzahl_regex` — regex that detects the country's primary
  identifier in PDF text. For AT it matches the UBA-internal AZ
  `02 NNNN` plus a couple of dash/no-space variants.

- `extract_proponent` — function(record) -\> character, pulls the
  proponent name out of the record's summary (returns NA on failure).

- `extra_signals` — character vector of additional patterns the
  validator will check for in PDF text (e.g. legal-basis strings).

## Examples

``` r
if (FALSE) { # \dontrun{
cfg <- at_discovery_config()
rec <- index_cache(country = "at")[1, ]
lapply(cfg$query_templates, function(f) f(rec))
} # }
```
