# List supported countries and portals.

Returns a tibble describing every country handler currently shipped, the
portal it targets, and the vocabularies of the search facets it accepts.
This is the canonical place to discover what values can be passed to
search parameters like `theme`, `advice_type`, `province`, `status`.

## Usage

``` r
get_assessments_coverage()
```

## Value

A tibble with one row per supported country, columns: `country`,
`source_portal`, `base_url`, `requires_auth`, `status`, plus a
list-column `facets` of named lists giving the valid values for each
search parameter the handler accepts.

## Examples

``` r
get_assessments_coverage()
#> # A tibble: 14 × 6
#>    country source_portal              base_url requires_auth status facets      
#>    <chr>   <chr>                      <chr>    <lgl>         <chr>  <list>      
#>  1 nl      commissiemer.nl            https:/… FALSE         suppo… <named list>
#>  2 de      uvp-verbund.de             https:/… FALSE         suppo… <named list>
#>  3 fr      projets-environnement.gou… https:/… FALSE         suppo… <named list>
#>  4 at      umweltbundesamt.at/uvpdb   https:/… FALSE         suppo… <named list>
#>  5 dk      miljoeportal.dk/eahub      https:/… FALSE         suppo… <named list>
#>  6 be      omgeving.vlaanderen.be/me… https:/… FALSE         suppo… <named list>
#>  7 ee      kotkas.envir.ee            https:/… FALSE         suppo… <named list>
#>  8 fi      ymparisto.fi               https:/… FALSE         suppo… <named list>
#>  9 bg      registers.moew.government… https:/… FALSE         suppo… <named list>
#> 10 cz      portal.cenia.cz            https:/… FALSE         suppo… <named list>
#> 11 hr      mzozt.gov.hr               https:/… FALSE         suppo… <named list>
#> 12 gr      eprm.ypen.gr               https:/… FALSE         suppo… <named list>
#> 13 is      skipulagsgatt.is           https:/… FALSE         suppo… <named list>
#> 14 ie      services.arcgis.com (gov.… https:/… FALSE         suppo… <named list>
```
