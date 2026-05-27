#' Required column names for any planscanR result tibble.
#' @noRd
required_columns <- function() {
  c(
    "country",
    "source_portal",
    "document_id",
    "url",
    "retrieved_at",
    "attachment_urls",
    "local_path"
  )
}

#' Construct an empty result tibble with required columns and correct types.
#'
#' Handlers can use this as a starting skeleton; extra columns can be appended.
#'
#' @return A 0-row tibble.
#' @noRd
empty_result_tibble <- function() {
  tibble::tibble(
    country = character(0),
    source_portal = character(0),
    document_id = character(0),
    url = character(0),
    retrieved_at = as.POSIXct(character(0), tz = "UTC"),
    attachment_urls = list(),
    local_path = list()
  )
}

#' Validate that a result tibble satisfies the required-columns schema.
#'
#' Checks presence and basic types of the required columns. Does **not**
#' reject extra columns — handlers are encouraged to add country-specific
#' fields freely.
#'
#' @param x A tibble.
#' @return `x`, invisibly. Aborts with class `planscanR_error_bad_schema` if invalid.
#' @noRd
validate_result_schema <- function(x) {
  if (!inherits(x, "data.frame")) {
    cli::cli_abort("Handler must return a data.frame / tibble.", class = "planscanR_error_bad_schema")
  }
  missing <- setdiff(required_columns(), names(x))
  if (length(missing) > 0L) {
    cli::cli_abort(
      "Result is missing required column{?s}: {.val {missing}}",
      class = "planscanR_error_bad_schema"
    )
  }
  checks <- list(
    country = is.character,
    source_portal = is.character,
    document_id = is.character,
    url = is.character,
    retrieved_at = function(v) inherits(v, "POSIXct"),
    attachment_urls = is.list,
    local_path = is.list
  )
  for (col in names(checks)) {
    if (!checks[[col]](x[[col]])) {
      cli::cli_abort(
        "Column {.val {col}} has wrong type ({.cls {class(x[[col]])[1]}}).",
        class = "planscanR_error_bad_schema"
      )
    }
  }
  invisible(x)
}

#' Tolerant row-bind across result tibbles with differing extra columns.
#'
#' Wraps `dplyr::bind_rows()`, which already pads missing columns with `NA`.
#' Validates the result schema before returning.
#'
#' @param ... Tibbles.
#' @return A single tibble.
#' @export
bind_results <- function(...) {
  out <- dplyr::bind_rows(...)
  if (nrow(out) > 0L) {
    validate_result_schema(out)
  }
  out
}
