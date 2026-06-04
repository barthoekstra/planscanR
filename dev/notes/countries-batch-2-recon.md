# Final-batch country recon (2026-06-04)

Reconnaissance for the final batch of `planscanR` country handlers. Captured by
parallel web-recon agents; **verify endpoints/selectors live before coding** —
several portals are SPAs whose exact JSON/POST endpoint could not be sniffed
without a real browser DevTools session.

Tiers (analogues: "HTML-scrape" = NL/DE pattern; "JSON-behind-SPA" = BE/DK/EE).

## In scope this batch (8)

### Italy — `va.mite.gov.it` (MASE VIA/VAS) — Easy–Medium, HTML-scrape
- Server-rendered HTML (ASP.NET), no SPA, no JSON.
- Dual register (like EE): VIA = EIA `/it-IT/Ricerca/ViaProcedura` (~10,576 records, ~1,058 pages); VAS = SEA `/it-IT/Ricerca/VasProcedura` (~139). (AIA is a 3rd register, out of scope.)
- Pagination `?pagina=N` (1-based, ~10 rows/page). Bonus `?mode=export` → full `.xlsx` (Progetto/Proponente/Procedura only — **no record id**, so use for counts/diff, not enumeration).
- Detail `/it-IT/Oggetti/Info/{id}`; doc index `/it-IT/Oggetti/Documentazione/{id}/{grp}` (paginated); **direct anonymous PDF** `/File/Documento/{fileId}` (verified 200, application/pdf).
- Filters: Procedura (VIA/VAS subtype) + free-text only; region/date are columns → filter client-side.
- **No per-record geometry** (textual Regione/Provincia/Comune only). Italian. robots: Allow all, no crawl-delay (be polite; large crawl).
- assessment_type: VIA→"EIA", VAS→"SEA"; prefix document_id to avoid collisions.

### Portugal — `siaia.apambiente.pt` (SIAIA / APA) — Easy–Medium, HTML-scrape
- Server-rendered HTML. AIA (EIA) only; AAE/SEA is a **separate** APA register (backlog).
- Listing `/ProcessoAIA?pagina=N` (25/page, ~38 pages, ~3.8k). `?sortOrder=pro_id_desc`.
- Detail `/ProcessoAIA/Detalhes/{pro_id}`; doc list `/ListaDocumentos?pro_id={id}` grouped (EIA / DIA / Consulta Pública / Parecer CA); **direct PDF** `https://siaia.apambiente.pt/AIADOC/AIA{n}/{file}.pdf` (verified).
- Filters: Autoridade de AIA, Ano de Decisão (1990–2026), Sentido de Decisão. No region/type/sector filter.
- Geometry via separate `sniambgeoviewer.apambiente.pt` (CRS unconfirmed, redirect-loops) → **skip geometry v1**, location = concelho text. Portuguese. robots absent.

### Slovenia — `gov.si` okoljske-presoje — Easy–Medium, JSON/CSV export (cleanest)
- The find for the "search if you can find something" country. Authority moved ARSO→MOPE (2021); registers on gov.si.
- **JSON export**: append `export/json/` to any list URL (CSV via `export/csv/`). Single GET = whole dataset, no pagination/auth/JS.
  - EIA screening (predhodni postopek): `…/okoljske-presoje/predhodni-postopek/export/json/` (336 records).
  - SEA/CPVO state spatial plans (25), municipal spatial plans (190) — sibling pages, same export mechanism.
- Record fields: Številka/Poseg (title), URLSegment (→detail), Datum objave, Naziv (proponent), Naslov (address), Številka zadeve (case no.), Sklep/Odločba (decision-doc id object), Oznaka posega (Annex code).
- **PDFs**: served from `…/assets/seznami/predhodni-postopek/<file>.pdf` (verified) but ids in export do **not** map to filenames → must fetch each detail page (via URLSegment) and scrape the `assets/seznami/...pdf` href.
- No geometry (proponent address only). Slovenian. Pre-2021 on `arso.gov.si` blocks bots (403) → scope 2021+.
- Multiple lists to enumerate (1 EIA + several CPVO) → dual/multi-register, reuse assessment_type.

### United Kingdom — Planning Inspectorate NSIP — Easy (index) / Medium (docs), bulk CSV + HTML
- Scope **NSIP only** (national infra; every NSIP has an Environmental Statement). Local-authority EIAs = no national register → out of scope. Natural England agri-EIA ODS, Scotland Energy Consents, DESNZ REPD = backlog.
- Base `national-infrastructure-consenting.planninginspectorate.gov.uk`.
- **Bulk CSV** `/api/applications-download` (one GET, ~540 projects). Columns incl. Project reference (sector-coded: EN/TR/WA/WW/WS/BC), name, applicant, region, **Easting/Northing + GPS lat/long**, stage, description, full date set.
- Detail `/projects/{REF}`; docs `/projects/{REF}/documents` (HTML, paginated; filter `?type=Environmental Statement`); **PDFs** at `nsip-documents.planninginspectorate.gov.uk/published-documents/{REF}-{NNNNNN}-{title}.pdf` (verified, range-supported). No doc JSON API → scrape HTML doc pages.
- **robots: Crawl-delay 10; AI-crawler UAs (ClaudeBot/GPTBot/CCBot/…) get Disallow:/.** → handler must use a **neutral UA** and honour 10 s. English.
- Geometry = point centroid (Easting/Northing OSGB EPSG:27700 + WGS84) → can write a point geometry.

### Slovakia — `enviroportal.sk` EIA/SEA — Medium, JSON-behind-SPA (needs capture)
- React (Vite) SPA + Symfony JSON `/api`. Legacy `/sk/eia/detail?page=N` 301→SPA.
- Browser pagination `?page=N`; detail SPA `/eia/detail/{seoId}` → data `GET /api/eia/detail/{seoId}`; docs `GET /api/eia/document?id[0]=…` (bulk).
- **One unified system** with `isEia` flag (EIA vs SEA) — reuse assessment_type.
- Filters: kraj (region), okres (district), type/isEia, stav (status), year; fulltext.
- Geometry via ArcGIS `geo.enviroportal.sk` (EPSG:5514) → separate hop, optional.
- **BLOCKER**: exact `/api` list endpoint URL + record JSON schema built dynamically in the React loader → **capture via DevTools** (one `?page=2` + one detail). Slovak.

### Norway — NVE `konsesjonssaker` — Medium, JSON-behind-SPA (needs capture)
- Energy/water concession cases; each dossier carries the konsekvensutredning (EIA) + hearing PDFs. Confirmed right data.
- Angular SPA; case list fetched by JS. **"Eksportér listen"** button ⇒ a server-side export endpoint (likely the cleanest bulk path). `api.nve.no` does NOT carry konsesjonssaker (only built-plant DBs).
- Detail GET-addressable `…/konsesjonssak?id=<regnr>&type=<code>` (server-rendered enough to read). Fields: title, saksnummer, status, applicant, fylke/kommune, dates, doc list.
- **PDFs**: `webfileservice.nve.no/API/PublishedFiles/Download/<saksnummer>/<fileId>` (and a UUID variant), no auth, grouped by section.
- Geometry via NVE ArcGIS (`nve.geodataonline.no`, EPSG:25833); per-case join unconfirmed → optional.
- EIA docs not type-flagged → filename heuristic ("konsekvensutredning"/"KU"/"melding"). **robots Crawl-delay 20.** Norwegian.
- **BLOCKER**: capture the list/export XHR URL + pagination/filter params via DevTools.

### Spain — MITECO SABIA — Medium–Hard, HTML/POST (needs reverse-engineer)
- National competence only (most EIA is regional → not here). Liferay portlet, server-rendered, **POST-driven forms** (likely session/CSRF).
- **Dual source**, same SABIA backend: `…/navServicioContenido` = project EIA; `…/navSabiaPlanes` = plan SEA → reuse assessment_type.
- Detail (ficha): title, status, expediente code, project/plan type, órgano sustantivo, promotor, province/CCAA; doc panel grouped by stage (EsIA / Consulta / DIA-Resolución / BOE) → PDFs (pattern uncaptured).
- Geometry internal, **no public WMS/WFS** → skip. Spanish. robots unverified → 1 req/s.
- **BLOCKER**: POST endpoint, namespaced portlet params, CSRF/session, pagination, PDF URL pattern → capture POST + results HTML + one ficha.

### Latvia — `eva.gov.lv` (Environmental State Bureau) — Medium, HTML-scrape (asymmetric)
- Drupal, server-rendered. **The two URLs are NOT parallel registers:**
  - EIA listing `…/ietekmes-uz-vidi-novertejumu-projekti?page=0..29` (0-indexed, 20/page, 581 records) with detail pages — **but EIA detail pages carry NO PDF attachments** (prose/decision numbers only).
  - SEA hub `…/strategiskais-ietekmes-uz-vidi-novertejums` → flat sub-pages `/atzinumi`, `/lemumi`, `/monitorings` with **direct PDFs** `…/media/{id}/download?attachment`.
- Filters are POST/AJAX (GET `?combine=` ignored) → **full-crawl** `?page=N`.
- No geometry (cadastral ids/parish text). Latvian. robots permissive for content.
- **Design consequence**: EIA half is effectively **metadata-only** (no portal PDFs) → set coverage `status = "supported (metadata-only…)"` so the existing `discover = TRUE` (Tavily) path applies; SEA half has direct PDFs. Confirm against one completed EIA record whether reports surface anywhere before committing.

## Deferred to a later batch (user decision 2026-06-04)

### Lithuania — `aaa.lrv.lt` PAV/SPAV — HARD (blocked)
- Entire `*.lrv.lt` behind **Cloudflare "Just a moment…" JS challenge** → plain HTTP 403. Needs a headless-browser / clearance transport **no handler in the family has**. Server-HTML CMS by year→stage, PDF/DOC links; possible per-year Excel index (unconfirmed → would need a `readxl` path). No JSON API, no open-data, no geometry, LT-only. SPAV register not located.

### Romania — ANPM→ANMAP — HARD (no national register)
- `raportare.anpm.ro` is a login-gated SIM submission portal (wrong target). Real EIA/SEA content fragmented across **~42 county sites mid-migration**: legacy Liferay `apm*.anpm.ro` (`?p_p_id=…&…_cur=N&…_delta=100`) + new WordPress `djm*.anmap.gov.ro` (per HG 311/2025; likely WP REST `/wp-json/wp/v2/posts`). High churn, possible **geo-blocking** (ECONNREFUSED from non-EU egress). PDFs downloadable; no geometry; RO-only. Forward bet = multi-site WP scraper, but needs per-county inventory + geo-block resolution first.
