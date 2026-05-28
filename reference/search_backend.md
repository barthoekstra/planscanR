# Build a custom search backend.

Wraps a user-supplied search function as a `planscanR_search_backend`
object compatible with
[`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md).
Use this when you have an in-house search service, want to swap to Bing
/ Brave / Google CSE without waiting for first-party support, or need a
deterministic mock in tests.

## Usage

``` r
search_backend(name, search_fn)
```

## Arguments

- name:

  Short identifier for the backend (e.g. `"tavily"`, `"google-cse"`).
  Surfaced in logs and the sidecar `discovery_log[]`.

- search_fn:

  A function `function(query, include_domains, max_results)` returning a
  list of result objects, each a named list with at minimum `url`
  (character) and optionally `title`, `content`, `score`.

## Value

A `planscanR_search_backend` object.

## Examples

``` r
if (FALSE) { # \dontrun{
my_backend <- search_backend(
  name = "fake-google",
  search_fn = function(query, include_domains, max_results) {
    list(list(url = "https://example.org/x.pdf", title = "Test", score = 1))
  }
)
web_search(my_backend, "windpark parndorf", NULL, 5)
} # }
```
