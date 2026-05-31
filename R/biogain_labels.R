# BIOGAIN zero-shot classification labels.
#
# The candidate-label set for the zero-shot classifier driver
# (`classify_assessments()`). Extracted from `classify_assessments.R` so the
# generic classifier framework can live without the BIOGAIN-specific config.

#' Candidate labels for BIOGAIN zero-shot classification.
#'
#' A named character vector: names are stable slugs (used as column suffixes,
#' e.g. `class_score_wind`), values are the natural-language hypotheses fed to
#' the zero-shot model. The set is **mutually exclusive** (used with
#' `multi_label = FALSE`): a record is assigned its single best label.
#'
#' Crucially it mixes positive energy classes with explicit **negative**
#' classes (water management, general land-use / spatial planning, other
#' non-energy). A record whose best label is a negative class is classified
#' as not-relevant — this is what removes the `Flurneuordnung` /
#' `Wasserwirtschaft` / business-park records that clear a cosine 0.5 on the
#' noisy `renewable_zoning` topic.
#'
#' The `relevant` attribute lists which slugs count as BIOGAIN-relevant.
#'
#' @return A named character vector with a `"relevant"` attribute.
#' @export
#' @examples
#' biogain_classification_labels()
#' attr(biogain_classification_labels(), "relevant")
biogain_classification_labels <- function() {
  labels <- c(
    # --- positive (BIOGAIN-relevant) energy classes ---
    # Phrasings tuned on a borderline DE sample: `power_grid` is restricted to
    # real transmission infrastructure (otherwise it over-attracts biomass /
    # biogas / heating records), and `other_renewable` explicitly claims
    # biomass/biogas/geothermal/hydropower so those land there instead of grid.
    wind = "a wind energy or wind farm project",
    solar = "a solar energy or photovoltaic project",
    power_grid = "an electricity power line, overhead transmission line, or grid substation",
    other_renewable = "a biomass, biogas, geothermal, or hydropower energy project",
    energy_strategy = "a regional energy transition strategy or energy plan",
    # Counterpart to the cosine `renewable_zoning` topic. Phrased around the
    # facilities (wind turbines / solar farms) rather than generic "zoning /
    # spatial plan" wording, because the latter collides with the negative
    # `land_use` class and lets generic plans (housing, rural bestemmingsplan,
    # ports) tip into this relevant class by a hair. Keeping it facility-
    # specific separates a "Windturbines Amsterdam-Noord" siting plan from a
    # "Woningbouw" housing plan.
    renewable_zoning = "designating land or search areas for building wind turbines or solar farms",
    # --- negative / distractor classes ---
    # `fossil_power` / `oil_gas_extraction` / `nuclear` give non-renewable
    # energy projects a proper home; without them, gas/coal/nuclear records
    # leak into `other_renewable` (the nearest energy bucket). They are NOT
    # BIOGAIN-relevant.
    fossil_power = "a fossil-fuel power plant: coal, natural gas, or oil-fired electricity generation",
    oil_gas_extraction = "an oil, natural gas, or hydrocarbon extraction, drilling, or refining project",
    nuclear = "a nuclear power or nuclear fuel project",
    water = "a water management or hydraulic engineering project",
    # Explicitly non-energy + concrete examples, so generic spatial plans land
    # here instead of tying with `renewable_zoning`.
    land_use = "a general spatial or zoning plan not about energy, such as housing, business parks, rural areas, or nature",
    transport = "a road, motorway, railway, or other transport infrastructure project",
    other = "an agriculture, industry, housing, or other non-energy project"
  )
  attr(labels, "relevant") <- c(
    "wind",
    "solar",
    "power_grid",
    "other_renewable",
    "energy_strategy",
    "renewable_zoning"
  )
  labels
}
