# Explicit assessment sources.

Lists the opt-in sources selectable with `get_assessments(source = )`,
in addition to the national portals reported by
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).

## Usage

``` r
get_assessments_sources()
```

## Value

A tibble with columns `source`, `name`, `granularity`, `geography`,
`scope`, `limitations`, `url` (zero rows when no source is registered).

## See also

[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md),
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)

## Examples

``` r
get_assessments_sources()
#> # A tibble: 5 × 7
#>   source    name                   granularity geography scope limitations url  
#>   <chr>     <chr>                  <chr>       <chr>     <chr> <chr>       <chr>
#> 1 worldbank World Bank Documents … document    "ISO-2 c… Disc… Document-l… http…
#> 2 eib       European Investment B… document (… "ISO-2 c… envi… not nation… http…
#> 3 be_dsi    Flanders DSI planning… planning d… "Flander… Flem… Document c… http…
#> 4 ifc       IFC project disclosur… project (E… "ISO-2 c… IFC … Document r… http…
#> 5 aiib      Asian Infrastructure … project (a… "ISO-2 c… 505 … Only some … http…
```
