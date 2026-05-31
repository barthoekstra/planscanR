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
#' When the URL's path does not carry a file extension (e.g. Kotkas's
#' `?attachment_id=...` endpoints), two things happen: an 8-char SHA-1 of
#' the full URL is folded into the slug to keep per-attachment names
#' unique under one record, and `.x` is used as a placeholder extension
#' that `finalize_extension()` rewrites to the real type after the body
#' has been fetched.
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
  url_ext <- tools::file_ext(raw)
  url_stem <- tools::file_path_sans_ext(raw)

  clean <- function(x) {
    x <- tolower(x)
    x <- gsub("[^a-z0-9._-]+", "-", x, perl = TRUE)
    x <- gsub("-{2,}", "-", x)
    x <- gsub("(^[-._]+|[-._]+$)", "", x)
    x
  }
  country <- clean(country)
  if (!nzchar(country)) country <- "x"
  document_id <- clean(document_id)
  if (!nzchar(document_id)) document_id <- "x"
  stem <- clean(url_stem)
  if (!nzchar(stem)) stem <- "attachment"
  ext <- clean(url_ext)

  if (!nzchar(ext)) {
    # Portals whose URL path doesn't expose a filename (Kotkas, similar)
    # need a per-URL disambiguator or every attachment of one record
    # collides on the same basename and downloads overwrite each other.
    stem <- paste0(stem, "-", substr(openssl::sha1(url), 1L, 8L))
    ext <- "x"
  }

  base <- paste0(country, "_", document_id, "_", stem, ".", ext)

  if (nchar(base) > max_chars) {
    short_hash <- substr(openssl::sha1(url), 1L, 8L)
    keep <- max_chars - nchar(country) - nchar(document_id) - nchar(ext) - 12L
    keep <- max(8L, keep)
    base <- paste0(
      country, "_", document_id, "_",
      substr(stem, 1L, keep), "-", short_hash, ".", ext
    )
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
cache_path_internal <- function(url, country, document_id, root = NULL) {
  dir <- cache_dir(file.path("files", country, document_id), create = TRUE, root = root)
  file.path(dir, slugify_filename(url, country, document_id))
}

#' Locate the actual on-disk file for a placeholder-extension cache path.
#'
#' When a URL has no file extension, `cache_path()` returns a `.x`
#' placeholder; the real file may have been renamed to e.g. `.pdf` after
#' the body was fetched. This helper returns the real path when a single
#' non-empty match exists, the original `dest` if it is already on disk,
#' or `NA_character_` if nothing has been cached yet.
#' @noRd
resolve_cached_path_internal <- function(dest) {
  if (length(dest) != 1L || is.na(dest) || !nzchar(dest)) {
    return(NA_character_)
  }
  if (file.exists(dest) && file.info(dest)$size > 0L) {
    return(dest)
  }
  if (tools::file_ext(dest) != "x") {
    return(NA_character_)
  }
  stem <- tools::file_path_sans_ext(dest)
  # Sys.glob doesn't escape its input; the slug only contains [a-z0-9._-]
  # so there are no glob metacharacters to worry about.
  matches <- Sys.glob(paste0(stem, ".*"))
  if (length(matches) == 0L) {
    return(NA_character_)
  }
  sizes <- file.info(matches)$size
  matches <- matches[!is.na(sizes) & sizes > 0L]
  if (length(matches) == 1L) matches[[1]] else NA_character_
}

#' Map an HTTP Content-Type header value to a file extension.
#'
#' Returns `NA_character_` when no mapping applies — the caller leaves the
#' file with its placeholder `.x` extension rather than guessing.
#' @noRd
content_type_to_ext <- function(content_type) {
  if (is.null(content_type) || length(content_type) != 1L ||
      is.na(content_type) || !nzchar(content_type)) {
    return(NA_character_)
  }
  mime <- tolower(trimws(sub(";.*$", "", content_type)))
  switch(mime,
    "application/pdf" = "pdf",
    "application/zip" = "zip",
    "application/x-zip-compressed" = "zip",
    "application/msword" = "doc",
    "application/vnd.openxmlformats-officedocument.wordprocessingml.document" = "docx",
    "application/vnd.ms-excel" = "xls",
    "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" = "xlsx",
    "application/vnd.ms-powerpoint" = "ppt",
    "application/vnd.openxmlformats-officedocument.presentationml.presentation" = "pptx",
    "application/rtf" = "rtf",
    "application/json" = "json",
    "application/xml" = "xml",
    "text/xml" = "xml",
    "text/plain" = "txt",
    "text/html" = "html",
    "text/csv" = "csv",
    "image/jpeg" = "jpg",
    "image/png" = "png",
    "image/tiff" = "tif",
    "image/gif" = "gif",
    "image/webp" = "webp",
    "image/svg+xml" = "svg",
    NA_character_
  )
}

#' Sniff a file's leading bytes to identify its real type.
#'
#' Used as a fallback when the server replies with a generic
#' `application/octet-stream`. Returns `NA_character_` for unrecognised
#' content so the caller can leave the placeholder extension in place.
#' @noRd
sniff_magic_ext <- function(path) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    return(NA_character_)
  }
  if (file.info(path)$size < 4L) {
    return(NA_character_)
  }
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  b <- readBin(con, what = "raw", n = 8L)
  eq <- function(prefix) length(b) >= length(prefix) && all(b[seq_along(prefix)] == as.raw(prefix))
  if (eq(c(0x25, 0x50, 0x44, 0x46))) return("pdf")          # %PDF
  if (eq(c(0x50, 0x4B, 0x03, 0x04))) return("zip")          # PK..  (also docx/xlsx/pptx containers)
  if (eq(c(0xFF, 0xD8, 0xFF))) return("jpg")
  if (eq(c(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))) return("png")
  if (eq(c(0x47, 0x49, 0x46, 0x38))) return("gif")
  if (eq(c(0x49, 0x49, 0x2A, 0x00)) || eq(c(0x4D, 0x4D, 0x00, 0x2A))) return("tif")
  NA_character_
}

#' Rewrite a placeholder `.x` filename to its real extension.
#'
#' Called after a successful download for paths produced by
#' `slugify_filename()` from URLs whose path didn't expose an extension.
#' Content-Type is the primary signal; magic-byte sniffing is a fallback
#' for generic responses. If neither yields a known type, the placeholder
#' extension is left in place so the file is still usable.
#'
#' @param dest On-disk path (already populated with the response body).
#' @param content_type Value of the `Content-Type` response header, or
#'   `NULL` / `NA` when unavailable.
#' @return The (possibly renamed) on-disk path.
#' @noRd
finalize_extension <- function(dest, content_type) {
  if (length(dest) != 1L || is.na(dest) || !nzchar(dest)) {
    return(dest)
  }
  if (tools::file_ext(dest) != "x" || !file.exists(dest)) {
    return(dest)
  }
  ext <- content_type_to_ext(content_type)
  if (is.na(ext)) {
    ext <- sniff_magic_ext(dest)
  }
  if (is.na(ext) || identical(ext, "x")) {
    return(dest)
  }
  new_dest <- paste0(tools::file_path_sans_ext(dest), ".", ext)
  if (identical(new_dest, dest) || file.exists(new_dest)) {
    return(dest)
  }
  ok <- tryCatch(file.rename(dest, new_dest), error = function(e) FALSE)
  if (isTRUE(ok)) new_dest else dest
}

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Percent-encode unsafe characters in a URL's path/query.
#'
#' Portal HTML sometimes yields attachment URLs with literal spaces (and other
#' characters illegal in a URL), which makes curl/httr2 abort the request with
#' "Failed to parse URL: Malformed input to a URL function". This encodes the
#' unsafe bytes while (a) leaving the `scheme://authority` untouched and
#' (b) preserving any existing `%XX` escapes, so already-encoded URLs are not
#' double-encoded. The original (un-encoded) URL is what we keep in
#' `download_status`/sidecars; only the network request uses the encoded form.
#' @noRd
url_encode_safe <- function(url) {
  if (length(url) != 1L || is.na(url) || !nzchar(url)) {
    return(url)
  }
  m <- regmatches(url, regexec("^([a-zA-Z][a-zA-Z0-9+.-]*://[^/]*)(.*)$", url))[[1]]
  if (length(m) == 3L) {
    prefix <- m[2]
    rest <- m[3]
  } else {
    prefix <- ""
    rest <- url
  }
  # Tokenise into either an existing %XX escape (kept verbatim) or a single
  # character (encoded via URLencode, which leaves URL-safe/reserved chars
  # like / ? & = : alone but escapes spaces and other unsafe bytes).
  tokens <- regmatches(rest, gregexpr("%[0-9A-Fa-f]{2}|.", rest, perl = TRUE))[[1]]
  enc <- vapply(
    tokens,
    function(tk) {
      if (grepl("^%[0-9A-Fa-f]{2}$", tk)) tk else utils::URLencode(tk, reserved = FALSE)
    },
    character(1)
  )
  paste0(prefix, paste0(enc, collapse = ""))
}

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
      req <- req_planscanr(url_encode_safe(url))
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
#'
#' Strips the `openssl::sha256()` S3 class before returning so the result is
#' a plain character — without this, jsonlite refuses to serialise the value
#' into the sidecar (`No method asJSON S3 class: sha256`).
#' @noRd
file_sha256 <- function(path) {
  if (is.na(path) || !file.exists(path)) {
    return(NA_character_)
  }
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  # `openssl::sha256()` returns an S3-classed value (`c("hash", "sha256")`).
  # `as.character()` keeps the class; `unclass()` first reverts to the raw
  # byte vector. The combination `unclass(as.character(x))` yields the
  # single-string hex digest with no class — what jsonlite needs to serialise.
  unclass(as.character(openssl::sha256(con)))
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
    dest <- cache_path_internal(u, country, document_id, root = root)
    cached <- resolve_cached_path_internal(dest)
    if (!is.na(cached) && !overwrite) {
      return(list(
        url = u,
        local_path = cached,
        status = "cached",
        size_bytes = unname(file.info(cached)$size),
        sha256 = file_sha256(cached),
        reason = NA_character_
      ))
    }
    if (overwrite) {
      # Sweep any pre-existing copies (placeholder or finalized) so the
      # new download can settle into the right name without colliding
      # with a stale finalized extension from a previous run.
      stem <- tools::file_path_sans_ext(dest)
      for (p in Sys.glob(paste0(stem, ".*"))) {
        unlink(p, force = TRUE)
      }
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
        req <- req_planscanr(url_encode_safe(u))
        resp <- httr2::req_perform(req, path = dest)
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
        ct <- tryCatch(httr2::resp_header(resp, "Content-Type"), error = function(e) NULL)
        final_dest <- finalize_extension(dest, ct)
        list(
          url = u,
          local_path = final_dest,
          status = "downloaded",
          size_bytes = unname(file.info(final_dest)$size),
          sha256 = file_sha256(final_dest),
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
#' or the relevance threshold skipped them) still need their URL list captured
#' on the sidecar so a later run can find them. A pending row carries the URL
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
