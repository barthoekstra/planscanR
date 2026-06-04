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
#' @param session A session from [browser_open()].
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
  )$result$value %||% ""
}
