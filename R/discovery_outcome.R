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
#' @return A tibble with `country`, `document_id`, `status`, `reason`, and
#'   `authoritative` columns plus UTC `checked_at`.
#' @export
resolve_attachment_inventory <- function(records, resolver = NULL, supported = supported_countries()) {
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
  if (nrow(records) == 0L) {
    return(tibble::tibble(
      country = character(0),
      document_id = character(0),
      status = character(0),
      reason = character(0),
      authoritative = logical(0),
      checked_at = character(0)
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
        checked_at = checked_at
      ))
    }
    urls <- collect_attachment_sections(rec)
    n_urls <- sum(lengths(urls))
    if (!is.null(resolver)) {
      fresh <- tryCatch(resolver(rec), error = function(e) {
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
      urls_supplied <- "urls" %in% names(fresh) && !is.null(fresh$urls)
      fresh_urls <- if (urls_supplied) {
        as.character(unlist(fresh$urls, use.names = FALSE))
      } else {
        character(0)
      }
      fresh_urls <- fresh_urls[!is.na(fresh_urls) & nzchar(fresh_urls)]
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
        checked_at = checked_at
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
        checked_at = checked_at
      ))
    }
    if (current$status == "empty" && n_urls == 0L && empty_is_authoritative) {
      return(list(
        country = country,
        document_id = document_id,
        status = "empty",
        reason = current$reason,
        authoritative = TRUE,
        checked_at = checked_at
      ))
    }
    if (current$status == "empty" && n_urls == 0L) {
      return(list(
        country = country,
        document_id = document_id,
        status = "retryable",
        reason = "legacy empty status lacks a discovery timestamp; refresh the portal inventory",
        authoritative = FALSE,
        checked_at = checked_at
      ))
    }
    if (current$status == "empty" && n_urls > 0L) {
      return(list(
        country = country,
        document_id = document_id,
        status = "retryable",
        reason = "empty status conflicts with captured attachment URLs",
        authoritative = FALSE,
        checked_at = checked_at
      ))
    }
    if (n_urls > 0L) {
      return(list(
        country = country,
        document_id = document_id,
        status = "success",
        reason = NA_character_,
        authoritative = TRUE,
        checked_at = checked_at
      ))
    }
    if (current$status == "success") {
      return(list(
        country = country,
        document_id = document_id,
        status = "retryable",
        reason = "success status has no attachment URLs; refresh the portal inventory",
        authoritative = FALSE,
        checked_at = checked_at
      ))
    }
    list(
      country = country,
      document_id = document_id,
      status = "retryable",
      reason = "no authoritative attachment inventory; refresh or resolve the portal before resuming",
      authoritative = FALSE,
      checked_at = checked_at
    )
  })
  tibble::as_tibble(do.call(rbind, lapply(out, as.data.frame, stringsAsFactors = FALSE)))
}
