test_that("get_assessments_coverage returns expected shape", {
  c <- get_assessments_coverage()
  expect_s3_class(c, "tbl_df")
  expect_true(all(c("country", "source_portal", "base_url", "requires_auth", "status", "facets") %in% names(c)))
  expect_true("nl" %in% c$country)
})

test_that("NL coverage row exposes the facet vocabularies", {
  c <- get_assessments_coverage()
  nl <- c[c$country == "nl", ]
  expect_identical(nl$source_portal, "commissiemer.nl")
  expect_false(nl$requires_auth)
  expect_identical(nl$status, "supported")
  f <- nl$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("advice_type", "status", "province", "theme"))
  expect_true("energie" %in% f$theme)
  expect_true("windenergie" %in% f$theme)
  expect_true("afgerond" %in% f$status)
  expect_true("toetsing" %in% f$advice_type)
})

test_that("DE coverage row exposes the procedure / bundesland vocabularies", {
  c <- get_assessments_coverage()
  de <- c[c$country == "de", ]
  expect_identical(de$source_portal, "uvp-verbund.de")
  expect_false(de$requires_auth)
  expect_identical(de$status, "supported")
  f <- de$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("procedure", "bundesland"))
  expect_true("Bayern" %in% f$bundesland)
  expect_true("Baden-Württemberg" %in% f$bundesland)
  expect_true("obj_class_zv" %in% f$procedure)
})

test_that("FR coverage row exposes the theme / status / native_type vocabularies", {
  c <- get_assessments_coverage()
  fr <- c[c$country == "fr", ]
  expect_identical(fr$source_portal, "projets-environnement.gouv.fr")
  expect_false(fr$requires_auth)
  expect_identical(fr$status, "supported")
  f <- fr$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("theme", "status", "native_type"))
  expect_true("ÉNERGIE" %in% f$theme)
  expect_true("ENVIRONNEMENT" %in% f$theme)
  expect_true("ouvert" %in% f$status)
  expect_true("clos" %in% f$status)
  expect_true("AENV" %in% f$native_type)
})

test_that("BE coverage row exposes the dossier-type vocabulary", {
  c <- get_assessments_coverage()
  be <- c[c$country == "be", ]
  expect_identical(be$source_portal, "omgeving.vlaanderen.be/merregister")
  expect_false(be$requires_auth)
  expect_identical(be$status, "supported")
  f <- be$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("dossier_type"))
  expect_true("PROJECT_MER" %in% f$dossier_type)
  expect_true("VERZOEK_TOT_ONTHEFFING" %in% f$dossier_type)
})

test_that("EE coverage row exposes the KOTKAS facet vocabularies", {
  c <- get_assessments_coverage()
  ee <- c[c$country == "ee", ]
  expect_identical(ee$source_portal, "kotkas.envir.ee")
  expect_false(ee$requires_auth)
  expect_identical(ee$status, "supported")
  f <- ee$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(
    names(f),
    c("assessment_type", "proceeding_status", "activity_area", "activity", "ksh_type")
  )
  expect_true("EIA" %in% f$assessment_type)
  expect_true("SEA" %in% f$assessment_type)
  expect_true("ONGOING" %in% f$proceeding_status)
  expect_true("Harju maakond" %in% f$activity_area)
  expect_true("Energeetika ja energiakandjate tootmine" %in% f$activity)
  expect_true("Detailplaneering" %in% f$ksh_type)
})

test_that("BG coverage row exposes the assessment_type vocabulary", {
  c <- get_assessments_coverage()
  bg <- c[c$country == "bg", ]
  expect_identical(bg$source_portal, "registers.moew.government.bg")
  expect_false(bg$requires_auth)
  expect_identical(bg$status, "supported")
  f <- bg$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("assessment_type"))
  expect_true("All" %in% f$assessment_type)
  expect_true("EIA" %in% f$assessment_type)
  expect_true("SEA" %in% f$assessment_type)
})

test_that("CZ coverage row exposes the assessment_type vocabulary", {
  c <- get_assessments_coverage()
  cz <- c[c$country == "cz", ]
  expect_identical(cz$source_portal, "portal.cenia.cz")
  expect_false(cz$requires_auth)
  expect_identical(cz$status, "supported")
  f <- cz$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("assessment_type", "register_view"))
  expect_true("All" %in% f$assessment_type)
  expect_true("EIA" %in% f$assessment_type)
  expect_true("SEA" %in% f$assessment_type)
  # Domestic-only register codes are documented; the cross-border ones are not.
  expect_true("eia100_cr" %in% f$register_view)
  expect_true("SEA100_koncepce" %in% f$register_view)
})

test_that("HR coverage row exposes the assessment_type vocabulary", {
  c <- get_assessments_coverage()
  hr <- c[c$country == "hr", ]
  expect_identical(hr$source_portal, "mzozt.gov.hr")
  expect_false(hr$requires_auth)
  expect_identical(hr$status, "supported")
  f <- hr$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("assessment_type", "register"))
  expect_true("All" %in% f$assessment_type)
  expect_true("EIA" %in% f$assessment_type)
  expect_true("SEA" %in% f$assessment_type)
  # PUO/SPUO register codes are documented.
  expect_true("PUO" %in% f$register)
  expect_true("SPUO" %in% f$register)
})

test_that("GR coverage row signals decisions-only status and exposes the type vocabulary", {
  c <- get_assessments_coverage()
  gr <- c[c$country == "gr", ]
  expect_identical(gr$source_portal, "eprm.ypen.gr")
  expect_false(gr$requires_auth)
  expect_identical(
    gr$status,
    "supported (decisions-only; studies/SEA login-gated)"
  )
  f <- gr$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("type"))
  expect_true("aepo_creation" %in% f$type)
  expect_true("aepo_renewal" %in% f$type)
  expect_true("pppa_creation" %in% f$type)
})

test_that("IS coverage row signals the GraphQL backend + coverage horizon and exposes the assessment_type vocabulary", {
  c <- get_assessments_coverage()
  is <- c[c$country == "is", ]
  expect_identical(is$source_portal, "skipulagsgatt.is")
  expect_false(is$requires_auth)
  expect_identical(
    is$status,
    "supported (GraphQL; cases from ~June 2023 onward)"
  )
  f <- is$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("assessment_type", "process_type"))
  expect_true("All" %in% f$assessment_type)
  expect_true("EIA" %in% f$assessment_type)
  expect_true("SEA" %in% f$assessment_type)
  # The three environmental-assessment process types are documented.
  expect_true("MAT_A_UMHVERFISAHRIFUM" %in% f$process_type)
  expect_true("UMHVERFISMAT_AETLANA" %in% f$process_type)
})

test_that("AT coverage row signals metadata-only status and exposes typology", {
  c <- get_assessments_coverage()
  at <- c[c$country == "at", ]
  expect_identical(at$source_portal, "umweltbundesamt.at/uvpdb")
  expect_false(at$requires_auth)
  expect_identical(at$status, "supported (metadata-only)")
  f <- at$facets[[1]]
  expect_true(is.list(f))
  expect_setequal(names(f), c("bundesland", "type", "type_group"))
  expect_true("Wien" %in% f$bundesland)
  expect_true("Burgenland" %in% f$bundesland)
  expect_true("Windkraftanlagen" %in% f$type)
  expect_true("Energie" %in% f$type_group)
})
