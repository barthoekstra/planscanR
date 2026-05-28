# Run a single web-search query through a backend.

The dispatching half of the search-backend interface. Returns a list of
result objects; each is a named list with at least `url`.
Implementations are responsible for honouring `include_domains` and
`max_results` to the best of the underlying API's ability.

## Usage

``` r
web_search(backend, query, include_domains = NULL, max_results = 10L)
```

## Arguments

- backend:

  A `planscanR_search_backend`.

- query:

  Character scalar.

- include_domains:

  Character vector, or `NULL` for no domain restriction.

- max_results:

  Integer cap on results (default 10).

## Value

List of result objects.
