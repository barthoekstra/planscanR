# Optional headless-browser transport.
#
# A small number of portals sit behind WAFs that reject libcurl outright —
# Spain's MITECO/SABIA fingerprints the TLS ClientHello (libcurl's handshake is
# reset before any HTTP is sent), and Lithuania's portal is behind a Cloudflare
# JS challenge. Neither can be reached by `httr2`/`curl` no matter the headers.
#
# These are handled by driving a real headless Chrome through the optional
# {chromote} package (Suggests). The browser navigates to the portal origin —
# clearing the TLS/JS gate the way a real browser does — and then either returns
# the rendered HTML, or runs the portal's own `fetch()` calls *in-page* (so the
# request rides Chrome's TLS + session cookies) and hands the response back to R
# for parsing. All request logic stays in R; the browser is only a transport.
#
# The dependency is strictly optional: the other country handlers never touch
# this file, and a handler that needs it degrades gracefully (a clear, actionable
# error) when {chromote} or Chrome is absent — see `require_browser()`.

#' Resolve a Chrome/Chromium binary for the optional browser transport.
#'
#' Honours `getOption("planscanR.chrome_path")` / `CHROMOTE_CHROME`, otherwise
#' defers to chromote's own discovery. Returns `NULL` when none is found.
#' @noRd
browser_chrome_path <- function() {
  opt <- getOption("planscanR.chrome_path", Sys.getenv("CHROMOTE_CHROME", ""))
  if (nzchar(opt) && file.exists(opt)) {
    return(opt)
  }
  if (!requireNamespace("chromote", quietly = TRUE)) {
    return(NULL)
  }
  path <- tryCatch(chromote::find_chrome(), error = function(e) NULL)
  if (is.null(path) || !nzchar(path)) NULL else path
}

#' Is the optional headless-browser transport usable?
#'
#' `TRUE` only when {chromote} is installed *and* a Chrome/Chromium binary is
#' resolvable. Cheap enough to call per request; handlers gate on it.
#' @noRd
browser_available <- function() {
  requireNamespace("chromote", quietly = TRUE) && !is.null(browser_chrome_path())
}

#' Abort with actionable guidance when a browser-backed handler can't run.
#'
#' @param country ISO-2 code, used only in the message.
#' @noRd
require_browser <- function(country) {
  if (browser_available()) {
    return(invisible(TRUE))
  }
  has_chromote <- requireNamespace("chromote", quietly = TRUE)
  cli::cli_abort(
    c(
      "Country {.val {country}} requires the optional headless-browser transport.",
      i = if (!has_chromote) {
        "Install it with {.code install.packages(\"chromote\")}."
      } else {
        "Install Google Chrome / Chromium, or point {.code options(planscanR.chrome_path=)} (or {.envvar CHROMOTE_CHROME}) at a Chrome binary."
      },
      i = "Every other country works without a browser; only {.val es} and {.val lt} need it."
    ),
    class = "planscanR_error_browser_unavailable"
  )
}

#' Open a headless-browser session pinned to a portal origin.
#'
#' Navigates to `origin` and waits for the page to settle, so the WAF/JS gate is
#' cleared and any session cookies are set. Subsequent `browser_fetch()` calls on
#' the returned session are same-origin and ride the established TLS + cookies.
#'
#' @param origin URL to land on (the portal origin or its search page).
#' @param wait Seconds to wait after load (for JS challenges / late XHR).
#' @return A `chromote` `ChromoteSession`. Caller must `browser_close()` it
#'   (use `on.exit()`).
#' @noRd
browser_open <- function(origin, wait = 2) {
  require_browser("es/lt")
  chrome <- browser_chrome_path()
  withr::local_options(list(chromote.chrome = chrome))
  session <- chromote::ChromoteSession$new()
  ok <- tryCatch(
    {
      session$Page$navigate(origin, wait_ = TRUE)
      session$Page$loadEventFired(wait_ = TRUE)
      TRUE
    },
    error = function(e) FALSE
  )
  if (!ok) {
    tryCatch(session$close(), error = function(e) NULL)
    cli::cli_abort(
      "Headless browser failed to load {.url {origin}}.",
      class = "planscanR_error_browser_navigate"
    )
  }
  if (is.finite(wait) && wait > 0) {
    Sys.sleep(wait)
  }
  session
}

#' Close a browser session opened by [browser_open()].
#' @noRd
browser_close <- function(session) {
  if (!is.null(session)) {
    tryCatch(session$close(), error = function(e) NULL)
  }
  invisible(NULL)
}

#' Fetch a URL through an open browser session (in-page `fetch()`).
#'
#' Runs `fetch()` inside the page so the request uses Chrome's TLS stack and the
#' session cookies established by [browser_open()] — the only way to reach a
#' TLS-fingerprinting WAF such as MITECO. Same-origin requests only.
#'
#' @param session A session from `browser_open()`.
#' @param url Request URL (same origin as the session).
#' @param method HTTP method.
#' @param body Request body string (e.g. a urlencoded form), or `NULL`.
#' @param headers Named list of request headers.
#' @param timeout Seconds to allow the in-page fetch to resolve.
#' @return `list(status = <integer>, body = <character>)`.
#' @noRd
browser_fetch <- function(
  session,
  url,
  method = "GET",
  body = NULL,
  headers = list(),
  timeout = 60
) {
  args <- list(
    url = url,
    method = toupper(method),
    headers = if (length(headers)) headers else structure(list(), names = character(0)),
    body = body
  )
  payload <- jsonlite::toJSON(args, auto_unbox = TRUE, null = "null")
  js <- sprintf(
    "(async () => {
       const a = %s;
       const opt = { method: a.method, headers: a.headers };
       if (a.body !== null && a.method !== 'GET') opt.body = a.body;
       const r = await fetch(a.url, opt);
       const t = await r.text();
       return JSON.stringify({ status: r.status, body: t });
     })()",
    payload
  )
  res <- session$Runtime$evaluate(
    js,
    awaitPromise = TRUE,
    returnByValue = TRUE,
    timeout = timeout * 1000
  )
  raw <- res$result$value
  if (is.null(raw)) {
    cli::cli_abort(
      "In-page fetch of {.url {url}} returned nothing.",
      class = "planscanR_error_browser_fetch"
    )
  }
  parsed <- jsonlite::fromJSON(raw, simplifyVector = TRUE)
  list(status = as.integer(parsed$status), body = parsed$body %||% "")
}

#' Drive a stateful portlet by submitting its in-page `<form>`.
#'
#' Some portals (MITECO/SABIA) hold navigation state **server-side, keyed by the
#' session cookie**, and advance it via successive POSTs of the page's own
#' `<form name="formulario">` with a different `accion`. Replaying those POSTs
#' with `browser_fetch()` is brittle (the exact hidden-field set differs per
#' step), so instead we set the requested fields on the live form and submit it,
#' then wait for the new page and return its rendered HTML. All *parsing* still
#' happens in R; the browser is only the transport that keeps the cookie-backed
#' portlet state in sync.
#'
#' @param session A session from `browser_open()`.
#' @param fields Named list of `<input>`/`<select>` `name` -> value to set on the
#'   form before submitting (e.g. `list(codigo_seleccionado = "20210330",
#'   accion = "listadoDocumentacion")`).
#' @param form_id The form element id (default `"formulario"`).
#' @param wait Seconds to wait after submit for the new page to render.
#' @return The rendered HTML of the resulting page as a single string.
#' @noRd
browser_submit_form <- function(session, fields, form_id = "formulario", wait = 4) {
  payload <- jsonlite::toJSON(
    list(form = form_id, fields = fields),
    auto_unbox = TRUE,
    null = "null"
  )
  js <- sprintf(
    "(function(){
       const a = %s;
       const f = document.getElementById(a.form) ||
                 document.querySelector(\"form[name='\" + a.form + \"']\");
       if (!f) return 'NO_FORM';
       for (const k in a.fields) {
         let el = f.querySelector(\"[name='\" + k + \"']\") ||
                  document.getElementById(k);
         if (el) { el.value = a.fields[k]; }
       }
       f.submit();
       return 'OK';
     })()",
    payload
  )
  res <- session$Runtime$evaluate(js, returnByValue = TRUE)
  if (identical(res$result$value, "NO_FORM")) {
    cli::cli_abort(
      "Form {.val {form_id}} not found in the page.",
      class = "planscanR_error_browser_form"
    )
  }
  if (is.finite(wait) && wait > 0) {
    Sys.sleep(wait)
  }
  session$Runtime$evaluate(
    "document.documentElement.outerHTML",
    returnByValue = TRUE
  )$result$value %||%
    ""
}

#' Download a (TLS-walled / session-bound) file through an open browser session.
#'
#' Fetches `url` *in-page* (so it rides Chrome's TLS + the cookie-backed portlet
#' state), reads the response as an `ArrayBuffer`, base64-encodes it in the page,
#' hands it back to R, and writes the decoded bytes to `dest_path`. This is the
#' only way to pull MITECO/SABIA PDFs, whose `BINARYPORTLET resource.process`
#' URLs are valid only inside the live session that rendered them.
#'
#' @param session A session from `browser_open()`.
#' @param url The (same-origin, session-bound) file URL.
#' @param dest_path Destination path on disk.
#' @param max_bytes Optional byte cap; when the response exceeds it the file is
#'   not written and the function returns a `"skipped_size"` outcome.
#' @param timeout Seconds to allow the in-page fetch to resolve.
#' @return `list(status, content_type, size_bytes, written = <logical>,
#'   reason)`.
#' @noRd
browser_download <- function(session, url, dest_path, max_bytes = Inf, timeout = 180) {
  # CDP rides a WebSocket whose per-message size is bounded, so a multi-MB PDF
  # base64'd into one Runtime.evaluate result overflows it ("message too large").
  # Instead: fetch the bytes once and stash the base64 on `window`, return only
  # the metadata + total length, then pull the base64 back in bounded slices and
  # reassemble in R.
  args <- list(url = url)
  payload <- jsonlite::toJSON(args, auto_unbox = TRUE, null = "null")
  fetch_js <- sprintf(
    "(async () => {
       const a = %s;
       const r = await fetch(a.url);
       const ct = r.headers.get('content-type') || '';
       const ab = await r.arrayBuffer();
       const bytes = new Uint8Array(ab);
       let bin = '';
       const chunk = 0x8000;
       for (let i = 0; i < bytes.length; i += chunk) {
         bin += String.fromCharCode.apply(null, bytes.subarray(i, i + chunk));
       }
       window.__planscanr_dl = btoa(bin);
       return JSON.stringify({ status: r.status, ct: ct, len: bytes.length, b64len: window.__planscanr_dl.length });
     })()",
    payload
  )
  res <- session$Runtime$evaluate(
    fetch_js,
    awaitPromise = TRUE,
    returnByValue = TRUE,
    timeout = timeout * 1000
  )
  raw <- res$result$value
  if (is.null(raw)) {
    return(list(
      status = NA_integer_,
      content_type = NA_character_,
      size_bytes = NA_real_,
      written = FALSE,
      reason = "in-page download returned nothing"
    ))
  }
  parsed <- jsonlite::fromJSON(raw, simplifyVector = TRUE)
  size <- as.numeric(parsed$len %||% NA_real_)
  b64len <- as.numeric(parsed$b64len %||% 0)
  if (is.finite(max_bytes) && !is.na(size) && size > max_bytes) {
    session$Runtime$evaluate("delete window.__planscanr_dl;", returnByValue = TRUE)
    return(list(
      status = as.integer(parsed$status),
      content_type = parsed$ct %||% NA_character_,
      size_bytes = size,
      written = FALSE,
      reason = sprintf("downloaded size %s exceeds cap %s", format(size), format(max_bytes))
    ))
  }
  # Pull the base64 back in <=4 MB slices (well under the WebSocket cap).
  slice <- 4000000L
  b64 <- ""
  ok <- tryCatch(
    {
      pos <- 0
      while (pos < b64len) {
        part <- session$Runtime$evaluate(
          sprintf("window.__planscanr_dl.substr(%d, %d)", pos, slice),
          returnByValue = TRUE
        )$result$value %||%
          ""
        b64 <- paste0(b64, part)
        pos <- pos + slice
      }
      bytes <- jsonlite::base64_dec(b64)
      dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)
      writeBin(bytes, dest_path)
      TRUE
    },
    error = function(e) FALSE
  )
  session$Runtime$evaluate("delete window.__planscanr_dl;", returnByValue = TRUE)
  list(
    status = as.integer(parsed$status),
    content_type = parsed$ct %||% NA_character_,
    size_bytes = size,
    written = ok,
    reason = if (ok) NA_character_ else "failed to decode/write bytes"
  )
}

#' Return the fully rendered HTML of a page (after JS / challenge).
#'
#' For portals where the *page itself* is what we want (a Cloudflare-gated HTML
#' listing), not an API call: navigate, settle, and return `outerHTML`.
#'
#' @param url Page URL.
#' @param wait Seconds to wait after load (challenge solve / render).
#' @param origin Optional origin to land on first; defaults to `url`.
#' @return The rendered HTML as a single string.
#' @noRd
browser_get_html <- function(url, wait = 3, origin = NULL) {
  session <- browser_open(origin %||% url, wait = if (is.null(origin)) wait else 2)
  on.exit(browser_close(session), add = TRUE)
  if (!is.null(origin) && !identical(origin, url)) {
    res <- browser_fetch(session, url, method = "GET")
    return(res$body)
  }
  if (is.finite(wait) && wait > 0) {
    Sys.sleep(0)
  }
  session$Runtime$evaluate(
    "document.documentElement.outerHTML",
    returnByValue = TRUE
  )$result$value %||%
    ""
}
