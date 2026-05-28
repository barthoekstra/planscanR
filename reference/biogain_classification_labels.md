# Candidate labels for BIOGAIN zero-shot classification.

A named character vector: names are stable slugs (used as column
suffixes, e.g. `class_score_wind`), values are the natural-language
hypotheses fed to the zero-shot model. The set is **mutually exclusive**
(used with `multi_label = FALSE`): a record is assigned its single best
label.

## Usage

``` r
biogain_classification_labels()
```

## Value

A named character vector with a `"relevant"` attribute.

## Details

Crucially it mixes positive energy classes with explicit **negative**
classes (water management, general land-use / spatial planning, other
non-energy). A record whose best label is a negative class is classified
as not-relevant — this is what removes the `Flurneuordnung` /
`Wasserwirtschaft` / business-park records that clear a cosine 0.5 on
the noisy `renewable_zoning` topic.

The `relevant` attribute lists which slugs count as BIOGAIN-relevant.

## Examples

``` r
biogain_classification_labels()
#>                                                                                                         wind 
#>                                                                         "a wind energy or wind farm project" 
#>                                                                                                        solar 
#>                                                                     "a solar energy or photovoltaic project" 
#>                                                                                                   power_grid 
#>                                  "an electricity power line, overhead transmission line, or grid substation" 
#>                                                                                              other_renewable 
#>                                                "a biomass, biogas, geothermal, or hydropower energy project" 
#>                                                                                              energy_strategy 
#>                                                       "a regional energy transition strategy or energy plan" 
#>                                                                                             renewable_zoning 
#>                                 "designating land or search areas for building wind turbines or solar farms" 
#>                                                                                                 fossil_power 
#>                          "a fossil-fuel power plant: coal, natural gas, or oil-fired electricity generation" 
#>                                                                                           oil_gas_extraction 
#>                              "an oil, natural gas, or hydrocarbon extraction, drilling, or refining project" 
#>                                                                                                      nuclear 
#>                                                                    "a nuclear power or nuclear fuel project" 
#>                                                                                                        water 
#>                                                        "a water management or hydraulic engineering project" 
#>                                                                                                     land_use 
#> "a general spatial or zoning plan not about energy, such as housing, business parks, rural areas, or nature" 
#>                                                                                                    transport 
#>                                       "a road, motorway, railway, or other transport infrastructure project" 
#>                                                                                                        other 
#>                                             "an agriculture, industry, housing, or other non-energy project" 
#> attr(,"relevant")
#> [1] "wind"             "solar"            "power_grid"       "other_renewable" 
#> [5] "energy_strategy"  "renewable_zoning"
attr(biogain_classification_labels(), "relevant")
#> [1] "wind"             "solar"            "power_grid"       "other_renewable" 
#> [5] "energy_strategy"  "renewable_zoning"
```
