
-- 1. ESTACIONS (Stations)
CREATE TABLE IF NOT EXISTS public.stations (
    station_id VARCHAR(50) PRIMARY KEY,
    operator VARCHAR(20),
    code VARCHAR(20),
    name VARCHAR(100),
    municipality VARCHAR(100),
    province VARCHAR(100),
    interchange_id VARCHAR(50),
    source VARCHAR(50),
    geom GEOMETRY(Point, 4326)
);

TRUNCATE TABLE public.stations CASCADE;
INSERT INTO public.stations (station_id, operator, code, name, municipality, province, interchange_id, source, geom)
SELECT station_id, operator, code, name, municipality, province, interchange_id, source,
       ST_SetSRID(ST_MakePoint(lon, lat), 4326) AS geom
FROM import.stations
ON CONFLICT (station_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_stations_geom ON public.stations USING GIST (geom);


-- 2. LÍNIES (Routes)
CREATE TABLE IF NOT EXISTS public.routes (
    route_id VARCHAR(50) PRIMARY KEY,
    operator VARCHAR(20),
    service VARCHAR(30),
    short_name VARCHAR(50),
    long_name VARCHAR(255),
    color VARCHAR(10)
);

TRUNCATE TABLE public.routes CASCADE;
INSERT INTO public.routes (route_id, operator, service, short_name, long_name, color)
SELECT route_id, operator, service, short_name, long_name, color
FROM import.routes
ON CONFLICT (route_id) DO NOTHING;


-- 3. TRAÇATS (Shapes)
CREATE TABLE IF NOT EXISTS public.shapes (
    shape_id VARCHAR(50) PRIMARY KEY,
    operator VARCHAR(20),
    geom GEOMETRY(Geometry, 4326)
);

TRUNCATE TABLE public.shapes CASCADE;
INSERT INTO public.shapes (shape_id, operator, geom)
SELECT shape_id, operator, ST_GeomFromText(geometry_wkt, 4326) AS geom
FROM import.shapes
WHERE geometry_wkt IS NOT NULL AND geometry_wkt <> ''
ON CONFLICT (shape_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_shapes_geom ON public.shapes USING GIST (geom);


-- 4. VIATGES PROGRAMATS (Trips)
CREATE TABLE IF NOT EXISTS public.trips (
    trip_id VARCHAR(100) PRIMARY KEY,
    operator VARCHAR(20),
    route_id VARCHAR(50) REFERENCES public.routes(route_id),
    service_date DATE,
    train_number VARCHAR(50),
    headsign VARCHAR(150),
    direction_id INTEGER,
    shape_id VARCHAR(50) REFERENCES public.shapes(shape_id),
    timetable_snapshot DATE,
    source_trip_id VARCHAR(100),
    feed VARCHAR(30)
);

TRUNCATE TABLE public.trips CASCADE;
INSERT INTO public.trips (
    trip_id, operator, route_id, service_date, train_number, 
    headsign, direction_id, shape_id, timetable_snapshot, source_trip_id, feed
)
SELECT 
    trip_id, operator, route_id, service_date, train_number, 
    headsign, direction_id, 
    CASE WHEN shape_id <> '' AND EXISTS (SELECT 1 FROM public.shapes s WHERE s.shape_id = import.trips.shape_id) 
         THEN shape_id ELSE NULL END,
    timetable_snapshot, source_trip_id, feed
FROM import.trips
ON CONFLICT (trip_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_trips_route ON public.trips(route_id);
CREATE INDEX IF NOT EXISTS idx_trips_date ON public.trips(service_date);


-- 5. POSICIONS EN TEMPS REAL / HISTÒRIC (Positions - 1 Milió de registres)
CREATE TABLE IF NOT EXISTS public.positions (
    time TIMESTAMPTZ NOT NULL,
    train_id VARCHAR(100) NOT NULL,
    operator VARCHAR(20),
    vehicle_id VARCHAR(50),
    trip_id VARCHAR(100),
    other_trip_ids TEXT,
    route_id VARCHAR(50),
    geom GEOMETRY(Point, 4326),
    movement VARCHAR(30),
    station_id VARCHAR(50),
    next_station_id VARCHAR(50),
    delay_s INTEGER,
    speed_kmh DOUBLE PRECISION,
    position_fixed BOOLEAN,
    carried_forward BOOLEAN,
    feed VARCHAR(30),
    raw_trip_id VARCHAR(100),
    PRIMARY KEY (time, train_id)
);

TRUNCATE TABLE public.positions;
INSERT INTO public.positions (
    time, train_id, operator, vehicle_id, trip_id, other_trip_ids, route_id, 
    geom, movement, station_id, next_station_id, delay_s, speed_kmh, 
    position_fixed, carried_forward, feed, raw_trip_id
)
SELECT 
    time, train_id, operator, vehicle_id, 
    NULLIF(trip_id, ''), other_trip_ids, NULLIF(route_id, ''),
    CASE WHEN lat IS NOT NULL AND lon IS NOT NULL 
         THEN ST_SetSRID(ST_MakePoint(lon, lat), 4326) 
         ELSE NULL END AS geom,
    movement, NULLIF(station_id, ''), NULLIF(next_station_id, ''), 
    delay_s, speed_kmh, position_fixed, carried_forward, feed, raw_trip_id
FROM import.positions
ON CONFLICT (time, train_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_positions_geom ON public.positions USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_positions_time ON public.positions (time);
CREATE INDEX IF NOT EXISTS idx_positions_trip ON public.positions (trip_id);
CREATE INDEX IF NOT EXISTS idx_positions_route ON public.positions (route_id);


-- 6. RETARDS DELS VIATGES (Trip Delays)
CREATE TABLE IF NOT EXISTS public.trip_delays (
    time TIMESTAMPTZ NOT NULL,
    trip_id VARCHAR(100) NOT NULL,
    delay_s INTEGER,
    source VARCHAR(30),
    on_time BOOLEAN,
    PRIMARY KEY (time, trip_id, source)
);

TRUNCATE TABLE public.trip_delays;
INSERT INTO public.trip_delays (time, trip_id, delay_s, source, on_time)
SELECT time, trip_id, delay_s, source, on_time
FROM import.trip_delays
ON CONFLICT DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_trip_delays_time ON public.trip_delays (time);
CREATE INDEX IF NOT EXISTS idx_trip_delays_trip ON public.trip_delays (trip_id);


-- 7. VIES D'OPENSTREETMAP (Tracks)
CREATE TABLE IF NOT EXISTS public.tracks (
    way_id VARCHAR(50) PRIMARY KEY,
    railway TEXT,
    name TEXT,
    infrastructure_operator TEXT,
    gauge TEXT,
    electrified TEXT,
    voltage TEXT,
    maxspeed_kmh INTEGER,
    usage TEXT,
    geom GEOMETRY(LineString, 4326)
);

TRUNCATE TABLE public.tracks;
INSERT INTO public.tracks (
    way_id, railway, name, infrastructure_operator, gauge, 
    electrified, voltage, maxspeed_kmh, usage, geom
)
SELECT 
    way_id, railway, name, infrastructure_operator, gauge, 
    electrified, voltage, maxspeed_kmh, usage,
    ST_GeomFromText(geometry_wkt, 4326) AS geom
FROM import.tracks
WHERE geometry_wkt IS NOT NULL AND geometry_wkt <> ''
ON CONFLICT (way_id) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_tracks_geom ON public.tracks USING GIST (geom);


-- 8. INCIDÈNCIES (Incidents)
CREATE TABLE IF NOT EXISTS public.incidents (
    incident_id VARCHAR(100) PRIMARY KEY,
    type TEXT,
    start TIMESTAMPTZ,
    "end" TIMESTAMPTZ,
    operator TEXT,
    route_id TEXT,
    trip_id TEXT,
    train_id TEXT,
    station_id TEXT,
    geom GEOMETRY(Point, 4326),
    details TEXT,
    related_alert_id TEXT,
    evidence TEXT
);

TRUNCATE TABLE public.incidents;
INSERT INTO public.incidents (
    incident_id, type, start, "end", operator, route_id, 
    trip_id, train_id, station_id, geom, details, related_alert_id, evidence
)
SELECT 
    incident_id, type, start, "end", operator, route_id, 
    NULLIF(trip_id, ''), NULLIF(train_id, ''), NULLIF(station_id, ''),
    CASE WHEN lat IS NOT NULL AND lon IS NOT NULL 
         THEN ST_SetSRID(ST_MakePoint(lon, lat), 4326) 
         ELSE NULL END AS geom,
    details, related_alert_id, evidence
FROM import.incidents
ON CONFLICT (incident_id) DO NOTHING;


-- 9. PARADES PER VIATGE (Stop Times)
CREATE TABLE IF NOT EXISTS public.stop_times (
    trip_id VARCHAR(100) NOT NULL,
    stop_sequence INTEGER NOT NULL,
    station_id VARCHAR(50),
    arrival_time TIMESTAMPTZ,
    departure_time TIMESTAMPTZ,
    inside_boundary BOOLEAN,
    PRIMARY KEY (trip_id, stop_sequence)
);

TRUNCATE TABLE public.stop_times;
INSERT INTO public.stop_times (
    trip_id, stop_sequence, station_id, arrival_time, departure_time, inside_boundary
)
SELECT
    trip_id,
    stop_sequence,
    NULLIF(station_id, ''),
    arrival_time,
    departure_time,
    inside_boundary
FROM import.stop_times
ON CONFLICT (trip_id, stop_sequence) DO NOTHING;

CREATE INDEX IF NOT EXISTS idx_stop_times_station ON public.stop_times (station_id);
CREATE INDEX IF NOT EXISTS idx_stop_times_trip ON public.stop_times (trip_id);


-- 10. ÍNDEX PER AL PANELL DE SORTIDES D'ESTACIONS
CREATE INDEX IF NOT EXISTS idx_stop_times_station_departure 
ON public.stop_times (station_id, departure_time);


-- 11. FUNCIÓ DE FIABILITAT PER NÚMERO DE TREN (últims X dies, màx 4)
CREATE OR REPLACE FUNCTION public.train_reliability(
    p_train_number VARCHAR,
    p_dias INTEGER DEFAULT 4
)
RETURNS TABLE (
    train_number VARCHAR,
    dies_analitzats INTEGER,
    total_observacions BIGINT,
    observacions_amb_retard BIGINT,
    percentatge_retard NUMERIC(5,2),
    percentatge_puntualitat NUMERIC(5,2)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_dias INTEGER := LEAST(GREATEST(COALESCE(p_dias, 4), 1), 4);
    v_max_date DATE;
BEGIN
    SELECT MAX(service_date) INTO v_max_date FROM public.trips;

    RETURN QUERY
    WITH dades_filtrades AS (
        SELECT
            t.train_number,
            td.delay_s,
            td.on_time,
            CASE 
                WHEN td.delay_s IS NOT NULL THEN (td.delay_s > 300)
                WHEN td.on_time IS NOT NULL THEN (NOT td.on_time)
                ELSE FALSE
            END AS es_retard
        FROM public.trips t
        JOIN public.trip_delays td ON t.trip_id = td.trip_id
        WHERE t.train_number = p_train_number
          AND t.service_date > (v_max_date - v_dias)
    )
    SELECT
        p_train_number AS train_number,
        v_dias AS dies_analitzats,
        COUNT(*) AS total_observacions,
        COUNT(*) FILTER (WHERE es_retard) AS observacions_amb_retard,
        ROUND(
            COALESCE(COUNT(*) FILTER (WHERE es_retard)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 0),
            2
        ) AS percentatge_retard,
        ROUND(
            COALESCE(COUNT(*) FILTER (WHERE NOT es_retard)::NUMERIC / NULLIF(COUNT(*), 0) * 100, 0),
            2
        ) AS percentatge_puntualitat
    FROM dades_filtrades;
END;
$$;



