# Offline tests for get_assessments_lu(): fixtures captured from
# enquetes.public.lu (search-results JSON items for cases 820, 889, 5010, 3904
# (an item without a `page` object) and 6198; detail pages 820, 889, 5010,
# 6198 trimmed of svg/script; 3904 is a minimal hand-made detail page).
# Network seams: lu_fetch_home(), lu_fetch_page(), lu_fetch_detail().

lu_html <- function(name) xml2::read_html(fixture_path("lu", name), encoding = "UTF-8")
lu_json <- function(name) jsonlite::read_json(fixture_path("lu", name))
lu_pages <- function() lapply(sprintf("list_p%d.json", 1:4), lu_json)
lu_mock <- function(
  pages = lu_pages(),
  detail = function(url) {
    id <- sub(".*/([0-9]+)\\.html$", "\\1", url)
    lu_html(sprintf("detail_%s.html", id))
  },
  env = parent.frame()
) {
  calls <- new.env()
  calls$pages <- integer()
  calls$themes <- character()
  calls$details <- character()
  testthat::local_mocked_bindings(
    lu_fetch_home = function() lu_html("home.html"),
    lu_fetch_page = function(id, page, theme = NULL) {
      calls$pages <- c(calls$pages, page)
      calls$themes <- c(calls$themes, theme %||% NA_character_)
      p <- pages[[page]]
      if (is.function(p)) p() else p
    },
    lu_fetch_detail = function(url) {
      calls$details <- c(calls$details, url)
      detail(url)
    },
    .env = env
  )
  calls
}
lu_items <- function() unlist(lapply(lu_pages(), function(p) p$search$items), recursive = FALSE)

test_that("listing items keep ids and urls even when the item has no `page` object", {
  it <- lu_items()
  e <- lapply(it, planscanR:::lu_parse_item)
  expect_identical(vapply(e, `[[`, "", "id"), c("820", "889", "5010", "3904", "6198"))
  expect_identical(e[[1]]$url, "https://enquetes.public.lu/fr/enquetes/800/820.html")
  expect_identical(e[[4]]$url, "https://enquetes.public.lu/fr/enquetes/3900/3904.html")
  expect_identical(e[[1]]$theme, "environement")
  expect_identical(e[[1]]$open_date, as.Date("2022-01-22"))
  expect_match(e[[1]]$listing_json, "hitMetaData", fixed = TRUE)
  expect_null(planscanR:::lu_parse_item(list(hitMetaData = list(page_title = "no link"))))
})

test_that("detail parser keeps every file entry, native labels and native grouping", {
  e <- planscanR:::lu_parse_item(lu_items()[[1]])
  rec <- planscanR:::lu_build_record(e, lu_html("detail_820.html"))
  expect_identical(rec$document_id, "lu_820")
  expect_identical(rec$country, "lu")
  expect_identical(rec$native_id, "820")
  expect_match(rec$title, "Dippach-Gare")
  expect_identical(rec$date_published, as.Date("2022-01-22"))
  expect_identical(rec$date_close, as.Date("2022-02-25"))
  expect_identical(rec$theme, "environement")
  expect_identical(rec$survey_type, "Enquête publique")
  expect_length(rec$attachment_urls[[1]], 13L) # 12 files + "Tout telecharger"
  expect_length(rec$attachment_urls_fichiers[[1]], 12L)
  expect_length(rec$attachment_urls_tout_telecharger[[1]], 1L)
  expect_true(any(grepl("Rapport_EIE.*\\.pdf$", rec$attachment_urls_fichiers[[1]])))
  expect_match(rec$attachment_labels_native, "I_-_Rapport_EIE_-_Contournement_Dippach-Gare.pdf (Pdf)", fixed = TRUE)
  expect_match(rec$attachment_labels_native, "Tout télécharger", fixed = TRUE)
  expect_match(rec$competent_authority, "^Minist\u00e8re de la Mobilit\u00e9")
  expect_identical(rec$jurisdiction, "Dippach, Reckange-sur-Mess")
  expect_true(is.na(rec$proponent))
  secs <- jsonlite::fromJSON(rec$detail_sections)
  expect_true(all(c("Cadre réglementaire", "Avis officiels") %in% names(secs)))
})

test_that("authority, procedure type, related links and multiple files parse for 889", {
  e <- planscanR:::lu_parse_item(lu_items()[[2]])
  rec <- planscanR:::lu_build_record(e, lu_html("detail_889.html"))
  expect_match(rec$competent_authority, "Commune de Hesperange; Ministère de la Mobilité", fixed = TRUE)
  expect_match(rec$procedure_type, "^Évaluation des incidences")
  expect_match(rec$municipalities_concerned, "Hesperange", fixed = TRUE)
  expect_match(rec$neighbouring_municipalities, "Roeser", fixed = TRUE)
  expect_match(rec$related_links, "/fr/avis/800/889_Avis812.html", fixed = TRUE)
  expect_length(rec$attachment_urls_fichiers[[1]], 17L)
})

test_that("a link in the description (7z dossier, abandoned case) is kept as its own group", {
  e <- planscanR:::lu_parse_item(lu_items()[[5]])
  rec <- planscanR:::lu_build_record(e, lu_html("detail_6198.html"))
  expect_identical(rec$reference_number, "97327")
  expect_match(rec$status_native, "Abandonn")
  expect_identical(
    rec$attachment_urls_description[[1]],
    "https://environnement-download.public.lu/EIE/2021/97327/Enquete/Dossier_enquete.7z"
  )
  expect_match(rec$attachment_labels_native, "Télécharger le dossier", fixed = TRUE)
})

test_that("a detail page without the expected structure is an error, a page without files is fine", {
  e <- planscanR:::lu_parse_item(lu_items()[[1]])
  expect_error(planscanR:::lu_build_record(e, lu_html("detail_error.html")), "unexpected")
  wrong <- planscanR:::lu_parse_item(lu_items()[[2]]) # page for 889 served for 820
  expect_error(planscanR:::lu_build_record(wrong, lu_html("detail_820.html")), "unexpected")
  rec <- planscanR:::lu_build_record(planscanR:::lu_parse_item(lu_items()[[4]]), lu_html("detail_3904.html"))
  expect_length(rec$attachment_urls[[1]], 0L)
  expect_identical(rec$reference_number, "96838")
  expect_false("attachment_urls_fichiers" %in% names(rec))
})

test_that("pagination: multi-page crawl, empty-page termination, sidecars, warm rerun", {
  with_temp_cache({
    calls <- lu_mock()
    res <- get_assessments_lu(download = FALSE)
    expect_identical(nrow(res), 5L)
    expect_true(all(grepl("^lu_[0-9]+$", res$document_id)))
    planscanR:::validate_result_schema(res)
    expect_identical(calls$pages, 1:3) # total reached after page 3
    expect_length(calls$details, 5L)

    back <- index_cache(country = "lu")
    expect_identical(nrow(back), 5L)
    expect_true(all(
      c("native_id", "theme", "listing_json", "detail_sections", "attachment_urls_fichiers", "date_close") %in%
        names(back)
    ))
    expect_length(back$attachment_urls_fichiers[back$document_id == "lu_820"][[1]], 12L)

    calls$details <- character()
    again <- get_assessments_lu(download = FALSE)
    expect_length(calls$details, 0L)
    expect_identical(sort(again$document_id), sort(res$document_id))
  })
})

test_that("an empty page ends the crawl; total is not required to be reached silently", {
  with_temp_cache({
    p <- lu_pages()
    p[[3]] <- p[[4]] # page 3 empty although total says 5
    lu_mock(pages = p)
    expect_warning(res <- get_assessments_lu(write_sidecar = FALSE), class = "planscanR_warning_partial")
    expect_identical(nrow(res), 4L)
  })
})

test_that("a repeated page and duplicate ids are deduped and flagged", {
  with_temp_cache({
    p <- lu_pages()
    p[[2]] <- p[[1]]
    p[[3]] <- p[[1]]
    lu_mock(pages = p)
    expect_warning(res <- get_assessments_lu(write_sidecar = FALSE), class = "planscanR_warning_partial")
    expect_identical(sort(res$document_id), c("lu_820", "lu_889"))
  })
})

test_that("a failed later page warns and the crawl continues; a short page warns", {
  with_temp_cache({
    p <- lu_pages()
    p[[2]] <- function() stop("HTTP 500")
    lu_mock(pages = p)
    expect_warning(res <- get_assessments_lu(write_sidecar = FALSE), class = "planscanR_warning_partial")
    expect_identical(sort(res$document_id), c("lu_6198", "lu_820", "lu_889"))
  })
  with_temp_cache({
    p <- lu_pages()
    p[[2]]$search$items <- p[[2]]$search$items[1] # short page (1 of 2)
    lu_mock(pages = p)
    expect_warning(res <- get_assessments_lu(write_sidecar = FALSE), class = "planscanR_warning_partial")
    expect_identical(nrow(res), 4L)
  })
})

test_that("malformed envelope or failed first page is an error, never an empty success", {
  with_temp_cache({
    p <- lu_pages()
    p[[1]] <- list(unexpected = TRUE)
    lu_mock(pages = p)
    expect_error(get_assessments_lu(), "malformed|unexpected", ignore.case = TRUE)
  })
  with_temp_cache({
    p <- lu_pages()
    p[[1]] <- function() stop("HTTP 503")
    lu_mock(pages = p)
    expect_error(get_assessments_lu(), "503")
  })
  with_temp_cache({
    p <- lu_pages()
    p[[1]]$search$items <- list() # total says 5 but nothing returned
    lu_mock(pages = p)
    expect_error(get_assessments_lu(), "none|no items", ignore.case = TRUE)
  })
  with_temp_cache({
    testthat::local_mocked_bindings(lu_fetch_home = function() xml2::read_html("<html><body></body></html>"))
    expect_error(get_assessments_lu(), "data-id")
  })
})

test_that("a genuinely empty portal result is a typed empty tibble", {
  with_temp_cache({
    p <- lu_pages()
    p[[1]] <- list(itemsPerPage = 21L, search = list(items = list(), totalMatches = 0L))
    lu_mock(pages = p)
    res <- get_assessments_lu()
    expect_identical(nrow(res), 0L)
    expect_identical(names(res), names(planscanR:::empty_result_tibble()))
  })
})

test_that("a failed or unexpected detail page keeps a listing-only record and is retried, not cached", {
  with_temp_cache({
    bad <- TRUE
    calls <- lu_mock(detail = function(url) {
      id <- sub(".*/([0-9]+)\\.html$", "\\1", url)
      if (bad && id == "889") {
        stop("HTTP 404")
      }
      if (bad && id == "5010") {
        return(lu_html("detail_error.html"))
      }
      lu_html(sprintf("detail_%s.html", id))
    })
    expect_warning(
      expect_warning(res <- get_assessments_lu(), "listing metadata only", class = "planscanR_warning_partial"),
      "listing metadata only",
      class = "planscanR_warning_partial"
    )
    expect_identical(nrow(res), 5L)
    expect_identical(
      res$detail_fetched[match(c("lu_889", "lu_5010", "lu_820"), res$document_id)],
      c(FALSE, FALSE, TRUE)
    )
    lo <- res[res$document_id == "lu_889", ]
    expect_length(lo$attachment_urls[[1]], 0L)
    expect_match(lo$title, "Alzingen")
    expect_identical(lo$theme, "environement")
    expect_identical(lo$date_published, planscanR:::lu_parse_item(lu_items()[[2]])$open_date)
    expect_match(lo$listing_json, "hitMetaData", fixed = TRUE)
    expect_false(any(c("lu_889", "lu_5010") %in% index_cache(country = "lu")$document_id))
    bad <- FALSE
    calls$details <- character()
    res2 <- get_assessments_lu()
    expect_identical(nrow(res2), 5L)
    expect_true(all(res2$detail_fetched))
    expect_identical(sort(basename(calls$details)), c("5010.html", "889.html"))
  })
})

test_that("a sidecar with detail_fetched = FALSE is a cache miss", {
  with_temp_cache({
    e <- planscanR:::lu_parse_item(lu_items()[[2]])
    rec <- planscanR:::lu_listing_record(e)
    planscanR:::write_fetched_record_sidecar(rec)
    calls <- lu_mock()
    res <- get_assessments_lu(query = "alzingen")
    expect_true(res$detail_fetched)
    expect_length(calls$details, 1L)
  })
})

test_that("proponent comes from the native Requerant line when present", {
  items <- lu_items()
  rec <- function(i, f) planscanR:::lu_build_record(planscanR:::lu_parse_item(items[[i]]), lu_html(f))
  expect_identical(rec(3, "detail_5010.html")$proponent, "LuxTram S.A.")
  expect_identical(rec(5, "detail_6198.html")$proponent, "LB Technology Google s.\u00e0 r.l.")
  expect_true(is.na(rec(1, "detail_820.html")$proponent))
})

test_that("a shifted listing (id seen twice, another missing) warns naming the duplicate", {
  with_temp_cache({
    p <- lu_pages()
    p[[2]]$search$items <- list(p[[1]]$search$items[[2]], p[[2]]$search$items[[1]]) # 889, 5010
    lu_mock(pages = p)
    expect_warning(
      res <- get_assessments_lu(write_sidecar = FALSE),
      "889",
      class = "planscanR_warning_partial"
    )
    expect_false("lu_3904" %in% res$document_id)
  })
})

test_that("theme filter: server hint, client check, positive and negative cases", {
  with_temp_cache({
    calls <- lu_mock()
    res <- get_assessments_lu(theme = "environement", write_sidecar = FALSE)
    expect_identical(nrow(res), 5L)
    expect_true(all(calls$themes == "environement"))
    # the portal ignores the hint (fixtures are all environement): the client check still decides
    none <- get_assessments_lu(theme = "gestion_eau", write_sidecar = FALSE)
    expect_identical(nrow(none), 0L)
    expect_identical(names(none), names(planscanR:::empty_result_tibble()))
    expect_error(get_assessments_lu(theme = "not-a-theme"), "theme")
  })
  with_temp_cache({
    p <- lu_pages()
    p[[2]]$search$items[[1]]$hitMetaData$theme_list <- list("tags_theme:enquetes_publiques\\etablissement")
    p[[2]]$search$items[[1]]$hitMetaData$theme <- "tags_theme:enquetes_publiques\\etablissement"
    lu_mock(pages = p)
    res <- get_assessments_lu(theme = "environement", write_sidecar = FALSE)
    expect_false("lu_5010" %in% res$document_id)
    expect_identical(nrow(res), 4L)
  })
})

test_that("query, date_range and limit filters have positive and negative cases", {
  with_temp_cache({
    lu_mock()
    expect_identical(nrow(get_assessments_lu(limit = 2, write_sidecar = FALSE)), 2L)
    a <- get_assessments_lu(query = "alzingen", write_sidecar = FALSE)
    expect_identical(a$document_id, "lu_889")
    expect_identical(nrow(get_assessments_lu(query = "zzzz-no-match", write_sidecar = FALSE)), 0L)
    d <- get_assessments_lu(date_range = c("2022-01-01", "2022-01-31"), write_sidecar = FALSE)
    expect_true("lu_820" %in% d$document_id)
    expect_false("lu_3904" %in% d$document_id)
    expect_identical(nrow(get_assessments_lu(date_range = c("2010-01-01", "2010-12-31"), write_sidecar = FALSE)), 0L)
  })
})

test_that("download = TRUE hands every URL (zip/7z included) to the shared downloader", {
  with_temp_cache({
    lu_mock()
    seen <- list()
    testthat::local_mocked_bindings(
      download_attachments = function(urls, country, document_id, overwrite, max_file_size_mb, root = NULL) {
        seen[[document_id]] <<- urls
        tibble::tibble(
          url = urls,
          local_path = file.path("files", "lu", document_id, basename(urls)),
          status = "downloaded",
          size_bytes = 1,
          sha256 = "x",
          reason = NA_character_
        )
      }
    )
    res <- get_assessments_lu(download = TRUE)
    expect_length(seen[["lu_820"]], 13L)
    expect_true(any(grepl("\\.7z$", seen[["lu_6198"]])))
    expect_length(res$local_path_fichiers[res$document_id == "lu_820"][[1]], 12L)
  })
})

test_that("relevance scoring works with the fake model", {
  with_temp_cache({
    lu_mock()
    res <- get_assessments_lu(
      write_sidecar = FALSE,
      topic = c(road = "contournement routier"),
      relevance_model = make_fake_model(languages = c("fr", "en"))
    )
    expect_identical(nrow(res), 5L)
    expect_true(is.numeric(res$relevance_score_road))
  })
})

test_that("get_assessments('lu') dispatches to the handler", {
  with_temp_cache({
    lu_mock()
    res <- get_assessments("lu", limit = 1, download = FALSE)
    expect_identical(res$country, "lu")
  })
})

test_that("get_assessments('lu') fetches a real record end-to-end", {
  skip_if_offline_tests()
  with_temp_cache({
    res <- get_assessments("lu", limit = 1, download = FALSE, theme = "environement")
    expect_identical(nrow(res), 1L)
    planscanR:::validate_result_schema(res)
    expect_match(res$document_id, "^lu_")
  })
})

test_that("an inquiry listed twice by the portal is deduped without an incompleteness warning", {
  with_temp_cache({
    p <- lu_pages()
    p[[3]]$search$items[[2]] <- p[[1]]$search$items[[1]] # 820 again; total stays 5 listed items
    lu_mock(pages = p)
    res <- expect_no_warning(get_assessments_lu(write_sidecar = FALSE))
    expect_identical(sum(res$document_id == "lu_820"), 1L)
    expect_identical(nrow(res), 5L)
  })
})

test_that("three consecutive failed result pages stop the crawl with a warning", {
  with_temp_cache({
    boom <- function() stop("HTTP 500")
    p <- lu_pages()
    p[[1]]$search$totalMatches <- 8L
    p[[2]] <- boom
    p[[3]] <- boom
    p[[4]] <- boom
    lu_mock(pages = p)
    w <- testthat::capture_warnings(res <- get_assessments_lu(write_sidecar = FALSE))
    expect_match(w, "result page 2", all = FALSE)
    expect_match(w, "3 consecutive", all = FALSE)
    expect_identical(sort(res$document_id), c("lu_820", "lu_889"))
  })
})

test_that("private-person requesters are not stored as proponent", {
  expect_identical(lu_organisation("Monsieur Kolen Rob"), NA_character_)
  expect_identical(lu_organisation("Mme Jo Person"), NA_character_)
  expect_identical(lu_organisation("LuxTram S.A."), "LuxTram S.A.")
  expect_identical(lu_organisation(NA_character_), NA_character_)
})
