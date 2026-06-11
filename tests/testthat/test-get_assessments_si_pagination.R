# Regression tests for issue #17: SI CPVO (SEA) registers have no per-record
# detail page — every record is a row in a paginated listing TABLE, and the
# download links live in that row's "Datoteka" cell. The old code followed the
# 302 redirect to listing page 1 and stapled page-1's links onto every record.
#
# These tests prove the fix: records are joined to their own listing-table row
# (by normalised title, with a prefix fallback for listing-side truncation),
# ALL pages are crawled, both /assets/seznami/ and /assets/ministrstva/ links
# are captured, and a record with no confident match gets EMPTY attachments
# (never another row's files). Sidecars are kept up to date even at
# download = FALSE.

si_fix <- function(name) rvest::read_html(fixture_path("si", name))
si_export <- jsonlite::fromJSON(
  fixture_path("si", "cpvo_obcinski_export.json"),
  simplifyVector = FALSE
)

si_obcinski_entry <- function(i) {
  raw <- si_export[[i]]
  list(
    register = "cpvo-obcinski",
    url_segment = raw$URLSegment,
    url = planscanR:::si_canonical_url("cpvo-obcinski", raw$URLSegment),
    raw = raw
  )
}

# Build the listing-index rows the real crawler would produce from the two
# fixture pages (parser exercised for real; only the page fetch is stubbed).
si_obcinski_index_rows <- function() {
  c(
    planscanR:::si_parse_listing_table(si_fix("cpvo_obcinski_page1.html")),
    planscanR:::si_parse_listing_table(si_fix("cpvo_obcinski_page2.html"))
  )
}

# ---------------------------------------------------------------------------
# si_normalise_title
# ---------------------------------------------------------------------------
test_that("si_normalise_title case-folds, de-nbsp's, and collapses whitespace", {
  expect_identical(
    planscanR:::si_normalise_title("OBČINSKI  PROSTORSKI NAČRT "),
    "občinski prostorski načrt"
  )
  expect_identical(
    planscanR:::si_normalise_title("Občinski prostorski načrt"),
    planscanR:::si_normalise_title("OBČINSKI PROSTORSKI NAČRT")
  )
  expect_true(is.na(planscanR:::si_normalise_title(NULL)))
  expect_true(is.na(planscanR:::si_normalise_title(NA_character_)))
})

# ---------------------------------------------------------------------------
# si_parse_listing_table — header-mapped, row-scoped attachment capture
# ---------------------------------------------------------------------------
test_that("si_parse_listing_table reads rows and captures both asset prefixes", {
  rows <- planscanR:::si_parse_listing_table(si_fix("cpvo_obcinski_page1.html"))
  expect_length(rows, 2L)

  alfa <- rows[[1]]
  expect_identical(alfa$title_norm, "občinski prostorski načrt občine alfa")
  expect_identical(alfa$datum, as.Date("2026-01-10"))
  # Row-scoped: BOTH /assets/seznami/ and /assets/ministrstva/, absolutised,
  # in document order.
  expect_identical(
    alfa$attachment_urls,
    c(
      "https://www.gov.si/assets/seznami/alfa/AlfaOdlocba.pdf",
      "https://www.gov.si/assets/ministrstva/MOPE/Okolje/alfa/AlfaOdlocba.docx"
    )
  )

  beta <- rows[[2]]
  expect_identical(
    beta$attachment_urls,
    "https://www.gov.si/assets/seznami/beta/BetaOdlocba.pdf"
  )
})

test_that("si_parse_listing_table maps columns by header, not fixed index", {
  # drzavni listing has NO "Občina" column, so "Datoteka" is the 3rd column.
  rows <- planscanR:::si_parse_listing_table(si_fix("cpvo_drzavni_page1.html"))
  expect_length(rows, 1L)
  expect_identical(
    rows[[1]]$attachment_urls,
    "https://www.gov.si/assets/seznami/drz/DrzOdlocba.pdf"
  )
})

# ---------------------------------------------------------------------------
# si_lookup_cpvo_attachments — join tiers
# ---------------------------------------------------------------------------
test_that("si_lookup_cpvo_attachments joins exact, prefix, and refuses fuzzy", {
  rows <- si_obcinski_index_rows()

  # Exact (case-folded) join.
  expect_identical(
    planscanR:::si_lookup_cpvo_attachments(
      rows,
      "Občinski prostorski načrt Občine Alfa",
      as.Date("2026-01-10")
    ),
    c(
      "https://www.gov.si/assets/seznami/alfa/AlfaOdlocba.pdf",
      "https://www.gov.si/assets/ministrstva/MOPE/Okolje/alfa/AlfaOdlocba.docx"
    )
  )

  # Listing-side truncation -> the full JSON title is matched by prefix.
  beta_full <- si_export[[2]]$Title
  expect_identical(
    planscanR:::si_lookup_cpvo_attachments(rows, beta_full, as.Date("2026-01-11")),
    "https://www.gov.si/assets/seznami/beta/BetaOdlocba.pdf"
  )

  # Abbreviated listing title ("OPN Delta") is NOT a confident match for the
  # full record -> NULL (caller leaves attachments empty), never DeltaWrong.pdf.
  expect_null(
    planscanR:::si_lookup_cpvo_attachments(
      rows,
      "Občinski prostorski načrt Občine Delta",
      as.Date("2026-01-13")
    )
  )
})

# ---------------------------------------------------------------------------
# si_build_cpvo_listing_index — crawls EVERY page, stops cleanly
# ---------------------------------------------------------------------------
test_that("si_build_cpvo_listing_index crawls all pages and stops at the end", {
  pages <- list(
    `0` = si_fix("cpvo_obcinski_page1.html"),
    `10` = si_fix("cpvo_obcinski_page2.html")
  )
  local_mocked_bindings(
    si_fetch_listing_page = function(base_url, start) {
      pages[[as.character(start)]] # NULL for start >= 20 -> crawl stops
    }
  )
  rows <- planscanR:::si_build_cpvo_listing_index("cpvo-obcinski")
  expect_length(rows, 4L) # 2 from page 1 + 2 from page 2
  expect_identical(
    vapply(rows, function(r) r$title_norm, character(1))[c(1, 3)],
    c("občinski prostorski načrt občine alfa", "tretje spremembe opn mestne občine gama")
  )
})

# ---------------------------------------------------------------------------
# End-to-end: the actual issue #17 regression
# ---------------------------------------------------------------------------
test_that("get_assessments_si(SEA) gives each record its OWN paginated attachments", {
  # Read fixtures BEFORE with_tempdir() changes the working directory (the
  # mocks below run inside it, where relative fixture paths no longer resolve).
  obcinski_entries <- lapply(seq_along(si_export), si_obcinski_entry)
  index_rows <- si_obcinski_index_rows()

  withr::with_tempdir({
    cache <- file.path(getwd(), "cache")
    options(planscanR.cache_dir = cache)
    on.exit(options(planscanR.cache_dir = NULL), add = TRUE)

    local_mocked_bindings(
      si_fetch_search = function(register) {
        emitted <- FALSE
        function() {
          if (emitted) {
            return(NULL)
          }
          emitted <<- TRUE
          if (register == "cpvo-obcinski") obcinski_entries else list()
        }
      },
      si_build_cpvo_listing_index = function(register) {
        if (register == "cpvo-obcinski") index_rows else list()
      }
    )

    res <- suppressWarnings(
      get_assessments_si(assessment_type = "SEA", limit = Inf, download = FALSE)
    )
    expect_identical(nrow(res), 4L)

    att_of <- function(segment) {
      row <- res[grepl(segment, res$url, fixed = TRUE), ]
      row$attachment_urls[[1]]
    }

    # Alfa: case-folded exact join + BOTH asset prefixes.
    expect_setequal(
      att_of("obcinski-prostorski-nacrt-obcine-alfa"),
      c(
        "https://www.gov.si/assets/seznami/alfa/AlfaOdlocba.pdf",
        "https://www.gov.si/assets/ministrstva/MOPE/Okolje/alfa/AlfaOdlocba.docx"
      )
    )
    # Beta: prefix (truncation) join.
    expect_identical(
      att_of("sd-opn-beta"),
      "https://www.gov.si/assets/seznami/beta/BetaOdlocba.pdf"
    )
    # Gama: lived on listing PAGE 2 -> its OWN attachments, not page 1's.
    expect_identical(
      att_of("opn-gama"),
      "https://www.gov.si/assets/seznami/gama/GamaOdlocba.pdf"
    )
    # Delta: abbreviated listing title -> EMPTY, never another row's file.
    expect_identical(att_of("opn-delta"), character(0))

    # Hard guarantee against the original bug: NO record is mis-attributed
    # another row's files (esp. the abbreviated DeltaWrong.pdf).
    all_urls <- unlist(res$attachment_urls)
    expect_false(any(grepl("DeltaWrong", all_urls)))
    expect_identical(sum(grepl("AlfaOdlocba", all_urls)), 2L)
    expect_identical(sum(grepl("GamaOdlocba", all_urls)), 1L)

    # Sidecars are kept up to date even though we did NOT download: the URLs
    # are persisted, but no PDF/DOCX lands on disk.
    expect_length(
      list.files(
        file.path(cache, "files", "si"),
        pattern = "\\.(pdf|docx)$",
        recursive = TRUE
      ),
      0L
    )
    sidecars <- list.files(
      file.path(cache, "files", "si"),
      pattern = "\\.meta\\.json$",
      recursive = TRUE,
      full.names = TRUE
    )
    expect_identical(length(sidecars), 4L)
    sc_text <- paste(
      vapply(sidecars, function(f) paste(readLines(f, warn = FALSE), collapse = " "), character(1)),
      collapse = " "
    )
    expect_true(grepl("AlfaOdlocba.pdf", sc_text, fixed = TRUE))
    expect_true(grepl("AlfaOdlocba.docx", sc_text, fixed = TRUE))
    expect_false(grepl("DeltaWrong", sc_text, fixed = TRUE))
  })
})
