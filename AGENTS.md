# AGENTS.md — planscanR project orientation

Written for AI agents and human contributors landing in the repo cold.
For the family-level picture (dependency direction, the sidecar-schema
contract shared across all three packages), see the parent-folder
`CLAUDE.md`.

## 1. What this package is

`planscanR` is an R package that provides a single, unified R API
([`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md))
for fetching environmental-assessment records (EIA, SEA, follow-up
advice) from European national portals — modelled on
[`aloftdata/getRad`](https://github.com/aloftdata/getRad). It is pure-R:
no Python, no Shiny, no project-specific scoring config.

**v0.1 scope.** Twenty-two country handlers ship: - Netherlands
([`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md))
— Commissie m.e.r. adviezenregister at `commissiemer.nl`. - Germany
([`get_assessments_de()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_de.md))
— UVP-Verbund federated portal at `uvp-verbund.de`. - France
([`get_assessments_fr()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_fr.md))
— national Projets-Environnement portal at
`projets-environnement.gouv.fr`, backed by a public **OpenDataSoft
Explore API v2.1** (a documented anonymous REST+JSON service — the
cleanest backend in the family). One export call enumerates the whole
flat dataset (~5,483 records, every field inline; no detail call).
Server-side ODSQL `where` filters: `query`
([`search()`](https://rdrr.io/r/base/search.html)), `theme`
(`dc_subject_theme`), `native_type` (`dc_type`), `status` (`vp_status`),
`date_range` (`dc_date`). Attachments come from a fixed set of typed
`dc_relation_*` fields mapped to curated slugs (`etude_impact`,
`resume_non_technique`, `avis_ae`, `reponse_avis_ae`, `dossier`, …),
restricted to real SICODEI document URLs (external préfecture HTML pages
are dropped). Records with a `localisation` Feature get a
`<document_id>.geometry.geojson` in **EPSG:4326** (WGS84; ODS always
serves 4326). - Denmark
([`get_assessments_dk()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_dk.md))
— Danmarks Miljøportal EA-Hub at `eahub.miljoeportal.dk`.
**Metadata-only** in v0.x (records carry full metadata + polygon
geometry; document downloads deferred). Geometry is persisted as
`<document_id>.geometry.geojson` next to the sidecar (EPSG:25832). -
Belgium (Flanders)
([`get_assessments_be()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_be.md))
— Departement Omgeving MER-register at
`merregister.omgeving.vlaanderen.be`. Project-MER and
ontheffingsaanvragen only (Plan-MER is a separate Flemish register).
Full metadata, polygon geometry (EPSG:31370, persisted in the same
GeoJSON layout as DK), and direct anonymous document downloads. The
geometry sidecar’s CRS is the only thing that distinguishes it from a DK
file. - Estonia
([`get_assessments_ee()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_ee.md))
— Keskkonnaamet KOTKAS at `kotkas.envir.ee`. Merges both Estonian
registers — **KMH** (EIA) and **KSH** (SEA) — into one result tibble;
each row carries an `assessment_type` column (`"EIA"` / `"SEA"`) and
`document_id` is prefixed `"KMH-"` / `"KSH-"` so the two registers never
collide on disk. Server-rendered (jQuery / Bootstrap) portal: index
pages paginate via a numeric `qs=` offset, detail pages are scraped with
`rvest`. Detail records carry an inline GeoJSON geometry (hidden form
input) in **EPSG:3301** (L-EST97), persisted as
`<document_id>.geometry.geojson` next to the sidecar in the same layout
as DK / BE. Direct anonymous document downloads, grouped per `Liik`
(document type) into `attachment_urls_<slug>` columns dynamically. -
Finland
([`get_assessments_fi()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_fi.md))
— the national environmental-administration site `ymparisto.fi`.
**EIA/YVA only** (no SOVA/SEA content type in the register;
`yva_project` is the only project type, so `assessment_type` accepts
only `"All"` / `"EIA"`). **Hybrid** handler: a JSON Elasticsearch-proxy
listing call (`POST .../fi/app/search/query`, raw ES Query DSL,
from/size paging filtered to `type=yva_project`) supplies all metadata,
then a per-record HTML landing-page fetch scrapes the attachment URLs
(absent from the index) from `<a href>` under `/sites/default/files/`,
typed from anchor text via a curated keyword map + auto-slug fallback.
The detail fetch runs even when `download = FALSE` (to populate
`attachment_urls`), skipped sidecar-first. Anonymous PDF downloads. **No
geometry.** Throttled to 5 req/s by default. Two network seams
(`fi_es_search`, `fi_fetch_detail`) mocked independently in tests. -
Bulgaria
([`get_assessments_bg()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_bg.md))
— Ministry of Environment and Water (МОСВ) registers at
`registers.moew.government.bg`. Merges both registers — **ОВОС** (EIA)
and **ЕО** (SEA) — into one result tibble; each row carries an
`assessment_type` column (`"EIA"` / `"SEA"`) and `document_id` is
prefixed `"OVOS-"` / `"EO-"` so the two registers never collide on disk.
Server-rendered (ASP.NET MVC) portal: listings paginate via
`?offset=<n>&limit=<k>`, detail pages (`/ovos/lot/<id>`, `/eo/lot/<id>`)
are scraped with `rvest` from a nested row-group `table.table-lot`. **No
geometry** (location is administrative text only). Direct anonymous
document downloads (`/ovos/file?fileKey=...&fileName=...`; the
`fileName` param is required, so the full href is kept verbatim),
grouped per row label into `attachment_urls_<slug>` columns dynamically
(Bulgarian labels transliterated to ASCII). Throttled to 2 req/s by
default (`getOption("planscanR.bg_throttle_rate")`). - Czech Republic
([`get_assessments_cz()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_cz.md))
— CENIA *Informační systém EIA/SEA* at `portal.cenia.cz/eiasea`.
**Domestic CZ only**: merges just the two in-scope registers —
`eia100_cr` (*Záměry na území ČR*, EIA) and `SEA100_koncepce`
(*Posuzování koncepcí*, SEA) — into one result tibble and **never**
crawls the cross-border / foreign (`eia100_mimo_cr`,
`sea100_mezistatni`) or special sub-registers (`eia100_podlimitni` /
`_pdz` / `_vzvp` / `eia244`, `sea100_pur*` / `zur*` / `up*`);
ministry-coded records (`EIA_MZP*` / `SEA_MZP*`) inside the two domestic
registers stay in scope. Each row carries an `assessment_type` column
(`"EIA"` / `"SEA"`) and `document_id` is the register-namespaced detail
code (`"EIA_JHC1237"`, `"SEA_HKK015K"`) so the two never collide on
disk. Server-rendered (JSP / Tomcat) portal: listings paginate via a
1-based `?p=<n>` query (out-of-range pages clamp to the last page, so
stop when a page adds no new codes), detail pages
(`/eiasea/detail/EIA_<CODE>`, `/eiasea/detail/SEA_<CODE>`) are scraped
with `rvest` from a `table.detail` of label/value rows interspersed with
bold stage headings. **No geometry** (location is administrative text
only: Kraj / Okres / Obec / Katastr). Direct anonymous document
downloads (`/eiasea/download/<token>/<file>`; token + filename kept
verbatim from the href), grouped per process stage into
`attachment_urls_<slug>` columns (Czech labels transliterated to ASCII);
some attachments are very large ZIPs, bounded by `max_file_size_mb`.
Throttled to 2 req/s by default
(`getOption("planscanR.cz_throttle_rate")`). - Croatia
([`get_assessments_hr()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_hr.md))
— Ministry of Environment and Green Transition CMS pages at
`mzozt.gov.hr`. **No API / no machine-readable register**: the register
is a small set of server-rendered ASP.NET CMS pages where each procedure
is an inlined
`<li><strong>TITLE</strong> <ul>...document links...</ul></li>` block.
The handler fetches the master page(s) once and parses each block as one
record — no pagination, no per-record detail endpoint. Merges both
registers — **PUO** (EIA) and **SPUO** (SEA) — into one result tibble;
each row carries an `assessment_type` column (`"EIA"` / `"SEA"`). No
native id: `document_id` is a stable SHA-1 hash of the title
(`HR-PUO-<hash>` / `HR-SPUO-<hash>`, year folded in) and `url` is the
master-page URL plus `#<document_id>` for a unique landing URL. **No
geometry** (spatial info is inside the PDFs; a county/grad is
heuristically pulled from the title into `jurisdiction`). Direct
anonymous `.pdf` / `.zip` downloads grouped by stage sub-heading into
`attachment_urls_<slug>` columns via a DE-style curated-map + auto-slug
fallback (Croatian diacritics transliterated to ASCII; flat SPUO docs
fall under `document`); the original href (with spaces / diacritics) is
kept verbatim and percent-encoded only at download time. Filters:
`assessment_type`, a client-side `query` title substring, and
client-side `date_range`. Throttled to 5 req/s by default
(`getOption("planscanR.hr_throttle_rate")`). - Greece
([`get_assessments_gr()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_gr.md))
— ΗΠΜ / EPRM JSON:API at `api.eprm.ypen.gr` (SPA landing at
`eprm.ypen.gr`, robots-disallowed for crawling, used only as the human
`url`). **AEPO decisions only**: the public registry exposes *Αποφάσεις
Έγκρισης Περιβαλλοντικών Όρων* (the regulatory output of the EIA / ΜΠΕ
process); the underlying ΜΠΕ study files and **all ΣΜΠΕ / SEA records
are behind the gov.gr login** and are not fetchable, so each record is a
decision (metadata + at most one decision PDF) and SEA is out of scope.
Public, no-auth JSON:API (`Accept: application/json`): listing
`GET /v1/license-decisions` paginates JSON:API-style (`page[number]`
1-based, `page[size]`) and **each row is already the full record** (no
detail call). `document_id` is the registry `id`. Server-side filters:
`query` (`filter[text_search]`), `type` (`filter[type]`, decision-type
enum), and `date_range` (`filter[issued_after]` /
`filter[issued_before]`, on the issue date). One attachment per decision
— the AEPO PDF from `diavgeia_doc_url` (hosted on Διαύγεια / Diavgeia) —
under `attachment_urls_aepo`; a null `diavgeia_doc_url` yields zero
attachments. Records with a `project_location` get a sibling
`.geometry.geojson` **Point** in **EPSG:4326** (WGS84 lat/lon — *not*
the Greek Grid EPSG:2100). Record language is Greek (`el`; country code
`gr` differs). Throttled to 5 req/s by default
(`getOption("planscanR.gr_throttle_rate")`). Reflected in
`get_assessments_coverage()$status` as
`"supported (decisions-only; studies/SEA login-gated)"`. - Iceland
([`get_assessments_is()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_is.md))
— **Skipulagsgátt** (Skipulagsstofnun) at `skipulagsgatt.is`; the
package’s **first GraphQL backend** (anonymous `POST .../graphql`, body
`{"query", "variables"}`, parsed via `perform_json`; single network seam
`is_graphql()`). **Coverage horizon: cases from ~June 2023 onward only**
(the dead `skipulag.is` DB is not crawled). Three `Issue` processes
selected by `processId`, merged + tagged via `assessment_type`: `15`
(matsskylda screening) + `16` (full EIA) → `"EIA"`, `501` (umhverfismat
áætlana) → `"SEA"`; `assessment_type` arg picks the loop; `document_id`
prefixed `IS-<processId>-<id>`. Listing = `issueConnection` cursor
connection (`after: endCursor`); detail = `singleIssue(issueId)`,
sidecar-first. Status from the plain `lifecycle` field — the
`issueStatus` enum is **not** requested (server-side serialization bug
500s the whole query on some records). Server-side filters: `query`
(GraphQL `search`), `date_range` (`fromDate`/`toDate`). Attachments from
`phases[].files[]` (published only), grouped by role into
`attachment_urls_almennt` / `_vidbrogd` / `_afgreidsla`; URLs
`https://www.skipulagsgatt.is/files/<uuid>`. `hasGeography` records get
a sibling `.geometry.geojson` in **EPSG:4326** (WGS84 lon/lat — *not*
projected ISN93); the per-feature geometry is a GeoJSON **string**
needing a second parse. Record language Icelandic (`is`). Throttled to 5
req/s by default (`getOption("planscanR.is_throttle_rate")`). Reflected
in `get_assessments_coverage()$status` as
`"supported (GraphQL; cases from ~June 2023 onward)"`. - Ireland
([`get_assessments_ie()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_ie.md))
— **gov.ie EIA Portal** at `services.arcgis.com` (the
`EIA_Location_Point` master layer); the package’s **first ArcGIS REST
backend** (anonymous `GET .../query?f=json`, parsed via `perform_json`;
single network seam `ie_arcgis_get(path, query)`). **EIA only — no
SEA.** **Portal hosts only the newspaper / public-notice PDF; the full
EIAR is off-portal** on the competent-authority sites, surfaced as the
`url_link_application` / `url_link_secondary` extras (kept out of
`attachment_urls` — a discovery target). **`OBJECTID_1` gotcha:** the
layer’s unique id field is `OBJECTID_1`, not the non-unique `OBJECTID`;
attachment lookups + the id fallback key off it, while `document_id` is
the `Portal_Ref`. Listing = paginated `query`
(`resultOffset`/`resultRecordCount`, page 1000, loop while
`exceededTransferLimit`); metadata is inline in `attributes` (no detail
endpoint); the synthetic `url` is a record-specific query on
`Portal_Ref` (no permalink). Server-side filters: `query`
(`UPPER(Description...) LIKE`), `competent_authority` (equality),
`date_range` (`Date_of_receipt_of_application_` epoch-ms BETWEEN).
Notice-PDF attachment URLs are resolved in a batched phase-2
`queryAttachments` (keyed by `OBJECTID_1`, needed even when
`download = FALSE`) and emitted under `attachment_urls_notice`. Esri
point geometry converted in-house to a GeoJSON Point and saved to a
sibling `.geometry.geojson` in **EPSG:2157** (Irish Transverse Mercator
— *not* reprojected). `Date_of_receipt_of_application_` is epoch
**milliseconds**. Record language English (`en`). Throttled to 5 req/s
by default (`getOption("planscanR.ie_throttle_rate")`). Reflected in
`get_assessments_coverage()$status` as
`"supported (EIA only; portal = notice PDFs, full EIAR off-portal)"`. -
Slovenia
([`get_assessments_si()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_si.md))
— **gov.si** environmental-assessment registers under
`…/okoljske-presoje/`. **Bulk-export enumeration**: each register is one
JSON GET (`<list>/export/json/`) returning the whole unpaginated array
(single network seam `si_fetch_search(register)`, parsed via
`perform_json`). **Dual-register** (`assessment_type` `"All"`/`"EIA"`/
`"SEA"`): EIA screening `predhodni-postopek` (`document_id` prefix
`PRED-`) vs. two SEA/CPVO registers — state plans `cpvo-drzavni`
(`CPVO-DRZ-`) and municipal plans `cpvo-obcinski` (`CPVO-OBC-`). Field
maps differ per register (screening:
`Poseg`/`Datum objave`/`Naziv`/`Naslov`/`Številka zadeve`/
`Oznaka posega`; CPVO: `Title`/`Naziv`/`Datum`/`Odločitev`). Export ids
don’t map to filenames, so attachments are scraped from each detail page
(sidecar-first; seam `si_fetch_attachments(url)`):
`a[href^="/assets/seznami/"]` absolutised against `https://www.gov.si`,
flat `attachment_urls` (no sections; may be empty). No geometry.
`competent_authority` fixed to *Ministrstvo za okolje, podnebje in
energijo*. `date_published` parses `"DD. MM. YYYY"`; `date_decision`
always `NA`; `date_range` matched client-side. Record language Slovenian
(`sl`). Throttled to 5 req/s
(`getOption("planscanR.si_throttle_rate")`). Scope ~2021 onward.
Reflected in `get_assessments_coverage()$status` as `"supported"`. -
Portugal
([`get_assessments_pt()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_pt.md))
— APA **SIAIA** register at `siaia.apambiente.pt` (server-rendered
ASP.NET MVC). **HTML-pagination enumeration**: a page generator walks
`?pagina=<n>` (~100 rows/page, seam `pt_fetch_search()`, parsed via
`perform_html`); an empty `<tbody>` ends the crawl. **Single register**
— AIA = project-level EIA only (no `assessment_type`); SEA/AAE lives in
a separate APA register and is out of scope. Per record: a sidecar-first
detail GET (`/ProcessoAIA/Detalhes/{id}`, `document_id` prefix `AIA-`)
parses the *Campo / Conteúdo* table, and a document-list GET
(`/ListaDocumentos?pro_id={id}`) yields the attachments. Direct
PDFs/ZIPs are `https://siaia.apambiente.pt/AIADOC/AIA{n}/...`; each
document’s Portuguese type label is classified into a coarse **phase**
(`dia` / `eia` / `consulta_publica` / `parecer` / `outros`) and grouped
into per-phase `attachment_urls_<slug>` / `local_path_<slug>` columns,
with `attachment_urls` the deduplicated union. Per-record **polygon
geometry** is captured from APA’s SNIAMB ArcGIS *ZoomToApp* service
(`sniambgeoext.apambiente.pt`, seam `pt_arcgis_get()`, `Referer`-gated,
queried `f=json&outSR=4326` with Esri rings → GeoJSON converted in-house
since the service’s `f=geojson` is broken): when the *Localização*
anchor resolves to a footprint it is saved as a sibling
`<document_id>.geometry.geojson` in **EPSG:4326** with `geometry_path` /
`geometry_crs` (both `NA` otherwise); the concelho text stays in
`municipalities`. This second host is throttled independently via
`getOption("planscanR.pt_geo_throttle_rate")` (default 5).
`decision_sense` (the *Sentido de Decisão*) is also the `native_type`.
`date_decision` parses `"DD/MM/YYYY"`; `query` and `date_range` are
matched client-side. Portuguese language. Throttled to 5 req/s
(`getOption("planscanR.pt_throttle_rate")`). Reflected in
`get_assessments_coverage()$status` as
`"supported (EIA/AIA only; SEA/AAE in a separate APA register)"`. -
United Kingdom
([`get_assessments_gb()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_gb.md))
— Planning Inspectorate’s **National Infrastructure Consenting**
register at `planninginspectorate.gov.uk`. **Bulk-CSV enumeration**: one
GET of `/api/applications-download` (≈540 rows) is the whole register
(seam `gb_fetch_search()`, parsed with base
[`utils::read.csv()`](https://rdrr.io/r/utils/read.table.html) — no new
dependency); the generator returns all rows once then NULL. **Single
register** — NSIP only (every NSIP carries a statutory Environmental
Statement, so it is an EIA source; no `assessment_type`; local-authority
EIAs out of scope). `document_id` is the *Project reference*
(e.g. `EN010001`); canonical URL `…/projects/{REF}`. Per record
(sidecar-first) a document-list GET
(`…/projects/{REF}/documents?type=Environmental Statement`) scrapes the
Environmental Statement PDF hrefs on
`nsip-documents.planninginspectorate.gov.uk/published-documents/...`
(flat `attachment_urls`, no section split). **Point geometry**: the
*Grid reference - Easting/Northing* is written to a sibling
`.geometry.geojson` (GeoJSON Point, OSGB **EPSG:27700**), with
`geometry_path` (relative) + `geometry_crs`. `query` / `status` /
`date_range` are matched client-side. English. Throttled to 0.1 req/s
(one request per 10 s, honouring the portal’s `robots.txt`
`Crawl-delay: 10`; the neutral `planscanR/…` UA is allowed where
AI-crawler UAs are `Disallow: /`); override via
`getOption("planscanR.gb_throttle_rate")`. Reflected in
`get_assessments_coverage()$status` as
`"supported (NSIP only; every NSIP carries an Environmental Statement)"`. -
Italy
([`get_assessments_it()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_it.md))
— MASE **Valutazioni e Autorizzazioni Ambientali** at `va.mite.gov.it`.
**HTML pagination**: each register’s search listing paginates via a
1-based `?pagina=N` query (seam `it_fetch_search()`, parsed with
`perform_html`); the page footer’s `"Pagina X di Y"` counter bounds the
crawl. **Dual-register** (`assessment_type` `"All"`/`"EIA"`/`"SEA"`):
VIA project EIA `Ricerca/ViaProcedura` (`document_id` prefix `VIA-`)
vs. VAS plan SEA `Ricerca/VasProcedura` (`VAS-`); the numeric
`Oggetti/Info/{id}` is the id. Per record (sidecar-first): the Info page
`/it-IT/Oggetti/Info/{id}` (`<p><strong>Label</strong>: value</p>`
fields + a procedure-timeline table for `date_published` /
`date_decision` / `status` / `outcome`) plus the Documentazione index
`/it-IT/Oggetti/Documentazione/{id}/{grp}` whose rows carry a *Sezione*
and a direct `/File/Documento/{fileId}` PDF link — grouped into
per-section `attachment_urls_<slug>` columns (DE pattern) + the
deduplicated union. The Info-page value reader strips `<!--…-->` comment
nodes before reading text (mirrors the EE comment-leak guard,
defensively). No geometry (location is *Regioni* / *Province* / *Comuni*
text, surfaced as the `regions` / `provinces` / `municipalities` extras,
Italian verbatim). `competent_authority` fixed to *Ministero
dell’Ambiente e della Sicurezza Energetica* (MASE). `query` (title
substring) and `date_range` matched client-side. Italian. Throttled to 5
req/s (`getOption("planscanR.it_throttle_rate")`); the VIA register is
large (~10.6k projects). Reflected in
`get_assessments_coverage()$status` as
`"supported (VIA/VAS dual register; HTML scrape; no geometry)"`. -
Slovakia
([`get_assessments_sk()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_sk.md))
— Slovak EIA/SEA central information system **enviroportal.sk** at
`enviroportal.sk`. **API Platform JSON** (a React SPA over a Symfony
backend), reached with pure `httr2` + the `Accept: application/ld+json`
content-negotiation header. **List**: `GET /api/eia_projects?page=N`
(seam `sk_fetch_search()`, parsed with `perform_json`); its
`hydra:member` is an **array of arrays** (a record bucket, a
pagination-metadata object, an empty bucket), so the handler flattens
one level and keeps the objects carrying a `seoId`. `hydra:totalItems` /
`hydra:view` are unreliable, so the generator **paginates until a page
flattens to zero records**. **Single mixed register** (`assessment_type`
`"All"`/`"EIA"`/`"SEA"`): the `zbierka` law string (`"časť EIA"` /
`"časť SEA"`) is the discriminator — each record is tagged and the
filter applied client-side; `register` is `"eia_projects"`;
`document_id` is the globally-unique numeric `id`, `SK-`-prefixed. The
canonical URL is the SPA page
`https://www.enviroportal.sk/eia/detail/{seoId}`; the detail JSON is
`/api/eia_projects/{seoId}` (sidecar-first). Attachments come from
`dokumenty$data` — an array of step groups (`{step, number, items}`);
every downloadable leaf’s `/eia/dokument/{id}` `url` is absolutised and
grouped by the `step` (phase) name into per-section
`attachment_urls_<slug>` columns (DE/IT pattern) + the deduplicated
union. `competent_authority` ← `prislusnyOrgan$name` (trimmed),
`proponent` ← `navrhovatel$name`; extras `law_collection`, `process`,
`region` (kraj), `district` (okres), `municipality` (obec),
`affected_municipality`, `locality`, `proponent_id` (ico). No geometry.
`query` (title substring) and `date_range` matched client-side. Slovak.
Throttled to 5 req/s (`getOption("planscanR.sk_throttle_rate")`); the
register is large (~18.7k records). Reflected in
`get_assessments_coverage()$status` as
`"supported (API Platform JSON; EIA/SEA via zbierka; no geometry)"`. -
Norway
([`get_assessments_no()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_no.md))
— NVE (*Norges vassdrags- og energidirektorat*) energy/water
concession-case register (`konsesjonssaker`) at `nve.no`. Plain JSON
list API + server-rendered detail HTML, reached with pure `httr2`.
**List**:
`GET /umbraco/api/license/getall?caseType=00&county=00&filterText=&municipality=00&pageNumber=N`
(seam `no_fetch_search()`, parsed with `perform_json`); its `Licenses`
array carries the case records (the
`Counties`/`Municipalities`/`CaseTypes`/ `LicenseStatuses` keys are
filter-vocab facets returned inline, `TotalCount` the unfiltered count).
The generator **paginates `pageNumber=1,2,…` until a page returns no
`Licenses`**. **Single concession register** (no `assessment_type` arg —
every case carries the EIA *konsekvensutredning* among its documents);
`document_id` is the numeric `SoknadId`, `NVE-`-prefixed. The canonical
URL is the detail page
`https://www.nve.no/konsesjon/konsesjonssaker/konsesjonssak?id={SoknadId}&type={Type}`
(sidecar-first). Attachments are scraped from the detail page’s
`div.n-filelist` sections —
`webfileservice.nve.no/API/PublishedFiles/Download/...` PDFs grouped by
the `<h2>` section heading into per-section `attachment_urls_<slug>`
columns (DE/IT/SK pattern) + the deduplicated union; EIA docs are
identified by filename, not a type flag. `competent_authority` is the
constant `"Norges vassdrags- og energidirektorat (NVE)"`; extras
`county` (Fylke), `municipality` (Kommune), `case_type` (Sakstype),
`case_type_id` (SakstypeID), `case_type_code` (Type), `stage` (Stadium),
`progress` (Fremdrift), `hearing_deadline` (HoeringsfristText), `mw`,
`gwh`, `installed_effect`, `estimated_production`. No geometry (NVE
ArcGIS is a separate keyed service). `query` is forwarded
**server-side** as the API `filterText` param; `date_range` matched
client-side. Norwegian. Throttled to 0.05 req/s (~20 s between requests,
honouring NVE’s `robots.txt` `Crawl-delay: 20`;
`getOption("planscanR.no_throttle_rate")`). Reflected in
`get_assessments_coverage()$status` as
`"supported (NVE energy/water concession cases; EIA docs by filename; no geometry)"`. -
Latvia
([`get_assessments_lv()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_lv.md))
— Environmental State Bureau (*Vides pārraudzības valsts birojs*) Drupal
portal at `eva.gov.lv`. Server-rendered HTML, reached with pure `httr2`.
**Asymmetric dual register** via `assessment_type`
(`"All"`/`"EIA"`/`"SEA"`). **EIA** = the Drupal Views listing
`https://www.eva.gov.lv/lv/ietekmes-uz-vidi-novertejumu-projekti?page=N`
(**0-indexed** `page`; seam `lv_fetch_eia()`; full crawl until an empty
page, ~20 rows/page); each `.views-row .node-catalog-item` links to a
per-project detail page that is **metadata-only** — it carries IVN
Statuss / proponent / decision-year + location/summary prose but **no
document attachments**, so EIA records leave `attachment_urls` empty and
documents are filled in downstream by
[`discover_attachments()`](https://barthoekstra.github.io/planscanR/reference/discover_attachments.md).
**SEA** = three flat sub-pages `/lv/atzinumi` (opinions), `/lv/lemumi`
(decisions), `/lv/monitorings` (monitoring) (seam `lv_fetch_sea()`),
each listing documents as **direct `/lv/media/{id}/download?attachment`
PDF links** (one attachment per record). `assessment_type` column
`"EIA"`/`"SEA"`; `register` column (`"ivn-projekti"` / `"atzinumi"` /
`"lemumi"` / `"monitorings"`); `document_id` prefixed per register
(`IVN-` / `ATZ-` / `LEM-` / `MON-`) so they never collide.
`competent_authority` is the constant
`"Vides pārraudzības valsts birojs"`; extras `location` (EIA cadastral /
parish prose) and `decision` (EIA decision text / SEA document number).
No geometry. `query` (title substring) and `date_range` are matched
**client-side** (the portal’s exposed-form filters are POST/AJAX).
Latvian. Throttled to 5 req/s
(`getOption("planscanR.lv_throttle_rate")`). Reflected in
`get_assessments_coverage()$status` as
`"supported (metadata-only EIA register — documents via discovery; SEA opinions/decisions carry direct PDFs)"`. -
Spain
([`get_assessments_es()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_es.md))
— MITECO/SABIA *Consulta pública de evaluaciones ambientales* at
`sede.miteco.gob.es`. **The only handler that cannot run on a pure-R
install:** the portal *TLS-fingerprints* the client and rejects
libcurl’s ClientHello before any HTTP, so it is reached **only** through
the optional [chromote](https://rstudio.github.io/chromote/)
headless-browser transport (`R/utils_browser.R`; `Suggests: chromote`).
The handler gates on `browser_available()` and aborts with class
`planscanR_error_browser_unavailable` (via `require_browser("es")`) when
the browser is absent — **degrade gracefully**. **National-competence
procedures only** (most Spanish EIA is regional → out of scope). **Dual
register** via `assessment_type` (`"All"`/`"EIA"`/`"SEA"`): EIA = the
`navServicioContenido` origin (`register = "proyectos"`), SEA = the
`navSabiaPlanes` origin (`register = "planes"`). One session per
register: `browser_open(origin)` → harvest `datosPropios` → a single
`accion=proy_resultados` `browser_fetch()` POST whose response carries
`<table id="tablaResultados">` (code / title / estado). The ficha PDFs
are reached by two in-page form submits (`browser_submit_form()`):
`proy_estado_tramitacion` then `listadoDocumentacion`, whose
`<table id="tablaDocumentos">` lists `BINARYPORTLET resource.process`
PDF links grouped by *Tipo de documento*. Those live URLs are
**session-bound and ephemeral**, so `attachment_urls` stores a stable
synthetic `<origin>#<code>/<NOMBRE_SABIA>` per document (grouped into
`attachment_urls_<slug>`); on `download = TRUE` the bytes are pulled
in-session via `browser_download()` (the PDFs are on the TLS-walled host
too). `document_id` prefixed `EIA-`/`SEA-`; `competent_authority` the
constant
`"Ministerio para la Transición Ecológica y el Reto Demográfico"`; extra
`expediente` (the code). No geometry. `query` → server-side `<Titulo>` +
client-side; `codigo` → server-side `<Codigo>` + client-side;
`date_range` client-side. Spanish. Throttled via
`getOption("planscanR.es_throttle_rate", 2)` (seconds between ficha
fetches). Coverage `status` =
`"supported (requires optional headless browser; TLS-fingerprinted portal)"`. -
Austria
([`get_assessments_at()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_at.md))
— Umweltbundesamt UVP-DB at `secure.umweltbundesamt.at/uvpdb`.
**Metadata-only**: the portal’s HTML pages and document attachments sit
behind a Keycloak login wall; only three open JSON service handlers
(`mapsdata`, `mapsgeom`, `vorhabenInfo`) expose record metadata
anonymously. The handler returns rich tibble rows but `attachment_urls`
and `local_path` are always empty, and `date_decision` is always `NA`
(the portal only exposes a `year`). Reflected in
`get_assessments_coverage()$status` as `"supported (metadata-only)"`.

The architecture is multi-country from day one — adding DK / etc. is a
pure additive change.

**Out of scope.** Spatial output (`sf`), zoning/plan documents,
LLM-based classification & normalisation. Topic scoring, classification,
and selection all live in the sibling packages now (see *The planscanR
family* below). Whatever remains flagged on the roadmap (§6) is here so
it doesn’t get prematurely wedged in.

## The planscanR family

`planscanR` is the **leaf** of a three-package family, each its own git
repo under this parent folder:

    planscanR             ←─── planscanR.screen ←─── planscanR.biogain
    (this package)              (scoring/select)      (BIOGAIN config + app)

- **planscanR** (here): fetches environmental-assessment records from
  the EU portals, owns the **cache** and the **sidecar JSON schema**,
  and does attachment **discovery**. Pure-R — no Python — and it Imports
  **neither** sibling. The outward-facing entry point.
- **planscanR.screen** — general-purpose
  scoring/classification/selection framework (embedding cosine,
  zero-shot classify, keyword lexicon, learned selection). Brings Python
  in via `reticulate`. Imports planscanR. See
  [../planscanR.screen/AGENTS.md](https://barthoekstra.github.io/planscanR.screen/AGENTS.md).
- **planscanR.biogain** — the BIOGAIN-specific config (topics / labels /
  lexicon), the ensemble `select` rule, the human review Shiny app, the
  Yoda / iRODS sync helpers, and the acquisition runbook. Imports both.
  See
  [../planscanR.biogain/AGENTS.md](https://barthoekstra.github.io/planscanR.biogain/AGENTS.md).

**Fetch-time relevance scoring is an optional, soft-dependency
feature.** You can pass `topic` to
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
to score records as they’re fetched — but the embedding work is
delegated to **planscanR.screen** (a Suggests dependency, called through
a [`requireNamespace()`](https://rdrr.io/r/base/ns-load.html) guard in
`R/utils_relevance.R`). Without planscanR.screen installed, passing
`topic` aborts with an install hint (`planscanR_error_screen_missing`);
**omit `topic` to fetch without any scoring** and planscanR stays a
pure-R fetcher. The slug / sidecar conventions are shared because both
packages write the planscanR-owned schema; the scoring *logic* is not
here.

## 1a. The acquisition runbook (lives in planscanR.biogain)

The canonical, top-to-bottom acquisition pipeline — scan + score →
classify → select → download / discover → report — is **no longer in
this repo**. It now ships with **planscanR.biogain** at
`inst/runbook/biogain_acquire.R`, reachable via:

``` r

system.file("runbook", "biogain_acquire.R", package = "planscanR.biogain")
```

It is the BIOGAIN package’s runbook, not planscanR’s: planscanR provides
the fetch / cache / discovery primitives it calls, but the selection
rule, thresholds, and phase orchestration live over there. When the
question is “how is BIOGAIN data processed end-to-end?”, that file is
the answer — see
[../planscanR.biogain/AGENTS.md](https://barthoekstra.github.io/planscanR.biogain/AGENTS.md).

## 2. Architecture in one diagram

    get_assessments(country, ...)
      ├── normalise_country() / assert_country()
      ├── select_assessments_handler(country)    # switch() returning a function
      │     ├── get_assessments_nl(...)          # commissiemer.nl
      │     ├── get_assessments_de(...)          # uvp-verbund.de
      │     ├── get_assessments_fr(...)          # projets-environnement.gouv.fr
      │     ├── get_assessments_at(...)          # secure.umweltbundesamt.at/uvpdb
      │     ├── get_assessments_dk(...)          # eahub.miljoeportal.dk
      │     ├── get_assessments_be(...)          # merregister.omgeving.vlaanderen.be
      │     ├── get_assessments_ee(...)          # kotkas.envir.ee
      │     ├── get_assessments_bg(...)          # registers.moew.government.bg
      │     ├── get_assessments_cz(...)          # portal.cenia.cz/eiasea
      │     ├── get_assessments_hr(...)          # mzozt.gov.hr
      │     ├── get_assessments_gr(...)          # api.eprm.ypen.gr (AEPO decisions)
      │     ├── get_assessments_is(...)          # skipulagsgatt.is/graphql (GraphQL)
      │     ├── get_assessments_ie(...)          # services.arcgis.com (ArcGIS REST; EIA)
      │     ├── get_assessments_si(...)          # gov.si (bulk JSON export; EIA + SEA/CPVO)
      │     ├── get_assessments_pt(...)          # siaia.apambiente.pt (HTML register; AIA/EIA)
      │     ├── get_assessments_gb(...)          # planninginspectorate.gov.uk (bulk CSV; NSIP/EIA)
      │     ├── get_assessments_it(...)          # va.mite.gov.it (HTML scrape; VIA/EIA + VAS/SEA)
      │     ├── get_assessments_sk(...)          # enviroportal.sk (API Platform JSON; EIA + SEA)
      │     ├── get_assessments_no(...)          # nve.no (JSON list + HTML detail; concession EIA)
      │     ├── get_assessments_lv(...)          # eva.gov.lv (Drupal HTML; metadata-only EIA + SEA PDFs)
      │     └── get_assessments_es(...)          # sede.miteco.gob.es (SABIA; needs {chromote} browser; EIA + SEA)
      ├── validate_result_schema()               # invariant gate before returning
      └── discover_attachments()                 # optional, when discover = TRUE

Every per-country handler is a self-contained file at
`R/get_assessments_<cc>.R` and is selected purely by the `switch` in
`R/get_assessments.R`. There is no S3 / class hierarchy — explicit
functional dispatch only.

When `topic` is supplied,
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
also runs fetch-time relevance scoring through `R/utils_relevance.R`,
which delegates the embedding to planscanR.screen (soft dependency).
**Score / classify / select as a pipeline are sibling-package concerns**
— the runbook in planscanR.biogain orchestrates them on top of the
tibble this package returns; planscanR itself only fetches (and,
optionally, scores by topic).

## 3. Return schema rules

**Required columns** (validated by `validate_result_schema()`, every
handler MUST emit them with the right types):

| Column | Type |
|----|----|
| `country` | chr (ISO-2, lowercase) |
| `source_portal` | chr |
| `document_id` | chr (unique within `source_portal`) |
| `url` | chr (canonical landing URL) |
| `retrieved_at` | POSIXct (UTC) |
| `attachment_urls` | list |
| `local_path` | list (parallel to `attachment_urls`; `character(0)` if `download = FALSE`) |

**Conventional columns** (use these names when the portal exposes the
concept, so cross-country tibbles can be `bind_rows()`-ed cleanly):

`title`, `summary`, `native_type`, `jurisdiction`, `status`,
`date_published`, `date_decision`, `competent_authority`, `proponent`,
`file_sha256`, `relevance_score`, `relevance_model`, `download_status`.

**Per-handler attachment splits.** A portal that groups its attachments
into named sections may add parallel list-columns. NL uses three:

- `attachment_urls_source` / `local_path_source` — files under a heading
  like *“Documenten waarop het advies is gebaseerd”* (the underlying
  EIA/SEA reports — the substantive documents for downstream analysis).
- `attachment_urls_advice` / `local_path_advice` — files under the
  advice card (Commissie advice + press releases). The heading text
  varies across template generations — *“Adviezen en persberichten”*
  (older pages) and *“Advies en persbericht”* (newer card layout) — so
  the handler classifies by a tolerant *contains* match, not an exact
  heading literal, and tests `source` **before** `advice` (the source
  heading itself contains the word “advies”).
- `attachment_urls_other` / `local_path_other` — catch-all for any
  `pas.commissiemer.nl/files/` document link whose enclosing section
  heading isn’t recognised (or is absent). This upholds the §4c
  capture-fidelity invariant: a future heading-wording drift degrades a
  document to `other` rather than silently dropping it. (Regression: the
  exact-literal match dropped every advice PDF on the new card layout —
  issue NL/#10.)

DE uses four:

- `attachment_urls_uvp_bericht` / `local_path_uvp_bericht` —
  *“UVP-Bericht, ggf. Antragsunterlagen”* (substantive UVP report +
  applicant docs).
- `attachment_urls_berichte` / `local_path_berichte` — *“Berichte und
  Empfehlungen”*.
- `attachment_urls_auslegung` / `local_path_auslegung` —
  *“Auslegungsinformationen”* (public-consultation notices).
- `attachment_urls_weitere` / `local_path_weitere` — *“Weitere
  Unterlagen”* (other materials; often the biggest section).

`attachment_urls` / `local_path` remain the deduplicated **union**
(source / substantive sections first), so the required-columns schema is
always satisfied.
[`read_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/read_record_sidecar.md)
is country-agnostic: any `attachment_urls_<section>` list-column a
handler emits flows through the sidecar and back out without changes
here.

**`download_status` list-column** (when `download = TRUE`): one tibble
per record with columns
`url, local_path, status, size_bytes, sha256, reason`. Values for
`status`: `"downloaded"`, `"cached"`, `"skipped_size"`, `"failed"`.

**No normalisation at fetch time.** Status, type, jurisdiction strings
stay in the portal’s own vocabulary (Dutch / German / Danish / …).
Cross-portal normalisation and classification are a **planscanR.screen**
concern that consumes this tibble downstream — not the fetcher’s job.

**Extra columns are encouraged.** Handlers can add any country-specific
column they like — `validate_result_schema()` only enforces the required
set. New conventional columns can be promoted in a later minor release.

**Derived score columns are owned by the siblings, not by the fetcher.**
`relevance_score_<slug>` (and, downstream, `class_*` / `kw_*` columns)
describe the *schema* planscanR persists, but the values are produced by
planscanR.screen / planscanR.biogain. They reach disk through
[`planscanR::write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md)
and fan back out through
[`planscanR::read_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/read_record_sidecar.md):
planscanR owns the schema and the **merge logic** (union-by-slug, so
re-scoring a slice never clobbers other topics’ scores), not the scoring
that fills these columns. The one exception is `relevance_score_<slug>`
written during a `get_assessments(topic = ...)` call — even there the
embedding is delegated to planscanR.screen.

## 4. Conventions

- **License**: GPL-3.

- **Formatter**: [Air](https://posit-dev.github.io/air/) with
  `line-width = 120` (see `air.toml`). Run `air format .` before
  pushing.

- **HTTP**: every outbound call goes through `req_planscanr()` in
  `R/utils_http.R` so user-agent, retry, and HTTP-cache behaviour stay
  consistent.

- **Caching**: file cache root is
  `tools::R_user_dir("planscanR", "cache")`, overridable via the
  `cache_dir` argument or `options(planscanR.cache_dir)`. Layout:

      <root>/
        files/<country>/<document_id>/
          <document_id>.meta.json                          # sidecar (see §4b)
          <country>_<document_id>_<slug>.<ext>             # flatten-safe basename

  When a portal’s attachment URLs don’t expose an extension in the path
  (e.g. Kotkas: `?attachment_id=...`), the slug carries an 8-char SHA-1
  of the full URL for per-attachment uniqueness, and the final `<ext>`
  is assigned post-download from the `Content-Type` header (with a
  magic-byte fallback for `application/octet-stream`). There is no
  separate HTTP cache — the sidecar JSONs ARE the cache, and per-country
  handlers consult them via `sidecar_url_index()` before going to the
  network. \[clear_cache()\] removes the `files/` tree (optionally
  scoped by `country`); pair with `refresh = TRUE` on the next call if
  you want fresh fetches afterwards. The download layer pre-flights
  every URL with HEAD; files exceeding
  `getOption("planscanR.max_file_size_mb", 50)` are skipped and recorded
  in `download_status`. Already-on-disk non-empty files become
  `status = "cached"` unless `overwrite = TRUE`.

- **Errors** carry classed conditions
  (`planscanR_error_unsupported_country`, `planscanR_error_bad_input`,
  `planscanR_error_bad_schema`, `planscanR_warning_partial`) so tests
  can target them cleanly.

- **Tests**: `testthat` (edition 3). HTTP is intercepted with
  [`testthat::local_mocked_bindings()`](https://testthat.r-lib.org/reference/local_mocked_bindings.html)
  against recorded fixtures under `tests/testthat/fixtures/<cc>/` (each
  handler exposes an internal `perform_*` seam — e.g. `perform_json`,
  `perform_html` — that the tests rebind); **no live HTTP in CI**. Live
  tests, if any, live under `tests/manual/` and are git-ignored.

- **Secrets**: portal handlers remain anonymous-access in v0.x and don’t
  need credentials. The discovery backend
  (`R/discover_backend_tavily.R`) reads a `TAVILY_API_KEY` from the
  environment. Credentialed sync (Yoda / iRODS) is a planscanR.biogain
  concern, not this package’s.

## 4b. Persistence and offline indexing

Every successfully processed record is persisted to a sidecar JSON at
`files/<country>/<document_id>/<document_id>.meta.json` — written
**atomically inside the per-record loop**, so an interrupted run leaves
N fully-indexable records on disk (not N orphan dirs). The sidecar
carries the full record (country, source_portal, document_id, url,
title, summary, dates, competent authority, proponent, relevance_score,
etc.) plus a per-file `files[]` array mirroring the `download_status`
columns (status, size_bytes, sha256, reason, section). Schema version:
`2`.

**The cache + sidecar are the family’s load-bearing contract, and the
I/O is exported.**
[`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md)
(the cache-root resolver), plus
[`read_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/read_record_sidecar.md)
/
[`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md)
(the sidecar reader/writer with the merge logic) are **exported** so the
sibling packages read and write the same cache without reaching into
internals. planscanR.screen and planscanR.biogain call
[`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md)
to persist their `relevance_scores[]` / `class_*` / `kw_*` results into
the schema this package owns; the merge here keeps those arrays intact
across re-scans.

**The sidecar is the authoritative cache.** Per-country handlers consult
`sidecar_url_index(country)` at the start of every call to build a
`url -> sidecar-path` lookup; any URL with an on-disk sidecar is loaded
**from JSON** rather than re-fetched over HTTP. This makes re-scoring an
already-scanned slice against a new topic essentially free (only the
embedding compute — done in planscanR.screen — and zero network). Pass
`refresh = TRUE` to bypass the sidecar lookup and force fresh
detail-page fetches.

Sidecar writes **merge** the `relevance_scores` array (this merge logic
is planscanR-owned, in `R/utils_sidecar.R`): prior topic entries whose
slug isn’t present in the current run are preserved. So running with
`topic = c(wind = "...")` after a multi-topic scan doesn’t wipe the
solar / power_grid scores from disk — only the wind entry is replaced.
The same merge protects the `class_*` arrays a sibling writes through
[`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md).

`index_cache(cache_dir = NULL, country = NULL)` walks every sidecar
under the root and reconstructs a tibble matching the planscanR schema —
no portal calls. Use it to: - re-read a previously-downloaded slice
offline; - enumerate what’s on disk before deciding what else to
fetch; - recover after manually relocating or flattening files (because
the basenames are globally unique, `find files/ -exec mv {} flat/` is
safe).

> **Yoda / iRODS sync moved out.** Pushing the cache to a Yoda iRODS
> server (`sync_cache_to_yoda()`, `fetch_attachments_via_yoda()`, the
> cache-resident `yoda/` config, and the `keyring`-based credential
> resolution) now lives in **planscanR.biogain**. It is a consumer of
> this package’s cache layout — the local sidecars remain the
> authoritative index here. See
> [../planscanR.biogain/AGENTS.md](https://barthoekstra.github.io/planscanR.biogain/AGENTS.md).

## 4c. Sidecar capture-fidelity invariant

A sidecar MUST capture every piece of record-relevant information the
portal exposes for that record. This is a **general** contract, not a
fixed field list:

- **Summary when present.** If the portal’s detail page shows a project
  summary / abstract / description, the sidecar’s `summary` must carry
  it (regression: NO / NVE dropped it — issue \#5).
- **Every document listed.** The `files[]` / `attachment_urls_*` arrays
  must enumerate *all* documents the portal lists for the record,
  following any pagination or lazy-loading (regression: GB / NSIP
  captured ~10 of \>1000 — issue \#6).
- **All exposed metadata.** Title, competent authority, proponent,
  decision / publication dates, location / geometry, status, type, and
  any per-record identifiers the portal surfaces must be captured when
  present.
- **Future fields too.** The invariant is open-ended: when a portal
  exposes a field the schema doesn’t yet name, the gap is still a
  capture defect.

The companion audit (`inst/audit/`, see its `README.md`) checks this
invariant across countries by diffing a generic, portal-agnostic probe
of the live source against the on-disk sidecars. The two named
regressions are exemplars; the audit is designed to surface
unanticipated gap classes as well. GB, NO and BG are deferred from the
active audit run while they are being re-ingested (a single
`AUDIT_DEFERRED` list, re-enableable later).

## 5. Adding a country

1.  Create `R/get_assessments_<cc>.R` with the same signature surface as
    [`get_assessments_nl()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_nl.md).
    The handler must return a tibble that passes
    `validate_result_schema()`.
2.  Add one line to the `switch` in `R/get_assessments.R`:
    `<cc> = get_assessments_<cc>,`.
3.  Update
    [`supported_countries()`](https://barthoekstra.github.io/planscanR/reference/supported_countries.md)
    in `R/utils_dispatch.R` and the
    [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md)
    tibble accordingly.
4.  Save the portal’s responses as fixture files under
    `tests/testthat/fixtures/<cc>/` and add
    `tests/testthat/test-get_assessments_<cc>.R`, intercepting the
    network by rebinding the handler’s `perform_*` seam(s) with
    [`testthat::local_mocked_bindings()`](https://testthat.r-lib.org/reference/local_mocked_bindings.html)
    (see the existing handler tests).
5.  Document portal-specific search-facet vocabularies (`status`,
    `native_type`, etc.) in the handler’s roxygen.

That’s the whole recipe — no edits to the core dispatcher are needed.

## 5a. Topics, scoring, classification, selection — moved to the siblings

These all left planscanR when the family split:

- **Topic defaults** (`biogain_assessment_topics()` and the canonical
  six-topic set) → **planscanR.biogain**.
- **Relevance scoring** (the pluggable embedding-model interface,
  `embedding_model_minilm()`, the cosine scorer, batch
  `score_records()`, zero-shot classification, the keyword lexicon, and
  the learned selection model) → **planscanR.screen**.
- **The BIOGAIN ensemble `select` rule**, the **review Shiny app**
  (`run_biogain_review()`), and the **acquisition runbook** →
  **planscanR.biogain**.

What planscanR keeps is the *fetch-time* slice only: pass `topic` to
[`get_assessments()`](https://barthoekstra.github.io/planscanR/reference/get_assessments.md)
and it delegates the embedding to planscanR.screen (soft dependency; see
*The planscanR family* and §3), writing `relevance_score_<slug>` columns
into the sidecar schema it owns. For everything past scoring — classify,
select, review, sync, report — see
[../planscanR.screen/AGENTS.md](https://barthoekstra.github.io/planscanR.screen/AGENTS.md)
and
[../planscanR.biogain/AGENTS.md](https://barthoekstra.github.io/planscanR.biogain/AGENTS.md).

## 6. Roadmap (informational; not actionable in v0.1)

- **Additional country handlers** — beyond the current six. Order not
  committed. Adding one is a pure additive change (§5).
- **`keyring`-based secrets for portal handlers** — when a portal grows
  to require API keys, add `keyring` as a Suggests dep and use the slot
  convention `planscanR_<country>_<portal>`. Handlers are
  anonymous-access for now.
- **`derived/` subdir under the cache root** — leave room for downstream
  artefacts (e.g. PDF-to-markdown chunks). The contract is: never mutate
  downloaded PDFs in place. The actual classification / normalisation
  work (docling chunking, LLM type assignment, cross-portal vocabulary
  normalisation) is a **planscanR.screen** concern that consumes the
  tibble this package returns — the fetcher stays raw. See
  [../planscanR.screen/AGENTS.md](https://barthoekstra.github.io/planscanR.screen/AGENTS.md).

## 7. Pointers

- Sibling packages (scoring / classification / selection, BIOGAIN
  config + review app + Yoda sync + runbook):
  [../planscanR.screen/AGENTS.md](https://barthoekstra.github.io/planscanR.screen/AGENTS.md),
  [../planscanR.biogain/AGENTS.md](https://barthoekstra.github.io/planscanR.biogain/AGENTS.md).
- Family-level orientation, dependency direction, and the sidecar-schema
  contract: the parent-folder `CLAUDE.md`.
- Architectural reference: <https://github.com/aloftdata/getRad>
- Adding a new country, end to end: `ADDING_A_COUNTRY.md`.
- Cache contract (exported):
  [`cache_dir_default()`](https://barthoekstra.github.io/planscanR/reference/cache_dir_default.md),
  [`read_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/read_record_sidecar.md),
  [`write_record_sidecar()`](https://barthoekstra.github.io/planscanR/reference/write_record_sidecar.md);
  schema + merge logic in `R/utils_sidecar.R`.
- Attachment discovery: `R/discover_attachments.R` (+
  [`discover_validate()`](https://barthoekstra.github.io/planscanR/reference/discover_validate.md),
  `discover_backend*`); the AT escape hatch is
  [`at_discovery_config()`](https://barthoekstra.github.io/planscanR/reference/at_discovery_config.md).
- Per-portal documentation lives in `vignettes/supported_sources.Rmd`;
  the runtime-accessible equivalent (including the valid search-facet
  vocabularies) is
  [`get_assessments_coverage()`](https://barthoekstra.github.io/planscanR/reference/get_assessments_coverage.md).
