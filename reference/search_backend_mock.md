# Build an in-memory mock search backend.

Returns a `planscanR_search_backend` that looks up incoming queries in a
static map and returns the canned responses. Used by the test suite (no
live HTTP) and by
[`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
when you want a fully deterministic replay against a cached corpus.

## Usage

``` r
search_backend_mock(responses = list())
```

## Arguments

- responses:

  Named list. Names are queries (matched exactly first, then by
  [`grepl()`](https://rdrr.io/r/base/grep.html) substring) and values
  are lists of result objects (each `list(url, title, content, score)`).
  Names not used are matched via the special key `"_default"` if
  supplied; absent that, an unmatched query yields an empty list.

## Value

A `planscanR_search_backend`.

## Examples

``` r
if (FALSE) { # \dontrun{
mock <- search_backend_mock(list(
  "windpark parndorf" = list(
    list(url = "https://x.example/parndorf.pdf", title = "Bescheid")
  ),
  "_default" = list()
))
web_search(mock, "windpark parndorf")
} # }
```
