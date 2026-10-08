# Explicit attachment-inventory outcomes.

# `unknown` is a compatibility sentinel for legacy sidecars that predate this
# field. It is deliberately not an authoritative empty result.
DISCOVERY_STATUSES <- c("success", "empty", "retryable", "blocked", "unknown")

#' Values used by the attachment discovery contract.
#' @noRd
discovery_statuses <- function(include_unknown = TRUE) {
  if (isTRUE(include_unknown)) DISCOVERY_STATUSES else setdiff(DISCOVERY_STATUSES, "unknown")
}

#' Set an explicit attachment-inventory outcome on one or more records.
#'
#' `empty` is authoritative only when the caller has completed an inventory
#' operation successfully. Missing status remains `unknown` when reading old
#' sidecars; callers must not turn that state into `no_documents`.
#' @param records A data frame.
#' @param status One of `success`, `empty`, `retryable`, `blocked`, or
#'   `unknown`; a scalar is recycled to all rows.
#' @param reason Optional character explanation, recycled to all rows.
#' @return `records` with `discovery_status` and `discovery_reason` columns.
#' @noRd
set_discovery_outcome <- function(records, status, reason = NA_character_) {
  if (!is.data.frame(records)) {
    cli::cli_abort("{.arg records} must be a data frame.")
  }
  if (length(status) == 0L || !is.character(status)) {
    cli::cli_abort("{.arg status} must contain a discovery status.")
  }
  if (length(status) == 1L) {
    status <- rep(status, nrow(records))
  }
  if (length(status) != nrow(records) || anyNA(status) || any(!status %in% DISCOVERY_STATUSES)) {
    cli::cli_abort(
      "{.arg status} must have one valid value per record: {.val {discovery_statuses()}}."
    )
  }
  if (length(reason) == 1L) {
    reason <- rep(reason, nrow(records))
  }
  if (length(reason) != nrow(records)) {
    cli::cli_abort("{.arg reason} must have one value per record.")
  }
  records$discovery_status <- as.character(status)
  records$discovery_reason <- as.character(reason)
  records
}

#' Read an outcome from a record, preserving legacy uncertainty.
#' @noRd
discovery_outcome_for_record <- function(record) {
  status <- if ("discovery_status" %in% names(record)) {
    as.character(record$discovery_status[[1]])
  } else {
    NA_character_
  }
  if (length(status) != 1L || is.na(status) || !status %in% DISCOVERY_STATUSES) {
    status <- "unknown"
  }
  reason <- if ("discovery_reason" %in% names(record)) {
    as.character(record$discovery_reason[[1]])
  } else {
    NA_character_
  }
  list(
    status = status,
    reason = reason,
    authoritative = status %in% c("success", "empty")
  )
}

#' Build the generic and section inventory columns for one record.
#' @noRd
discovery_inventory_columns <- function(record) {
  sections <- collect_attachment_sections(record)
  urls <- as.character(unique(unlist(sections, use.names = FALSE)))
  urls <- urls[!is.na(urls) & nzchar(urls)]
  out <- list(attachment_urls = urls)
  for (name in names(sections)) {
    if (identical(name, "generic")) {
      next
    }
    out[[paste0("attachment_urls_", name)]] <- sections[[name]]
  }
  out
}

#' Validate a refreshed portal record against its persisted source identity.
#' @noRd
discovery_refresh_identity <- function(record, fresh, expected_portal, expected_url = NULL) {
  required <- c("country", "source_portal", "document_id")
  if (!all(required %in% names(fresh)) || nrow(fresh) != 1L) {
    return("portal inventory returned a malformed record")
  }
  persisted <- vapply(required, function(name) {
    value <- record[[name]][[1L]]
    if (length(value) == 0L || is.na(value)) "" else as.character(value)
  }, character(1))
  observed <- vapply(required, function(name) {
    value <- fresh[[name]][[1L]]
    if (length(value) == 0L || is.na(value)) "" else as.character(value)
  }, character(1))
  if (any(!nzchar(persisted)) || any(!nzchar(observed)) ||
    !identical(persisted[["country"]], observed[["country"]]) ||
    !identical(persisted[["source_portal"]], observed[["source_portal"]]) ||
    !identical(persisted[["document_id"]], observed[["document_id"]]) ||
    !identical(observed[["source_portal"]], expected_portal)) {
    return("portal inventory identity conflicts with the persisted source")
  }
  if (identical(expected_portal, "uvp-verbund.de")) {
    response_id <- if ("response_document_id" %in% names(fresh)) {
      fresh$response_document_id[[1L]]
    } else {
      NA_character_
    }
    response_id <- if (length(response_id) == 1L) as.character(response_id) else NA_character_
    if (is.na(response_id) || !nzchar(response_id)) {
      return("portal inventory response identity is missing")
    }
    if (!identical(response_id, persisted[["document_id"]])) {
      return("portal inventory response identity conflicts with the persisted source")
    }
  }
  if (!is.null(expected_url)) {
    if (!"url" %in% names(fresh) || !identical(as.character(fresh$url[[1L]]), expected_url)) {
      return("portal inventory URL conflicts with the persisted source")
    }
  }
  NULL
}

#' Resolve an exact persisted source through an existing portal detail helper.
#' @noRd
discovery_refresh_record <- function(record) {
  country <- as.character(record$country[[1L]])
  adapters <- c(
    nl = "commissiemer.nl",
    de = "uvp-verbund.de",
    dk = "miljoeportal.dk/eahub"
  )
  if (!country %in% names(adapters)) {
    return(list(
      status = "blocked",
      reason = sprintf("no exact-source inventory adapter is available for portal country: %s", country),
      urls = character(0),
      inventory = list(attachment_urls = character(0))
    ))
  }
  expected_portal <- unname(adapters[[country]])
  source_portal <- if ("source_portal" %in% names(record)) as.character(record$source_portal[[1L]]) else ""
  source_url <- if ("url" %in% names(record)) as.character(record$url[[1L]]) else ""
  document_id <- as.character(record$document_id[[1L]])
  if (length(source_portal) != 1L || is.na(source_portal) ||
    !identical(source_portal, expected_portal) || length(source_url) != 1L ||
    is.na(source_url) || !nzchar(source_url) || length(document_id) != 1L ||
    is.na(document_id) || !nzchar(document_id)) {
    return(list(
      status = "retryable",
      reason = "persisted source identity is incomplete or conflicts with the selected portal adapter",
      urls = character(0),
      inventory = list(attachment_urls = character(0))
    ))
  }

  if (identical(country, "dk")) {
    per_section <- tryCatch(
      dk_collect_attachments(document_id, strict = TRUE),
      error = function(error) error
    )
    if (inherits(per_section, "error")) {
      status <- if (inherits(per_section, "planscanR_dk_blocked")) "blocked" else "retryable"
      return(list(
        status = status,
        reason = conditionMessage(per_section),
        urls = character(0),
        inventory = list(attachment_urls = character(0))
      ))
    }
    if (!is.list(per_section) || (length(per_section) > 0L && is.null(names(per_section)))) {
      return(list(
        status = "retryable",
        reason = "EA-Hub document inventory returned a malformed section inventory",
        urls = character(0),
        inventory = list(attachment_urls = character(0))
      ))
    }
    inventory <- list(attachment_urls = character(0))
    for (section in names(per_section)) {
      urls <- per_section[[section]]
      if (!is.character(urls) || anyNA(urls) || any(!nzchar(urls))) {
        return(list(
          status = "retryable",
          reason = "EA-Hub document inventory returned malformed attachment URLs",
          urls = character(0),
          inventory = list(attachment_urls = character(0))
        ))
      }
      inventory[[paste0("attachment_urls_", section)]] <- unique(urls)
      inventory$attachment_urls <- unique(c(inventory$attachment_urls, urls))
    }
    return(list(
      status = "success",
      reason = if (length(inventory$attachment_urls) == 0L) "portal inventory completed with no attachment URLs" else NA_character_,
      urls = inventory$attachment_urls,
      inventory = inventory
    ))
  }

  fresh <- tryCatch(
    if (identical(country, "nl")) nl_parse_detail(source_url) else de_parse_detail(source_url),
    error = function(error) error
  )
  if (inherits(fresh, "error")) {
    return(list(
      status = "retryable",
      reason = conditionMessage(fresh),
      urls = character(0),
      inventory = list(attachment_urls = character(0))
    ))
  }
  identity_error <- discovery_refresh_identity(
    record,
    fresh,
    expected_portal = expected_portal,
    expected_url = source_url
  )
  if (!is.null(identity_error)) {
    return(list(
      status = "retryable",
      reason = identity_error,
      urls = character(0),
      inventory = list(attachment_urls = character(0))
    ))
  }
  fields <- grep("^attachment_urls($|_)", names(fresh), value = TRUE)
  if (length(fields) == 0L) {
    return(list(
      status = "retryable",
      reason = "portal inventory returned no attachment URL columns",
      urls = character(0),
      inventory = list(attachment_urls = character(0))
    ))
  }
  for (field in fields) {
    value <- fresh[[field]]
    if (!is.list(value) || length(value) != 1L ||
      (!is.character(value[[1L]]) && length(value[[1L]]) > 0L) ||
      (is.character(value[[1L]]) && anyNA(value[[1L]]))) {
      return(list(
        status = "retryable",
        reason = "portal inventory returned malformed attachment URL columns",
        urls = character(0),
        inventory = list(attachment_urls = character(0))
      ))
    }
  }
  inventory <- discovery_inventory_columns(fresh)
  if (length(inventory$attachment_urls) == 0L) {
    title <- if ("title" %in% names(fresh)) as.character(fresh$title[[1L]]) else NA_character_
    if (length(title) != 1L || is.na(title) || !nzchar(trimws(title))) {
      return(list(
        status = "retryable",
        reason = "portal detail did not provide a recognizable project title for an empty inventory",
        urls = character(0),
        inventory = list(attachment_urls = character(0))
      ))
    }
  }
  list(
    status = "success",
    reason = if (length(inventory$attachment_urls) == 0L) "portal inventory completed with no attachment URLs" else NA_character_,
    urls = inventory$attachment_urls,
    inventory = inventory
  )
}

#' Resolve the attachment-inventory outcome for cached records.
#'
#' This resolver is deliberately conservative. A record with captured generic
#' or section URLs is a successful inventory; a timestamped explicit `empty`
#' status is an authoritative successful-empty inventory. A legacy sidecar with
#' no URLs, no timestamped outcome, or an unknown status is `retryable`, because
#' an old or swallowed fetch error must not become a terminal `no_documents`
#' result. Unsupported country codes are `blocked`.
#'
#' @param records A data frame with at least `country` and `document_id`.
#' @param resolver Optional function called with one record row to perform a
#'   fresh portal inventory. It may return a list with `status`, `reason`, and
#'   optional `urls`; resolver errors become `retryable`.
#' @param supported Character vector of enabled country codes.
#' @param refresh Logical; when `TRUE` and `resolver` is `NULL`, refresh only
#'   the exact NL, DE, or DK source identity through its existing detail helper.
#'   The refresh never crawls listings, downloads files, or writes sidecars.
#' @return A tibble with `country`, `document_id`, `status`, `reason`, and
#'   `authoritative` columns plus UTC `checked_at` and attachment URL columns.
#' @export
resolve_attachment_inventory <- function(
  records,
  resolver = NULL,
  supported = supported_countries(),
  refresh = FALSE
) {
  if (!is.data.frame(records)) {
    cli::cli_abort("{.arg records} must be a data frame.")
  }
  needed <- c("country", "document_id")
  missing <- setdiff(needed, names(records))
  if (length(missing) > 0L) {
    cli::cli_abort("{.arg records} is missing {.field {missing}}.")
  }
  if (!is.null(resolver) && !is.function(resolver)) {
    cli::cli_abort("{.arg resolver} must be NULL or a function.")
  }
  if (length(refresh) != 1L || !is.logical(refresh) || is.na(refresh)) {
    cli::cli_abort("{.arg refresh} must be a single `TRUE` or `FALSE`.")
  }
  if (nrow(records) == 0L) {
    return(tibble::tibble(
      country = character(0),
      document_id = character(0),
      status = character(0),
      reason = character(0),
      authoritative = logical(0),
      checked_at = character(0),
      attachment_urls = list()
    ))
  }
  checked_at <- format(Sys.time(), "%Y-%m-%dT%H:%M:%SZ", tz = "UTC")
  out <- lapply(seq_len(nrow(records)), function(i) {
    rec <- records[i, , drop = FALSE]
    country <- as.character(rec$country[[1]])
    document_id <- as.character(rec$document_id[[1]])
    if (!country %in% supported) {
      return(list(
        country = country,
        document_id = document_id,
        status = "blocked",
        reason = sprintf("unsupported portal country: %s", country),
        authoritative = FALSE,
        checked_at = checked_at,
        inventory = list(attachment_urls = character(0))
      ))
    }
    urls <- collect_attachment_sections(rec)
    n_urls <- sum(lengths(urls))
    current_inventory <- discovery_inventory_columns(rec)
    active_resolver <- resolver
    if (isTRUE(refresh) && is.null(active_resolver)) {
      active_resolver <- discovery_refresh_record
    }
    if (!is.null(active_resolver)) {
      fresh <- tryCatch(active_resolver(rec), error = function(e) {
        list(status = "retryable", reason = conditionMessage(e), urls = character(0))
      })
      if (!is.list(fresh) || is.null(fresh$status)) {
        fresh <- list(
          status = "retryable",
          reason = "portal resolver returned no explicit status",
          urls = character(0)
        )
      }
      fresh_status <- as.character(fresh$status[[1]])
      if (length(fresh_status) != 1L || is.na(fresh_status)) {
        fresh_status <- "unknown"
      }
      fresh_reason <- fresh$reason %||% NA_character_
      fresh_reason <- if (length(fresh_reason) == 0L) NA_character_ else as.character(fresh_reason[[1]])
      inventory <- if (is.list(fresh$inventory)) fresh$inventory else list()
      if (length(inventory) == 0L) {
        inventory <- list(attachment_urls = character(0))
      }
      urls_supplied <- "urls" %in% names(fresh) && !is.null(fresh$urls)
      fresh_urls <- if (urls_supplied) {
        as.character(unlist(fresh$urls, use.names = FALSE))
      } else {
        as.character(inventory$attachment_urls %||% character(0))
      }
      fresh_urls <- fresh_urls[!is.na(fresh_urls) & nzchar(fresh_urls)]
      inventory$attachment_urls <- unique(c(
        as.character(inventory$attachment_urls %||% character(0)),
        fresh_urls
      ))
      if (!fresh_status %in% DISCOVERY_STATUSES || identical(fresh_status, "unknown")) {
        fresh_status <- "retryable"
        fresh_reason <- fresh_reason %||% "portal resolver returned an unknown status"
      }
      if (fresh_status == "success" && urls_supplied && length(fresh_urls) == 0L) {
        fresh_status <- "empty"
      } else if (fresh_status == "success" && !urls_supplied && n_urls == 0L) {
        fresh_status <- "retryable"
        fresh_reason <- "portal resolver returned success without an attachment inventory"
      } else if (fresh_status == "empty" && urls_supplied && length(fresh_urls) > 0L) {
        fresh_status <- "retryable"
        fresh_reason <- "portal resolver returned links with an empty status"
      } else if (fresh_status == "empty" && !urls_supplied) {
        fresh_status <- "retryable"
        fresh_reason <- if (n_urls > 0L) {
          "portal resolver returned empty without links despite cached attachment URLs"
        } else {
          "portal resolver returned empty without an explicit attachment inventory"
        }
      }
      return(list(
        country = country,
        document_id = document_id,
        status = fresh_status,
        reason = fresh_reason,
        authoritative = fresh_status %in% c("success", "empty"),
        checked_at = checked_at,
        inventory = inventory
      ))
    }
    current <- discovery_outcome_for_record(rec)
    stored_checked_at <- if ("discovery_checked_at" %in% names(rec)) {
      as.character(rec$discovery_checked_at[[1]])
    } else {
      NA_character_
    }
    empty_is_authoritative <- current$status == "empty" &&
      length(stored_checked_at) == 1L &&
      !is.na(stored_checked_at) &&
      nzchar(stored_checked_at)
    if (current$status %in% c("retryable", "blocked")) {
      return(list(
        country = country,
        document_id = document_id,
        status = current$status,
        reason = current$reason,
        authoritative = FALSE,
        checked_at = checked_at,
        inventory = current_inventory
      ))
    }
    if (current$status == "empty" && n_urls == 0L && empty_is_authoritative) {
      return(list(
        country = country,
        document_id = document_id,
        status = "empty",
        reason = current$reason,
        authoritative = TRUE,
        checked_at = checked_at,
        inventory = current_inventory
      ))
    }
    if (current$status == "empty" && n_urls == 0L) {
      return(list(
        country = country,
        document_id = document_id,
        status = "retryable",
        reason = "legacy empty status lacks a discovery timestamp; refresh the portal inventory",
        authoritative = FALSE,
        checked_at = checked_at,
        inventory = current_inventory
      ))
    }
    if (current$status == "empty" && n_urls > 0L) {
      return(list(
        country = country,
        document_id = document_id,
        status = "retryable",
        reason = "empty status conflicts with captured attachment URLs",
        authoritative = FALSE,
        checked_at = checked_at,
        inventory = current_inventory
      ))
    }
    if (n_urls > 0L) {
      return(list(
        country = country,
        document_id = document_id,
        status = "success",
        reason = NA_character_,
        authoritative = TRUE,
        checked_at = checked_at,
        inventory = current_inventory
      ))
    }
    if (current$status == "success") {
      return(list(
        country = country,
        document_id = document_id,
        status = "retryable",
        reason = "success status has no attachment URLs; refresh the portal inventory",
        authoritative = FALSE,
        checked_at = checked_at,
        inventory = current_inventory
      ))
    }
    list(
      country = country,
      document_id = document_id,
      status = "retryable",
      reason = "no authoritative attachment inventory; refresh or resolve the portal before resuming",
      authoritative = FALSE,
      checked_at = checked_at,
      inventory = current_inventory
    )
  })
  result <- tibble::tibble(
    country = vapply(out, `[[`, character(1), "country"),
    document_id = vapply(out, `[[`, character(1), "document_id"),
    status = vapply(out, `[[`, character(1), "status"),
    reason = vapply(out, function(row) as.character(row$reason %||% NA_character_), character(1)),
    authoritative = vapply(out, `[[`, logical(1), "authoritative"),
    checked_at = vapply(out, `[[`, character(1), "checked_at")
  )
  inventory_names <- unique(unlist(lapply(out, function(row) names(row$inventory)), use.names = FALSE))
  inventory_names <- inventory_names[nzchar(inventory_names)]
  for (name in inventory_names) {
    result[[name]] <- lapply(out, function(row) {
      value <- row$inventory[[name]]
      if (is.null(value)) character(0) else as.character(value)
    })
  }
  result
}
