#' List supported countries and portals.
#'
#' Returns a tibble describing every country handler currently shipped, the
#' portal it targets, and the vocabularies of the search facets it accepts.
#' This is the canonical place to discover what values can be passed to
#' search parameters like `theme`, `advice_type`, `province`, `status`.
#'
#' Each country's `facets` list mixes two kinds of vocabulary, distinguished in
#' that handler's facet documentation:
#'   * **filter facets** — valid values for a search argument the handler
#'     actually honours (e.g. `assessment_type`, `theme`, `province`).
#'   * **reference facets** — portal classifications surfaced for documentation
#'     only. They are NOT accepted as search arguments; they typically appear
#'     instead as output columns (e.g. DK `annex`, EE `assessment_subtype`,
#'     AT `type` / `type_group`, DE `procedure`).
#' Vocabularies are point-in-time snapshots (capture dates noted per country);
#' the facet/argument mapping was last reconciled on 2026-06-04.
#'
#' @return A tibble with one row per supported country, columns:
#'   `country`, `source_portal`, `base_url`, `requires_auth`, `status`,
#'   plus a list-column `facets` of named lists (filter and reference
#'   vocabularies; see Details).
#' @export
#' @examples
#' get_assessments_coverage()
get_assessments_coverage <- function() {
  tibble::tibble(
    country = c("nl", "de", "fr", "at", "dk", "be", "ee", "fi", "bg", "cz", "hr", "gr", "is", "ie", "si", "pt"),
    source_portal = c(
      "commissiemer.nl",
      "uvp-verbund.de",
      "projets-environnement.gouv.fr",
      "umweltbundesamt.at/uvpdb",
      "miljoeportal.dk/eahub",
      "omgeving.vlaanderen.be/merregister",
      "kotkas.envir.ee",
      "ymparisto.fi",
      "registers.moew.government.bg",
      "portal.cenia.cz",
      "mzozt.gov.hr",
      "eprm.ypen.gr",
      "skipulagsgatt.is",
      "services.arcgis.com (gov.ie EIA Portal)",
      "gov.si",
      "siaia.apambiente.pt"
    ),
    base_url = c(
      "https://www.commissiemer.nl",
      "https://www.uvp-verbund.de",
      "https://www.projets-environnement.gouv.fr",
      "https://secure.umweltbundesamt.at/uvpdb/public",
      "https://eahub.miljoeportal.dk",
      "https://merregister.omgeving.vlaanderen.be",
      "https://kotkas.envir.ee",
      "https://www.ymparisto.fi",
      "https://registers.moew.government.bg",
      "https://portal.cenia.cz/eiasea",
      "https://mzozt.gov.hr",
      "https://eprm.ypen.gr",
      "https://www.skipulagsgatt.is",
      "https://services.arcgis.com/NzlPQPKn5QF9v2US/arcgis/rest/services/EIA_Location_Point/FeatureServer/0",
      "https://www.gov.si/podrocja/okolje-in-prostor/okolje/okoljske-presoje",
      "https://siaia.apambiente.pt"
    ),
    requires_auth = c(
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE,
      FALSE
    ),
    status = c(
      "supported",
      "supported",
      "supported", # fr
      "supported (metadata-only)", # at
      "supported", # dk
      "supported",
      "supported",
      "supported (EIA/YVA only; no SEA in register)", # fi
      "supported", # bg
      "supported", # cz
      "supported", # hr
      "supported (decisions-only; studies/SEA login-gated)", # gr
      "supported (GraphQL; cases from ~June 2023 onward)", # is
      "supported (EIA only; portal = notice PDFs, full EIAR off-portal)", # ie
      "supported", # si
      "supported (EIA/AIA only; SEA/AAE in a separate APA register)" # pt
    ),
    facets = list(
      commissiemer_facets(),
      uvp_facets(),
      projets_environnement_fr_facets(),
      uvpdb_at_facets(),
      eahub_dk_facets(),
      merregister_be_facets(),
      kotkas_ee_facets(),
      ymparisto_fi_facets(),
      moew_bg_facets(),
      cenia_cz_facets(),
      mzozt_hr_facets(),
      eprm_gr_facets(),
      skipulagsgatt_is_facets(),
      eia_portal_ie_facets(),
      gov_si_facets(),
      siaia_pt_facets()
    )
  )
}

#' Static lookup of the SIAIA (Portugal) facet vocabularies.
#'
#' SIAIA covers the **AIA** register only (project-level EIA); the SEA/AAE
#' register lives in a separate APA application and is out of scope, so there
#' is no `assessment_type` selector. The portal offers server-side
#' authority/year filters, but the handler applies every honoured filter
#' client-side (`query` as a substring match on the title, `date_range`
#' against `date_decision` / `decision_year`). The only first-class reference
#' vocabulary worth surfacing is the *Sentido de Decisão* enum — the decision
#' sense that lands in the `decision_sense` output column (also the
#' `native_type`). Pass any other value through unchanged.
#' @noRd
siaia_pt_facets <- function() {
  list(
    decision_sense = c(
      "Favorável",
      "Favorável condicionado",
      "Desfavorável",
      "Desconformidade do EIA",
      "Encerrado"
    )
  )
}

#' Static lookup of the gov.si (Slovenia) facet vocabularies.
#'
#' Slovenia publishes its environmental-assessment registers as unfiltered
#' bulk JSON exports, so there are no server-side search filters. The only
#' first-class discriminator is the `assessment_type` selector (which
#' register(s) to crawl — the screening register for EIA, the two CPVO
#' registers for SEA, or all three). The three raw register codes are surfaced
#' here for reference (they land in the `register` output column); `date_range`
#' is matched client-side after the bulk export is fetched.
#' @noRd
gov_si_facets <- function() {
  list(
    assessment_type = c("All", "EIA", "SEA"),
    register = c(
      EIA = "predhodni-postopek",
      SEA_state = "cpvo-drzavni",
      SEA_municipal = "cpvo-obcinski"
    )
  )
}

#' Static lookup of the gov.ie EIA Portal (Ireland) facet vocabularies.
#'
#' Ireland's EIA Portal is an Esri ArcGIS REST FeatureServer covering **EIA
#' applications only** (no SEA register), and the portal hosts only the
#' statutory newspaper / public-notice PDF — the full EIAR sits off-portal on
#' the competent-authority sites (surfaced as the `url_link_application` /
#' `url_link_secondary` extras, a discovery target). The first-class
#' server-side discriminator surfaced here is `competent_authority`
#' (`Competent_Authority` equality). The portal also honours free-text (the
#' `query` argument, sent as an `UPPER(Description...) LIKE`) and an
#' application-receipt date window (`date_range`, matched against
#' `Date_of_receipt_of_application_`). The handful of authorities below are the
#' common ones for reference — pass any other `Competent_Authority` value
#' directly. Note the OBJECTID_1 gotcha: the layer's unique id field is
#' `OBJECTID_1`, not the non-unique `OBJECTID`.
#' @noRd
eia_portal_ie_facets <- function() {
  list(
    competent_authority = c(
      "An Bord Plean\u00e1la",
      "Environmental Protection Agency"
    )
  )
}

#' Static lookup of the Skipulagsgátt (Iceland) facet vocabularies.
#'
#' Skipulagsgátt's GraphQL `Issue` model carries environmental assessment in
#' three `process`es, selected server-side by `processId`. The first-class
#' discriminator surfaced here is the `assessment_type` selector (which
#' process(es) to crawl — `{15, 16}` for EIA, `501` for SEA, or all three),
#' plus the three environmental-assessment `process_type` codes for reference
#' (screening, full EIA, SEA). The portal also honours free-text (the `query`
#' argument, forwarded as the GraphQL `search` field) and a published-date
#' window (`fromDate` / `toDate`, the `date_range` argument). Note the coverage
#' horizon: only cases from roughly June 2023 onward are in the register.
#' @noRd
skipulagsgatt_is_facets <- function() {
  list(
    assessment_type = c("All", "EIA", "SEA"),
    process_type = c(
      `15` = "TILKYNNING_TIL_AKVORDUNAR_UM_MATSSKYLDU",
      `16` = "MAT_A_UMHVERFISAHRIFUM",
      `501` = "UMHVERFISMAT_AETLANA"
    )
  )
}

#' Static lookup of the EPRM (Greece) facet vocabularies.
#'
#' The public EPRM JSON:API exposes **AEPO decisions only** — the underlying
#' ΜΠΕ (EIA study) files and all ΣΜΠΕ / SEA records sit behind the gov.gr login
#' and are not fetchable here. The first-class server-side discriminator is the
#' decision `type` enum (`filter[type]`), surfaced below. The portal also
#' honours free-text (`filter[text_search]`, the `query` argument) and an issue
#' date window (`filter[issued_after]` / `filter[issued_before]`, the
#' `date_range` argument); other JSON:API filters (region, Natura 2000, ...) are
#' not first-class in v0.1.
#' @noRd
eprm_gr_facets <- function() {
  list(
    type = c(
      "aepo_creation",
      "aepo_essential_modification",
      "aepo_nonessential_modification",
      "aepo_renewal",
      "aepo_essential_modification_and_renewal",
      "aepo_nonessential_modification_and_renewal",
      "aepo_terms_review_and_revision",
      "pppa_creation"
    )
  )
}

#' Static lookup of the Flemish MER-register (Belgium) facet vocabularies.
#'
#' The DMVB API only honours two server-side filters (`nummer`, `niscode`)
#' and ignores anything else, so the only first-class vocabulary worth
#' surfacing here is the `dossierType` enum the API stamps on each row.
#' Municipality NIS codes are not enumerated — they're served live by
#' `https://dmvb.omgeving.vlaanderen.be/api/v1/locatie`.
#' @noRd
merregister_be_facets <- function() {
  list(
    dossier_type = c("PROJECT_MER", "VERZOEK_TOT_ONTHEFFING")
  )
}

#' Static lookup of the Projets-Environnement (France) facet vocabularies.
#'
#' The OpenDataSoft dataset exposes every field as a server-side ODSQL filter.
#' The first-class discriminators surfaced here are the ones the handler maps
#' to dedicated arguments: `theme` (`dc_subject_theme`), `status` (`vp_status`),
#' and `native_type` (`dc_type`). The `theme` / `status` vocabularies below are
#' the displayed single-value facets from the live `/facets` endpoint (captured
#' 2026-06-04); composite multi-value facet labels are omitted. `native_type`
#' is open-ended (free-text autorisation labels), so only the two dominant
#' codes are surfaced for reference — pass any other `dc_type` value directly.
#' @noRd
projets_environnement_fr_facets <- function() {
  list(
    theme = c(
      "ENVIRONNEMENT (dont ICPE installation class\u00e9e)",
      "ENVIRONNEMENT",
      "\u00c9NERGIE",
      "URBANISME ET CONSTRUCTION",
      "TRANSPORTS",
      "INDUSTRIE",
      "AGRICULTURE, SYLVICULTURE ET P\u00caCHE",
      "AGRO-ALIMENTAIRE",
      "PRODUCTION, TECHNOLOGIE ET RECHERCHE"
    ),
    status = c("ouvert", "clos", "non defini"),
    native_type = c(
      "AENV",
      "Autorisation au titre du code de l'environnement",
      "Permis de construire"
    )
  )
}

#' Static lookup of the ymparisto.fi (Finland) facet vocabularies.
#'
#' The Finnish register is **EIA/YVA-only** — the ymparisto.fi Elasticsearch
#' index has no SOVA/SEA content type, only `yva_project`. The single
#' first-class discriminator is therefore the `assessment_type` selector, which
#' accepts only `"All"` / `"EIA"` (both crawl the one `yva_project` register);
#' there is no `"SEA"` value. The portal also honours free-text (the `query`
#' argument, sent as an ES `match` on the `content` + `title` fields) and a
#' published-date window (`date_range`, matched against `publishTime`). The
#' `yva_project` content type is surfaced below for reference.
#' @noRd
ymparisto_fi_facets <- function() {
  list(
    assessment_type = c("All", "EIA"),
    type = c(EIA = "yva_project")
  )
}

#' Static lookup of the KOTKAS (Estonia) facet vocabularies.
#'
#' KOTKAS exposes a small set of server-side filters on its KMH / KSH
#' indexes. The values here are the discriminators we currently honour:
#' the `assessment_type` discriminator (which register to crawl — KMH for
#' EIA, KSH for SEA, or both), the procedural-status enum, the maakond
#' (county) codes that the portal accepts as `s__activity_area`, and the
#' activity-sector codes that the portal accepts as `s__activity`. The
#' detailed `initiation_activity` (Annex-I-style) sub-vocabulary is
#' available on the portal but is not enumerated here — pass the code
#' directly via `...` if needed. The `assessment_subtype` entries are a
#' **reference** vocabulary for the SEA planning-document type that lands in the
#' `assessment_subtype` output column; it is not a search argument.
#' @noRd
kotkas_ee_facets <- function() {
  list(
    assessment_type = c("All", "EIA", "SEA"),
    proceeding_status = c("INITIATED", "ONGOING", "SUSPENDED", "FINISHED"),
    activity_area = c(
      ESTONIA = "\u00dcle Eesti",
      SEA = "Meri",
      CROSSBORDER = "Piiri\u00fclene",
      `0037` = "Harju maakond",
      `0039` = "Hiiu maakond",
      `0045` = "Ida-Viru maakond",
      `0050` = "J\u00f5geva maakond",
      `0052` = "J\u00e4rva maakond",
      `0056` = "L\u00e4\u00e4ne maakond",
      `0060` = "L\u00e4\u00e4ne-Viru maakond",
      `0064` = "P\u00f5lva maakond",
      `0068` = "P\u00e4rnu maakond",
      `0071` = "Rapla maakond",
      `0074` = "Saare maakond",
      `0079` = "Tartu maakond",
      `0081` = "Valga maakond",
      `0084` = "Viljandi maakond",
      `0087` = "V\u00f5ru maakond"
    ),
    activity = c(
      `1100` = "J\u00e4\u00e4tmek\u00e4itlus",
      `1200` = "Ehitussektor",
      `1300` = "Energeetika ja energiakandjate tootmine",
      `1400` = "Info- ja kommunikatsioonitehnoloogia",
      `1500` = "Keemiat\u00f6\u00f6stus",
      `1600` = "Kiirgus",
      `1700` = "Metallide tootmine ja t\u00f6\u00f6tlemine",
      `1800` = "Mineraalsete materjalide t\u00f6\u00f6tlemine",
      `1900` = "Kaevandamine ja geoloogia",
      `2000` = "Ohtlike ainete k\u00e4itlus",
      `2100` = "Puidu, tselluloosi- ja paberit\u00f6\u00f6stus",
      `2200` = "P\u00f5llumajandus ja vesiviljelus",
      `2300` = "Toiduainet\u00f6\u00f6stus ja s\u00f6\u00f6da tootmine",
      `2400` = "Transport ja taristu",
      `2500` = "Veekasutus",
      `2600` = "Muud tegevusvaldkonnad ja muud juhud"
    ),
    assessment_subtype = c(
      `1000` = "\u00dcleriigiline planeering",
      `1100` = "Riigi eriplaneering",
      `1200` = "Maakonnaplaneering",
      `1300` = "\u00dcldplaneering",
      `1400` = "Kohaliku omavalitsuse eriplaneering",
      `1500` = "Detailplaneering",
      `1600` = "Arengukava",
      `1700` = "Strateegia",
      `1800` = "Programm",
      `1900` = "Muu"
    )
  )
}

#' Static lookup of the МОСВ registers (Bulgaria) facet vocabularies.
#'
#' The МОСВ registers (ОВОС / ЕО) expose a small set of server-side GET
#' filters. The first-class discriminator surfaced here is the
#' `assessment_type` selector (which register to crawl — ОВОС for EIA, ЕО for
#' SEA, or both). The portal also honours `projectName` (the free-text
#' `query` argument, matched against the project/plan name) and
#' `contractorNames` (proponent), plus region / authority / procedure / date
#' filters; only `assessment_type` and `query` are first-class in v0.1. Pass
#' any other server filter directly via `...` if needed (currently warned
#' about as an unknown argument).
#' @noRd
moew_bg_facets <- function() {
  list(
    assessment_type = c("All", "EIA", "SEA")
  )
}

#' Static lookup of the CENIA EIA/SEA (Czech Republic) facet vocabularies.
#'
#' The handler crawls only the two **domestic** registers and exposes the
#' `assessment_type` discriminator (which register to crawl — `eia100_cr` for
#' EIA, `SEA100_koncepce` for SEA, or both). The in-scope register view codes
#' are surfaced here for documentation; the cross-border / foreign / sub-limit
#' / territorial-planning sub-registers are deliberately out of scope and never
#' crawled. The portal honours additional server-side search (free-text name,
#' code, oznamovatel, Zařazení) via a POST form, but only `assessment_type` is
#' first-class in v0.1.
#' @noRd
cenia_cz_facets <- function() {
  list(
    assessment_type = c("All", "EIA", "SEA"),
    register_view = c(EIA = "eia100_cr", SEA = "SEA100_koncepce")
  )
}

#' Static lookup of the mzozt.gov.hr (Croatia) facet vocabularies.
#'
#' Croatia has no machine-readable register or API; the handler scrapes a
#' small set of server-rendered CMS master pages. The only first-class
#' discriminator is the `assessment_type` selector (which register to crawl —
#' PUO for EIA, SPUO for SEA, or both). There are no server-side search
#' filters: `query` and `date_range` are matched client-side after the master
#' pages are fetched. The PUO / SPUO register codes are surfaced here for
#' documentation.
#' @noRd
mzozt_hr_facets <- function() {
  list(
    assessment_type = c("All", "EIA", "SEA"),
    register = c(EIA = "PUO", SEA = "SPUO")
  )
}

#' Static lookup of the EA-Hub (Denmark) facet vocabularies.
#'
#' EA-Hub's master-data endpoints (`/api/master-data/...`) are the
#' authoritative source for these vocabularies; this static snapshot
#' captures only the search-time discriminators we currently honour
#' (`assessment_type`), plus the EIA-Directive Annex I/II numeric labels as a
#' **reference** vocabulary (`annex` is not a search argument). Anything richer (plan types,
#' plan categories, statuses, etc.) is best fetched live from the API.
#' @noRd
eahub_dk_facets <- function() {
  list(
    assessment_type = c("All", "Plans", "Project"),
    annex = c(
      "Annex I (mandatory EIA)",
      "Annex II (case-by-case screening)"
    )
  )
}

#' Static lookup of the UVP-DB (Austria) facet vocabularies.
#'
#' The portal classifies each procedure by a 1-based `type` integer (1 =
#' Abfallwirtschaft, ..., 23 = Windkraftanlagen) and groups those into
#' broader categories (Energie, Infrastruktur, Freizeit, Agrar, Industrie,
#' Fehler, Sonstige). Documented here for reference; only `bundesland`
#' is honoured as a runtime filter (via the `jurisdiction` argument).
#' @noRd
uvpdb_at_facets <- function() {
  list(
    bundesland = c(
      "Burgenland",
      "K\u00e4rnten",
      "Nieder\u00f6sterreich",
      "Ober\u00f6sterreich",
      "Salzburg",
      "Steiermark",
      "Tirol",
      "Vorarlberg",
      "Wien"
    ),
    type = at_typology_legend(),
    type_group = c("Energie", "Infrastruktur", "Freizeit", "Agrar", "Industrie", "Fehler", "Sonstige")
  )
}

#' Static lookup of the UVP-Verbund facet vocabularies.
#'
#' The portal exposes a `procedure=` facet (Zulassungsverfahren,
#' Bauleitplanung, Raumordnungsverfahren, Negative Vorprüfungen,
#' Linienbestimmungen, Ausländische Vorhaben) and an implicit federal-state
#' partner facet via search-result icons; neither is honoured yet in v0.1.
#' Captured for forward compatibility / documentation.
#' @noRd
uvp_facets <- function() {
  list(
    procedure = c(
      "obj_class_zv",
      "obj_class_nv",
      "obj_class_blp",
      "obj_class_ro",
      "obj_class_li",
      "obj_class_av"
    ),
    bundesland = c(
      "Baden-W\u00fcrttemberg",
      "Bayern",
      "Berlin",
      "Brandenburg",
      "Bremen",
      "Hamburg",
      "Hessen",
      "Mecklenburg-Vorpommern",
      "Niedersachsen",
      "Nordrhein-Westfalen",
      "Rheinland-Pfalz",
      "Saarland",
      "Sachsen",
      "Sachsen-Anhalt",
      "Schleswig-Holstein",
      "Th\u00fcringen",
      "Bund"
    )
  )
}

#' Static lookup of the Commissie m.e.r. facet vocabularies.
#'
#' Captured from the FacetWP preload at <https://www.commissiemer.nl/adviezen/>
#' on 2026-05-26. Used both for documenting valid search values and for
#' validating user input in [get_assessments_nl()].
#'
#' @return Named list of character vectors.
#' @noRd
commissiemer_facets <- function() {
  # fmt: skip
  list(
    advice_type = c(
      "toetsing", "richtlijnen", "reikwijdte-en-detailniveau", "beoordeling", "overig", "ontheffing", "evaluatie"
    ),
    status = c("afgerond", "lopend"),
    province = c(
      "provincie-noord-brabant", "provincie-zuid-holland", "provincie-gelderland", "provincie-noord-holland",
      "provincie-overijssel", "provincie-limburg", "landelijk", "provincie-groningen", "provincie-friesland",
      "provincie-utrecht", "provincie-zeeland", "provincie-drenthe", "provincie-flevoland", "belgium", "germany",
      "antarctica", "norway", "united-kingdom", "aruba", "georgia", "ukraine"
    ),
    theme = c(
      "afval", "bagger", "bedrijventerreinen", "buisleidingen", "cultuurhistorie", "delfstofwinning-en-ontgrondingen",
      "dijken", "duurzame-ontwikkeling", "energie", "externe-veiligheid", "fossiele-brandstoffen", "geluid",
      "gezondheid", "grensoverschrijdende-projecten", "hoogspanningsleidingen", "kernenergie", "klimaatadaptatie",
      "landelijk-gebied", "landschap", "luchthavens", "luchtkwaliteit", "mkba", "natuur", "omgevingsplannen",
      "participatie", "procesindustrie", "recreatie", "spoorwegen", "stedelijke-ontwikkeling", "structuurvisies",
      "tuinbouw", "uitnodigingsplanologie", "vaarwegen-en-havens", "veehouderij", "waddenzee", "waterbeheer",
      "waterwinning", "wegen", "windenergie"
    )
  )
}
