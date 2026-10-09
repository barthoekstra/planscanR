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
  if (!nzchar(country)) {
    country <- "x"
  }
  document_id <- clean(document_id)
  if (!nzchar(document_id)) {
    document_id <- "x"
  }
  stem <- clean(url_stem)
  if (!nzchar(stem)) {
    stem <- "attachment"
  }
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
      country,
      "_",
      document_id,
      "_",
      substr(stem, 1L, keep),
      "-",
      short_hash,
      ".",
      ext
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
  filename <- slugify_filename(url, country, document_id)
  if (exists("storage_root_validate", mode = "function") && exists("storage_path", mode = "function")) {
    root <- if (is.null(root)) cache_dir_default() else root
    root <- storage_root_validate(root, create = TRUE, writable = TRUE)
    return(storage_path(root, file.path("files", country, document_id, filename), create_parent = TRUE))
  }
  dir <- cache_dir(file.path("files", country, document_id), create = TRUE, root = root)
  file.path(dir, filename)
}

#' Locate the actual on-disk file for a placeholder-extension cache path.
#'
#' When a URL has no file extension, `cache_path()` returns a `.x`
#' placeholder; the real file may have been renamed to e.g. `.pdf` after
#' the body was fetched. This helper returns the real path when a single
#' receipt-backed match exists, the original `dest` when its verification
#' receipt matches its bytes, or `NA_character_` otherwise.
#' @noRd
resolve_cached_path_internal <- function(dest) {
  if (length(dest) != 1L || is.na(dest) || !nzchar(dest)) {
    return(NA_character_)
  }
  if (grepl("\\.part$", basename(dest), ignore.case = TRUE)) {
    return(NA_character_)
  }
  if (is_verified_download(dest)) {
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
  matches <- matches[!grepl("\\.part$", basename(matches), ignore.case = TRUE)]
  if (length(matches) == 0L) {
    return(NA_character_)
  }
  sizes <- file.info(matches)$size
  matches <- matches[!is.na(sizes) & sizes > 0L & vapply(matches, is_verified_download, logical(1))]
  if (length(matches) == 1L) matches[[1]] else NA_character_
}

#' Map an HTTP Content-Type header value to a file extension.
#'
#' Returns `NA_character_` when no mapping applies. Unknown types are still
#' accepted by the downloader; callers use the URL extension or a stable
#' generic `.bin` fallback when no stronger signal is available.
#' @noRd
content_type_to_ext <- function(content_type) {
  if (is.null(content_type) || length(content_type) != 1L || is.na(content_type) || !nzchar(content_type)) {
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
    "application/x-7z-compressed" = "7z",
    "application/x-rar-compressed" = "rar",
    "application/vnd.rar" = "rar",
    "application/gzip" = "gz",
    "application/x-gzip" = "gz",
    "application/x-bzip2" = "bz2",
    "application/x-xz" = "xz",
    "application/x-sqlite3" = "sqlite",
    "application/vnd.ms-outlook" = "msg",
    "application/x-msg" = "msg",
    "application/epub+zip" = "epub",
    "application/x-tar" = "tar",
    "text/xml" = "xml",
    "text/plain" = "txt",
    "text/html" = "html",
    "text/csv" = "csv",
    "text/css" = "css",
    "text/calendar" = "ics",
    "image/jpeg" = "jpg",
    "image/png" = "png",
    "image/tiff" = "tif",
    "image/gif" = "gif",
    "image/webp" = "webp",
    "image/svg+xml" = "svg",
    "image/bmp" = "bmp",
    "image/x-ms-bmp" = "bmp",
    NA_character_
  )
}

#' Sniff a file's leading bytes to identify its real type.
#'
#' Used as a fallback when the server replies with a generic
#' `application/octet-stream`. Returns `NA_character_` for unrecognised
#' content; the downloader then uses the URL extension or `.bin`.
#' @noRd
sniff_magic_ext <- function(path) {
  if (length(path) != 1L || is.na(path) || !file.exists(path)) {
    return(NA_character_)
  }
  if (file.info(path)$size < 2L) {
    return(NA_character_)
  }
  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  b <- readBin(con, what = "raw", n = 32L)
  eq <- function(prefix) length(b) >= length(prefix) && all(b[seq_along(prefix)] == as.raw(prefix))
  if (eq(c(0x25, 0x50, 0x44, 0x46))) {
    return("pdf")
  } # %PDF
  if (eq(c(0x50, 0x4B, 0x03, 0x04))) {
    return("zip")
  } # PK..  (also docx/xlsx/pptx containers)
  if (eq(c(0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C))) {
    return("7z")
  } # 7z archive
  if (eq(c(0x52, 0x61, 0x72, 0x21, 0x1A, 0x07))) {
    return("rar")
  } # RAR archive
  if (eq(c(0x1F, 0x8B))) {
    return("gz")
  } # gzip
  if (eq(c(0x42, 0x5A, 0x68))) {
    return("bz2")
  } # bzip2
  if (eq(c(0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00))) {
    return("xz")
  } # xz
  if (eq(c(0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1))) {
    return("ole")
  } # OLE Compound File (MSG/DOC/XLS and similar)
  if (eq(c(0x42, 0x4D))) {
    return("bmp")
  } # Windows bitmap
  sqlite_magic <- as.raw(c(
    charToRaw("SQLite format 3"),
    0x00
  ))
  if (length(b) >= length(sqlite_magic) &&
    all(b[seq_along(sqlite_magic)] == sqlite_magic)) {
    return("sqlite")
  }
  if (eq(c(0xFF, 0xD8, 0xFF))) {
    return("jpg")
  }
  if (eq(c(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A))) {
    return("png")
  }
  if (eq(c(0x47, 0x49, 0x46, 0x38))) {
    return("gif")
  }
  if (eq(c(0x49, 0x49, 0x2A, 0x00)) || eq(c(0x4D, 0x4D, 0x00, 0x2A))) {
    return("tif")
  }
  NA_character_
}

#' Rewrite a placeholder `.x` filename to its real extension.
#'
#' Called after a successful download for paths produced by
#' `slugify_filename()` from URLs whose path didn't expose an extension.
#' The URL extension is retained when it is present. For extensionless URLs,
#' magic-byte sniffing is preferred over Content-Type because portals often
#' mislabel archives and office files; `.bin` is used when neither signal is
#' known. This keeps every nonempty binary attachment addressable without
#' pretending that its format was identified.
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
  ext <- attachment_extension(dest, content_type, path = dest)
  new_dest <- paste0(tools::file_path_sans_ext(dest), ".", ext)
  if (identical(new_dest, dest) || file.exists(new_dest)) {
    return(dest)
  }
  ok <- tryCatch(file.rename(dest, new_dest), error = function(e) FALSE)
  if (isTRUE(ok)) new_dest else dest
}

#' Choose a stable extension for a downloaded attachment.
#' @noRd
attachment_extension <- function(
  dest,
  content_type,
  path = NULL,
  content_disposition = NA_character_
) {
  expected_ext <- tolower(tools::file_ext(dest))
  if (nzchar(expected_ext) && expected_ext != "x") {
    return(expected_ext)
  }
  disposition_ext <- content_disposition_to_ext(content_disposition)
  if (!is.na(disposition_ext) && nzchar(disposition_ext)) {
    return(disposition_ext)
  }
  magic_ext <- if (!is.null(path)) sniff_magic_ext(path) else NA_character_
  if (!is.na(magic_ext) && nzchar(magic_ext)) {
    return(magic_ext)
  }
  mime_ext <- content_type_to_ext(content_type)
  if (!is.na(mime_ext) && nzchar(mime_ext) &&
    (!identical(mime_ext, "html") || is_explicit_html_attachment(
      content_disposition, dest
    ))) {
    return(mime_ext)
  }
  "bin"
}

#' Extract a safe extension from a Content-Disposition filename.
#' @noRd
content_disposition_to_ext <- function(content_disposition) {
  if (is.null(content_disposition) || length(content_disposition) != 1L ||
    is.na(content_disposition) || !nzchar(content_disposition)) {
    return(NA_character_)
  }
  match <- regexec(
    "filename\\*?\\s*=\\s*([^;]+)",
    content_disposition,
    ignore.case = TRUE,
    perl = TRUE
  )
  value <- regmatches(content_disposition, match)[[1L]]
  if (length(value) < 2L) {
    return(NA_character_)
  }
  value <- trimws(value[[2L]])
  value <- gsub('^"|"$', "", value)
  # RFC 5987 values use charset''percent-encoded-name. Keep ordinary
  # apostrophes in quoted filenames while removing only that prefix.
  value <- sub("^[^']*''", "", value)
  ext <- tolower(tools::file_ext(tryCatch(utils::URLdecode(value), error = function(e) value)))
  ext <- gsub("[^a-z0-9]", "", ext, perl = TRUE)
  if (!nzchar(ext)) NA_character_ else ext
}

#' Whether a response carries explicit evidence of an HTML attachment.
#' @noRd
is_explicit_html_attachment <- function(content_disposition, dest) {
  if (is.null(content_disposition) || length(content_disposition) != 1L ||
    is.na(content_disposition) || !grepl(
    "(^|;)\\s*attachment\\s*(;|$)",
    content_disposition,
    ignore.case = TRUE,
    perl = TRUE
  )) {
    return(FALSE)
  }
  expected_ext <- tolower(tools::file_ext(dest))
  disposition_ext <- content_disposition_to_ext(content_disposition)
  identical(expected_ext, "html") || identical(expected_ext, "htm") ||
    identical(disposition_ext, "html") || identical(disposition_ext, "htm")
}

#' Detect a JSON authorization/error envelope without rejecting data fields.
#' @noRd
looks_like_json_error <- function(preview_text) {
  if (!grepl("^\\s*\\{", preview_text, perl = TRUE)) {
    return(FALSE)
  }
  marker <- "(error|exception|failure|failed|unauthori|forbidden|not[ -]?found|login|sign[ -]?in|expired|access[ -]?denied|session[ -]?(expired|invalid|ended)|invalid[ -]?token)"
  code <- "\\b(401|403|404|408|419|429|500|502|503|504)\\b"
  parsed <- tryCatch(
    jsonlite::fromJSON(preview_text, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.list(parsed)) {
    for (key in intersect(names(parsed), c("error", "errors", "exception", "message", "status"))) {
      values <- unlist(parsed[[key]], recursive = TRUE, use.names = FALSE)
      if (length(values) == 0L) {
        next
      }
      text <- tolower(paste(as.character(values), collapse = " "))
      if (grepl(marker, text, perl = TRUE) || grepl(code, text, perl = TRUE)) {
        return(TRUE)
      }
    }
    return(FALSE)
  }
  # A large JSON attachment may be truncated by the preview read. Inspect
  # only scalar values for error-like keys; `"error": 0` and similar data
  # fields therefore remain valid.
  pairs <- regmatches(
    preview_text,
    gregexpr(
      "\"([^\"]+)\"\\s*:\\s*(\"[^\"]*\"|true|false|null|-?[0-9]+)",
      preview_text,
      perl = TRUE
    )
  )[[1L]]
  for (pair in pairs) {
    fields <- regmatches(
      pair,
      regexec(
        "\"([^\"]+)\"\\s*:\\s*(\"([^\"]*)\"|true|false|null|-?[0-9]+)",
        pair,
        perl = TRUE
      )
    )[[1L]]
    if (length(fields) < 4L ||
      !tolower(fields[[2L]]) %in% c("error", "errors", "exception", "message", "status")) {
      next
    }
    value <- if (length(fields) >= 4L && !is.na(fields[[4L]]) &&
      nzchar(fields[[4L]])) {
      fields[[4L]]
    } else {
      fields[[3L]]
    }
    if (is.na(value)) {
      next
    }
    value <- tolower(value)
    if (grepl(marker, value, perl = TRUE) || grepl(code, value, perl = TRUE)) {
      return(TRUE)
    }
  }
  FALSE
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
      timeout <- getOption("planscanR.timeout", 60)
      if (length(timeout) == 1L && is.numeric(timeout) &&
        isTRUE(is.infinite(timeout)) && isTRUE(timeout > 0)) {
        # A queue run may disable the aggregate GET timeout, but the cheap
        # preflight must still fail promptly when a server never answers HEAD.
        req <- httr2::req_timeout(req, 60)
      }
      req <- httr2::req_method(req, "HEAD")
      resp <- httr2::req_perform(req)
      response_content_length(resp)
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

#' Return a filesystem-safe basename for a verification receipt.
#' @noRd
download_receipt_basename <- function(path, sha256) {
  base <- basename(path)
  suffix <- paste0(".", as.character(sha256), ".verified.json")
  max_bytes <- 254L
  if (nchar(base, type = "bytes") + nchar(suffix, type = "bytes") <= max_bytes) {
    return(paste0(base, suffix))
  }
  base_hash <- substr(unclass(as.character(openssl::sha1(base))), 1L, 12L)
  marker <- paste0("-", base_hash)
  keep <- max(1L, max_bytes - nchar(suffix, type = "bytes") - nchar(marker, type = "bytes"))
  paste0(substr(base, 1L, keep), marker, suffix)
}

#' Path of the publication proof stored beside a verified attachment.
#' @noRd
download_receipt_path <- function(path, sha256 = NULL) {
  if (length(path) != 1L || is.na(path) || !nzchar(path)) {
    return(NA_character_)
  }
  if (is.null(sha256)) {
    sha256 <- file_sha256(path)
  }
  if (length(sha256) == 1L && !is.na(sha256) && nzchar(sha256)) {
    return(file.path(dirname(path), download_receipt_basename(path, sha256)))
  }
  paste0(path, ".verified.json")
}

#' Check the immutable publication proof for a cached attachment.
#' @noRd
is_verified_download <- function(path) {
  if (!file.exists(path) || file.info(path)$size <= 0) {
    return(FALSE)
  }
  digest <- file_sha256(path)
  if (is.na(digest)) {
    return(FALSE)
  }
  receipt_path <- download_receipt_path(path, digest)
  if (!file.exists(receipt_path)) {
    return(FALSE)
  }
  receipt <- tryCatch(jsonlite::read_json(receipt_path, simplifyVector = TRUE), error = function(e) NULL)
  if (!is.list(receipt) || !identical(as.integer(receipt$schema_version), 1L)) {
    return(FALSE)
  }
  size <- suppressWarnings(as.numeric(receipt$size_bytes))
  receipt_sha256 <- as.character(receipt$sha256 %||% NA_character_)
  if (length(size) != 1L || is.na(size) || size != file.info(path)$size || length(receipt_sha256) != 1L || is.na(receipt_sha256)) {
    return(FALSE)
  }
  identical(digest, receipt_sha256)
}

#' Inspect a cached attachment and optionally repair its receipt from trusted metadata.
#' @noRd
reconcile_cached_download_internal <- function(
  path,
  expected_size_bytes = NA_real_,
  expected_sha256 = NA_character_,
  url = NA_character_,
  content_type = NA_character_,
  repair = FALSE
) {
  if (length(path) != 1L || is.na(path) || !nzchar(path)) {
    return(tibble::tibble(
      path = as.character(path)[1],
      status = "missing",
      size_bytes = NA_real_,
      sha256 = NA_character_,
      receipt_path = NA_character_,
      reason = "empty path"
    ))
  }
  if (!file.exists(path)) {
    return(tibble::tibble(
      path = path,
      status = "missing",
      size_bytes = NA_real_,
      sha256 = NA_character_,
      receipt_path = NA_character_,
      reason = "file does not exist"
    ))
  }
  info <- file.info(path)
  if (isTRUE(info$isdir)) {
    return(tibble::tibble(
      path = path,
      status = "unverified",
      size_bytes = NA_real_,
      sha256 = NA_character_,
      receipt_path = NA_character_,
      reason = "path is a directory"
    ))
  }
  size <- as.numeric(info$size)
  if (grepl("\\.part$", basename(path), ignore.case = TRUE)) {
    return(tibble::tibble(
      path = path,
      status = "partial",
      size_bytes = size,
      sha256 = NA_character_,
      receipt_path = NA_character_,
      reason = "staging file is not a published attachment"
    ))
  }
  digest <- if (!is.na(size) && size > 0) file_sha256(path) else NA_character_
  receipt_path <- if (!is.na(digest)) download_receipt_path(path, digest) else NA_character_
  if (isTRUE(is_verified_download(path))) {
    return(tibble::tibble(
      path = path,
      status = "verified",
      size_bytes = size,
      sha256 = digest,
      receipt_path = receipt_path,
      reason = NA_character_
    ))
  }
  if (!isTRUE(repair)) {
    return(tibble::tibble(
      path = path,
      status = "unverified",
      size_bytes = size,
      sha256 = digest,
      receipt_path = receipt_path,
      reason = if (is.na(size) || size <= 0) {
        "empty or unreadable file"
      } else {
        "matching verification receipt is absent or invalid"
      }
    ))
  }

  expected_size <- suppressWarnings(as.numeric(expected_size_bytes))
  expected_sha <- as.character(expected_sha256)
  expected_ok <- length(expected_size) == 1L && !is.na(expected_size) &&
    length(expected_sha) == 1L && !is.na(expected_sha) && nzchar(expected_sha) &&
    expected_size == size && identical(tolower(expected_sha), tolower(digest))
  if (!isTRUE(expected_ok)) {
    return(tibble::tibble(
      path = path,
      status = "unverified",
      size_bytes = size,
      sha256 = digest,
      receipt_path = receipt_path,
      reason = "trusted size and SHA-256 metadata do not match the published bytes"
    ))
  }
  repaired <- tryCatch(
    {
      write_download_receipt(
        path,
        url = if (length(url) == 1L && !is.na(url)) url else NA_character_,
        content_type = if (length(content_type) == 1L && !is.na(content_type)) content_type else NA_character_,
        size_bytes = expected_size,
        sha256 = digest
      )
      TRUE
    },
    error = function(e) e
  )
  if (inherits(repaired, "error")) {
    return(tibble::tibble(
      path = path,
      status = "unverified",
      size_bytes = size,
      sha256 = digest,
      receipt_path = receipt_path,
      reason = conditionMessage(repaired)
    ))
  }
  tibble::tibble(
    path = path,
    status = "repaired",
    size_bytes = size,
    sha256 = digest,
    receipt_path = receipt_path,
    reason = "published verification receipt from trusted metadata"
  )
}

#' Audit published and interrupted attachment files under a cache root.
#' @noRd
audit_cache_downloads_internal <- function(cache_dir = NULL, country = NULL) {
  root <- if (is.null(cache_dir)) cache_dir_default() else cache_dir
  files_root <- file.path(root, "files")
  if (!dir.exists(files_root)) {
    return(tibble::tibble(
      path = character(0),
      status = character(0),
      size_bytes = numeric(0),
      sha256 = character(0),
      receipt_path = character(0),
      reason = character(0),
      country = character(0),
      document_id = character(0)
    ))
  }
  scan_root <- if (is.null(country)) files_root else file.path(files_root, tolower(country))
  if (!dir.exists(scan_root)) {
    return(tibble::tibble(
      path = character(0),
      status = character(0),
      size_bytes = numeric(0),
      sha256 = character(0),
      receipt_path = character(0),
      reason = character(0),
      country = character(0),
      document_id = character(0)
    ))
  }
  paths <- list.files(scan_root, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE)
  paths <- paths[!file.info(paths)$isdir]
  if (length(paths) == 0L) {
    return(tibble::tibble(
      path = character(0),
      status = character(0),
      size_bytes = numeric(0),
      sha256 = character(0),
      receipt_path = character(0),
      reason = character(0),
      country = character(0),
      document_id = character(0)
    ))
  }
  base <- basename(paths)
  data_paths <- paths[
    !grepl("\\.meta\\.json$|\\.geometry\\.geojson$|\\.verified\\.json$|\\.lock$", base, ignore.case = TRUE)
  ]
  rows <- lapply(data_paths, reconcile_cached_download_internal)
  out <- if (length(rows) == 0L) {
    tibble::tibble(
      path = character(0),
      status = character(0),
      size_bytes = numeric(0),
      sha256 = character(0),
      receipt_path = character(0),
      reason = character(0)
    )
  } else {
    do.call(rbind, rows)
  }
  if (nrow(out) > 0L) {
    rel <- substring(out$path, nchar(files_root) + 2L)
    parts <- strsplit(rel, "/", fixed = TRUE)
    out$country <- vapply(parts, function(x) if (length(x) >= 1L) x[[1]] else NA_character_, character(1))
    out$document_id <- vapply(parts, function(x) if (length(x) >= 2L) x[[2]] else NA_character_, character(1))
  } else {
    out$country <- character(0)
    out$document_id <- character(0)
  }
  # A receipt whose hash no longer matches any sibling is itself evidence of
  # an interrupted/replaced publication. Keep it visible to recovery tooling.
  receipt_paths <- paths[grepl("\\.verified\\.json$", basename(paths), ignore.case = TRUE)]
  if (length(receipt_paths) > 0L) {
    expected_receipts <- unlist(lapply(data_paths, function(p) {
      d <- file_sha256(p)
      if (is.na(d)) NA_character_ else download_receipt_path(p, d)
    }), use.names = FALSE)
    orphan <- receipt_paths[!receipt_paths %in% expected_receipts]
    if (length(orphan) > 0L) {
      orphan_rows <- tibble::tibble(
        path = orphan,
        status = "orphan_receipt",
        size_bytes = as.numeric(file.info(orphan)$size),
        sha256 = NA_character_,
        receipt_path = orphan,
        reason = "receipt has no matching current data bytes"
      )
      rel_orphan <- substring(orphan, nchar(files_root) + 2L)
      orphan_parts <- strsplit(rel_orphan, "/", fixed = TRUE)
      orphan_rows$country <- vapply(
        orphan_parts,
        function(x) if (length(x) >= 1L) x[[1]] else NA_character_,
        character(1)
      )
      orphan_rows$document_id <- vapply(
        orphan_parts,
        function(x) if (length(x) >= 2L) x[[2]] else NA_character_,
        character(1)
      )
      out <- rbind(out, orphan_rows)
    }
  }
  out[order(out$path, out$status), , drop = FALSE]
}

#' Atomically write the proof that a canonical attachment was verified.
#' @noRd
write_download_receipt <- function(path, url, content_type, size_bytes, sha256, publish = TRUE) {
  if (length(sha256) != 1L || is.na(sha256) || !nzchar(sha256)) {
    stop("a SHA-256 digest is required for a verification receipt", call. = FALSE)
  }
  receipt_path <- download_receipt_path(path, sha256)
  part <- tempfile(pattern = ".planscanR-receipt-", tmpdir = dirname(receipt_path), fileext = ".part")
  if (isTRUE(publish)) {
    on.exit(unlink(part, force = TRUE), add = TRUE)
  }
  jsonlite::write_json(
    list(
      schema_version = 1L,
      url = if (length(url) == 1L && !is.na(url)) url else NULL,
      size_bytes = as.numeric(size_bytes),
      sha256 = sha256,
      content_type = if (length(content_type) == 1L && !is.na(content_type)) content_type else NULL
    ),
    part,
    auto_unbox = TRUE,
    null = "null"
  )
  if (!isTRUE(publish)) {
    return(list(path = receipt_path, part = part))
  }
  if (!isTRUE(tryCatch(rename_download_file(part, receipt_path), error = function(e) FALSE))) {
    stop("atomic verification receipt publication failed", call. = FALSE)
  }
  invisible(receipt_path)
}

#' Publish an already-downloaded, validated file with a receipt.
#' @noRd
publish_verified_download_copy <- function(
  part,
  dest,
  url,
  content_type = "application/octet-stream",
  content_disposition = NA_character_
) {
  if (!file.exists(part) || isTRUE(file.info(part)$isdir) || file.info(part)$size <= 0) {
    stop("cannot publish an empty or missing staged download", call. = FALSE)
  }
  # Discovery receives an HTTP 200 even for portal login/error pages. Reuse
  # the same body/MIME/magic validation as the normal downloader before any
  # receipt or canonical bytes are published.
  validate_download_body(part, content_type, dest, content_disposition)
  size <- unname(file.info(part)$size)
  sha256 <- file_sha256(part)
  if (is.na(sha256)) {
    stop("could not compute SHA-256 for staged download", call. = FALSE)
  }
  receipt <- write_download_receipt(
    dest,
    url = url,
    content_type = content_type,
    size_bytes = size,
    sha256 = sha256,
    publish = FALSE
  )
  on.exit(unlink(receipt$part, force = TRUE), add = TRUE)
  if (!isTRUE(tryCatch(rename_download_file(receipt$part, receipt$path), error = function(e) FALSE))) {
    stop("atomic verification receipt publication failed", call. = FALSE)
  }
  if (!atomic_publish_download(part, dest)) {
    stop("atomic download publication failed", call. = FALSE)
  }
  remove_download_variants(dest, dest)
  list(local_path = dest, size_bytes = size, sha256 = sha256)
}

#' Return one response header as a scalar character value.
#' @noRd
response_header_value <- function(resp, name) {
  value <- tryCatch(httr2::resp_header(resp, name), error = function(e) NULL)
  if (is.null(value) || length(value) == 0L || is.na(value[[1]])) {
    return(NA_character_)
  }
  as.character(value[[1]])
}

#' Parse a response Content-Length, returning NA for missing or invalid values.
#' @noRd
response_content_length <- function(resp) {
  encoding <- response_header_value(resp, "Content-Encoding")
  if (!is.na(encoding) && nzchar(trimws(encoding)) && tolower(trimws(encoding)) != "identity") {
    return(NA_real_)
  }
  value <- response_header_value(resp, "Content-Length")
  if (is.na(value)) {
    return(NA_real_)
  }
  out <- suppressWarnings(as.numeric(trimws(value)))
  if (is.na(out) || out < 0 || !is.finite(out)) NA_real_ else out
}

#' Create a unique staging path beside the eventual cache destination.
#' @noRd
download_part_path <- function(dest) {
  tempfile(pattern = ".planscanR-", tmpdir = dirname(dest), fileext = ".part")
}

#' Validate an attachment body before it can be published.
#' @noRd
validate_download_body <- function(
  path,
  content_type,
  dest,
  content_disposition = NA_character_
) {
  size <- unname(file.info(path)$size)
  if (is.na(size) || size <= 0) {
    stop("download response body is empty", call. = FALSE)
  }

  allow_html_attachment <- is_explicit_html_attachment(content_disposition, dest)

  con <- file(path, open = "rb")
  on.exit(close(con), add = TRUE)
  preview <- readBin(con, what = "raw", n = 4096L)
  preview_ascii <- preview
  preview_ascii[as.integer(preview_ascii) > 127L] <- as.raw(0x20)
  preview_text <- tryCatch(tolower(trimws(rawToChar(preview_ascii))), error = function(e) "")
  if (grepl(
    "^(<!doctype[[:space:]]+html|<(html|head|body|script|title|form|meta|div|p|a)([[:space:]]|>|/))",
    preview_text
  ) &&
    !allow_html_attachment) {
    stop("download response body looks like an HTML/login/error body", call. = FALSE)
  }
  # Portals sometimes return a JSON error envelope with HTTP 200 and a
  # generic MIME type. Inspect values belonging to error-like fields so a
  # legitimate data object such as `{"error": 0, ...}` remains downloadable.
  if (looks_like_json_error(preview_text)) {
    stop("download response body looks like an error response", call. = FALSE)
  }

  # Format checks are deliberately advisory. A portal can return a valid
  # attachment with a generic or incorrect MIME type, an uncommon magic
  # signature, or a legacy file format. Empty bodies and clear error pages
  # were rejected above; every other nonempty response is retained and gets
  # a stable URL/MIME/magic-derived extension (or `.bin`).
  attachment_extension(
    dest,
    content_type,
    path = path,
    content_disposition = content_disposition
  )
}

#' Replace a cache file atomically while preserving it if publication fails.
#' @noRd
rename_download_file <- function(from, to) {
  file.rename(from, to)
}

#' @noRd
atomic_publish_download <- function(part, dest) {
  published <- tryCatch(rename_download_file(part, dest), error = function(e) FALSE)
  isTRUE(published)
}

#' Remove stale extension variants after a successful publication.
#' @noRd
remove_download_variants <- function(dest, keep) {
  if (tools::file_ext(dest) != "x") {
    return(invisible(NULL))
  }
  stem <- tools::file_path_sans_ext(dest)
  paths <- Sys.glob(paste0(stem, ".*"))
  receipts <- paths[grepl("\\.verified\\.json$", basename(paths), ignore.case = TRUE)]
  variants <- paths[
    !grepl("\\.part$|\\.verified\\.json$", basename(paths), ignore.case = TRUE) &
      normalizePath(paths, mustWork = FALSE) != normalizePath(keep, mustWork = FALSE)
  ]
  data_paths <- paths[!grepl("\\.part$|\\.verified\\.json$", basename(paths), ignore.case = TRUE)]
  generated_receipts <- vapply(
    data_paths,
    function(path) {
      digest <- file_sha256(path)
      if (is.na(digest)) NA_character_ else download_receipt_path(path, digest)
    },
    character(1)
  )
  receipts <- unique(c(receipts, generated_receipts[!is.na(generated_receipts)]))
  if (length(variants) > 0L) {
    unlink(variants, force = TRUE)
  }
  if (length(receipts) > 0L) {
    keep_receipt <- normalizePath(
      download_receipt_path(keep, file_sha256(keep)),
      mustWork = FALSE
    )
    receipts <- receipts[normalizePath(receipts, mustWork = FALSE) != keep_receipt]
    if (length(receipts) > 0L) {
      unlink(receipts, force = TRUE)
    }
  }
}

#' Stream one response into a bounded staging file.
#' @noRd
invoke_storage_guard <- function(storage_guard, cumulative_bytes, advertised_size,
                                 phase = "stream", pending_bytes = 0) {
  if (!is.function(storage_guard)) {
    return(list(ok = TRUE))
  }
  cumulative_bytes <- suppressWarnings(as.numeric(cumulative_bytes))
  advertised_size <- suppressWarnings(as.numeric(advertised_size))
  if (length(cumulative_bytes) != 1L || is.na(cumulative_bytes) ||
    !is.finite(cumulative_bytes) || cumulative_bytes < 0) {
    return(list(ok = FALSE, reason = "The storage guard received invalid cumulative bytes."))
  }
  if (length(advertised_size) != 1L || is.nan(advertised_size) ||
    (!is.na(advertised_size) && (!is.finite(advertised_size) || advertised_size < 0))) {
    advertised_size <- NA_real_
  }
  pending_bytes <- suppressWarnings(as.numeric(pending_bytes))
  if (length(pending_bytes) != 1L || is.na(pending_bytes) ||
    !is.finite(pending_bytes) || pending_bytes < 0) {
    return(list(ok = FALSE, reason = "The storage guard received invalid pending bytes."))
  }
  formals <- tryCatch(names(formals(storage_guard)), error = function(error) character())
  accepts_phase <- "phase" %in% formals || "..." %in% formals
  accepts_pending <- "pending_bytes" %in% formals || "..." %in% formals
  result <- tryCatch(
    if (isTRUE(accepts_phase) && isTRUE(accepts_pending)) {
      storage_guard(
        cumulative_bytes,
        advertised_size,
        phase = phase,
        pending_bytes = pending_bytes
      )
    } else if (isTRUE(accepts_phase)) {
      storage_guard(cumulative_bytes, advertised_size, phase = phase)
    } else if (isTRUE(accepts_pending)) {
      storage_guard(cumulative_bytes, advertised_size, pending_bytes = pending_bytes)
    } else {
      storage_guard(cumulative_bytes, advertised_size)
    },
    error = function(error) error
  )
  if (inherits(result, "error")) {
    return(list(ok = FALSE, reason = conditionMessage(result)))
  }
  if (is.logical(result) && length(result) == 1L && !is.na(result)) {
    return(list(ok = isTRUE(result), reason = if (isTRUE(result)) NULL else "The storage guard rejected the write."))
  }
  if (!is.list(result) || length(result$ok) != 1L || is.na(result$ok)) {
    return(list(ok = FALSE, reason = "The storage guard returned no valid decision."))
  }
  list(
    ok = isTRUE(result$ok),
    reason = if (isTRUE(result$ok)) NULL else as.character(result$reason %||% "The storage guard rejected the write.")
  )
}

download_stream_to_part <- function(
  req, part, cap, storage_guard = NULL, advertised_size = NA_real_
) {
  con <- file(part, open = "wb")
  on.exit(close(con), add = TRUE)
  bytes <- 0
  exceeded <- FALSE
  guard_failed <- FALSE
  guard_reason <- NULL
  callback <- function(chunk) {
    chunk <- as.raw(chunk)
    n <- length(chunk)
    if (is.finite(cap) && bytes + n > cap) {
      allowed <- max(0L, floor(cap - bytes))
      if (allowed > 0L) {
        if (is.function(storage_guard)) {
          guard <- invoke_storage_guard(
            storage_guard,
            bytes,
            advertised_size,
            phase = "stream",
            pending_bytes = allowed
          )
          if (!isTRUE(guard$ok)) {
            guard_failed <<- TRUE
            guard_reason <<- guard$reason %||% "The storage guard rejected the write."
            return(FALSE)
          }
        }
        writeBin(chunk[seq_len(allowed)], con)
        bytes <<- bytes + allowed
      }
      exceeded <<- TRUE
      return(FALSE)
    }
    if (n > 0L && is.function(storage_guard)) {
      guard <- invoke_storage_guard(
        storage_guard,
        bytes,
        advertised_size,
        phase = "stream",
        pending_bytes = n
      )
      if (!isTRUE(guard$ok)) {
        guard_failed <<- TRUE
        guard_reason <<- guard$reason %||% "The storage guard rejected the write."
        return(FALSE)
      }
    }
    if (n > 0L) {
      writeBin(chunk, con)
      bytes <<- bytes + n
    }
    TRUE
  }
  resp <- httr2::req_perform_stream(req, callback = callback, round = "byte")
  list(
    response = resp,
    size_bytes = bytes,
    exceeded = exceeded,
    guard_failed = guard_failed,
    guard_reason = guard_reason
  )
}

#' Download, validate, checksum and publish one response from a staged path.
#' @noRd
download_staged_response <- function(
  req, url, dest, cap, storage_guard = NULL, advertised_size = NA_real_
) {
  part <- download_part_path(dest)
  on.exit(unlink(part, force = TRUE), add = TRUE)

  tryCatch(
    {
      transfer <- download_stream_to_part(
        req,
        part,
        cap,
        storage_guard = storage_guard,
        advertised_size = advertised_size
      )
      resp <- transfer$response
      status <- tryCatch(httr2::resp_status(resp), error = function(e) NA_integer_)
      if (length(status) == 1L && !is.na(status) && (status < 200L || status >= 300L)) {
        stop(sprintf("download returned HTTP status %s", status), call. = FALSE)
      }

      size <- as.numeric(transfer$size_bytes)
      if (isTRUE(transfer$guard_failed)) {
        return(list(
          local_path = NA_character_,
          status = "failed",
          size_bytes = size,
          sha256 = NA_character_,
          reason = transfer$guard_reason %||% "The storage guard rejected the transfer."
        ))
      }
      if (isTRUE(transfer$exceeded)) {
        return(list(
          local_path = NA_character_,
          status = "skipped_size",
          size_bytes = size,
          sha256 = NA_character_,
          reason = sprintf("streamed size exceeds cap %s", format(cap))
        ))
      }
      get_length <- response_content_length(resp)
      if (!is.na(get_length) && get_length > cap) {
        return(list(
          local_path = NA_character_,
          status = "skipped_size",
          size_bytes = get_length,
          sha256 = NA_character_,
          reason = sprintf("GET Content-Length %s exceeds cap %s", format(get_length), format(cap))
        ))
      }
      if (!is.na(size) && size > cap) {
        return(list(
          local_path = NA_character_,
          status = "skipped_size",
          size_bytes = size,
          sha256 = NA_character_,
          reason = sprintf("downloaded size %s exceeds cap %s", format(size), format(cap))
        ))
      }
      if (!is.function(storage_guard) && !is.na(get_length) &&
        (is.na(size) || get_length != size)) {
        stop(
          sprintf("GET Content-Length %s does not match downloaded size %s", format(get_length), format(size)),
          call. = FALSE
        )
      }

      content_type <- response_header_value(resp, "Content-Type")
      content_disposition <- response_header_value(resp, "Content-Disposition")
      extension <- validate_download_body(
        part,
        content_type,
        dest,
        content_disposition
      )
      sha256 <- file_sha256(part)
      if (is.na(sha256)) {
        stop("could not compute SHA-256 for staged download", call. = FALSE)
      }
      if (is.function(storage_guard)) {
        guard <- invoke_storage_guard(
          storage_guard,
          size,
          if (is.na(advertised_size)) get_length else advertised_size,
          phase = "publish",
          pending_bytes = 0
        )
        if (!isTRUE(guard$ok)) {
          return(list(
            local_path = NA_character_,
            status = "failed",
            size_bytes = size,
            sha256 = NA_character_,
            reason = guard$reason %||% "The storage guard rejected publication."
          ))
        }
      }
      publication_dest <- dest
      if (tools::file_ext(dest) == "x") {
        publication_dest <- paste0(tools::file_path_sans_ext(dest), ".", extension)
      }
      receipt <- write_download_receipt(
        publication_dest,
        url = url,
        content_type = content_type,
        size_bytes = size,
        sha256 = sha256,
        publish = FALSE
      )
      on.exit(unlink(receipt$part, force = TRUE), add = TRUE)
      if (!isTRUE(tryCatch(rename_download_file(receipt$part, receipt$path), error = function(e) FALSE))) {
        stop("atomic verification receipt publication failed", call. = FALSE)
      }
      if (!atomic_publish_download(part, publication_dest)) {
        stop("atomic download publication failed", call. = FALSE)
      }
      remove_download_variants(dest, publication_dest)
      list(
        local_path = publication_dest,
        status = "downloaded",
        size_bytes = unname(file.info(publication_dest)$size),
        sha256 = sha256,
        reason = NA_character_
      )
    },
    error = function(e) {
      list(
        local_path = NA_character_,
        status = "failed",
        size_bytes = NA_real_,
        sha256 = NA_character_,
        reason = conditionMessage(e)
      )
    }
  )
}

#' Run the shared preflight and staged download path for one URL.
#' @noRd
download_request <- function(url) {
  req <- req_planscanr(url_encode_safe(url))
  timeout <- getOption("planscanR.timeout", 60)
  # Queue workers may deliberately disable the aggregate request timeout for
  # large downloads. Keep those workers from hanging forever on a stalled
  # socket while leaving the normal finite timeout path unchanged.
  if (length(timeout) == 1L && is.numeric(timeout) &&
    isTRUE(is.infinite(timeout)) && isTRUE(timeout > 0)) {
    req <- httr2::req_options(
      req,
      connecttimeout = 60,
      low_speed_limit = 1,
      low_speed_time = 120
    )
  }
  req
}

#' @noRd
download_one_attachment <- function(url, dest, cap, storage_guard = NULL) {
  announced <- head_content_length(url)
  if (!is.na(announced) && announced > cap) {
    return(list(
      local_path = NA_character_,
      status = "skipped_size",
      size_bytes = announced,
      sha256 = NA_character_,
      reason = sprintf("HEAD Content-Length %s exceeds cap %s", format(announced), format(cap))
    ))
  }
  if (is.function(storage_guard)) {
    guard <- invoke_storage_guard(storage_guard, 0, announced, phase = "stream")
    if (!isTRUE(guard$ok)) {
      return(list(
        local_path = NA_character_,
        status = "failed",
        size_bytes = NA_real_,
        sha256 = NA_character_,
        reason = guard$reason %||% "The storage guard rejected the transfer."
      ))
    }
  }
  tryCatch(
    if (is.function(storage_guard)) {
      download_staged_response(
        download_request(url), url, dest, cap,
        storage_guard = storage_guard,
        advertised_size = announced
      )
    } else {
      download_staged_response(download_request(url), url, dest, cap)
    },
    error = function(e) {
      list(
        local_path = NA_character_,
        status = "failed",
        size_bytes = NA_real_,
        sha256 = NA_character_,
        reason = conditionMessage(e)
      )
    }
  )
}

#' Download a set of attachment URLs, with size cap and structured per-file
#' status reporting.
#'
#' For each URL:
#'  * If a file and matching SHA-256 verification receipt already exist at the
#'    destination and `overwrite = FALSE`, it is treated as cached: status
#'    `"cached"`.
#'  * Otherwise a HEAD probe checks `Content-Length`; URLs whose announced
#'    size exceeds `max_file_size_mb` are skipped with status `"skipped_size"`.
#'  * If the HEAD probe fails (e.g. server doesn't support HEAD), the download
#'    is streamed into bounded staging and stops when the cap is crossed.
#'    Completed responses are checked for length and clear HTML/error bodies
#'    before publication; arbitrary nonempty attachment bytes are retained.
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
    out <- download_one_attachment(u, dest, cap)
    c(list(url = u), out)
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
  # winslash = "/" so the prefix check below works on Windows, where
  # normalizePath() otherwise returns backslash paths that never match the
  # forward-slash-appended root.
  abs_targets <- normalizePath(targets, winslash = "/", mustWork = TRUE)
  root_real <- normalizePath(root, winslash = "/", mustWork = TRUE)
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
