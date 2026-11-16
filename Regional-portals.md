# Regional and local portals (not supported yet)

Sub-national portals (state, regional, municipal) that publish
assessment documents the national portals miss. Notes only: nothing here
is fetched by planscanR. Add an entry when you come across a portal;
promote it to a source via
[ADDING_A_COUNTRY.md](https://barthoekstra.github.io/planscanR/ADDING_A_COUNTRY.md)
when there is a need. National portals still to add are in
[Countries-to-add.md](https://barthoekstra.github.io/planscanR/Countries-to-add.md).

Why this matters: some project types rarely reach the national EIA
portal. German ground-mounted solar parks are mostly approved through a
municipal zoning plan (Bebauungsplan) with an environmental report
(Umweltbericht), so UVP-Verbund holds only 2-3 substantive solar
dossiers (checked 2026-11-10). Its “Bauleitplanung” entries are only
links to municipal websites.

| Country | Portal | Covers | What we know | Checked |
|----|----|----|----|----|
| DE (Schleswig-Holstein) | [BOB-SH](https://bob-sh.de/) | Bauleitplanung (B-Plan, F-Plan) participation for the whole state | List of current and recent procedures (about 200, newest first, map view), dozens of Solarpark / Agri-PV B-Plans. A procedure page lists all PDFs, e.g. [Solarpark Rader Insel](https://bob-sh.de/verfahren/solarpark-rader-insel/public/detail): 12 PDFs incl. Begründung with Umweltbericht, Biotopkartierung, Artenschutzprüfung, Blendgutachten, Geräuschprognose. URLs: `/verfahren/<uuid-or-slug>/public/detail`, files `/file/<slug>/<uuid>`. Search facility unconfirmed. | 2026-11-10 |
| DE (Nordrhein-Westfalen) | [Beteiligung NRW](https://beteiligung.nrw.de/portal/hauptportal/beteiligung/themen?format=Bauleitplan) | Bauleitplan participation for participating municipalities | 66 current and 736 ended Bauleitplan procedures, per municipality (`/portal/<gemeinde>/beteiligung/themen/<id>`). Share of solar procedures and document availability not checked. | 2026-11-10 |
| DE (federal) | [DiPlanung / DiPlanBeteiligung](https://www.diplanung.de) | Federal participation platform used by several states | Not checked. | \- |
| NL | [ruimtelijkeplannen.nl](https://www.ruimtelijkeplannen.nl) | Zoning plans with appendices (`b_<id>_tb.html`) | Holds specialist reports (ecology, noise) that commissiemer.nl lacks for about 20% of NL dossiers. Planned as an opt-in source (RPNL in the parent Plans.md). | 2026-11-10 |
