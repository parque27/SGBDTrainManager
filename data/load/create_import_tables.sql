-- Generated from schema.csv by the data build. Do not edit: regenerate instead.
-- One table per data file in schema "import", typed, with no keys, indexes or geometry columns.
-- Rerunning this file drops and recreates the import tables.

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE SCHEMA IF NOT EXISTS import;

DROP TABLE IF EXISTS import.stations;
CREATE TABLE import.stations (
    station_id text,
    operator text,
    code text,
    name text,
    lat double precision,
    lon double precision,
    municipality text,
    province text,
    interchange_id text,
    source text
);
COMMENT ON TABLE import.stations IS 'Stations used by any kept trip or inside the boundary, RENFE and FGC. File: network/stations.csv.gz';
COMMENT ON COLUMN import.stations.station_id IS 'Station id, operator-prefixed (`renfe:...` or `fgc:...`). RENFE uses its 5-digit code, FGC its 2-letter code.';
COMMENT ON COLUMN import.stations.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.stations.code IS 'The operator''s own station code, without prefix.';
COMMENT ON COLUMN import.stations.name IS 'Station name from the operator''s timetable (GTFS stops.txt).';
COMMENT ON COLUMN import.stations.lat IS 'Latitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.stations.lon IS 'Longitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.stations.municipality IS 'Municipality from RENFE''s station list (estaciones.csv). Empty when unknown, always for FGC.';
COMMENT ON COLUMN import.stations.province IS 'Province from RENFE''s station list (estaciones.csv). Empty when unknown, always for FGC.';
COMMENT ON COLUMN import.stations.interchange_id IS 'Shared by stations of different operators that are the same place (same normalised name, within 300 m). Empty when there is no counterpart.';
COMMENT ON COLUMN import.stations.source IS 'Timetable file the station comes from: `renfe_gtfs` or `fgc_gtfs`.';

DROP TABLE IF EXISTS import.routes;
CREATE TABLE import.routes (
    route_id text,
    operator text,
    service text,
    short_name text,
    long_name text,
    color text
);
COMMENT ON TABLE import.routes IS 'Lines (routes) of the kept trips. File: network/routes.csv';
COMMENT ON COLUMN import.routes.route_id IS 'Route (line) id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.routes.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.routes.service IS '`rodalies`, `regional`, `long_distance` or `fgc`.';
COMMENT ON COLUMN import.routes.short_name IS 'Public line name, for example `R1`, `S1` or `REGIONAL`.';
COMMENT ON COLUMN import.routes.long_name IS 'Route description, usually its end stations.';
COMMENT ON COLUMN import.routes.color IS 'Line colour as 6 hex digits without `#`.';

DROP TABLE IF EXISTS import.trips;
CREATE TABLE import.trips (
    trip_id text,
    operator text,
    route_id text,
    service_date date,
    train_number text,
    headsign text,
    direction_id integer,
    shape_id text,
    timetable_snapshot date,
    source_trip_id text,
    feed text
);
COMMENT ON TABLE import.trips IS 'Timetabled runs with a stop in the boundary, service dates 2026-11-02 to 2026-11-06. File: network/trips.csv.gz';
COMMENT ON COLUMN import.trips.trip_id IS 'Run id `<operator>:<raw trip id>@<service date>`. Raw timetable ids repeat on several days, so the service date is part of the id.';
COMMENT ON COLUMN import.trips.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.trips.route_id IS 'Route (line) id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.trips.service_date IS 'Madrid calendar date the timetable runs on.';
COMMENT ON COLUMN import.trips.train_number IS 'Public train number (RENFE). Empty for FGC.';
COMMENT ON COLUMN import.trips.headsign IS 'Destination shown on the train.';
COMMENT ON COLUMN import.trips.direction_id IS 'GTFS direction, 0 or 1.';
COMMENT ON COLUMN import.trips.shape_id IS 'Route shape. Empty when the timetable has none (RENFE long distance has no shapes).';
COMMENT ON COLUMN import.trips.timetable_snapshot IS 'Date of the GTFS snapshot used (the same day as service_date).';
COMMENT ON COLUMN import.trips.source_trip_id IS 'Trip id exactly as in the operator''s GTFS trips.txt, without prefix or date.';
COMMENT ON COLUMN import.trips.feed IS 'Timetable file: `cercanias` (RENFE Cercanias GTFS), `ld` (RENFE long/medium distance GTFS) or `fgc`.';

DROP TABLE IF EXISTS import.stop_times;
CREATE TABLE import.stop_times (
    trip_id text,
    stop_sequence integer,
    station_id text,
    arrival_time timestamptz,
    departure_time timestamptz,
    inside_boundary boolean
);
COMMENT ON TABLE import.stop_times IS 'Timetabled stops of every trip, times in UTC. File: network/stop_times.csv.gz';
COMMENT ON COLUMN import.stop_times.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';
COMMENT ON COLUMN import.stop_times.stop_sequence IS 'Order of the stop within the trip (GTFS stop_sequence, increasing, not always 1, 2, 3).';
COMMENT ON COLUMN import.stop_times.station_id IS 'Station id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.stop_times.arrival_time IS 'Timetabled arrival, UTC, ISO 8601 with Z. Converted from GTFS local time, including times after 24:00.';
COMMENT ON COLUMN import.stop_times.departure_time IS 'Timetabled departure, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.stop_times.inside_boundary IS 'true when the station lies inside the buffered Catalonia boundary.';

DROP TABLE IF EXISTS import.shapes;
CREATE TABLE import.shapes (
    shape_id text,
    operator text,
    geometry_wkt text
);
COMMENT ON TABLE import.shapes IS 'Route shapes from the timetables, clipped to the boundary. File: network/shapes.csv.gz';
COMMENT ON COLUMN import.shapes.shape_id IS 'Shape id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.shapes.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.shapes.geometry_wkt IS 'WKT LINESTRING or MULTILINESTRING, lon lat order, SRID 4326.';

DROP TABLE IF EXISTS import.tracks;
CREATE TABLE import.tracks (
    way_id text,
    railway text,
    name text,
    infrastructure_operator text,
    gauge text,
    electrified text,
    voltage text,
    maxspeed_kmh integer,
    usage text,
    geometry_wkt text
);
COMMENT ON TABLE import.tracks IS 'Railway track geometry from OpenStreetMap (ODbL). File: network/tracks.csv.gz';
COMMENT ON COLUMN import.tracks.way_id IS 'OpenStreetMap way id, `osm:<id>`.';
COMMENT ON COLUMN import.tracks.railway IS 'OpenStreetMap railway tag: `rail`, `narrow_gauge`, `subway` or `tram`.';
COMMENT ON COLUMN import.tracks.name IS 'Line name from OpenStreetMap.';
COMMENT ON COLUMN import.tracks.infrastructure_operator IS 'OpenStreetMap operator tag: who manages the track (for example Adif or FGC), not the train operator. Replaces the spec''s `operator` column to avoid that confusion.';
COMMENT ON COLUMN import.tracks.gauge IS 'Track gauge as tagged, for example `1668`; can list several values separated by `;`.';
COMMENT ON COLUMN import.tracks.electrified IS 'OpenStreetMap electrified tag, for example `contact_line` or `no`.';
COMMENT ON COLUMN import.tracks.voltage IS 'Electrification voltage as tagged.';
COMMENT ON COLUMN import.tracks.maxspeed_kmh IS 'Speed limit as tagged.';
COMMENT ON COLUMN import.tracks.usage IS 'OpenStreetMap usage tag: `main`, `branch`, `industrial`, `freight` or `tourism`.';
COMMENT ON COLUMN import.tracks.geometry_wkt IS 'WKT LINESTRING, lon lat order, SRID 4326.';

DROP TABLE IF EXISTS import.positions;
CREATE TABLE import.positions (
    time timestamptz,
    train_id text,
    operator text,
    vehicle_id text,
    trip_id text,
    other_trip_ids text,
    route_id text,
    lat double precision,
    lon double precision,
    movement text,
    station_id text,
    next_station_id text,
    delay_s integer,
    speed_kmh double precision,
    position_fixed boolean,
    carried_forward boolean,
    feed text,
    raw_trip_id text
);
COMMENT ON TABLE import.positions IS 'One row per train per minute, cleaned. One file per Madrid day. File: realtime/positions/*.csv.gz';
COMMENT ON COLUMN import.positions.time IS 'Minute of the observation, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.positions.train_id IS 'Train: Rodalies `renfe:<trip>` (one running train), long distance `renfe:<train number>`, FGC `fgc:<record id>` (one run of the timetable, not a physical unit). With time, the natural key.';
COMMENT ON COLUMN import.positions.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.positions.vehicle_id IS 'Vehicle as published: RENFE vehicle id, FGC unit (`ut`). Empty when not published.';
COMMENT ON COLUMN import.positions.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';
COMMENT ON COLUMN import.positions.other_trip_ids IS 'Long distance only: other trip ids the same train was published under in the same minute, `;`-separated.';
COMMENT ON COLUMN import.positions.route_id IS 'Route (line) id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.positions.lat IS 'Latitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.positions.lon IS 'Longitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.positions.movement IS '`moving`, `stopped_station` (still within the station radius) or `stopped_line` (still between stations).';
COMMENT ON COLUMN import.positions.station_id IS 'Station the train is stopped at; only when movement is `stopped_station`.';
COMMENT ON COLUMN import.positions.next_station_id IS 'Next station as published by the feed. It can lag behind the train.';
COMMENT ON COLUMN import.positions.delay_s IS 'Delay of the trip in this minute (positive = late). Empty when not reported.';
COMMENT ON COLUMN import.positions.speed_kmh IS 'Average speed since the train''s previous observed position. Empty when the row is not a new observation or starts a track (the train''s first row, after more than 10 min absent, or at a `track_split` in data_issues).';
COMMENT ON COLUMN import.positions.position_fixed IS 'true when cleaning corrected this position; the original is in data_issues.';
COMMENT ON COLUMN import.positions.carried_forward IS 'true when the row repeats the previous minute''s state because the feed did not change or could not be fetched.';
COMMENT ON COLUMN import.positions.feed IS 'Realtime feed the train comes from: `rodalies` (RENFE Cercanias/Rodalies feed, which also carries the regional lines), `ld` (RENFE long and medium distance feed) or `fgc` (FGC positions).';
COMMENT ON COLUMN import.positions.raw_trip_id IS 'Trip id exactly as the realtime feed published it (long distance ids embed a date that can differ from the timetable''s).';

DROP TABLE IF EXISTS import.trip_delays;
CREATE TABLE import.trip_delays (
    time timestamptz,
    trip_id text,
    delay_s integer,
    source text,
    on_time boolean
);
COMMENT ON TABLE import.trip_delays IS 'Delay of each trip per minute while the feeds report it. File: realtime/trip_delays.csv.gz';
COMMENT ON COLUMN import.trip_delays.time IS 'Minute, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.trip_delays.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id). Long-distance trips missing from the Catalan timetable keep the same id form but have no trips row.';
COMMENT ON COLUMN import.trip_delays.delay_s IS 'Delay, positive = late. Empty for `fgc_flag` rows.';
COMMENT ON COLUMN import.trip_delays.source IS '`renfe_trip` (RENFE trip delay), `renfe_stop` (RENFE stop delay), `fgc_computed` (FGC predicted minus timetabled time at the next stop) or `fgc_flag` (only FGC''s on-time flag).';
COMMENT ON COLUMN import.trip_delays.on_time IS 'FGC on-time flag (`en_hora`), only on `fgc_flag` rows.';

DROP TABLE IF EXISTS import.stop_arrivals;
CREATE TABLE import.stop_arrivals (
    trip_id text,
    stop_sequence integer,
    station_id text,
    scheduled_arrival timestamptz,
    observed_arrival timestamptz,
    delay_s integer,
    skipped boolean
);
COMMENT ON TABLE import.stop_arrivals IS 'Observed arrival at each timetabled stop. File: realtime/stop_arrivals.csv.gz';
COMMENT ON COLUMN import.stop_arrivals.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';
COMMENT ON COLUMN import.stop_arrivals.stop_sequence IS 'Stop order, as in stop_times.';
COMMENT ON COLUMN import.stop_arrivals.station_id IS 'Station id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.stop_arrivals.scheduled_arrival IS 'Timetabled arrival, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.stop_arrivals.observed_arrival IS 'Last prediction published before the train passed the stop, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.stop_arrivals.delay_s IS 'observed_arrival minus scheduled_arrival.';
COMMENT ON COLUMN import.stop_arrivals.skipped IS 'true when the feed marked the stop as skipped.';

DROP TABLE IF EXISTS import.cancellations;
CREATE TABLE import.cancellations (
    trip_id text,
    service_date date,
    scope text,
    first_seen timestamptz,
    last_seen timestamptz,
    evidence text
);
COMMENT ON TABLE import.cancellations IS 'Cancelled or partly cancelled trips. File: realtime/cancellations.csv';
COMMENT ON COLUMN import.cancellations.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';
COMMENT ON COLUMN import.cancellations.service_date IS 'Madrid calendar date of the trip.';
COMMENT ON COLUMN import.cancellations.scope IS '`trip` (whole trip) or `partial` (some stops skipped).';
COMMENT ON COLUMN import.cancellations.first_seen IS 'First minute the feed reported it, UTC, ISO 8601 with Z. Empty for `not_reported`.';
COMMENT ON COLUMN import.cancellations.last_seen IS 'Last minute the feed reported it, UTC, ISO 8601 with Z. Empty for `not_reported`.';
COMMENT ON COLUMN import.cancellations.evidence IS '`feed_canceled` (the feed said so), `stops_skipped` (the feed skipped at least one stop) or `not_reported` (timetabled but never seen in any feed: low confidence).';

DROP TABLE IF EXISTS import.alerts;
CREATE TABLE import.alerts (
    alert_id text,
    operator text,
    first_seen timestamptz,
    last_seen timestamptz,
    active_start timestamptz,
    active_end timestamptz,
    header text,
    description text,
    language text,
    live boolean
);
COMMENT ON TABLE import.alerts IS 'Service alerts published by RENFE and FGC. File: realtime/alerts.csv';
COMMENT ON COLUMN import.alerts.alert_id IS 'Alert id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.alerts.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.alerts.first_seen IS 'First minute the alert was in the feed, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.alerts.last_seen IS 'Last minute the alert was in the feed, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.alerts.active_start IS 'Start of the period the alert says it applies to, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.alerts.active_end IS 'End of that period, UTC, ISO 8601 with Z. Empty when open.';
COMMENT ON COLUMN import.alerts.header IS 'Alert title. RENFE publishes none.';
COMMENT ON COLUMN import.alerts.description IS 'Alert text.';
COMMENT ON COLUMN import.alerts.language IS 'Language of header and description: `ca` or `es`.';
COMMENT ON COLUMN import.alerts.live IS 'false for RENFE alerts first seen before 2026-11-04T16:49Z, when that feed was frozen.';

DROP TABLE IF EXISTS import.alert_targets;
CREATE TABLE import.alert_targets (
    alert_id text,
    route_id text,
    station_id text,
    trip_id text
);
COMMENT ON TABLE import.alert_targets IS 'What each alert applies to, one row per target. File: realtime/alert_targets.csv';
COMMENT ON COLUMN import.alert_targets.alert_id IS 'Alert.';
COMMENT ON COLUMN import.alert_targets.route_id IS 'Route (line) id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.alert_targets.station_id IS 'Station id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.alert_targets.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';

DROP TABLE IF EXISTS import.occupancy;
CREATE TABLE import.occupancy (
    time timestamptz,
    train_id text,
    car text,
    occupancy_pct integer,
    level integer
);
COMMENT ON TABLE import.occupancy IS 'FGC occupancy per car per minute. File: realtime/occupancy.csv.gz';
COMMENT ON COLUMN import.occupancy.time IS 'Minute, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.occupancy.train_id IS 'Train id as in positions.train_id (Rodalies: the trip; long distance: the train number; FGC: the run). Not unique per day: group by trip_id for one run.';
COMMENT ON COLUMN import.occupancy.car IS 'FGC car position code: `mi`, `ri`, `m1` or `m2`.';
COMMENT ON COLUMN import.occupancy.occupancy_pct IS 'Occupancy of the car.';
COMMENT ON COLUMN import.occupancy.level IS 'FGC occupancy band (`tram`), 1 = low to 3 = high.';

DROP TABLE IF EXISTS import.stops;
CREATE TABLE import.stops (
    stop_event_id text,
    train_id text,
    trip_id text,
    kind text,
    station_id text,
    start timestamptz,
    "end" timestamptz,
    duration_s integer,
    lat double precision,
    lon double precision,
    operator text,
    feed text
);
COMMENT ON TABLE import.stops IS 'Every time a train stood still for 2 minutes or more. File: events/stops.csv.gz';
COMMENT ON COLUMN import.stops.stop_event_id IS '`<train_id>:<start>`.';
COMMENT ON COLUMN import.stops.train_id IS 'Train id as in positions.train_id (Rodalies: the trip; long distance: the train number; FGC: the run). Not unique per day: group by trip_id for one run.';
COMMENT ON COLUMN import.stops.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';
COMMENT ON COLUMN import.stops.kind IS '`station` (within the station radius) or `line` (between stations).';
COMMENT ON COLUMN import.stops.station_id IS 'Station, when kind is `station`.';
COMMENT ON COLUMN import.stops.start IS 'First minute stopped, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.stops."end" IS 'Last minute stopped, UTC, ISO 8601 with Z. `end` is a reserved word in SQL: write "end".';
COMMENT ON COLUMN import.stops.duration_s IS 'end minus start.';
COMMENT ON COLUMN import.stops.lat IS 'Latitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.stops.lon IS 'Longitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.stops.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.stops.feed IS 'Realtime feed the train comes from: `rodalies` (RENFE Cercanias/Rodalies feed, which also carries the regional lines), `ld` (RENFE long and medium distance feed) or `fgc` (FGC positions).';

DROP TABLE IF EXISTS import.incidents;
CREATE TABLE import.incidents (
    incident_id text,
    type text,
    start timestamptz,
    "end" timestamptz,
    operator text,
    route_id text,
    trip_id text,
    train_id text,
    station_id text,
    lat double precision,
    lon double precision,
    details text,
    related_alert_id text,
    evidence text
);
COMMENT ON TABLE import.incidents IS 'Interpreted events: unexpected stops, cancellations, alerts. File: events/incidents.csv';
COMMENT ON COLUMN import.incidents.incident_id IS '`<type>:<n>`.';
COMMENT ON COLUMN import.incidents.type IS '`unexpected_stop`, `cancellation` or `alert`. Alerts: every RENFE alert and FGC `INCIDENCE_*`; FGC `OBSERVATIONS_*` timetable notes are only in alerts.';
COMMENT ON COLUMN import.incidents.start IS 'Start, UTC, ISO 8601 with Z. Cancellations: the timetabled start of the trip.';
COMMENT ON COLUMN import.incidents."end" IS 'End, UTC, ISO 8601 with Z. Cancellations: the timetabled end, which can be after the 5-day window. `end` is a reserved word in SQL: write "end".';
COMMENT ON COLUMN import.incidents.operator IS 'Train operator: `renfe` or `fgc`.';
COMMENT ON COLUMN import.incidents.route_id IS 'Route (line) id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.incidents.trip_id IS 'Run of a timetabled trip, `<operator>:<raw trip id>@<service date>` (see trips.trip_id).';
COMMENT ON COLUMN import.incidents.train_id IS 'Train id as in positions.train_id (Rodalies: the trip; long distance: the train number; FGC: the run). Not unique per day: group by trip_id for one run.';
COMMENT ON COLUMN import.incidents.station_id IS 'Station id, operator-prefixed (`renfe:...` or `fgc:...`).';
COMMENT ON COLUMN import.incidents.lat IS 'Latitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.incidents.lon IS 'Longitude, WGS84 (SRID 4326), 6 decimals.';
COMMENT ON COLUMN import.incidents.details IS 'Human-readable explanation.';
COMMENT ON COLUMN import.incidents.related_alert_id IS 'A live alert that matches the incident; for alerts, the alert itself.';
COMMENT ON COLUMN import.incidents.evidence IS 'Why it is an incident: `positions` (unexpected stops), `feed_canceled` or `stops_skipped` (cancellations), `live` or `not_live` (alerts).';

DROP TABLE IF EXISTS import.data_issues;
CREATE TABLE import.data_issues (
    time timestamptz,
    train_id text,
    issue text,
    original_lat double precision,
    original_lon double precision,
    fixed_lat double precision,
    fixed_lon double precision,
    note text,
    feed text
);
COMMENT ON TABLE import.data_issues IS 'Every position the cleaning changed or dropped, with the original values. File: events/data_issues.csv.gz';
COMMENT ON COLUMN import.data_issues.time IS 'Minute, UTC, ISO 8601 with Z.';
COMMENT ON COLUMN import.data_issues.train_id IS 'Train id as in positions.train_id (Rodalies: the trip; long distance: the train number; FGC: the run). Not unique per day: group by trip_id for one run. Empty for `failed_minute`.';
COMMENT ON COLUMN import.data_issues.issue IS '`station_fallback`, `spike`, `frozen`, `unexplained_jump`, `duplicate_merged`, `track_split` (the train reappeared too far away to be the same run: a new track starts, position kept) or `failed_minute`.';
COMMENT ON COLUMN import.data_issues.original_lat IS 'Latitude as published.';
COMMENT ON COLUMN import.data_issues.original_lon IS 'Longitude as published.';
COMMENT ON COLUMN import.data_issues.fixed_lat IS 'Latitude after fixing (as in positions). Empty when the row was dropped.';
COMMENT ON COLUMN import.data_issues.fixed_lon IS 'Longitude after fixing. Empty when the row was dropped.';
COMMENT ON COLUMN import.data_issues.note IS 'Explanation for `duplicate_merged`, `track_split` and `failed_minute`.';
COMMENT ON COLUMN import.data_issues.feed IS 'Realtime feed the train comes from: `rodalies` (RENFE Cercanias/Rodalies feed, which also carries the regional lines), `ld` (RENFE long and medium distance feed) or `fgc` (FGC positions). For `failed_minute`, the raw feed that could not be fetched.';

-- Geometry examples (not run). Build your real tables from import.* with INSERT ... SELECT:
--   SELECT station_id, ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS geom FROM import.stations;
--   SELECT shape_id, ST_GeomFromText(geometry_wkt, 4326) AS geom FROM import.shapes;
--   SELECT way_id, ST_GeomFromText(geometry_wkt, 4326) AS geom FROM import.tracks;
-- Distances in metres in Catalonia: ST_Transform(geom, 25831), or geography: geom::geography.
-- Note: "end" (stops, incidents) is a reserved word and must be quoted.
