# Names of the features the selection model is trained on.

The default set is the three numeric relevance signals already persisted
on every sidecar: one cosine score per BIOGAIN topic
(`relevance_score_<slug>`), one zero-shot classifier score per candidate
label (`class_score_<slug>`), and the keyword total (`kw_total`).

## Usage

``` r
selection_feature_names(
  topics = biogain_assessment_topics(),
  labels = biogain_classification_labels(),
  include = character(0)
)
```

## Arguments

- topics:

  Named topic vector naming the cosine columns. Defaults to
  [`biogain_assessment_topics()`](https://barthoekstra.github.io/planscanR/reference/biogain_assessment_topics.md).

- labels:

  Named classifier-label vector naming the classifier columns. Defaults
  to
  [`biogain_classification_labels()`](https://barthoekstra.github.io/planscanR/reference/biogain_classification_labels.md).

- include:

  Optional extra feature columns to append (off by default). Recognised:
  `"country"`, `"native_type"`. These are country-specific and will not
  transfer to an unseen portal — opt in only when training and
  predicting on the same set of countries.

## Value

A character vector of feature column names, in a stable order.

## Examples

``` r
selection_feature_names()
#>  [1] "relevance_score_wind"                      
#>  [2] "relevance_score_solar"                     
#>  [3] "relevance_score_power_grid"                
#>  [4] "relevance_score_renewable_energy"          
#>  [5] "relevance_score_energy_transition_strategy"
#>  [6] "relevance_score_renewable_zoning"          
#>  [7] "class_score_wind"                          
#>  [8] "class_score_solar"                         
#>  [9] "class_score_power_grid"                    
#> [10] "class_score_other_renewable"               
#> [11] "class_score_energy_strategy"               
#> [12] "class_score_renewable_zoning"              
#> [13] "class_score_fossil_power"                  
#> [14] "class_score_oil_gas_extraction"            
#> [15] "class_score_nuclear"                       
#> [16] "class_score_water"                         
#> [17] "class_score_land_use"                      
#> [18] "class_score_transport"                     
#> [19] "class_score_other"                         
#> [20] "kw_total"                                  
selection_feature_names(include = "country")
#>  [1] "relevance_score_wind"                      
#>  [2] "relevance_score_solar"                     
#>  [3] "relevance_score_power_grid"                
#>  [4] "relevance_score_renewable_energy"          
#>  [5] "relevance_score_energy_transition_strategy"
#>  [6] "relevance_score_renewable_zoning"          
#>  [7] "class_score_wind"                          
#>  [8] "class_score_solar"                         
#>  [9] "class_score_power_grid"                    
#> [10] "class_score_other_renewable"               
#> [11] "class_score_energy_strategy"               
#> [12] "class_score_renewable_zoning"              
#> [13] "class_score_fossil_power"                  
#> [14] "class_score_oil_gas_extraction"            
#> [15] "class_score_nuclear"                       
#> [16] "class_score_water"                         
#> [17] "class_score_land_use"                      
#> [18] "class_score_transport"                     
#> [19] "class_score_other"                         
#> [20] "kw_total"                                  
#> [21] "country"                                   
```
