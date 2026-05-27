#' Local cache directory for planscanR.
#'
#' Resolves a subdirectory under `tools::R_user_dir("planscanR", "cache")`,
#' or under a user-supplied root if `getOption("planscanR.cache_dir")` is set
#' (or if the calling handler resolved one via the `cache_dir` argument).
#'
#' @param sub Optional subdirectory.
#' @param create Whether to create the directory if it does not exist.
#' @param root Optional explicit root. If `NULL`, uses the option or default.
#' @return Absolute path (character).
#' @noRd
cache_dir <- function(sub = NULL, create = TRUE, root = NULL) {
  if (is.null(root)) {
    root <- getOption("planscanR.cache_dir")
    if (is.null(root) || !nzchar(root)) {
      root <- tools::R_user_dir("planscanR", "cache")
    }
  }
  path <- if (is.null(sub)) root else file.path(root, sub)
  if (create && !dir.exists(path)) {
    dir.create(path, recursive = TRUE, showWarnings = FALSE)
  }
  path
}

#' Slugify a filename so it survives being flattened into a single directory.
#'
#' Produces a portable, lowercase, ASCII basename of the form
#' `<country>_<document_id>_<slug>.<ext>`. The slug is the URL basename's
#' filename portion, lowercased and with any character outside
#' `[a-z0-9._-]` replaced by `-`; consecutive hyphens are collapsed.
#'
#' If the resulting name exceeds `max_chars`, the slug portion is truncated
#' and a short SHA-1 prefix of the URL is appended to keep collisions
#' impossible.
#'
#' @param url Source URL.
#' @param country ISO-2 country code.
#' @param document_id Portal-native document ID.
#' @param max_chars Hard cap on the final basename length. Default 200, well
#'   under the 255-byte limit imposed by common filesystems.
#' @return Character scalar (the basename, no directories).
#' @noRd
slugify_filename <- function(url, country, document_id, max_chars = 200L) {
  # Strip query / fragment, then take the last path segment. Avoiding
  # httr2::url_parse here means we tolerate slightly malformed URLs that
  # may show up from HTML scraping (e.g. unencoded spaces).
  raw <- sub("[#?].*$", "", url)
  raw <- basename(raw)
  if (!nzchar(raw) || raw %in% c("/", ".")) {
    raw <- "attachment"
  }
  raw <- tryCatch(utils::URLdecode(raw), error = function(e) raw)
  ext <- tools::file_ext(raw)
  stem <- tools::file_path_sans_ext(raw)

  slug_part <- function(x) {
    x <- tolower(x)
    x <- gsub("[^a-z0-9._-]+", "-", x, perl = TRUE)
    x <- gsub("-{2,}", "-", x)
    x <- gsub("(^[-._]+|[-._]+$)", "", x)
    if (!nzchar(x)) "x" else x
  }
  country <- slug_part(country)
  document_id <- slug_part(document_id)
  stem <- slug_part(stem)
  ext <- slug_part(ext)

  base <- paste0(country, "_", document_id, "_", stem)
  if (nzchar(ext)) {
    base <- paste0(base, ".", ext)
  }

  if (nchar(base) > max_chars) {
    short_hash <- substr(openssl::sha1(url), 1L, 8L)
    keep <- max_chars - nchar(country) - nchar(document_id) - nchar(ext) - 12L
    keep <- max(8L, keep)
    base <- paste0(country, "_", document_id, "_", substr(stem, 1L, keep), "-", short_hash)
    if (nzchar(ext)) base <- paste0(base, ".", ext)
  }
  base
}

#' Construct a deterministic local path for an attachment.
#'
#' Layout: `<cache_root>/files/<country>/<document_id>/<slugified-name>`.
#' Filenames are flatten-safe: they encode `<country>_<document_id>_<slug>`
#' so the file is globally unique even outside its containing directory.
#'
#' @param url Source URL.
#' @param country ISO-2 country code.
#' @param document_id Portal-native document ID.
#' @param root Cache root (or `NULL` to use default).
#' @return Absolute path.
#' @noRd
cache_path <- function(url, country, document_id, root = NULL) {
  dir <- cache_dir(file.path("files", country, document_id), create = TRUE, root = root)
  file.path(dir, slugify_filename(url, country, document_id))
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Cap on the size of files that will be downloaded.
#'
#' Returns the configured ceiling in bytes. `NULL` / `Inf` means no cap.
#' @noRd
max_file_size_bytes <- function(max_file_size_mb = NULL) {
  if (is.null(max_file_size_mb)) {
    max_file_size_mb <- getOption("planscanR.max_file_size_mb", 50)
  }
  if (is.null(max_file_size_mb) || is.infinite(max_file_size_mb) || max_file_size_mb <= 0) {
    return(Inf)
  }
  as.numeric(max_file_size_mb) * 1024 * 1024
}

#' Probe a URL's Content-Length via a cheap HEAD request.
#'
#' Returns the size in bytes, or `NA_real_` if the server doesn't advertise
#' one (or the HEAD request fails).
#'
#' @noRd
head_content_length <- function(url) {
  res <- tryCatch(
    {
      req <- req_planscanr(url)
      req <- httr2::req_method(req, "HEAD")
      resp <- httr2::req_perform(req)
      httr2::resp_header(resp, "Content-Length")
    },
    error = function(e) NULL
  )
  if (is.null(res)) {
    return(NA_real_)
  }
  n <- suppressWarnings(as.numeric(res))
  if (is.na(n)) NA_real_ else n
}

#' Compute SHA-256 for a local file.
#' @noRd
file_sha256 <- function(path) {
  if (is.na(path) || !file.exists(path)) {
    return(NA_character_)
  }
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  as.character(openssl::sha256(con))
}

#' Download a set of attachment URLs, with size cap and structured per-file
#' status reporting.
#'
#' For each URL:
#'  * If a non-empty file already exists at the destination and
#'    `overwrite = FALSE`, the file is treated as cached: status `"cached"`.
#'  * Otherwise a HEAD probe checks `Content-Length`; URLs whose announced
#'    size exceeds `max_file_size_mb` are skipped with status `"skipped_size"`.
#'  * If the HEAD probe fails (e.g. server doesn't support HEAD) the download
#'    is attempted; if the resulting file then exceeds the cap, it is
#'    discarded with status `"skipped_size"` (post-hoc).
#'  * Any other failure yields status `"failed"` with the error message in `reason`.
#'
#' @param urls Character vector of URLs.
#' @param country ISO-2 country code.
#' @param document_id Portal-native ID.
#' @param overwrite Whether to re-download existing files.
#' @param max_file_size_mb Numeric cap in MiB; `NULL` defers to the option.
#' @param root Cache root.
#' @return A tibble with one row per input URL and columns:
#'   `url`, `local_path` (NA when skipped/failed), `status`, `size_bytes`,
#'   `sha256` (NA when no local file), `reason`.
#' @noRd
download_attachments <- function(urls, country, document_id, overwrite = FALSE, max_file_size_mb = NULL, root = NULL) {
  if (length(urls) == 0L) {
    return(empty_download_status())
  }
  cap <- max_file_size_bytes(max_file_size_mb)
  results <- lapply(urls, function(u) {
    dest <- cache_path(u, country, document_id, root = root)
    if (file.exists(dest) && !overwrite && file.info(dest)$size > 0L) {
      return(list(
        url = u,
        local_path = dest,
        status = "cached",
        size_bytes = unname(file.info(dest)$size),
        sha256 = file_sha256(dest),
        reason = NA_character_
      ))
    }
    # Pre-flight size check via HEAD
    announced <- head_content_length(u)
    if (!is.na(announced) && announced > cap) {
      return(list(
        url = u,
        local_path = NA_character_,
        status = "skipped_size",
        size_bytes = announced,
        sha256 = NA_character_,
        reason = sprintf("HEAD Content-Length %s exceeds cap %s", format(announced), format(cap))
      ))
    }
    out <- tryCatch(
      {
        req <- req_planscanr(u)
        httr2::req_perform(req, path = dest)
        size <- unname(file.info(dest)$size)
        if (!is.na(size) && size > cap) {
          unlink(dest, force = TRUE)
          return(list(
            url = u,
            local_path = NA_character_,
            status = "skipped_size",
            size_bytes = size,
            sha256 = NA_character_,
            reason = sprintf("downloaded size %s exceeds cap %s", format(size), format(cap))
          ))
        }
        list(
          url = u,
          local_path = dest,
          status = "downloaded",
          size_bytes = size,
          sha256 = file_sha256(dest),
          reason = NA_character_
        )
      },
      error = function(e) {
        if (file.exists(dest) && file.info(dest)$size == 0L) {
          unlink(dest, force = TRUE)
        }
        list(
          url = u,
          local_path = NA_character_,
          status = "failed",
          size_bytes = NA_real_,
          sha256 = NA_character_,
          reason = conditionMessage(e)
        )
      }
    )
    out
  })
  do.call(rbind, lapply(results, tibble::as_tibble_row))
}

#' Invalidate (delete) part or all of the planscanR cache.
#'
#' Use this when you actually want to force a refresh — for example after a
#' portal's HTML layout changes, or to free disk space. By default the
#' function asks for interactive confirmation before deleting anything, and
#' refuses to operate on directories outside the resolved cache root.
#'
#' The cache is a single tree under `<root>/files/<country>/<doc_id>/`
#' containing per-record sidecar JSON files plus any downloaded attachments.
#' `clear_cache()` removes that tree (or a country-scoped subset).
#'
#' @param cache_dir Optional cache root. Defaults to the
#'   `getOption("planscanR.cache_dir")` value (which itself falls back to
#'   `tools::R_user_dir("planscanR", "cache")`).
#' @param country Optional ISO-2 country code. If supplied, only that
#'   country's subtree (`<root>/files/<country>/`) is removed. Otherwise the
#'   whole `<root>/files/` tree is removed.
#' @param confirm If `TRUE` (default) and the session is interactive, print
#'   a summary (path, file count, size) and ask for explicit y/n before
#'   deleting. Set to `FALSE` for scripted/automated use.
#' @return Invisibly, a tibble describing what was removed
#'   (`path`, `n_files`, `bytes`, `removed`).
#' @export
#' @examples
#' \dontrun{
#' # Wipe everything under the default cache root, with confirmation prompt
#' clear_cache()
#'
#' # Wipe only NL files (sidecars + attachments)
#' clear_cache(country = "nl")
#'
#' # Scripted use (no prompt)
#' clear_cache(confirm = FALSE)
#' }
clear_cache <- function(cache_dir = NULL, country = NULL, confirm = TRUE) {
  root <- if (is.null(cache_dir)) cache_dir_default() else cache_dir
  root <- normalizePath(root, mustWork = FALSE)
  if (!dir.exists(root)) {
    cli::cli_inform(c(i = "Cache root {.file {root}} does not exist; nothing to do."))
    return(invisible(empty_cache_clear_result()))
  }

  targets <- if (is.null(country)) {
    file.path(root, "files")
  } else {
    file.path(root, "files", tolower(country))
  }
  targets <- targets[dir.exists(targets)]
  if (length(targets) == 0L) {
    cli::cli_inform(c(i = "Nothing to remove at {.file {root}}."))
    return(invisible(empty_cache_clear_result()))
  }

  # Sanity guard: every target must resolve under the cache root.
  abs_targets <- normalizePath(targets, mustWork = TRUE)
  root_real <- normalizePath(root, mustWork = TRUE)
  if (!all(startsWith(paste0(abs_targets, "/"), paste0(root_real, "/")))) {
    cli::cli_abort(
      "Refusing to clear paths outside the cache root {.file {root_real}}.",
      class = "planscanR_error_unsafe_clear"
    )
  }

  # Compute size up-front for the prompt + return value.
  summary <- lapply(abs_targets, dir_summary)
  total_files <- sum(vapply(summary, `[[`, integer(1), "n_files"))
  total_bytes <- sum(vapply(summary, `[[`, numeric(1), "bytes"))

  if (confirm && interactive()) {
    cli::cli_inform(c(
      "About to remove {.val {total_files}} file{?s} ({format_bytes(total_bytes)}):",
      stats::setNames(paste0(abs_targets), rep(" ", length(abs_targets)))
    ))
    ans <- tolower(trimws(readline("Proceed? [y/N] ")))
    if (!ans %in% c("y", "yes")) {
      cli::cli_inform(c(i = "Aborted; nothing removed."))
      return(invisible(empty_cache_clear_result()))
    }
  }

  removed <- vapply(
    abs_targets,
    function(p) {
      unlink(p, recursive = TRUE, force = TRUE) == 0L
    },
    logical(1)
  )

  invisible(tibble::tibble(
    path = abs_targets,
    n_files = vapply(summary, `[[`, integer(1), "n_files"),
    bytes = vapply(summary, `[[`, numeric(1), "bytes"),
    removed = removed
  ))
}

#' Empty result for clear_cache no-ops.
#' @noRd
empty_cache_clear_result <- function() {
  tibble::tibble(
    path = character(0),
    n_files = integer(0),
    bytes = numeric(0),
    removed = logical(0)
  )
}

#' Count + size of a directory tree.
#' @noRd
dir_summary <- function(path) {
  files <- list.files(path, recursive = TRUE, all.files = TRUE, full.names = TRUE, no.. = TRUE)
  list(
    n_files = length(files),
    bytes = sum(file.info(files)$size, na.rm = TRUE)
  )
}

#' Human-readable byte size.
#' @noRd
format_bytes <- function(x) {
  if (!is.finite(x) || x < 0) {
    return(as.character(x))
  }
  units <- c("B", "KB", "MB", "GB", "TB")
  i <- min(length(units), max(1L, 1L + as.integer(log(max(x, 1), 1024))))
  sprintf("%.1f %s", x / 1024^(i - 1), units[i])
}

#' Empty per-download status tibble with the right column types.
#' @noRd
empty_download_status <- function() {
  tibble::tibble(
    url = character(0),
    local_path = character(0),
    status = character(0),
    size_bytes = numeric(0),
    sha256 = character(0),
    reason = character(0)
  )
}

#' Build a per-URL "pending" download_status for known but not-yet-fetched URLs.
#'
#' Records whose PDFs we deliberately didn't fetch this run (download = FALSE,
#' or the relevance gate skipped them) still need their URL list captured on
#' the sidecar so a later run can find them. A pending row carries the URL
#' and its section tag (set later by the sidecar writer) but `local_path = NA`.
#'
#' @noRd
pending_download_status <- function(urls) {
  if (length(urls) == 0L) {
    return(empty_download_status())
  }
  tibble::tibble(
    url = urls,
    local_path = NA_character_,
    status = "pending",
    size_bytes = NA_real_,
    sha256 = NA_character_,
    reason = NA_character_
  )
}
