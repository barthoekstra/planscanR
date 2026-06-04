# Tolerant row-bind across result tibbles with differing extra columns.

Wraps
[`dplyr::bind_rows()`](https://dplyr.tidyverse.org/reference/bind_rows.html),
which already pads missing columns with `NA`. Validates the result
schema before returning.

## Usage

``` r
bind_results(...)
```

## Arguments

- ...:

  Tibbles.

## Value

A single tibble.

## Examples

``` r
a <- tibble::tibble(
  country = "nl", source_portal = "x", document_id = "1", url = "https://x/1",
  retrieved_at = as.POSIXct("2024-01-01", tz = "UTC"),
  attachment_urls = list(character()), local_path = list(character())
)
bind_results(a, a)
#> # A tibble: 2 × 7
#>   country source_portal document_id url      retrieved_at        attachment_urls
#>   <chr>   <chr>         <chr>       <chr>    <dttm>              <list>         
#> 1 nl      x             1           https:/… 2024-01-01 00:00:00 <chr [0]>      
#> 2 nl      x             1           https:/… 2024-01-01 00:00:00 <chr [0]>      
#> # ℹ 1 more variable: local_path <list>
```
