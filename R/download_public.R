# Public download surface.
#
# These are thin, stable wrappers over the internal download plumbing in
# `utils_download.R` / `utils_http.R`. They exist so downstream packages
# (notably planscanR.biogain's Yoda sync) can fetch a single attachment into
# the planscanR cache *exactly as planscanR's own downloader would* — same
# `files/<cc>/<doc>/<slug>` layout, same throttled/retrying httr2 client, same
# size cap, same SHA-256 — without reaching into `planscanR:::` internals.

#' Compute the local cache path an attachment URL would land at.
#'
#' Returns the deterministic destination path for an attachment without
#' downloading anything. The layout is
#' `<cache_dir>/files/<country>/<document_id>/<slug>`, where the slug is a
#' flatten-safe, lowercase ASCII basename derived from the URL (see the package
#' download docs). Computing this up front lets a caller decide whether to
#' fetch a URL — e.g. checking whether the file already exists locally or
#' remotely — before spending a request on it.
#'
#' For URLs whose path carries no file extension, the returned path uses a `.x`
#' placeholder extension; the real extension is only known after the body has
#' been fetched (see [resolve_cached_path()] and [download_to_cache()]).
#'
#' @param url Source URL (character scalar).
#' @param country ISO-2 country code.
#' @param document_id Portal-native document ID.
#' @param cache_dir Cache root. Defaults to [cache_dir_default()].
#' @return Absolute path (character scalar). The parent directory is created
#'   as a side effect.
#' @seealso [resolve_cached_path()], [download_to_cache()]
#' @export
#' @examples
#' cache_path(
#'   "https://pas.commissiemer.nl/files/nl/3619/a3619ts.pdf",
#'   country = "nl",
#'   document_id = "3619",
#'   cache_dir = tempdir()
#' )
cache_path <- function(url, country, document_id, cache_dir = cache_dir_default()) {
  cache_path_internal(url, country, document_id, root = cache_dir)
}

#' Locate the on-disk file for a (possibly placeholder) cache path.
#'
#' [cache_path()] returns a `.x` placeholder path for URLs whose path carries
#' no file extension; the real file may have been renamed to e.g. `.pdf` after
#' its body was fetched and its type sniffed. Given the path [cache_path()]
#' returned, this resolves the actual file on disk:
#'
#' * the path itself when a non-empty file already exists there;
#' * the single finalized sibling (same stem, real extension) when exactly one
#'   exists for a `.x` placeholder;
#' * `NA_character_` when nothing is cached yet (so the caller knows to
#'   download) or when the match is ambiguous.
#'
#' @param dest A path as returned by [cache_path()].
#' @return The resolved absolute path, or `NA_character_`.
#' @seealso [cache_path()], [download_to_cache()]
#' @export
#' @examples
#' \dontrun{
#' dest <- cache_path(url, "ee", "KMH-44")
#' resolve_cached_path(dest)
#' }
resolve_cached_path <- function(dest) {
  resolve_cached_path_internal(dest)
}

#' Download one attachment URL into the planscanR cache.
#'
#' Fetches a single URL into the planscanR cache, behaving exactly as
#' planscanR's own downloader does. In order, it:
#'
#' * resolves the destination path with [cache_path()];
#' * runs a cheap HEAD probe and skips the URL if its advertised
#'   `Content-Length` already exceeds the cap, so an over-size file is never
#'   transferred;
#' * downloads through the shared throttled, retrying httr2 client;
#' * re-checks the size cap after downloading and discards an over-cap file;
#' * finalizes the file extension (a URL with no extension lands at a `.x`
#'   placeholder, renamed from the response `Content-Type` or magic bytes);
#' * computes the SHA-256 of the result.
#'
#' This is the public, single-URL counterpart to planscanR's internal batch
#' downloader; it is intended for downstream callers (e.g. mirroring to
#' external storage) that need one file in the canonical cache location with a
#' structured result.
#'
#' @param url Source URL (character scalar).
#' @param country ISO-2 country code.
#' @param document_id Portal-native document ID.
#' @param cache_dir Cache root. Defaults to [cache_dir_default()].
#' @param max_file_size_mb Per-file size ceiling in MiB. Defaults to
#'   `getOption("planscanR.max_file_size_mb", 50)`. `Inf`, `NULL`, or a
#'   non-positive value means no cap.
#' @param overwrite If `FALSE` (default) and a non-empty file is already
#'   cached, it is returned as-is with status `"exists"`. If `TRUE`, any
#'   pre-existing copy (placeholder or finalized) is swept and the URL is
#'   re-fetched.
#' @return A one-row tibble with columns:
#'   `url`, `local_path` (`NA` when skipped/failed), `size_bytes`, `sha256`
#'   (`NA` when no local file), `status`, `reason`. `status` is one of
#'   `"downloaded"`, `"exists"`, `"skipped_size"`, or `"failed"`.
#' @seealso [cache_path()], [resolve_cached_path()]
#' @export
#' @examples
#' \dontrun{
#' download_to_cache(
#'   "https://pas.commissiemer.nl/files/nl/3619/a3619ts.pdf",
#'   country = "nl",
#'   document_id = "3619"
#' )
#' }
download_to_cache <- function(
  url,
  country,
  document_id,
  cache_dir = cache_dir_default(),
  max_file_size_mb = getOption("planscanR.max_file_size_mb", 50),
  overwrite = FALSE
) {
  if (!is.character(url) || length(url) != 1L || is.na(url) || !nzchar(url)) {
    cli::cli_abort(
      "{.arg url} must be a single non-empty string.",
      class = "planscanR_error_bad_input"
    )
  }
  cap <- max_file_size_bytes(max_file_size_mb)
  dest <- cache_path_internal(url, country, document_id, root = cache_dir)

  cached <- resolve_cached_path_internal(dest)
  if (!is.na(cached) && !overwrite) {
    return(download_to_cache_row(
      url,
      local_path = cached,
      size_bytes = unname(file.info(cached)$size),
      sha256 = file_sha256(cached),
      status = "exists"
    ))
  }
  if (overwrite) {
    stem <- tools::file_path_sans_ext(dest)
    for (p in Sys.glob(paste0(stem, ".*"))) {
      unlink(p, force = TRUE)
    }
  }

  announced <- head_content_length(url)
  if (!is.na(announced) && announced > cap) {
    return(download_to_cache_row(
      url,
      local_path = NA_character_,
      size_bytes = announced,
      sha256 = NA_character_,
      status = "skipped_size",
      reason = sprintf("HEAD Content-Length %s exceeds cap %s", format(announced), format(cap))
    ))
  }

  tryCatch(
    {
      req <- req_planscanr(url_encode_safe(url))
      resp <- httr2::req_perform(req, path = dest)
      size <- unname(file.info(dest)$size)
      if (!is.na(size) && size > cap) {
        unlink(dest, force = TRUE)
        return(download_to_cache_row(
          url,
          local_path = NA_character_,
          size_bytes = size,
          sha256 = NA_character_,
          status = "skipped_size",
          reason = sprintf("downloaded size %s exceeds cap %s", format(size), format(cap))
        ))
      }
      ct <- tryCatch(httr2::resp_header(resp, "Content-Type"), error = function(e) NULL)
      final_dest <- finalize_extension(dest, ct)
      download_to_cache_row(
        url,
        local_path = final_dest,
        size_bytes = unname(file.info(final_dest)$size),
        sha256 = file_sha256(final_dest),
        status = "downloaded"
      )
    },
    error = function(e) {
      if (file.exists(dest) && file.info(dest)$size == 0L) {
        unlink(dest, force = TRUE)
      }
      download_to_cache_row(
        url,
        local_path = NA_character_,
        size_bytes = NA_real_,
        sha256 = NA_character_,
        status = "failed",
        reason = conditionMessage(e)
      )
    }
  )
}

#' One-row result tibble for [download_to_cache()].
#' @noRd
download_to_cache_row <- function(url, local_path, size_bytes, sha256, status, reason = NA_character_) {
  tibble::tibble(
    url = url,
    local_path = local_path,
    size_bytes = as.numeric(size_bytes),
    sha256 = sha256,
    status = status,
    reason = reason
  )
}
