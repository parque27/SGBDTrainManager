# Data licences and credits

The files in `data/` are derived from open data. When you use or show them (in the app, the report or slides), keep these credits.

## RENFE: CC BY 4.0

> Origen de los datos: Renfe Operadora

- Sources: RENFE open data portal (https://data.renfe.com): GTFS-RT realtime feeds (`vehicle_positions`, `trip_updates`, `alerts` and their long-distance versions, https://gtfsrt.renfe.com/), the Cercanías and long/medium distance GTFS timetables, and the station list (`estaciones.csv`).
- Data recorded from 2026-11-01T23:00Z to 2026-11-06T23:00Z; timetable snapshots of 2026-11-02 to 2026-11-06.
- Licence: Creative Commons Attribution 4.0 (https://creativecommons.org/licenses/by/4.0/). Reuse conditions: https://data.renfe.com/legal
- The data has been filtered to Catalonia, cleaned and transformed (see `README.md`). Renfe does not endorse this project and does not guarantee the continuity or accuracy of the data.

## FGC: CC BY 4.0

> Font: Ferrocarrils de la Generalitat de Catalunya (FGC)

- Source: FGC open data portal (https://dadesobertes.fgc.cat): `posicionament-dels-trens`, the GTFS-RT feeds and the GTFS timetable.
- Licence: Creative Commons Attribution 4.0 (https://creativecommons.org/licenses/by/4.0/).
- The data has been cleaned and transformed. FGC does not endorse this project.

## OpenStreetMap: ODbL 1.0

> © OpenStreetMap contributors

- Used for `network/tracks.csv.gz` (railway track geometry) and `catalonia.geojson` (the Catalonia boundary), both downloaded through the Overpass API.
- Licence: Open Database License 1.0 (https://opendatacommons.org/licenses/odbl/1-0/). See https://www.openstreetmap.org/copyright
- These two files are derived databases of OpenStreetMap: if you publish them or a database made from them, it must stay under the ODbL and keep the credit.
