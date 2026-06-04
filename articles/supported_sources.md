# Supported sources

`planscanR` is a thin layer over a handful of national
environmental-assessment portals (currently Netherlands, Germany,
France, Austria, Denmark, Belgium (Flanders), Estonia, Finland,
Bulgaria, the Czech Republic, Croatia, Greece, Iceland, Ireland,
Slovenia, Portugal, the United Kingdom, Italy, Slovakia, Norway, Latvia,
and Spain). There is no shared API behind the scenes — each country
gives us a different mix of HTML pages, sitemaps, search endpoints, and
undocumented JSON handlers, and each one comes with its own quirks. This
vignette describes what each handler does, where it pulls data from, and
what to expect (or watch out for) when using it.

For the runtime equivalent — the same information in tabular form,
including the valid vocabularies for the search facets each handler
accepts — call:

``` r

get_assessments_coverage()
```

## A note on stability

> [!WARNING]
> None of these portals expose a contractually stable API. Some handlers
> parse HTML detail pages with `rvest` (NL, DE, EE), the rest sit on
> undocumented JSON or REST endpoints (AT, DK, BE). Any of the operators
> can change a CSS class, rename a field, or slip a login wall in front
> of an endpoint without warning, and the corresponding handler will
> then break — sometimes silently. Treat the results with the scepticism
> that a scraping pipeline deserves, and please file an issue when you
> spot differences.

> [!CAUTION]
> Because we are often not talking to real APIs, we have no rate-limit
> contract with these servers. The package throttles where we know it
> matters (NL is capped at ~1 request/second, DK and BE at 5), but a
> careless full-register crawl can still put real load on a small
> government portal. Use `limit` and `query` while exploring.

## Netherlands — `"nl"`

- **Portal:** Commissie m.e.r. adviezenregister
  ([commissiemer.nl/adviezen](https://www.commissiemer.nl/adviezen/))
- **Status:** supported — full records and document downloads.
- **Authentication:** none.
- **Coverage:** ~3,600 advisory records.
- **Throttle:** ~1 request/second by default
  (`getOption("planscanR.nl_throttle_rate")`).

URL enumeration is driven by the portal’s own sitemap index
(`wp-sitemap.xml`, following the `advice-sitemap*` sub-sitemaps).
Per-record metadata is parsed from each detail page with `rvest` and
persisted to a sidecar JSON, so re-running a slice is essentially free
once the cache is warm.

**Filter coverage.** Free-text `query`, `date_range` (matched against
`date_decision`), and `province` (substring match against
`competent_authority`) are honoured. The portal’s taxonomy facets —
`theme`, `advice_type`, `status` — are driven by a client-side FacetWP
layer that does not yield to programmatic access; those arguments are
accepted for forward compatibility but currently emit a one-shot
warning.

**Documents.** Detail pages group PDFs into two on-page sections, which
are exposed as separate list-columns (`attachment_urls_source` and the
deduplicated `attachment_urls` union). See
[`?get_assessments_nl`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md)
for the section layout.

``` r

get_assessments_nl(limit = 20, download = FALSE)
```

## Germany — `"de"`

- **Portal:** UVP-Verbund
  ([uvp-verbund.de](https://www.uvp-verbund.de/))
- **Status:** supported — full records and document downloads.
- **Authentication:** none.
- **Coverage:** ~24,289 records federated across all federal-state
  authorities (the full register).

The portal exposes no sitemap, no OAI-PMH, and no CSW endpoint.
Enumeration goes through the portal’s Solr-backed full-text search
(`/freitextsuche`). When no `query` is supplied the handler sends the
wildcard `q=*:*`, which paginates through the full register (~2,429
pages of 10 records each). The `toggle_procedure=` parameter is
explicitly set to an empty value so the portal does not silently
restrict results to currently-running and last-year-modified procedures.

**Filter coverage.** `query` is passed straight through as the
server-side `q` parameter (real full-text search, not a client-side
substring match). `date_range` matches against the detail-page “Zuletzt
geändert” timestamp, exposed as `date_decision`. `jurisdiction` is a
substring match against the federal-state partner (e.g. `"Bayern"`,
`"Baden-Württemberg"`).

**Documents.** Detail pages group documents under open-ended
`h4.title-font` section headings. Each heading becomes its own
`attachment_urls_<slug>` / `local_path_<slug>` column; known headings
get a curated slug (`uvp_bericht`, `berichte`, `entscheidung`,
`auslegung`, `weitere`) and any unknown heading is auto-slugged from its
title so a new section type appears without a code change. See
[`?get_assessments_de`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md)
for the full layout.

``` r

get_assessments_de(query = "windenergie", limit = 20, download = FALSE)
```

## France — `"fr"`

- **Portal:** Projets-Environnement
  ([projets-environnement.gouv.fr](https://www.projets-environnement.gouv.fr/))
- **Status:** supported — full records, WGS84 geometry, and document
  downloads.
- **Authentication:** none.
- **Coverage:** ~5,483 records (the full diffusion dataset).

Unlike the SPA-behind-a-private-API portals elsewhere in the family,
this one is a public **OpenDataSoft Explore API v2.1** platform — a
documented, anonymous REST+JSON service. The whole register is one flat
dataset (`projets-environnement-diffusion`), with every field inline in
each record, so there is no separate detail call. The handler enumerates
via the export endpoint (`/exports/json?limit=-1`), which has no offset
cap and returns the full filtered set in one call. The stable business
key `recordsid` is used as `document_id`.

**Throttle.** 5 requests per second by default
(`getOption("planscanR.fr_throttle_rate")`). The enumeration is a single
export call; the throttle mainly paces per-attachment downloads.

**Filter coverage.** All filters are server-side via ODSQL `where`
clauses: `query` becomes `search("<query>")`; `theme`
(`dc_subject_theme`), `native_type` (`dc_type`) and `status`
(`vp_status`) become equality clauses; `date_range` becomes a `dc_date`
window. See
[`?get_assessments_coverage`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
for the `theme` / `status` / `native_type` vocabularies.

**Documents.** Attachments come from a fixed set of typed
`dc_relation_*` fields, each mapped to a curated slug:
`attachment_urls_etude_impact` (the étude d’impact PDF),
`_resume_non_technique` (résumé non technique), `_avis_ae` (avis de
l’Autorité environnementale), `_reponse_avis_ae`, `_dossier` (the
`*_DCZIP.zip`), plus a few others. Only real document URLs on the
`sicodei.projets-environnement.gouv.fr` blob host (or `.pdf`/`.zip`
links) become attachments — external préfecture web pages are kept only
as extras.

**Geometry.** About 1,472 records carry a `localisation` GeoJSON Feature
(typically a `MultiPolygon`). OpenDataSoft always serves WGS84, so each
is saved as a sibling `<document_id>.geometry.geojson` with
`geometry_crs = "EPSG:4326"`.

``` r

get_assessments_fr(query = "éolien", limit = 20, download = FALSE)
```

## Austria — `"at"`

- **Portal:** Umweltbundesamt UVP-DB
  ([secure.umweltbundesamt.at/uvpdb/public](https://secure.umweltbundesamt.at/uvpdb/public))
- **Status:** supported (metadata-only) — documents sit behind a
  Keycloak login wall and are not retrievable by this version.
- **Authentication:** none for metadata.
- **Coverage:** ~500 procedures (the full register is small).

The public HTML pages of the portal sit behind a Keycloak login, but
three JSON service handlers are open: `mapsdata`, `mapsgeom`, and
`vorhabenInfo`. Enumeration is a single `mapsdata` call that returns the
full index keyed by Aktenzahl; per-record detail is one `vorhabenInfo`
call per `v2id`. No pagination, no CSRF, no session required.

**Filter coverage.** `query` is a case-insensitive substring match on
`title` + `summary`. `date_range` is matched against the record’s `year`
(treated as a Jan 1 – Dec 31 span) — `date_decision` is always `NA`,
because the anonymous service handlers do not expose a decision or
last-modified timestamp. `jurisdiction` is a substring match against the
comma-joined Austrian federal-state list (so `"Wien"` works, `"Bayern"`
will not).

**Documents.** Not available to anonymous callers. Every record returns
`attachment_urls = character(0)`. The `download` argument is accepted
for API symmetry but has no effect. If you need attachments, point
`get_assessments(..., discover = TRUE)` at a web-search backend — see
\[[`?discover_attachments`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)\].

``` r

get_assessments_at(query = "Windpark", limit = 20, download = FALSE)
```

## Denmark — `"dk"`

- **Portal:** Danmarks Miljøportal EA-Hub
  ([eahub.miljoeportal.dk](https://eahub.miljoeportal.dk/))
- **Status:** supported (metadata-only) — full metadata and polygon
  geometry are fetched; document downloads are a future addition.
- **Authentication:** none.
- **Coverage:** ~2,700 records (both EIA, “miljøvurdering af projekter”,
  and SEA, “miljøvurdering af planer”).
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.dk_throttle_rate")`), because the geometry
  fetch is one tiny GET per record-with-geometry.

EA-Hub is a Vue SPA sitting on a public REST API (Swagger at
`/api/swagger/v1/swagger.json`). One `POST /assessments/search` call
returns the entire register — each row already carries title, year
range, status, authorities, EIA-Directive Annex I/II categories, plan
types/categories, and a `hasGeometry` flag — so no detail call is needed
during the scan phase.

**Geometry.** Records with `hasGeometry == TRUE` carry a polygon
(typically a MULTIPOLYGON in EPSG:25832 / ETRS89-UTM32N). When
`write_sidecar = TRUE`, the geometry is fetched from
`GET /assessments/{id}/geometry` and saved next to the sidecar as
`<document_id>.geometry.geojson`; the sidecar carries a `geometry_path`
and `geometry_crs` for downstream consumption with `sf`.

**Filter coverage.** `query` is forwarded to the API’s server-side
`freeText`. `assessment_type` (`"All"`, `"Plans"`, `"Project"`) is
honoured. `date_range` is matched client-side against each record’s
`fromYear`/`toYear` (treated as Jan 1 – Dec 31 spans); `date_decision`
is always `NA` because EA-Hub exposes only year fields, no decision
timestamp.

**Documents.** EA-Hub exposes PDFs at public Azure blob URLs reachable
via `GET /assessments/{id}/documents/{docId}/links`, but resolving them
costs an extra HTTP call per document. The current handler is scan +
classify only; a future release will add the download phase.

``` r

get_assessments_dk(query = "vindmølle", limit = 20, download = FALSE)
```

## Belgium (Flanders) — `"be"`

- **Portal:** Departement Omgeving MER-register
  ([merregister.omgeving.vlaanderen.be](https://merregister.omgeving.vlaanderen.be/))
- **Status:** supported — full metadata, polygon geometry, and document
  downloads.
- **Authentication:** none.
- **Coverage:** ~3,000 Project-MER dossiers (project-level EIA) and
  dossier MER-plicht ontheffingsaanvragen (exemption requests). Plan-MER
  (SEA) lives in a separate Flemish register and is out of scope for
  this handler.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.be_throttle_rate")`).

The portal is a Vue SPA backed by a public REST API at
`https://dmvb.omgeving.vlaanderen.be/api/v1/`. The SPA reads its backend
host from `/rest/configuratie` and then paginates `/api/v1/dossier` to
enumerate the register (page size capped server-side at 25). The full
per-record payload — coordinator, expertise domains, document list,
geometry — is one `/api/v1/dossier/{nummer}` call.

**Geometry.** Every detail record carries a `locatie` field in
GeoJSON-style (typically MULTIPOLYGON) directly inline — no separate
geometry call. Coordinates are in **EPSG:31370** (Belgian Lambert 72).
When `write_sidecar = TRUE`, the geometry is saved next to the sidecar
as `<document_id>.geometry.geojson`; the sidecar carries `geometry_path`
and `geometry_crs` for downstream consumption with `sf`.

**Filter coverage.** `query` is a case-insensitive substring match on
`title` + `document_id`. `niscode` (5-digit municipality code) and
`nummer` (dossier ID, e.g. `"PR4037"`) are forwarded server-side; the
API ignores anything else. `dossier_type` (`"PROJECT_MER"` /
`"VERZOEK_TOT_ONTHEFFING"`) is applied client-side. `date_range` matches
against `date_published`, derived from the earliest document creation
date on the record; `date_decision` is always `NA` because the API
exposes no separate decision timestamp.

**Documents.** Direct, anonymous download URLs are emitted for every
`documenten[]` entry. Documents are grouped by their portal `type`
(`Aanmelding`, `Ontheffingsaanvraag`, `Verslag toekenning ontheffing`,
…); each type becomes its own `attachment_urls_<slug>` /
`local_path_<slug>` column. The deduplicated union is at
`attachment_urls` / `local_path` as the schema requires.

``` r

get_assessments_be(query = "wind", limit = 20, download = FALSE)
```

## Estonia — `"ee"`

- **Portal:** Keskkonnaamet KOTKAS (KMH-register and KSH-register)
  ([kotkas.envir.ee](https://kotkas.envir.ee/))
- **Status:** supported — full metadata, polygon geometry, and document
  downloads, across **both** registers.
- **Authentication:** none.
- **Coverage:** ~500 EIA records (KMH, *Keskkonnamõju hindamine*) and
  ~750 SEA records (KSH, *Keskkonnamõju strateegiline hindamine*) at the
  time of writing. The handler merges both registers into one result
  tibble and tags each row via the `assessment_type` column (`"EIA"` for
  KMH, `"SEA"` for KSH). `document_id` is prefixed `"KMH-"` / `"KSH-"`
  so the two registers never collide on disk.
- **Throttle:** 2 requests/second by default
  (`getOption("planscanR.ee_throttle_rate")`) — the portal pushes back
  with a 300 s retry-backoff at 5 req/s under sustained load.

KOTKAS is a server-rendered jQuery/Bootstrap portal (not a SPA). Each
register’s index paginates via a numeric `qs=` offset (page size = 40,
server-controlled); detail pages live at `/kmh/kmh_view?kmh_id=<id>` and
`/kmh/ksh_view?ksh_id=<id>` respectively. Every field a downstream
classifier needs — full title, narrative summary, developer/proponent,
decider/competent authority, KOV municipality, geometry, attachment URLs
— is on the detail page.

**Geometry.** Every detail record carries its activity area as an inline
GeoJSON geometry, embedded in a hidden form input
(`#activity_area_geojson`). Coordinates are in **EPSG:3301** (Estonian
Coordinate System of 1997 / L-EST97). When `write_sidecar = TRUE`, the
geometry is saved next to the sidecar as
`<document_id>.geometry.geojson`; the sidecar carries `geometry_path`
and `geometry_crs` for downstream consumption with `sf`.

**Filter coverage.** `query` is forwarded server-side as
`s__search_keyword` (matches title / code / related-person).
`assessment_type` (`"All"`, `"EIA"`, `"SEA"`) decides which register(s)
to crawl. `proceeding_status` (`"INITIATED"`, `"ONGOING"`,
`"SUSPENDED"`, `"FINISHED"`), `activity_area` (maakond code,
e.g. `"0037"` = Harju), and `activity` (sector code, e.g. `"1300"` =
energy) are all forwarded server-side. `date_range` is matched
client-side against `date_published` (the portal’s *Algatamise kpv* /
initiation date); `date_decision` is always `NA` because the portal does
not expose a separate decision timestamp on the detail page (only
per-document dates inside the *Dokumendid* table).

**Documents.** Detail pages expose a *Dokumendid* table whose rows have
direct, anonymous download URLs (`/kmh/<kmh|ksh>_file_download?...`).
Documents are grouped by their portal *Liik* (type) — common ones
include *Algatamise otsus* (initiation decision), *Programm* (assessment
programme), *Programmi otsus* (programme decision), *Aruanne* (report),
*Aruande otsus* (report decision). Each type becomes its own
`attachment_urls_<slug>` / `local_path_<slug>` column. The deduplicated
union is at `attachment_urls` / `local_path` as the schema requires.

``` r

# Both registers, wind-themed slice
get_assessments_ee(query = "tuulepark", limit = 20, download = FALSE)

# SEA only
get_assessments_ee(assessment_type = "SEA", limit = 20, download = FALSE)
```

## Finland — `"fi"`

- **Portal:** ymparisto.fi, the national environmental-administration
  site ([ymparisto.fi](https://www.ymparisto.fi/))
- **Status:** supported — **EIA/YVA only**. The ymparisto.fi search
  index has no SOVA/SEA (strategic assessment) content type;
  `yva_project` is the only project type, so this handler delivers
  project-level EIA (*YVA*, *ympäristövaikutusten arviointi*) records
  only. There is no SEA path.
- **Authentication:** none.
- **Coverage:** ~1,334 YVA records at the time of writing.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.fi_throttle_rate")`) — the ~1,334 per-record
  HTML landing-page GETs (needed to harvest attachment URLs) dominate a
  cold crawl.

This handler is a **hybrid**. ymparisto.fi is a Drupal + React site
whose site-search is backed by an Elasticsearch index exposed through a
same-origin proxy that passes raw ES Query DSL:
`POST https://www.ymparisto.fi/fi/app/search/query` with a JSON body.
The handler filters to `{"query":{"term":{"type":"yva_project"}}}` and
paginates with ES `from`/`size` against a stable id sort; the whole
register sits under the 10,000 `max_result_window`. All record
**metadata** (title, description, publish time, project phase, the
responsible ELY-keskus, municipality, province, subject area) comes from
the index. A Swedish `/sv/` index exists but is ignored in v0.1.

**Geometry.** None — neither the index nor the landing page exposes
coordinates, so no geometry columns are emitted.

**Filter coverage.** `query` is forwarded server-side as an ES `match`
over the `content` + `title` fields. `assessment_type` accepts only
`"All"` / `"EIA"` (both crawl the single `yva_project` register; there
is no `"SEA"`). `date_range` is matched client-side against
`date_published` (the `publishTime` unix-seconds epoch); `date_decision`
is always `NA` (no structured decision timestamp in the index).

**Documents.** Attachment URLs are **not** in the Elasticsearch index —
they live only on the HTML landing page. For each kept record the
handler GETs the record’s landing page and scrapes every `<a href>`
under `/sites/default/files/`, resolving them to absolute, anonymous
`https://www.ymparisto.fi/sites/default/files/documents/<file>.{pdf,doc,docx}`
URLs. Because the URLs come from the HTML, this detail fetch runs even
when `download = FALSE` (to populate `attachment_urls`); it is skipped
only when a sidecar already exists for the URL (sidecar-first).
Documents are typed by their **anchor text** (the page has no structured
section markup) via a curated keyword map with an auto-slug fallback:
`arviointiohjelma` → `programme`, `arviointiselostus` → `report`,
`lausunto` → `statement`, `kuulutus` → `notice`, `tiivistelmä` →
`summary`. Each type becomes its own `attachment_urls_<slug>` /
`local_path_<slug>` column; the deduplicated union is at
`attachment_urls` / `local_path` as the schema requires.

``` r

# Wind-themed slice (server-side full-text)
get_assessments_fi(query = "tuulivoima", limit = 20, download = FALSE)
```

## Bulgaria — `"bg"`

- **Portal:** Ministry of Environment and Water (МОСВ) public registers
  — ОВОС-register (EIA) and ЕО-register (SEA)
  ([registers.moew.government.bg](https://registers.moew.government.bg/))
- **Status:** supported — full metadata and anonymous document
  downloads, across **both** registers. No geometry.
- **Authentication:** none.
- **Coverage:** ~35,000 EIA records (ОВОС, *Оценка на въздействието
  върху околната среда*) and ~10,000 SEA records (ЕО, *Екологична
  оценка*) at the time of writing. The handler merges both registers
  into one result tibble and tags each row via the `assessment_type`
  column (`"EIA"` for ОВОС, `"SEA"` for ЕО). `document_id` is prefixed
  `"OVOS-"` / `"EO-"` so the two registers never collide on disk.
  Because the registers are large, pass `limit` and/or `query` while
  exploring.
- **Throttle:** 2 requests/second by default
  (`getOption("planscanR.bg_throttle_rate")`) — detail fetches are slow
  (~4 s server-side) and the host is a small government server.

The registers are server-rendered ASP.NET MVC pages (no SPA, no
viewstate). Each register’s listing paginates via a numeric `offset`
plus a `limit` query parameter (`?offset=<n>&limit=<k>`); the page text
*Намерени досиета.* (“Found N dossiers”) is the authoritative total.
Detail pages live at `/ovos/lot/<id>` and `/eo/lot/<id>` and are scraped
with `rvest` from a single nested row-group `table.table-lot` (each row
carries a label `<th>` and a value `<td>`).

**Geometry.** None. The МОСВ registers expose no coordinates or GeoJSON;
location is administrative text only and is composed into `jurisdiction`
(Област / Община / Населено място). No `geometry_path` / `geometry_crs`
columns are emitted.

**Filter coverage.** `query` is forwarded server-side as `projectName`
(substring match on the project/plan name). `assessment_type` (`"All"`,
`"EIA"`, `"SEA"`) decides which register(s) to crawl. `date_range` is
matched client-side against `date_published` (the dossier submission
date); `date_decision` is the termination-decision date (*Дата на
решението за прекратяване*) when present, else `NA`. The portal also
accepts `contractorNames` and region/authority/procedure/date filters
server-side; these are not first-class in v0.1.

**Documents.** Detail pages render document links inline inside the lot
table’s value cells, with direct anonymous download URLs of the form
`/ovos/file?fileKey=<uuid>&fileName=<name>` (and `/eo/file?...`). The
`fileName` query parameter is required by the server (it 500s without
it), so the handler captures the full href verbatim rather than
reconstructing it. Documents are typed only by the table-row label they
sit under (Уведомление, Описание, Писмо, …); each label becomes its own
`attachment_urls_<slug>` / `local_path_<slug>` column (the Bulgarian
label is transliterated to ASCII). The deduplicated union is at
`attachment_urls` / `local_path` as the schema requires.

``` r

# Both registers, wind-themed slice
get_assessments_bg(query = "вятър", limit = 20, download = FALSE)

# SEA only
get_assessments_bg(assessment_type = "SEA", limit = 20, download = FALSE)
```

## Czech Republic — `"cz"`

- **Portal:** CENIA *Informační systém EIA/SEA* — the EIA register
  *Záměry na území ČR* (`eia100_cr`) and the SEA register *Posuzování
  koncepcí* (`SEA100_koncepce`)
  ([portal.cenia.cz/eiasea](https://portal.cenia.cz/eiasea/))
- **Status:** supported — full metadata and anonymous document
  downloads, across **both** in-scope registers. No geometry.
- **Authentication:** none.
- **Scope (domestic CZ only):** the handler crawls **only** the two
  domestic registers above. The portal also hosts cross-border / foreign
  registers (`eia100_mimo_cr` — projects outside CZ, `sea100_mezistatni`
  — cross-border SEA) and several special sub-registers (the sub-limit /
  priority-transport / large-project EIA registers `eia100_podlimitni` /
  `_pdz` / `_vzvp` / `eia244`, and the territorial-planning SEA
  registers `sea100_pur*` / `zur*` / `up*`); these are **never**
  enumerated. Ministry-coded records (`EIA_MZP*` / `SEA_MZP*`) *inside*
  the two domestic registers are domestic projects/plans assessed by the
  Ministry and stay in scope.
- **Coverage:** ~22,780 EIA záměry and ~640 SEA koncepce at the time of
  writing. Both registers merge into one result tibble and tag each row
  via the `assessment_type` column (`"EIA"` / `"SEA"`). `document_id` is
  the register-namespaced detail code (e.g. `"EIA_JHC1237"`,
  `"SEA_HKK015K"`), so the two never collide on disk. Because the EIA
  register is large, pass `limit` while exploring.
- **Throttle:** 2 requests/second by default
  (`getOption("planscanR.cz_throttle_rate")`) — the portal is a single
  Tomcat instance and a full crawl is large.
- **Language:** record content is Czech (ISO-639-1 `cs`; the country
  code `cz` differs from the language code). `lang=en` only flips UI
  chrome, so the handler fetches with `lang=cs`.

The registers are server-rendered JSP pages (Apache Tomcat — not a SPA).
Each listing paginates via a **1-based** `?p=<n>` query (10
records/page); out-of-range pages are clamped to the last page by the
server, so the handler stops paginating once a page contributes no
detail codes it has not already seen. Detail pages live at
`/eiasea/detail/EIA_<CODE>` and `/eiasea/detail/SEA_<CODE>` and are
scraped with `rvest` from a single `table.detail` of label/value rows
interspersed with bold process-stage heading rows.

**Geometry.** None. The CENIA detail pages expose no coordinates or
GeoJSON; location is administrative text only and is composed into
`jurisdiction` (Kraj / Okres / Obec / Katastr). No `geometry_path` /
`geometry_crs` columns are emitted.

**Filter coverage.** `assessment_type` (`"All"`, `"EIA"`, `"SEA"`)
decides which register(s) to crawl. `date_range` is matched client-side
against `date_published` — the EIA last-modified date (*Datum a čas
posledních úprav*) or the SEA publication date (*Datum zveřejnění*);
`date_decision` is always `NA` because the portal exposes no single
clean decision-date field. Dates are parsed from the Java
`Date.toString()` form (e.g. `Thu Jun 04 07:28:50 CEST 2026`).

**Documents.** Detail pages render document links inline inside the
detail table’s value cells, with direct anonymous download URLs of the
form `/eiasea/download/<token>/<file>`. Both the base64-ish token and
the trailing human filename are captured verbatim from the rendered
href. Documents are grouped by process-stage heading (OZNÁMENÍ,
ZJIŠŤOVACÍ ŘÍZENÍ, DOKUMENTACE, POSUDEK, VEŘEJNÉ PROJEDNÁNÍ, STANOVISKO
for EIA; the oznámení / vyhodnocení / návrh koncepce / stanovisko /
schválená koncepce fields for SEA); each stage becomes its own
`attachment_urls_<slug>` / `local_path_<slug>` column (the Czech label
is transliterated to ASCII). The deduplicated union is at
`attachment_urls` / `local_path` as the schema requires. Note that some
attachments are very large ZIP bundles (e.g. a 79 MB `oznameni.zip`);
the `max_file_size_mb` cap skips oversized files rather than fetching
them.

``` r

# Both registers, first few records
get_assessments_cz(limit = 5, download = FALSE)

# SEA only
get_assessments_cz(assessment_type = "SEA", limit = 5, download = FALSE)
```

## Croatia — `"hr"`

- **Portal:** Ministry of Environment and Green Transition CMS pages —
  *Procjena utjecaja zahvata na okoliš* (PUO / project-level EIA) and
  *Strateška procjena utjecaja na okoliš* (SPUO / plan-level SEA)
  ([mzozt.gov.hr](https://mzozt.gov.hr/)). Pin the domain
  `mzozt.gov.hr`; it was renamed from `mingor` / `mingo` and the old
  links 30x-redirect to it.
- **Status:** supported — full metadata and anonymous document
  downloads, across **both** registers. No API. No geometry.
- **Authentication:** none.
- **No machine-readable register.** Croatia exposes no JSON API and no
  per-record detail endpoint. The “register” is a small set of
  server-rendered ASP.NET CMS pages; each procedure is an inlined
  `<li><strong>PROJECT TITLE</strong> <ul>...document links...</ul></li>`
  block. The handler fetches the master page(s) once and treats each
  block as one record — there is **no** pagination. PUO is one large
  master archive page (~550 procedures / ~2,500 documents); SPUO is two
  small pages (Ministry-competent and other-competent-body procedures).
- **Coverage:** both registers merge into one result tibble and tag each
  row via the `assessment_type` column (`"EIA"` / `"SEA"`). Because
  there is no native procedure id, `document_id` is a stable
  deterministic SHA-1 hash of the title (`HR-PUO-<hash>` /
  `HR-SPUO-<hash>`, with a cleanly-parseable year folded in when
  present), so the two never collide on disk. `url` is the master-page
  URL plus `#<document_id>`, giving each record a unique landing URL
  while still pointing a human at the right page.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.hr_throttle_rate")`) — only ~3 HTML fetches
  plus N PDF downloads, so the throttle is politeness for the download
  phase.
- **Language:** record content is Croatian (ISO-639-1 `hr`).

**Geometry.** None. The CMS pages expose no coordinates or GeoJSON;
spatial information, where present, lives inside the PDFs. A county /
*grad* is heuristically pulled from the title into `jurisdiction` when
trivially present, else `NA`. No `geometry_path` / `geometry_crs`
columns are emitted.

**Filter coverage.** `assessment_type` (`"All"`, `"EIA"`, `"SEA"`)
decides which register(s) to crawl. `query` is a **client-side** title
substring match (the CMS pages have no server-side search). `date_range`
is matched client-side against `date_published` — the earliest document
date in the block (every document anchor is prefixed `DD.MM.YYYY.`);
`date_decision` is the *rješenje* / *odluka* (decision) date when
present, else `NA`.

**Documents.** Direct anonymous `.pdf` (sometimes `.zip`) download links
carry stable `data-fileid` attributes. Documents are grouped by the
stage sub-heading they sit under (PUO *informacija o zahtjevu* / *javni
uvid* / *nacrt rješenja* / *rješenje*); SPUO procedures often list their
documents flat under the title with no stage sub-heading, which fall
under the `document` slug. Known stage labels get a stable curated slug;
anything else is auto-slugged from the heading (Croatian diacritics
transliterated to ASCII). Each stage becomes its own
`attachment_urls_<slug>` / `local_path_<slug>` column; the deduplicated
union is at `attachment_urls` / `local_path` as the schema requires. The
`href` is captured verbatim (with its spaces and Croatian diacritics)
and percent-encoded only for the network request at download time.

``` r

# Both registers, first few records
get_assessments_hr(limit = 5, download = FALSE)

# SEA only
get_assessments_hr(assessment_type = "SEA", download = FALSE)
```

## Greece — `"gr"`

- **Portal:** ΗΠΜ / EPRM (*Ηλεκτρονικό Περιβαλλοντικό Μητρώο* —
  Electronic Environmental Registry) of the Ministry of Environment &
  Energy (ΥΠΕΝ), served by a public JSON:API at
  [api.eprm.ypen.gr](https://api.eprm.ypen.gr/v1/license-decisions). The
  human-facing SPA lives at [eprm.ypen.gr](https://eprm.ypen.gr/) (its
  `robots.txt` disallows crawling the HTML, so the handler harvests only
  from the JSON:API and uses the SPA route purely as the canonical
  `url`).
- **Status:** supported, **with an important coverage caveat (decisions
  only)** — see below. Reflected in `get_assessments_coverage()$status`
  as `"supported (decisions-only; studies/SEA login-gated)"`.
- **Authentication:** none for the public registry (each request sends
  `Accept: application/json`; no cookie / CSRF).
- **AEPO decisions only (read this first).** The public registry exposes
  only **AEPO decisions** — *Αποφάσεις Έγκρισης Περιβαλλοντικών Όρων*,
  the regulatory **output** of the EIA (ΜΠΕ) process. The underlying
  **ΜΠΕ study files and all ΣΜΠΕ / SEA records sit behind the gov.gr
  login** on `platform.eprm.ypen.gr` and are **not** fetchable here. So
  each record is a decision (metadata + at most one decision PDF) —
  never the EIA study itself, and the SEA register is entirely out of
  scope. Plan for a decisions-only corpus.
- **Coverage:** ≈19,800 AEPO decisions. The listing endpoint
  (`GET /v1/license-decisions`) paginates JSON:API-style via
  `page[number]` (1-based) and `page[size]` (default 100); each list row
  is **already the full record**, so there is no separate detail call.
  `document_id` is the registry `id` (e.g. `"19895"`, globally unique in
  the register).
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.gr_throttle_rate")`) — enumeration is ≈200 list
  calls plus one download per attachment.
- **Language:** record content is Greek (ISO-639-1 `el`; note the
  country code `gr` differs from the language code `el`).

**Geometry.** A record’s `project_location` is an array of `{lat, lon}`
pairs. When present, the first pair is written as a **Point** geometry
next to the sidecar as `<document_id>.geometry.geojson` (the family
FeatureCollection layout, GeoJSON-2008 `crs` member naming
`urn:ogc:def:crs:EPSG::4326`). The coordinates are already geographic
**WGS84 (EPSG:4326)** — *not* the Greek Grid (EPSG:2100) — so no
reprojection happens; `geometry_crs` is `"EPSG:4326"`. Records with no
location leave the geometry columns `NA`.

**Filter coverage.** All server-side JSON:API `filter[...]` parameters:
`query` -\> `filter[text_search]` (free-text), `type` -\> `filter[type]`
(decision-type enum — see
[`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md),
e.g. `"aepo_creation"`), and `date_range` -\> `filter[issued_after]` /
`filter[issued_before]` (matched on the decision issue date, re-checked
client-side as a guard). `date_published` is the registry publication
timestamp; `date_decision` is the issue date.

**Documents.** At most one document per decision — the AEPO decision PDF
— taken verbatim from `diavgeia_doc_url`. These are hosted on **Διαύγεια
/ Diavgeia** (the Greek government transparency portal) at
`https://diavgeia.gov.gr/luminapi/api/decisions/{ADA}/document.pdf`; the
ADA in the path contains Greek characters, left for the HTTP client to
percent-encode at request time. It lands under the single slug
`attachment_urls_aepo` / `local_path_aepo`, with the deduplicated union
at `attachment_urls` / `local_path`. Records whose `diavgeia_doc_url` is
`null` yield zero attachments (still schema-valid).

``` r

# AEPO decisions, first few records
get_assessments_gr(limit = 5, download = FALSE)

# New AEPO approvals only
get_assessments_gr(type = "aepo_creation", limit = 5, download = FALSE)
```

## Iceland — `"is"`

- **Portal:** **Skipulagsgátt** (Skipulagsstofnun / National Planning
  Agency), served by an anonymous **GraphQL** API at
  [www.skipulagsgatt.is/graphql](https://www.skipulagsgatt.is/graphql).
  The human-facing Vue SPA lives at
  [www.skipulagsgatt.is](https://www.skipulagsgatt.is/); the canonical
  `url` for a record is `https://www.skipulagsgatt.is/issues/<id>`. This
  is the package’s **first GraphQL-backed handler** — the transport is a
  single HTTP `POST .../graphql` with a JSON body
  `{"query": ..., "variables": ...}`.
- **Status:** supported, **with an important coverage caveat (recent
  cases only)** — see below. Reflected in
  `get_assessments_coverage()$status` as
  `"supported (GraphQL; cases from ~June 2023 onward)"`.
- **Authentication:** none (anonymous GraphQL).
- **Coverage horizon (read this first).** Skipulagsgátt only carries
  cases from **roughly June 2023 onward** (when the portal went live).
  The older `skipulag.is` / `island.is` “gagnagrunnur umhverfismats” is
  dead (it now redirects to static info) and is **not** crawled. So this
  handler yields a recent-cases-only corpus (~235
  environmental-assessment issues at the time of writing).
- **Three processes merged.** The portal models every dossier as a
  unified `Issue`; environmental assessment lives in three of its
  `process`es, selected server-side by `processId` and merged into one
  tibble with an `assessment_type` tag: `15` (*matsskylda* screening,
  EIA-track) and `16` (full *Mat á umhverfisáhrifum*, EIA) → `"EIA"`;
  `501` (*Umhverfismat áætlana*, SEA) → `"SEA"`. The `assessment_type`
  argument (`"All"`/`"EIA"`/`"SEA"`) picks the process loop. Because the
  three share the same `Issue.id` space, `document_id` is prefixed
  `IS-<processId>-<id>` (e.g. `IS-16-137`) so they never collide on
  disk; the finer distinction is kept in `process_type` / `native_type`.
- **Enumeration.** The listing is the GraphQL
  `issueConnection(input, first, after)` cursor connection, paginated
  with `after: endCursor`. `processId` is single-valued per query, so
  the handler loops the selected processes. Detail is one
  `singleIssue(issueId)` call per record, sidecar-first.
- **Status field gotcha.** Record status is read from the plain-string
  `lifecycle` field (e.g. `"done"`, `"process_initialized"`). The
  handler deliberately does **not** request the `issueStatus` enum — it
  has a server-side serialization bug that returns HTTP 500 for the
  whole query on some records.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.is_throttle_rate")`).
- **Language:** record content is Icelandic (ISO-639-1 `is`).

**Geometry.** `Issue.hasGeography` flags whether a record has a
footprint; `Issue.geographies` returns a GraphQL `FeatureCollection`
whose per-feature `geometry` arrives as a GeoJSON **string** that needs
a *second*
[`jsonlite::fromJSON`](https://jeroen.r-universe.dev/jsonlite/reference/fromJSON.html)
parse. Point / LineString / Polygon are all observed. Coordinates are
already geographic **WGS84 (EPSG:4326 lon/lat)** — *not* the projected
ISN93 grid — so no reprojection happens. When present, the geometry is
written next to the sidecar as `<document_id>.geometry.geojson` (family
FeatureCollection layout, `urn:ogc:def:crs:EPSG::4326`); `geometry_crs`
is `"EPSG:4326"`. Records with `hasGeography = false` / an empty
collection leave the geometry columns `NA`.

**Filter coverage.** Server-side: `query` -\> the GraphQL `search` field
(full-text), and `date_range` -\> `fromDate` / `toDate` (matched on the
`publishedDate`, re-checked client-side as a guard). `assessment_type`
selects which process(es) to crawl (applied in R, by choosing the
process loop). `date_published` is the `publishedDate`; `date_decision`
is the `closedDate`.

**Documents.** Documents live under `phases[].files[]`, each an
`IssuePhaseFile` with a semantic-role `type` and a nested `data` `File`.
Only files with `published == true` are emitted. They are grouped by
their role into lowercase slugs — `almennt` (general; incl. the
matsskýrsla / EIA report and matsáætlun), `vidbrogd` (developer
responses), `afgreidsla` (the decision / álit) — one
`attachment_urls_<slug>` / `local_path_<slug>` list-column each, with
the deduplicated union at `attachment_urls` / `local_path`. The download
URL is `https://www.skipulagsgatt.is/<File.path>` (path of the form
`files/<uuid>`), anonymous. PDFs are large (often 10-16 MB) — set
`max_file_size_mb` accordingly. The top-level `Issue.files` collection
is usually empty and is ignored.

``` r

# Recent EIA cases (screening + full), first few records
get_assessments_is(assessment_type = "EIA", limit = 5, download = FALSE)

# SEA only (umhverfismat áætlana)
get_assessments_is(assessment_type = "SEA", limit = 5, download = FALSE)
```

## Ireland — `"ie"`

- **Portal:** Ireland’s **EIA Portal** (gov.ie), an Esri ArcGIS Online
  map app backed by a public **anonymous ArcGIS REST FeatureServer** at
  [services.arcgis.com](https://services.arcgis.com/NzlPQPKn5QF9v2US/arcgis/rest/services/EIA_Location_Point/FeatureServer/0)
  (the `EIA_Location_Point` master layer, ≈5,100 records). The
  human-facing app lives at
  [experience.arcgis.com/…/a1a85d92623147b191dd25a14b2571da](https://experience.arcgis.com/experience/a1a85d92623147b191dd25a14b2571da/).
  This is the package’s **first ArcGIS REST-backed handler** — transport
  is a plain `GET .../query?f=json`, pagination is `resultOffset` /
  `resultRecordCount`, and the Esri point geometry is converted to
  GeoJSON in-house.
- **Status:** supported, **with two important caveats** — see below.
  Reflected in `get_assessments_coverage()$status` as
  `"supported (EIA only; portal = notice PDFs, full EIAR off-portal)"`.
- **Authentication:** none (anonymous public layer).
- **EIA only — no SEA.** The portal covers **EIA applications only**;
  there is no SEA register here.
- **Notices only — full EIAR is off-portal.** For each application the
  portal hosts (at most) the statutory **newspaper / public-notice
  PDF**. The full EIAR itself lives **off-portal** on the relevant
  competent-authority website (An Bord Pleanála, the local council, the
  EPA, …). Those external case pages are surfaced as the
  `url_link_application` / `url_link_secondary` extras columns — HTML
  landing pages on heterogeneous third-party sites, *not* direct PDFs —
  and are deliberately kept **out** of `attachment_urls`. Treat them as
  a discovery target.
- **The `OBJECTID_1` gotcha.** The layer’s unique object-id field is
  **`OBJECTID_1`**, *not* the plain `OBJECTID` (which is non-unique on
  this layer and frequently `0`). All attachment lookups and the
  internal id fallback key off `OBJECTID_1`. The stable business key
  used as `document_id` is `Portal_Ref` (e.g. `"2024092"`).
- **Enumeration.** Listing is `GET <layer>/query`, paginated with
  `resultOffset` / `resultRecordCount` (page size 1000), looping while
  `exceededTransferLimit` is true, ordered by `OBJECTID_1 ASC`. Each
  feature carries all its metadata inline in `attributes` (no separate
  detail endpoint). The portal has no per-record permalink, so a unique,
  deterministic `url` is synthesised per record — the record-specific
  query URL `<layer>/query?where=Portal_Ref='<ref>'&outFields=*&f=json`.
- **Dates.** `Date_of_receipt_of_application_` is **epoch milliseconds**
  → `date_published` (divided by 1000). `date_decision` is `NA` (no
  decision-date field on the layer).
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.ie_throttle_rate")`).
- **Language:** English (ISO-639-1 `en`).

**Geometry.** Each record carries an Esri point `geometry` (`{x, y}`) in
**Irish Transverse Mercator (IRENET95 ITM / EPSG:2157)** — requested via
`outSR=2157`. It is converted in-house to a GeoJSON **Point** and, when
`write_sidecar = TRUE`, written next to the sidecar as
`<document_id>.geometry.geojson` (family FeatureCollection layout,
`urn:ogc:def:crs:EPSG::2157`); `geometry_crs` is `"EPSG:2157"`. No
reprojection happens — coordinates stay in EPSG:2157. Records with a
null geometry leave the geometry columns `NA`.

**Filter coverage.** Server-side: `query` -\> an
`UPPER(Description__Max__256_character) LIKE '%…%'` predicate (free-text
over the description), `competent_authority` -\> equality on
`Competent_Authority`, and `date_range` -\> a
`Date_of_receipt_of_application_` BETWEEN window (epoch ms), re-checked
client-side against `date_published`.

**Documents.** Portal-hosted attachments are ArcGIS feature attachments
— the statutory newspaper / public-notice PDF. Because the download URL
needs both the `OBJECTID_1` and the per-attachment id
(`<layer>/<OBJECTID_1>/attachments/<id>`), attachment metadata is
resolved in a batched **phase-2** `queryAttachments` call (keyed by
`OBJECTID_1`) — even when `download = FALSE`, this is needed to populate
`attachment_urls`. The single slug is `notice` (`attachment_urls_notice`
/ `local_path_notice`); the deduplicated union goes to `attachment_urls`
/ `local_path`. A record may carry **0** attachments (still
schema-valid). The full EIAR is *not* here — see the off-portal caveat
above.

``` r

# Recent EIA applications, first few records (portal hosts the notice PDF only)
get_assessments_ie(limit = 5, download = FALSE)

# Wind-themed slice (server-side description LIKE)
get_assessments_ie(query = "wind", limit = 20, download = FALSE)
```

## Slovenia — `"si"`

- **Portal:** the Slovenian government portal **gov.si**, which
  publishes its environmental-assessment registers under the
  [okoljske-presoje](https://www.gov.si/podrocja/okolje-in-prostor/okolje/okoljske-presoje)
  pages. Each register offers a **bulk JSON export** at
  `<list>/export/json/` that returns the whole register as a single JSON
  array (not paginated) — the handler issues one GET per register.
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported"`).
- **Authentication:** none (anonymous public exports).
- **Dual-register.** Three registers are merged into one result tibble,
  tagged with `assessment_type` (`"EIA"` / `"SEA"`) and the raw
  `register` label:
  - EIA screening — `predhodni-postopek` (register
    `"predhodni-postopek"`, `document_id` prefix `PRED-`);
  - SEA — CPVO decisions for **state** spatial plans
    (`odlocitve-…-drzavnih-prostorskih-nacrtov`, register
    `"cpvo-drzavni"`, prefix `CPVO-DRZ-`) and **municipal** spatial
    plans (`odlocitve-…-obcinskih-prostorskih-nacrtov-2`, register
    `"cpvo-obcinski"`, prefix `CPVO-OBC-`). An `assessment_type`
    argument (`"All"` default / `"EIA"` / `"SEA"`) selects which
    register(s) to crawl.
- **Field maps differ per register.** The screening export uses
  Slovenian keys (`Poseg` → title, `Datum objave` → `date_published`,
  `Naziv` → proponent, `Naslov` → `proponent_address`, `Številka zadeve`
  → `case_number`, `Oznaka posega` → `annex_code`); the CPVO exports use
  `Title`/`Naziv` → title, `Datum` → `date_published`, and `Odločitev` →
  `decision` (also the `native_type`). `competent_authority` is the
  fixed national ministry (*Ministrstvo za okolje, podnebje in
  energijo*). Slovenian values are kept verbatim.
- **Attachments.** The bulk-export ids do not map to filenames, so
  attachments are scraped from each record’s detail page
  (sidecar-first): every `/assets/seznami/…` link is collected and
  absolutised against `https://www.gov.si`. These go to
  `attachment_urls` (a flat list, no section split). A record may carry
  **0** attachments (still schema-valid).
- **No geometry.** The registers expose no spatial geometry.
- **Dates.** `date_published` parses the Slovenian `"DD. MM. YYYY"`
  format; `date_decision` is always `NA` (no decision date as a date).
  `date_range` is matched client-side against `date_published`.
- **Scope.** The registers cover roughly **2021 onward**.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.si_throttle_rate")`).
- **Language:** Slovenian (ISO-639-1 `sl`); no normalisation.

``` r

# Recent screening + CPVO records (no PDFs downloaded yet)
get_assessments_si(limit = 5, download = FALSE)

# SEA only (both CPVO registers)
get_assessments_si(assessment_type = "SEA", limit = 10, download = FALSE)
```

## Portugal — `"pt"`

- **Portal:** the **SIAIA** register (*Sistema de Informação sobre AIA*)
  of the Agência Portuguesa do Ambiente (APA),
  [siaia.apambiente.pt](https://siaia.apambiente.pt/). It is a
  server-rendered ASP.NET MVC application: the listing lives at
  `https://siaia.apambiente.pt/ProcessoAIA?pagina=<n>` (1-based pages,
  ~100 rows each), and the handler walks pages until an out-of-range
  page returns an empty table body.
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported (EIA/AIA only; SEA/AAE in a separate APA register)"`).
- **Authentication:** none (anonymous public register).
- **AIA only (single register).** SIAIA covers **AIA** procedures
  (*Avaliação de Impacte Ambiental* — project-level EIA). The **AAE**
  (*Avaliação Ambiental Estratégica* — plan/programme SEA) register sits
  in a separate APA application and is **not** covered, so there is no
  `assessment_type` argument — every row is an EIA-equivalent procedure.
- **Per-record fetch.** For each listing row the handler reads the
  detail page `https://siaia.apambiente.pt/ProcessoAIA/Detalhes/{id}`
  (the canonical record URL, sidecar-first) — its *Campo / Conteúdo*
  table supplies `title` (*Designação do projeto*), `proponent`,
  `competent_authority` (*Autoridade AIA*), `municipalities`
  (*Localização (Concelhos)*), `decision_sense` (*Sentido da Decisão*,
  also the `native_type`), `status`, and `date_decision` (*Data da
  decisão*) — plus the document list at
  `https://siaia.apambiente.pt/ListaDocumentos?pro_id={id}`.
  `document_id` is the `AIA-<n>` form built from the *Nº AIA*.
- **Attachments — per-phase grouping.** Documents are direct PDFs/ZIPs
  of the form `https://siaia.apambiente.pt/AIADOC/AIA{n}/{file}`. SIAIA
  prints no phase headings, so each document’s Portuguese type label is
  classified into a coarse **phase** — `dia` (the decision, *Declaração
  de Impacte Ambiental*), `eia` (the substantive dossier),
  `consulta_publica`, `parecer`, or `outros` — and grouped into its own
  `attachment_urls_<slug>` / `local_path_<slug>` list column.
  `attachment_urls` is the deduplicated union across phases.
- **No geometry.** SIAIA exposes the location only as free-text
  *concelho* (municipal) names, so no spatial geometry is written.
- **Filters (client-side).** `query` is a case-insensitive substring
  match on the project title; `date_range` is matched against
  `date_decision` when the detail page exposes a full decision date,
  otherwise against the `decision_year` (the listing’s *Ano Decisão*).
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.pt_throttle_rate")`).
- **Language:** Portuguese (ISO-639-1 `pt`); no normalisation.

``` r

# Recent AIA procedures (no PDFs downloaded yet)
get_assessments_pt(limit = 5, download = FALSE)

# Substring query on the project designation
get_assessments_pt(query = "solar", limit = 20, download = FALSE)
```

## United Kingdom — `"gb"`

- **Portal:** the Planning Inspectorate’s **National Infrastructure
  Consenting** service,
  [national-infrastructure-consenting.planninginspectorate.gov.uk](https://national-infrastructure-consenting.planninginspectorate.gov.uk/),
  the register of **Nationally Significant Infrastructure Projects
  (NSIPs)**.
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported (NSIP only; every NSIP carries an Environmental Statement)"`).
- **Authentication:** none (anonymous public register).
- **NSIP only (single register).** Every NSIP application carries a
  statutory **Environmental Statement**, so the register is an
  EIA-equivalent source; every row is an EIA-equivalent procedure and
  there is no `assessment_type` argument. Local-authority /
  Town-and-Country-Planning EIAs are **not** in this register and are
  out of scope.
- **Bulk-CSV enumeration.** The whole register is published as a single
  bulk CSV export at `…/api/applications-download` (≈540 rows). One GET
  fetches the entire register; it is parsed with base
  [`utils::read.csv()`](https://rdrr.io/r/utils/read.table.html) (no
  extra package dependency). `document_id` is the *Project reference*
  (e.g. `EN010001`); the canonical record URL is `…/projects/{REF}`.
- **Attachments — Environmental Statement PDFs.** Per record
  (sidecar-first) the handler fetches the project’s Environmental
  Statement document list
  (`…/projects/{REF}/documents?type=Environmental Statement`) and
  scrapes the published-document PDF hrefs, which live on
  `https://nsip-documents.planninginspectorate.gov.uk/published-documents/{REF}-{NNNNNN}-{title}.pdf`.
  These become a flat `attachment_urls` list (no per-section split). A
  project with no ES documents yet yields an empty list, which is valid.
- **Point geometry (EPSG:27700).** Each row carries an Ordnance Survey
  National Grid point (*Grid reference - Easting/Northing*). When
  present it is written next to the sidecar as a GeoJSON `Point` in
  OSGB36 **EPSG:27700**, recorded on `geometry_path` (relative to the
  cache root) / `geometry_crs`. The raw grid reference and the portal’s
  WGS84 *GPS co-ordinates* string are also surfaced as extras.
- **Filters (client-side).** `query` is a case-insensitive substring
  match on the project name; `status` matches the project *Stage*
  (e.g. `"Examination"`, `"Withdrawn"`); `date_range` is matched against
  `date_decision` when present, otherwise `date_published` (the
  application-accepted date).
- **Throttle:** 0.1 requests/second by default — one request every 10 s,
  to honour the portal’s `robots.txt` `Crawl-delay: 10`
  (`getOption("planscanR.gb_throttle_rate")`). The package’s neutral
  `planscanR/…` User-Agent is allowed by the portal’s `robots.txt`,
  which blocks AI-crawler agents (ClaudeBot / GPTBot / CCBot) with
  `Disallow: /`.
- **Language:** English (ISO-639-1 `en`); no normalisation.

``` r

# Recent NSIP applications (no PDFs downloaded yet)
get_assessments_gb(limit = 5, download = FALSE)

# Substring query on the project name
get_assessments_gb(query = "solar", limit = 20, download = FALSE)
```

## Italy — `"it"`

- **Portal:** the *Ministero dell’Ambiente e della Sicurezza Energetica*
  (MASE) portal **Valutazioni e Autorizzazioni Ambientali**,
  [va.mite.gov.it](https://va.mite.gov.it/), a server-rendered HTML
  register (no JSON API).
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported (VIA/VAS dual register; HTML scrape; no geometry)"`).
- **Authentication:** none (anonymous public register).
- **Dual register (`assessment_type`).** Two adjacent registers are
  merged into one result tibble, tagged by `assessment_type` (`"EIA"` /
  `"SEA"`) and `register` (`"VIA"` / `"VAS"`):
  - **VIA** — *Valutazione di Impatto Ambientale* (project-level EIA),
    `…/it-IT/Ricerca/ViaProcedura`; `document_id` prefix `VIA-`.
  - **VAS** — *Valutazione Ambientale Strategica* (plan/programme SEA),
    `…/it-IT/Ricerca/VasProcedura`; `document_id` prefix `VAS-`. Pass
    `assessment_type = "All"` (default), `"EIA"`, or `"SEA"` to select
    which register(s) to crawl. The numeric `…/it-IT/Oggetti/Info/{id}`
    is the record id.
- **HTML pagination.** Each register’s search listing paginates via a
  1-based `?pagina=N` query parameter; the page footer carries a
  `"Pagina X di Y"` counter that bounds the crawl. Each row gives the
  project/plan title, the proponent, the procedure type, an *Info*
  detail link, and a *Doc* documentation link.
- **Detail (Info + Documentazione).** Per record (sidecar-first) the
  handler reads the Info page `…/it-IT/Oggetti/Info/{id}` (its
  `<strong>Label</strong>: value` paragraphs and a procedure-timeline
  table for the start date, decree date, status, and *Esito* / outcome),
  then the documentation index
  `…/it-IT/Oggetti/Documentazione/{id}/{grp}`.
- **Attachments — direct PDFs grouped by *Sezione*.** Each documentation
  row carries a *Sezione* (category) and a direct, public download link
  `https://va.mite.gov.it/File/Documento/{fileId}` (the server returns
  `application/pdf`; no authentication). PDFs are grouped by *Sezione*
  into per-section `attachment_urls_<slug>` columns (the same pattern as
  Germany), plus the deduplicated union in `attachment_urls`.
- **No geometry.** Location is published only as named Italian text
  lists — *Regioni* / *Province* / *Comuni* — surfaced as the `regions`,
  `provinces`, and `municipalities` extras (Italian text kept verbatim).
  No coordinate geometry is available.
- **Competent authority.** Fixed to *Ministero dell’Ambiente e della
  Sicurezza Energetica* (MASE), the national ministry that runs the
  register.
- **Filters (client-side).** `query` is a case-insensitive substring
  match on the record title; `date_range` is matched against
  `date_published` (the procedure’s *Data avvio* / start date). The
  portal’s own Procedura / free-text search is server-side, but
  client-side filtering is sufficient for v0.1.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.it_throttle_rate")`). The VIA register is large
  (~10 600 projects across ~1 060 listing pages), so a `limit` is
  recommended for exploratory runs; VAS is far smaller (~270 plans).
- **Language:** Italian (ISO-639-1 `it`); portal-native values kept
  verbatim.

``` r

# Recent VIA/VAS records (no PDFs downloaded yet)
get_assessments_it(limit = 5, download = FALSE)

# SEA (VAS) register only
get_assessments_it(assessment_type = "SEA", limit = 10, download = FALSE)
```

## Slovakia — `"sk"`

- **Portal:** the Slovak EIA/SEA central information system
  **enviroportal.sk**, [enviroportal.sk](https://www.enviroportal.sk/),
  a React single-page app served by a Symfony **API Platform** JSON
  backend.
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported (API Platform JSON; EIA/SEA via zbierka; no geometry)"`).
- **Authentication:** none (anonymous public register).
- **Plain JSON, no browser.** Although the site is a SPA, the handler
  talks to the JSON API directly with `httr2` plus the
  `Accept: application/ld+json` content-negotiation header — no headless
  browser is involved.
- **Single mixed register (`assessment_type`).** The portal exposes one
  `eia_projects` collection that mixes project-level EIA and
  plan/programme SEA records. The discriminator is the `zbierka` (law
  collection) string, which contains either *časť EIA* or *časť SEA*.
  Each record is tagged with an `assessment_type` column (`"EIA"` /
  `"SEA"`); `register` is the raw collection label `"eia_projects"`;
  `document_id` is the globally-unique numeric portal `id`, prefixed
  `SK-`. Pass `assessment_type = "All"` (default), `"EIA"`, or `"SEA"`
  to filter client-side.
- **List — array-of-arrays flatten + paginate-until-empty.** The list
  endpoint is `GET /api/eia_projects?page=N`. Its `hydra:member` is an
  **array of arrays** — a bucket of record objects, a
  pagination-metadata object, and (sometimes) an empty bucket — so the
  handler flattens one level and keeps only the objects carrying a
  `seoId`. Because `hydra:totalItems` / `hydra:view` are unreliable or
  absent, the generator paginates `page = 1, 2, 3, …` until a page
  flattens to zero records.
- **Detail.** Per record (sidecar-first) the handler reads
  `GET /api/eia_projects/{seoId}`, which carries the full field set:
  `name` (title), `ucel` (purpose → summary), `navrhovatel$name`
  (proponent), `prislusnyOrgan$name` (competent authority, trimmed),
  `stav` (status), `proces` (process), `kraj` / `okres` / `obec` (region
  / district / municipality), and the `dokumenty` documents object.
- **Attachments — PDFs grouped by procedural step.** `dokumenty$data` is
  an array of step groups (`{step, number, items}`); each `items[]`
  element is either a document group or a plain text field. The handler
  walks every downloadable leaf and absolutises its `/eia/dokument/{id}`
  `url` to `https://www.enviroportal.sk/eia/dokument/{id}`, grouping the
  URLs by the `step` (phase) name into per-section
  `attachment_urls_<slug>` columns (the same pattern as Germany /
  Italy), plus the deduplicated union in `attachment_urls`.
- **No geometry.** The portal exposes only named region / district /
  municipality text (surfaced as the `region`, `district`,
  `municipality`, and `affected_municipality` extras, Slovak verbatim).
  No coordinate geometry is available.
- **Canonical URL.** The human SPA detail page
  `https://www.enviroportal.sk/eia/detail/{seoId}` is used as the
  canonical `url` (the cache key); the API detail path is
  `/api/eia_projects/{seoId}`.
- **Filters (client-side).** `assessment_type` (from `zbierka`), `query`
  (a case-insensitive substring of the title), and `date_range` (against
  `date_published`, the date part of *datumPoslednejZmeny*) are all
  matched in R after the list is fetched.
- **Throttle:** 5 requests/second by default
  (`getOption("planscanR.sk_throttle_rate")`). The register is large
  (~18 700 records across ~940 pages), so a `limit` is recommended for
  exploratory runs.
- **Language:** Slovak (ISO-639-1 `sk`); portal-native values kept
  verbatim.

``` r

# Recent records (no PDFs downloaded yet)
get_assessments_sk(limit = 5, download = FALSE)

# SEA records only
get_assessments_sk(assessment_type = "SEA", limit = 10, download = FALSE)
```

## Norway — `"no"`

- **Portal:** the NVE (*Norges vassdrags- og energidirektorat*,
  Norwegian Water Resources & Energy Directorate) concession-case
  register (`konsesjonssaker`),
  [nve.no](https://www.nve.no/konsesjon/konsesjonssaker). Each case is
  an energy/water concession application that carries the application,
  the *konsekvensutredning* (EIA), and the hearing documents as
  downloadable PDFs.
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported (NVE energy/water concession cases; EIA docs by filename; no geometry)"`).
- **Authentication:** none (anonymous public register).
- **Plain JSON + HTML, no browser.** The handler talks to NVE’s JSON
  list API and the server-rendered detail HTML directly with `httr2` —
  no headless browser is involved.
- **List — getall JSON + `pageNumber` pagination.** The list endpoint is
  `GET /umbraco/api/license/getall?caseType=00&county=00&filterText=&municipality=00&pageNumber=N`.
  Its `Licenses` array carries the case records (25–10 per page); the
  `Counties` / `Municipalities` / `CaseTypes` / `LicenseStatuses` keys
  are filter-vocab facets returned inline, and `TotalCount` is the
  unfiltered count. The defaults
  `caseType=00&county=00&municipality=00&filterText=` mean “all”. The
  generator paginates `pageNumber = 1, 2, …` until a page returns no
  `Licenses`.
- **Single concession register (no `assessment_type`).** NVE publishes
  one concession-case register; there is no EIA/SEA split, so there is
  no `assessment_type` argument — every case carries the EIA documents.
  `document_id` is the numeric `SoknadId`, prefixed `NVE-`.
- **Detail — server-rendered HTML.** Per record (sidecar-first) the
  handler reads
  `https://www.nve.no/konsesjon/konsesjonssaker/konsesjonssak?id={SoknadId}&type={Type}`,
  which renders the case documents in one or more `div.n-filelist`
  sections.
- **Attachments — PDFs grouped by section heading.** Each
  `div.n-filelist` section has an `<h2>` heading and a list of links to
  downloadable PDFs at
  `https://webfileservice.nve.no/API/PublishedFiles/Download/<saksnummer>/<fileId>`
  (and a UUID variant `.../Download/<uuid>/<saksnummer>/<fileId>`). The
  handler scrapes those links and groups the URLs by the section heading
  into per-section `attachment_urls_<slug>` columns (the same pattern as
  Germany / Italy / Slovakia), plus the deduplicated union in
  `attachment_urls`. EIA documents are **not** type-flagged — every case
  document is collected, and the document label (the link’s `<h3>`) is
  kept verbatim so the *konsekvensutredning* / *KU* / *melding* can be
  identified by filename downstream.
- **No geometry.** NVE’s spatial concession layers live in a separate
  keyed ArcGIS service that is out of scope for this handler in v0.1.
- **Conventional columns + extras.** `title` ← Tittel, `proponent` ←
  Tiltakshaver, `competent_authority` is the constant
  `"Norges vassdrags- og energidirektorat (NVE)"`, `native_type` /
  `status` from Sakstype / Status. Norwegian-verbatim extras: `county`
  (Fylke), `municipality` (Kommune), `case_type` (Sakstype),
  `case_type_id` (SakstypeID), `case_type_code` (Type), `stage`
  (Stadium), `progress` (Fremdrift), `hearing_deadline`
  (HoeringsfristText), `mw`, `gwh`, `installed_effect`,
  `estimated_production`.
- **Filters.** `query` is forwarded **server-side** as the API
  `filterText` parameter (the getall API matches it and returns a
  filtered list); `date_range` is matched client-side against
  `date_published` (the case `Dato`). The getall API also accepts
  server-side `caseType` / `county` / `municipality` filters via the
  facet codes returned inline, documented for reference but not
  first-class in v0.1.
- **Throttle:** ~20 s between requests (0.05 requests/second) by
  default, honouring NVE’s `robots.txt` `Crawl-delay: 20` —
  intentionally conservative. Override via
  `getOption("planscanR.no_throttle_rate")` (requests/sec).
- **Language:** Norwegian (ISO-639-1 `no`); portal-native values kept
  verbatim.

``` r

# Recent concession cases (no PDFs downloaded yet)
get_assessments_no(limit = 5, download = FALSE)

# Wind-themed slice (server-side filterText)
get_assessments_no(query = "vind", limit = 20, download = FALSE)
```

## Latvia — `"lv"`

- **Portal:** the Environmental State Bureau (*Vides pārraudzības valsts
  birojs*) register at [eva.gov.lv](https://www.eva.gov.lv/), a
  server-rendered Drupal site.
- **Status:** supported (`get_assessments_coverage()$status` =
  `"supported (metadata-only EIA register — documents via discovery; SEA opinions/decisions carry direct PDFs)"`).
- **Authentication:** none (anonymous public register).
- **Plain HTML, no browser.** The handler talks to the Drupal HTML pages
  directly with `httr2` — no headless browser is involved.
- **Asymmetric dual register.** The portal exposes two structurally
  *different* halves, unioned via the `assessment_type` argument
  (`"All"` / `"EIA"` / `"SEA"`):
  - **EIA — *Ietekmes uz vidi novērtējums* (project-level EIA).** A
    Drupal Views listing at
    `https://www.eva.gov.lv/lv/ietekmes-uz-vidi-novertejumu-projekti?page=N`.
    The `page` parameter is **0-indexed** (~20 records per page). The
    portal’s exposed-form filters are POST/AJAX (a GET `?combine=` is
    ignored), so the handler does a **full crawl** `?page=0,1,2,…`,
    stopping when a page yields no records. Each row links to a
    per-project detail page (sidecar-first).
  - **SEA — *Stratēģiskais IVN* (plan/programme SEA).** Three flat
    sub-pages — `/lv/atzinumi` (opinions), `/lv/lemumi` (decisions),
    `/lv/monitorings` (monitoring). Each is a year-grouped HTML table
    (no pagination, no detail pages) whose rows carry a direct PDF link,
    a document number, a date, and the planning-document title.
- **Attachments — EIA metadata-only / SEA direct PDFs.** This is the key
  asymmetry:
  - EIA detail pages carry metadata (IVN Statuss, proponent, decision
    year, location prose, a short description) but **no downloadable
    document attachments** — decisions are referenced as prose/numbers.
    Every EIA record therefore has an empty `attachment_urls`; its
    documents are filled in downstream by
    [`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md)
    (`discover = TRUE`).
  - SEA sub-page rows each link to a public PDF at
    `https://www.eva.gov.lv/lv/media/{id}/download?attachment` (no
    authentication; the server returns `application/pdf`). One
    attachment per SEA record.
- **No geometry.** The portal exposes location only as Latvian prose
  (cadastral numbers, parishes, municipalities), surfaced for EIA
  records in the `location` extra column. No coordinate geometry is
  available.
- **Registers tagged + prefixed.** An `assessment_type` column (`"EIA"`
  / `"SEA"`) and a `register` column (`"ivn-projekti"` for EIA;
  `"atzinumi"` / `"lemumi"` / `"monitorings"` for SEA) tag each row.
  `document_id` is prefixed per register (`IVN-` / `ATZ-` / `LEM-` /
  `MON-`) so the halves never collide on disk.
- **Conventional columns + extras.** `competent_authority` is the
  constant `"Vides pārraudzības valsts birojs"`. Latvian-verbatim
  extras: `location` (EIA cadastral / parish text) and `decision` (the
  EIA decision text or the SEA document number).
- **Filters.** `assessment_type` selects which half to crawl; `query` is
  a case-insensitive substring on the title, and `date_range` is matched
  client-side against `date_published` / `date_decision`. All filtering
  is **client-side** — the portal’s own exposed-form filters are
  POST/AJAX and not honoured.
- **Throttle:** 5 requests/second by default; override via
  `getOption("planscanR.lv_throttle_rate")` (requests/sec).
- **Language:** Latvian (ISO-639-1 `lv`); portal-native values kept
  verbatim.

``` r

# Recent records across both halves (no PDFs downloaded yet)
get_assessments_lv(limit = 5, download = FALSE)

# SEA only — the three flat sub-pages, with direct PDFs
get_assessments_lv(assessment_type = "SEA", limit = 10, download = TRUE)
```

## Spain — `"es"`

- **Portal:** the MITECO/SABIA *Consulta pública de evaluaciones
  ambientales* on the electronic headquarters at
  [sede.miteco.gob.es](https://sede.miteco.gob.es/), a server-rendered
  Liferay portal driven entirely by POST forms.
- **Requires the optional
  [chromote](https://rstudio.github.io/chromote/) headless browser.**
  This is the one handler in the package that cannot run on a pure-R
  install. The SABIA portal *TLS-fingerprints* the client and resets
  `libcurl`’s TLS handshake before any HTTP is exchanged, so `httr2`
  cannot reach it at all. `planscanR` therefore drives a real headless
  Chrome through the optional
  [chromote](https://rstudio.github.io/chromote/) package (in
  `Suggests`): it navigates to the portal origin — clearing the TLS gate
  and establishing the Liferay session cookie the way a real browser
  would — and then runs the portal’s own in-page requests so they ride
  Chrome’s TLS stack and cookies. All parsing still happens in R. If
  [chromote](https://rstudio.github.io/chromote/) or a Chrome/Chromium
  binary is unavailable the handler aborts up front with an actionable
  message; install [chromote](https://rstudio.github.io/chromote/) and
  Google Chrome (or point `options(planscanR.chrome_path=)` / the
  `CHROMOTE_CHROME` environment variable at a Chrome binary) to enable
  it.
- **National competence only.** Most Spanish EIA is decided by the
  autonomous communities and lives in their regional registers, which
  are out of scope here. SABIA covers the national-competence
  procedures.
- **Dual register (SABIA).** Selected with the `assessment_type`
  argument (`"All"` / `"EIA"` / `"SEA"`): **EIA** = *Evaluación de
  Impacto Ambiental de proyectos* via the `navServicioContenido` origin
  (`register = "proyectos"`); **SEA** = *Evaluación Ambiental
  Estratégica de planes y programas* via the `navSabiaPlanes` origin
  (`register = "planes"`). An `assessment_type` column tags each row;
  `document_id` is prefixed `EIA-` / `SEA-`.
- **Enumeration — one bulk POST.** Per register, the handler opens the
  origin, harvests the per-session `datosPropios` token from the search
  form, and issues a single `accion=proy_resultados` POST whose response
  carries `<table id="tablaResultados">` with every record (expediente
  code, title, *estado de tramitación*).
- **Attachments — ficha PDFs, downloaded in-session.** Each record’s
  documents (DIA / EsIA / resolución / BOE) are reached through the
  *Acceso a la Documentación* panel (`<table id="tablaDocumentos">`),
  grouped by *Tipo de documento*. The portal’s document URLs are
  **session-bound and ephemeral** (and the PDFs are on the same
  TLS-walled host), so `attachment_urls` stores a stable synthetic
  identity per document and, when `download = TRUE`, the bytes are
  pulled in-session through the browser.
- **No geometry.** SABIA exposes no public per-record geometry.
- **Filters:** `assessment_type`; `query` (free-text title, sent into
  the server-side *Buscador* `<Titulo>` filter and re-checked
  client-side); `codigo` (exact expediente code, server-side
  `<Codigo>` + client-side); `date_range` client-side; `limit`.
- **Language:** Spanish (ISO-639-1 `es`); portal-native values kept
  verbatim.

``` r

# Requires {chromote} + a Chrome/Chromium binary.
get_assessments_es(limit = 5, download = FALSE)

# SEA only (the planes register)
get_assessments_es(assessment_type = "SEA", limit = 10, download = FALSE)

# Title substring + download the national-competence PDFs through the browser
get_assessments_es(query = "eólica", limit = 5, download = TRUE)
```

## Adding a new source

Adding a handler for another national portal is a matter of writing one
`get_assessments_<cc>()` that returns a tibble with the planscanR
required columns (`country`, `source_portal`, `document_id`, `url`,
`retrieved_at`, `attachment_urls`, `local_path`) and wiring it into the
dispatcher in
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md).
If you have a portal in mind, open an issue describing what it exposes
(sitemap? search? open JSON?) and we can sketch out a handler.
