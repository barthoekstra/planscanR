#' Build a planscanR HTTP request.
#'
#' Wraps every outbound call so user-agent, retry, throttle, and cache
#' behaviour stay consistent across handlers.
#'
#' @param base_url Base URL string.
#' @param path Optional path segment to append.
#' @return An `httr2_request`.
#' @noRd
req_planscanr <- function(base_url, path = NULL) {
  req <- httr2::request(base_url)
  if (!is.null(path)) {
    req <- httr2::req_url_path_append(req, path)
  }
  req <- req_user_agent_planscanr(req)
  req <- req_retry_planscanr(req)
  req <- req_throttle_planscanr(req)
  req <- httr2::req_timeout(req, getOption("planscanR.timeout", 60))
  req
}

#' Apply a politeness throttle when one is configured.
#'
#' Off by default (`getOption("planscanR.throttle_rate")` is `NULL`), so the
#' fast handlers (DE streaming crawl, AT JSON services) are unaffected. A
#' handler that talks to a rate-limiting portal sets the option for the
#' duration of its call — e.g. the NL handler caps itself at ~1 req/s because
#' commissiemer.nl 429s under a sustained burst. `httr2::req_throttle()`
#' enforces the cap with a token bucket keyed by host (`realm`), so the delay
#' only spreads requests to the throttled host.
#' @noRd
req_throttle_planscanr <- function(req) {
  rate <- getOption("planscanR.throttle_rate", NULL)
  if (is.null(rate) || !is.finite(rate) || rate <= 0) {
    return(req)
  }
  httr2::req_throttle(req, rate = rate)
}

#' @noRd
req_user_agent_planscanr <- function(req) {
  ua <- getOption("planscanR.user_agent")
  if (is.null(ua) || !nzchar(ua)) {
    ua <- sprintf(
      "planscanR/%s (https://github.com/barthoekstra/planscanR)",
      utils::packageVersion("planscanR")
    )
  }
  httr2::req_user_agent(req, ua)
}

#' @noRd
req_retry_planscanr <- function(req, max_tries = NULL) {
  if (is.null(max_tries)) {
    max_tries <- getOption("planscanR.max_tries", 5)
  }
  httr2::req_retry(
    req,
    max_tries = max_tries,
    backoff = function(i) min(60, 2^i),
    is_transient = function(resp) httr2::resp_status(resp) %in% c(429, 500, 502, 503, 504)
  )
}

#' Perform a request, parsing as JSON.
#'
#' Skips the Content-Type check because real portals (notably AT's UVP-DB
#' service handlers) serve valid JSON with the wrong MIME (`text/html`).
#' We still abort if the body isn't actually JSON-parseable.
#' @noRd
perform_json <- function(req) {
  resp <- httr2::req_perform(req)
  httr2::resp_body_json(resp, check_type = FALSE, simplifyVector = FALSE)
}

#' Perform a request, parsing as XML.
#' @noRd
perform_xml <- function(req) {
  resp <- httr2::req_perform(req)
  xml2::read_xml(httr2::resp_body_string(resp))
}

#' Perform a request, parsing as HTML.
#' @noRd
perform_html <- function(req) {
  resp <- httr2::req_perform(req)
  rvest::read_html(httr2::resp_body_string(resp))
}
