# Build a Tavily search backend.

Requires a Tavily API key in the `TAVILY_API_KEY` environment variable
(set in `~/.Renviron` or per-session with
[`Sys.setenv()`](https://rdrr.io/r/base/Sys.setenv.html)).

## Usage

``` r
search_backend_tavily(
  api_key = NULL,
  search_depth = c("basic", "advanced"),
  max_results_cap = 10L
)
```

## Arguments

- api_key:

  Optional explicit key. Defaults to `Sys.getenv("TAVILY_API_KEY")`.
  Stored on the backend object — never logged or persisted by the
  package.

- search_depth:

  Either `"basic"` (default, cheaper) or `"advanced"` (deeper crawl per
  result, ~3x the cost).

- max_results_cap:

  Hard cap passed through as `max_results`. Tavily allows up to 20;
  default 10.

## Value

A `planscanR_search_backend`.

## Examples

``` r
if (FALSE) { # \dontrun{
Sys.setenv(TAVILY_API_KEY = "tvly-...")
tav <- search_backend_tavily()
web_search(tav, "Windpark Parndorf Bescheid filetype:pdf")
} # }
```
