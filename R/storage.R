# Small, local-disk storage primitives shared by acquisition callers.
#
# `planscanR` owns the physical root and path resolver.  The screen package
# owns catalog metadata and policy; it must pass paths through these helpers
# instead of joining user supplied strings itself.

storage_abort <- function(message, class) {
  cli::cli_abort(message, class = class)
}

storage_scalar_path <- function(value, arg) {
  if (!is.character(value) || length(value) != 1L || is.na(value) ||
    !nzchar(trimws(value))) {
    storage_abort(
      paste0("{.arg ", arg, "} must be one non-empty path string."),
      "planscanR_error_storage_root"
    )
  }
  enc2utf8(trimws(value))
}

storage_is_absolute_path <- function(path) {
  grepl("^(/|[A-Za-z]:[/\\\\]|\\\\\\\\)", path)
}

storage_root_resolve <- function(root = NULL, create = FALSE, writable = FALSE) {
  if (is.null(root)) {
    root <- cache_dir_default()
  }
  root <- storage_scalar_path(root, "root")
  if (!isTRUE(storage_is_absolute_path(root))) {
    storage_abort(
      "Storage roots must be absolute paths.",
      "planscanR_error_storage_root"
    )
  }
  root <- normalizePath(root, winslash = "/", mustWork = FALSE)
  if (isTRUE(create) && !dir.exists(root) &&
    !dir.create(root, recursive = TRUE, showWarnings = FALSE)) {
    storage_abort(
      paste0("Could not create storage root: ", root),
      "planscanR_error_storage_root"
    )
  }
  if (!dir.exists(root) || !isTRUE(file.info(root)$isdir[[1L]])) {
    storage_abort(
      paste0("Storage root is not an existing directory: ", root),
      "planscanR_error_storage_root"
    )
  }
  root <- normalizePath(root, winslash = "/", mustWork = TRUE)
  if (isTRUE(writable) && file.access(root, 2L) != 0L) {
    storage_abort(
      paste0("Storage root is not writable: ", root),
      "planscanR_error_storage_root"
    )
  }
  root
}

#' Validate and resolve a local storage root.
#'
#' @param root Absolute directory path. `NULL` resolves the planscanR cache
#'   root.
#' @param create Create the directory when it does not exist.
#' @param writable Require write access.
#' @return A canonical absolute directory path.
#' @export
storage_root_validate <- function(root = NULL, create = FALSE, writable = FALSE) {
  storage_root_resolve(root, create = create, writable = writable)
}

#' Return total and free bytes on the filesystem containing a storage root.
#'
#' @param root Existing storage root.
#' @return A list with non-negative `total_bytes` and `free_bytes` values.
#' @export
storage_capacity <- function(root) {
  root <- storage_root_resolve(root, writable = FALSE)
  output <- tryCatch(
    system2("df", c("-Pk", shQuote(root)), stdout = TRUE, stderr = TRUE),
    error = function(error) character(0)
  )
  output <- output[nzchar(trimws(output))]
  if (length(output) < 2L) {
    storage_abort(
      "Could not determine filesystem capacity for the storage root.",
      "planscanR_error_storage_space"
    )
  }
  fields <- strsplit(trimws(output[[length(output)]]), "[[:space:]]+")[[1L]]
  total_kib <- suppressWarnings(as.numeric(fields[[2L]]))
  available_kib <- suppressWarnings(as.numeric(fields[[4L]]))
  if (length(total_kib) != 1L || is.na(total_kib) || total_kib < 0 ||
    length(available_kib) != 1L || is.na(available_kib) || available_kib < 0) {
    storage_abort(
      "The filesystem did not report usable capacity values.",
      "planscanR_error_storage_space"
    )
  }
  list(total_bytes = total_kib * 1024, free_bytes = available_kib * 1024)
}

#' Return free bytes on the filesystem containing a storage root.
#'
#' @param root Existing storage root.
#' @return A non-negative numeric byte count.
#' @export
storage_free_bytes <- function(root) {
  storage_capacity(root)$free_bytes
}

#' Return the finite per-download cap used by planscanR.
#'
#' Acquisition workers use this cap as a hard reservation maximum. An
#' unbounded downloader option is rejected so a transfer cannot exceed its
#' reservation without a separate bounded growth protocol.
#'
#' @return A positive byte count.
#' @export
storage_transfer_cap_bytes <- function() {
  cap <- max_file_size_bytes()
  if (!is.finite(cap) || cap <= 0) {
    storage_abort(
      "Acquisition transfers require a finite planscanR.max_file_size_mb cap.",
      "planscanR_error_storage_space"
    )
  }
  as.numeric(cap)
}

storage_validate_relative <- function(relative_path) {
  relative_path <- storage_scalar_path(relative_path, "relative_path")
  relative_path <- gsub("\\\\", "/", relative_path, fixed = TRUE)
  if (
    storage_is_absolute_path(relative_path) ||
      grepl("^[A-Za-z]:", relative_path) ||
      grepl("(^|/)(\\.|\\.\\.)(/|$)", relative_path) ||
      grepl("(^/|/$|//)", relative_path, perl = TRUE) ||
      grepl("\\0", relative_path, fixed = TRUE)
  ) {
    storage_abort(
      "Storage locations must be portable relative paths below their root.",
      "planscanR_error_storage_path"
    )
  }
  relative_path
}

storage_canonicalize_candidate <- function(path) {
  path <- normalizePath(path, winslash = "/", mustWork = FALSE)
  suffix <- character(0)
  current <- path
  repeat {
    link <- tryCatch(Sys.readlink(current), error = function(error) "")
    if (length(link) == 1L && !is.na(link) && nzchar(link)) {
      storage_abort(
        "The storage location contains a dangling symlink.",
        "planscanR_error_storage_path"
      )
    }
    if (file.exists(current) || dir.exists(current)) break
    parent <- dirname(current)
    if (identical(parent, current)) break
    suffix <- c(basename(current), suffix)
    current <- parent
  }
  if (file.exists(current) || dir.exists(current)) {
    current <- normalizePath(current, winslash = "/", mustWork = TRUE)
  }
  if (length(suffix) == 0L) current else file.path(current, paste(suffix, collapse = "/"))
}

storage_path_within_root <- function(root, relative_path) {
  root <- storage_root_resolve(root, writable = FALSE)
  relative_path <- storage_validate_relative(relative_path)
  candidate <- file.path(root, relative_path)
  candidate_normalized <- storage_canonicalize_candidate(candidate)
  prefix <- paste0(root, "/")
  if (!startsWith(candidate_normalized, prefix)) {
    storage_abort(
      "The storage location escapes its registered root.",
      "planscanR_error_storage_path"
    )
  }
  list(root = root, relative_path = relative_path, path = candidate_normalized)
}

#' Resolve one portable location below a storage root.
#'
#' Existing symlink components are canonicalized before the containment check,
#' so a path cannot escape through a symlink below the root.
#'
#' @param root Existing storage root.
#' @param relative_path Portable path below `root`.
#' @param create_parent Create the containing directory after validation.
#' @return An absolute canonical path.
#' @export
storage_path <- function(root, relative_path, create_parent = FALSE) {
  resolved <- storage_path_within_root(root, relative_path)
  parent <- dirname(resolved$path)
  if (isTRUE(create_parent) && !dir.exists(parent) &&
    !dir.create(parent, recursive = TRUE, showWarnings = FALSE)) {
    storage_abort(
      paste0("Could not create storage location parent: ", parent),
      "planscanR_error_storage_path"
    )
  }
  # Re-check after creating parents: a concurrent process may have inserted a
  # symlink between the first validation and directory creation.
  resolved <- storage_path_within_root(resolved$root, resolved$relative_path)
  resolved$path
}

#' Normalize a path for catalog storage relative to a root.
#'
#' @param path Absolute or relative path.
#' @param root Existing storage root.
#' @return A portable relative path.
#' @export
storage_relative_path <- function(path, root) {
  path <- storage_scalar_path(path, "path")
  root <- storage_root_resolve(root, writable = FALSE)
  if (!storage_is_absolute_path(path)) {
    return(storage_path_within_root(root, path)$relative_path)
  }
  normalized <- normalizePath(path, winslash = "/", mustWork = FALSE)
  normalized <- storage_canonicalize_candidate(normalized)
  prefix <- paste0(root, "/")
  if (!startsWith(normalized, prefix)) {
    storage_abort(
      "The absolute storage path is outside its registered root.",
      "planscanR_error_storage_path"
    )
  }
  relative <- substring(normalized, nchar(prefix) + 1L)
  storage_validate_relative(relative)
}
