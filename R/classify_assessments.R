# BIOGAIN zero-shot classification: candidate labels + the offline driver
# that classifies records and (optionally) persists the verdict to sidecars.
#
# This is the "select later" half of the harvest-broad-classify-later design:
# it reads records that were already scanned + scored (from get_assessments()
# or index_cache()) and adds a calibrated, multi-class verdict that includes
# explicit NEGATIVE classes — which is what filters out the planning /
# water-management false-positives that a bare cosine cutoff lets through.

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

#' Build the text fed to the classifier for one record set.
#'
#' Concatenates `title`, `summary`, and — when the portal exposes it — the
#' record's own category (`native_type`, e.g. DE's UVP-Kategorie or AT's
#' category). The category is a strong extra signal where present (it's the
#' portal's own topic taxonomy); records without one (e.g. NL) simply fall
#' back to title + summary.
#' @noRd
classification_text <- function(records) {
  n <- nrow(records)
  get_col <- function(nm) {
    if (nm %in% names(records)) {
      as.character(records[[nm]])
    } else {
      rep(NA_character_, n)
    }
  }
  title <- get_col("title")
  summary <- get_col("summary")
  category <- get_col("native_type")
  vapply(
    seq_len(n),
    function(i) {
      parts <- c(title[i], summary[i], category[i])
      parts <- parts[!is.na(parts) & nzchar(parts)]
      if (length(parts) == 0L) "" else paste(parts, collapse = ". ")
    },
    character(1)
  )
}

#' Classify assessment records with a zero-shot model.
#'
#' Offline pass (no portal calls): for each record, classifies
#' title + summary + category against `labels` and adds the verdict as new
#' columns. Pairs with [index_cache()] and [score_assessments()] — same
#' harvest-broad-classify-later workflow.
#'
#' Added columns:
#' * `class_label` — best label slug.
#' * `class_score` — probability of the best label.
#' * `class_relevant` — `TRUE` if the best label is in the `relevant`
#'   attribute of `labels` (i.e. an energy class, not a negative class).
#' * `class_model` — the classifier's name.
#' * `class_score_<slug>` — one column per label with its probability.
#'
#' @param records A tibble (from [get_assessments()] / [index_cache()]); must
#'   have at least `title` (and ideally `summary`, `native_type`).
#' @param classifier A `planscanR_classifier`. Defaults to
#'   [classify_model_zeroshot()].
#' @param labels Named character vector of candidate labels (see
#'   [biogain_classification_labels()], the default). A `relevant` attribute
#'   marks which slugs are BIOGAIN-relevant; if absent, every label is treated
#'   as relevant.
#' @param multi_label If `FALSE` (default) labels are mutually exclusive
#'   (softmax); the negative classes then compete with the positive ones,
#'   which is the point. `TRUE` scores each label independently.
#' @param batch_size Number of records handed to the classifier per call —
#'   controls progress granularity and R-Python round trips. This is distinct
#'   from the model's GPU `batch_size` (set on [classify_model_zeroshot()]),
#'   which controls how the NLI pairs are batched through the device.
#' @param write_sidecar If `TRUE`, persist the verdict into each record's
#'   sidecar JSON. Default `FALSE` (in-memory only).
#' @return `records` with the `class_*` columns added.
#' @export
#' @examples
#' \dontrun{
#' recs <- index_cache(country = "de")
#' classified <- classify_assessments(recs, write_sidecar = TRUE)
#' table(classified$class_label, classified$class_relevant)
#' }
classify_assessments <- function(
  records,
  classifier = NULL,
  labels = biogain_classification_labels(),
  multi_label = FALSE,
  batch_size = 64L,
  write_sidecar = FALSE
) {
  if (!is.data.frame(records)) {
    cli::cli_abort("{.arg records} must be a data frame.")
  }
  if (is.null(classifier)) {
    classifier <- classify_model_zeroshot()
  }
  if (!inherits(classifier, "planscanR_classifier")) {
    cli::cli_abort("{.arg classifier} must be a planscanR_classifier object.")
  }
  slugs <- names(labels)
  relevant <- attr(labels, "relevant", exact = TRUE) %||% slugs

  n <- nrow(records)
  if (n == 0L) {
    for (s in slugs) {
      records[[paste0("class_score_", s)]] <- numeric(0)
    }
    records$class_label <- character(0)
    records$class_score <- numeric(0)
    records$class_relevant <- logical(0)
    records$class_model <- character(0)
    return(records)
  }

  texts <- classification_text(records)

  # Pre-allocate the verdict columns so each batch can fill its slice and the
  # sidecar for those records can be written immediately.
  records$class_label <- NA_character_
  records$class_score <- NA_real_
  records$class_relevant <- NA
  records$class_model <- classifier_name(classifier)
  for (s in slugs) {
    records[[paste0("class_score_", s)]] <- NA_real_
  }
  score_cols <- paste0("class_score_", slugs)

  # Score AND persist per batch, so an interrupted run leaves every
  # already-classified record on disk (crash-safe / resumable, matching the
  # scan and download paths) rather than discarding the whole run's work.
  starts <- seq.int(1L, n, by = batch_size)
  cli::cli_progress_bar(
    format = paste0(
      "{cli::pb_spin} classifying {cli::pb_current}/{cli::pb_total} batches",
      "  |  elapsed {cli::pb_elapsed}  |  ETA {cli::pb_eta}"
    ),
    total = length(starts),
    clear = FALSE
  )
  for (st in starts) {
    idx <- st:min(st + batch_size - 1L, n)
    sc <- classify_text(classifier, texts[idx], labels, multi_label = multi_label)
    best <- max.col(replace(sc, is.na(sc), -Inf), ties.method = "first")
    records$class_label[idx] <- slugs[best]
    records$class_score[idx] <- sc[cbind(seq_along(idx), best)]
    records$class_relevant[idx] <- slugs[best] %in% relevant
    for (j in seq_along(slugs)) {
      records[[score_cols[j]]][idx] <- sc[, j]
    }
    if (write_sidecar) {
      for (i in idx) {
        # Pass the record's existing download_status so record_to_sidecar
        # rewrites the `files[]` array (attachment URLs + their section tags)
        # instead of emptying it. Without this, classification would wipe the
        # portal attachment URLs off the sidecar.
        dl <- if ("download_status" %in% names(records)) {
          records$download_status[[i]]
        } else {
          NULL
        }
        tryCatch(
          write_record_sidecar(records[i, ], downloads = dl),
          error = function(e) {
            warn_partial(
              "Could not write sidecar for {.val {records$document_id[i]}}: {conditionMessage(e)}"
            )
          }
        )
      }
    }
    cli::cli_progress_update()
  }
  cli::cli_progress_done()

  records
}
