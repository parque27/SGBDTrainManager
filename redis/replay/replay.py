"""Replay: reproduce en Redis los 5 días grabados, minuto a minuto.

Lee las posiciones de PostgreSQL (public.positions), o de los CSV de data/ si no hay
Postgres, y escribe en Redis el estado de cada minuto según redis/docs/modelo-de-claves.md.

El reloj simulado vive aquí, en la memoria del replay. Redis guarda la copia que lee el backend
(sim:clock y sim:snapshot), y el backend controla la simulación escribiendo en sim:control:
    HSET sim:control status paused                  # pausa (status playing para seguir)
    HSET sim:control speed 60                       # x60: un minuto simulado por segundo real
    HSET sim:control seek 2026-11-05T07:00:00Z      # saltar a ese minuto (UTC)

Normalmente lo arranca el docker-compose (servicio replay). A mano, desde la raíz del repo:
    python redis/replay/replay.py                                  # 5-nov, 06:00 en Barcelona
    python redis/replay/replay.py --start 2026-11-03T06:30:00Z --interval 1
    python redis/replay/replay.py --source csv                     # sin Postgres
"""

from __future__ import annotations

import argparse
import csv
import gzip
import json
import math
import os
import signal
import statistics
import time
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from itertools import groupby
from pathlib import Path
from zoneinfo import ZoneInfo

import psycopg
import redis
from psycopg.rows import dict_row

DATA = Path(__file__).resolve().parent.parent.parent / "data"  # data/ del repo (solo para --source csv)
MADRID = ZoneInfo("Europe/Madrid")
WAIT_S = 5  # cada cuánto se reintenta mientras Redis o Postgres no están listos

TRAIN_TTL = 180  # s reales: red de seguridad, si el replay se para todo lo "en vivo" caduca solo
DELAY_EVENT_S = 900  # a partir de 15 min de retraso se publica una incidencia
TS_RETENTION_MS = 7 * 24 * 3600 * 1000
HLL_TTL = 8 * 24 * 3600
TRAIL_LEN = 30  # posiciones (minutos simulados) que guarda la estela de cada tren

SNAPSHOT_KEY = "sim:snapshot"
SNAPSHOT_VERSION = 1  # se sube si se quitan o cambian campos de la foto (añadir no la cambia)
INCIDENTS_KEY = "sim:incidents"
CONTROL_KEY = "sim:control"
CONTROL_POLL_S = 0.5  # cada cuánto se mira sim:control mientras se espera al siguiente minuto
PAUSED_REFRESH_S = 30  # en pausa, cada cuánto se reescribe el minuto para que no caduque
SPEED_MIN, SPEED_MAX = 1.0, 600.0  # x1 = tiempo real; x600 = un minuto cada 0,1 s

# Errores de "Redis no está" (caído, reiniciando o cargando el AOF). Los demás sí son fallos del código.
REDIS_DOWN = (redis.ConnectionError, redis.TimeoutError)

# Se borran y se vuelven a crear en cada arranque: si cambia el esquema, se aplica solo
INDEXES = {
    "idx:trains": ["ON", "HASH", "PREFIX", "1", "train:", "SCHEMA",
                   "line", "TAG", "operator", "TAG", "service", "TAG", "movement", "TAG", "province", "TAG",
                   "trip_id", "TAG", "train_number", "TAG", "station", "TAG", "next_station", "TAG",
                   "delay_s", "NUMERIC", "SORTABLE", "location", "GEO",
                   "next_station_name", "TEXT", "headsign", "TEXT"],
    "idx:stations": ["ON", "HASH", "PREFIX", "1", "station:", "SCHEMA",
                     "name", "TEXT", "operator", "TAG", "province", "TAG", "location", "GEO"],
}


def read_csv(path: Path):
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8", newline="") as f:
        yield from csv.DictReader(f)


def parse(t: str) -> datetime:
    when = datetime.fromisoformat(t.strip().replace("Z", "+00:00"))
    return when if when.tzinfo else when.replace(tzinfo=timezone.utc)  # sin zona: UTC


def iso(t: datetime) -> str:
    return t.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(t: datetime | str) -> str:
    """Para los logs: la hora en UTC, como en el contrato, y la de Barcelona entre paréntesis."""
    when = parse(t) if isinstance(t, str) else t
    return f"{iso(when)[:16]}Z ({when.astimezone(MADRID):%d/%m %H:%M} en Barcelona)"


@dataclass
class Network:
    """Datos de la red que no cambian: se cargan una vez al arrancar."""
    routes: dict  # route_id -> operator, service, short_name, color
    stations: dict  # station_id -> operator, name, lat, lon, province
    trips: dict  # trip_id -> train_number, headsign

    def line_services(self) -> dict[tuple[str, str], str]:
        return {(r["operator"], r["short_name"]): r["service"] for r in self.routes.values() if r["short_name"]}


class PostgresSource:
    """Lee de public.positions: una consulta por minuto (usa el índice por time)."""

    # Todo sale como texto, igual que en los CSV, para que el resto del replay no dependa de la fuente
    POSITIONS_SQL = """
        SELECT p.train_id, p.operator, p.trip_id, p.route_id, p.movement, p.station_id, p.next_station_id,
               round(ST_Y(p.geom)::numeric, 6)::text AS lat, round(ST_X(p.geom)::numeric, 6)::text AS lon,
               p.delay_s::text AS delay_s, p.speed_kmh::text AS speed_kmh{province_col}
        FROM public.positions p{province_join}
        WHERE p.time = %s
        ORDER BY p.train_id"""
    # Si existe public.provinces (límites de las provincias), cruce espacial: en qué provincia está cada tren
    PROVINCE_COL = ", pv.name AS province"
    PROVINCE_JOIN = """
        LEFT JOIN LATERAL (SELECT pr.name FROM public.provinces pr
                           WHERE ST_Contains(pr.geom, p.geom) LIMIT 1) pv ON true"""

    INCIDENTS_SQL = """
        SELECT incident_id, type, operator, route_id, trip_id, train_id, station_id, start, "end", details
        FROM public.incidents
        WHERE start <= %(t)s AND ("end" IS NULL OR "end" > %(t)s)
        ORDER BY start, incident_id"""

    def __init__(self, dsn: str):
        self.dsn = dsn
        self.conn = self._wait_for_data(dsn)
        bounds = self.conn.execute("SELECT min(time) AS first, max(time) AS last FROM public.positions").fetchone()
        self.first, self.last = bounds["first"], bounds["last"]
        self.has_provinces = self.conn.execute(
            "SELECT to_regclass('public.provinces') IS NOT NULL AS ok").fetchone()["ok"]
        self.positions_sql = self.POSITIONS_SQL.format(
            province_col=self.PROVINCE_COL if self.has_provinces else "",
            province_join=self.PROVINCE_JOIN if self.has_provinces else "")
        print("Provincias: " + ("cruce espacial con public.provinces" if self.has_provinces
                                else "la de la estación (no hay public.provinces)"), flush=True)

    @staticmethod
    def _wait_for_data(dsn: str) -> psycopg.Connection:
        # La primera vez que arranca, Postgres tarda ~1 min en cargar los datos y su
        # healthcheck dice "healthy" antes de terminar: esperamos a que haya posiciones.
        while True:
            conn = None
            try:
                conn = psycopg.connect(dsn, autocommit=True, row_factory=dict_row, connect_timeout=5)
                if conn.execute("SELECT EXISTS (SELECT 1 FROM public.positions) AS ok").fetchone()["ok"]:
                    return conn
            except (psycopg.OperationalError, psycopg.errors.UndefinedTable):
                pass
            if conn is not None:
                conn.close()
            print(f"Esperando a que PostgreSQL tenga los datos cargados… (reintento en {WAIT_S} s)", flush=True)
            time.sleep(WAIT_S)

    def _query(self, sql: str, params=None) -> list[dict]:
        while True:
            try:
                rows = self.conn.execute(sql, params).fetchall()
                return [{k: "" if v is None else v for k, v in row.items()} for row in rows]
            except psycopg.OperationalError as exc:
                # Postgres reiniciado o caído: se reconecta y se repite la misma consulta
                print(f"PostgreSQL no responde ({type(exc).__name__}): reconecto…", flush=True)
                self.conn.close()
                self.conn = self._wait_for_data(self.dsn)

    def routes(self) -> dict:
        rows = self._query("SELECT route_id, operator, service, short_name, color FROM public.routes")
        return {row["route_id"]: row for row in rows}

    def stations(self) -> dict:
        province = ("coalesce(nullif(s.province, ''), (SELECT pr.name FROM public.provinces pr "
                    "WHERE ST_Contains(pr.geom, s.geom) LIMIT 1))" if self.has_provinces else "s.province")
        rows = self._query(f"""
            SELECT s.station_id, s.operator, s.name, {province} AS province,
                   round(ST_Y(s.geom)::numeric, 6)::text AS lat, round(ST_X(s.geom)::numeric, 6)::text AS lon
            FROM public.stations s""")
        return {row["station_id"]: row for row in rows}

    def trips(self) -> dict:
        rows = self._query("SELECT trip_id, train_number, headsign FROM public.trips")
        return {row["trip_id"]: row for row in rows}

    def incidents(self, t: str) -> list[dict]:
        """Incidencias oficiales (cancelaciones, avisos, paradas inesperadas) activas en el minuto t."""
        return self._query(self.INCIDENTS_SQL, {"t": parse(t)})

    def minutes(self, start: datetime, loop: bool):
        t = min(max(start.replace(second=0, microsecond=0), self.first), self.last)
        while True:
            while t <= self.last:
                yield iso(t), self._query(self.positions_sql, (t,))
                t += timedelta(minutes=1)
            if not loop:
                return
            t = self.first  # siguiente vuelta: desde el principio


class CsvSource:
    """Lee de los CSV de data/ (para trabajar sin Postgres). Sin incidencias oficiales."""

    POSITIONS = sorted((DATA / "realtime" / "positions").glob("*.csv.gz"))

    def __init__(self):
        # Aproximado (de la medianoche del primer día a la del último): solo sirve para "range" y "seek"
        self.first = self._file_end(self.POSITIONS[0]) - timedelta(days=1)
        self.last = self._file_end(self.POSITIONS[-1]) - timedelta(minutes=1)

    def routes(self) -> dict:
        return {row["route_id"]: row for row in read_csv(DATA / "network" / "routes.csv")}

    def stations(self) -> dict:
        return {row["station_id"]: row for row in read_csv(DATA / "network" / "stations.csv.gz")}

    def trips(self) -> dict:
        return {row["trip_id"]: row for row in read_csv(DATA / "network" / "trips.csv.gz")}

    def incidents(self, t: str) -> list[dict]:
        return []

    @staticmethod
    def _file_end(path: Path) -> datetime:
        """Cada archivo es un día de Madrid: termina a la medianoche siguiente de Madrid."""
        day = datetime.fromisoformat(path.name.split(".")[0])
        return (day + timedelta(days=1)).replace(tzinfo=MADRID).astimezone(timezone.utc)

    def minutes(self, start: datetime, loop: bool):
        """Los CSV ya vienen ordenados por (time, train_id)."""
        start_s = iso(start)
        while True:
            for path in self.POSITIONS:
                if self._file_end(path) <= start:
                    continue
                rows = (row for row in read_csv(path) if row["time"] >= start_s)
                for t, group in groupby(rows, key=lambda row: row["time"]):
                    yield t, list(group)
            if not loop:
                return
            start, start_s = datetime.min.replace(tzinfo=timezone.utc), ""  # siguiente vuelta: desde el principio


def connect_redis(url: str) -> redis.Redis:
    # Timeouts cortos: si Redis se cae, el replay se entera en segundos en vez de quedarse colgado
    r = redis.Redis.from_url(url, decode_responses=True, socket_connect_timeout=2, socket_timeout=5)
    while True:
        try:
            r.ping()
            return r
        except REDIS_DOWN:
            print(f"Esperando a Redis… (reintento en {WAIT_S} s)", flush=True)
            time.sleep(WAIT_S)


def setup(r: redis.Redis, net: Network) -> None:
    """Estaciones, índices y etiquetas de las series. Al arrancar y cada vez que Redis vuelve tras una caída."""
    pipe = r.pipeline(transaction=False)
    geo = []
    for s in net.stations.values():
        fields = {"name": s["name"], "operator": s["operator"], "location": f"{s['lon']},{s['lat']}"}
        if s.get("province"):
            fields["province"] = s["province"]
        pipe.hset(f"station:{s['station_id']}", mapping=fields)
        geo += [s["lon"], s["lat"], s["station_id"]]
    pipe.execute_command("GEOADD", "stations:geo", *geo)
    # Trenes, estelas y líneas que haya dejado una ejecución anterior (SCAN, nunca KEYS)
    for pattern in ("train:*", "trail:*", "line:*:trains"):
        for key in r.scan_iter(match=pattern, count=500):
            pipe.unlink(key)
    pipe.unlink("live:delays")
    pipe.execute()

    for name, args in INDEXES.items():
        try:
            r.execute_command("FT.DROPINDEX", name)  # sin DD: borra el índice, no los hashes
        except redis.ResponseError:
            pass  # no existía
        r.execute_command("FT.CREATE", name, *args)

    # Las etiquetas de una serie solo se ponen al crearla: TS.ALTER las pone (y reindexa) en las que ya hay
    services = net.line_services()
    pipe = r.pipeline(transaction=False)
    for prefix, metric in (("ts:delay:line:", "avg_delay"), ("ts:delay_max:line:", "max_delay")):
        for key in r.scan_iter(match=f"{prefix}*", count=500):
            op, line = key.removeprefix(prefix).split(":", 1)
            pipe.execute_command("TS.ALTER", key, "LABELS", "metric", metric, "operator", op, "line", line,
                                 "service", services.get((op, line)) or "unknown")
    pipe.execute()


class State:
    def __init__(self):
        self.line_keys: list[str] = []  # conjuntos line:… escritos en el minuto anterior
        self.delayed: set[str] = set()  # viajes que ya generaron incidencia de retraso
        self.present: dict[str, str] = {}  # trenes escritos en el minuto anterior -> su trip_id
        self.last_t: str | None = None  # último minuto que avanzó (para detectar saltos)


def _number(value: str, kind):
    return kind(value) if value not in ("", None) else None


def _incidents_doc(t: str, incidents: list[dict], net: Network) -> dict:
    items = [{
        "incident_id": inc["incident_id"], "type": inc["type"], "operator": inc["operator"] or None,
        "route_id": inc["route_id"] or None, "line": net.routes.get(inc["route_id"], {}).get("short_name") or None,
        "trip_id": inc["trip_id"] or None, "train_id": inc["train_id"] or None,
        "station_id": inc["station_id"] or None,
        "station_name": net.stations.get(inc["station_id"], {}).get("name") or None,
        "start": iso(inc["start"]) if inc["start"] else None, "end": iso(inc["end"]) if inc["end"] else None,
        "details": inc["details"] or None,
    } for inc in incidents]
    return {"simulated_at": t, "count": len(items), "incidents": items}


def write_minute(r: redis.Redis, t: str, rows: list[dict], incidents: list[dict], net: Network, state: State,
                 meta: dict, history: bool = True) -> None:
    """Escribe un minuto en Redis. Con history=False (pausa) solo refresca el estado actual:
    no añade puntos a las series, ni a las estelas, ni al contador del día, ni incidencias."""
    when = parse(t)
    ts_ms = int(when.timestamp() * 1000)
    day = when.astimezone(MADRID).date().isoformat()
    # Si no viene justo el minuto siguiente (salto, vuelta al principio, Redis caído), las estelas empiezan de cero
    jumped = history and state.last_t is not None and when - parse(state.last_t) != timedelta(minutes=1)

    # MULTI … EXEC: el minuto entero se aplica de golpe. Quien lea ve el minuto
    # anterior completo o el nuevo completo, nunca una mezcla.
    pipe = r.pipeline(transaction=True)
    geo, by_delay, live_delays, events, positions = [], [], [], [], []
    by_line: dict[str, list[str]] = defaultdict(list)
    line_delays: dict[tuple[str, str], list[int]] = defaultdict(list)
    line_service: dict[tuple[str, str], str] = {}
    delayed = set(state.delayed)  # se guarda en state solo si Redis acepta la transacción

    for row in rows:
        train, op = row["train_id"], row["operator"]
        route = net.routes.get(row["route_id"], {})
        trip = net.trips.get(row["trip_id"], {})
        line = route.get("short_name") or "?"
        station, next_station = net.stations.get(row["station_id"], {}), net.stations.get(row["next_station_id"], {})
        fields = {"line": line, "operator": op, "color": route.get("color", ""),
                  "movement": row["movement"], "time": t}
        optional = {
            "service": route.get("service", ""),
            "trip_id": row["trip_id"],
            "train_number": trip.get("train_number", ""),
            "headsign": trip.get("headsign", ""),
            "lat": row["lat"],
            "lon": row["lon"],
            "location": f"{row['lon']},{row['lat']}" if row["lat"] else "",
            "delay_s": row["delay_s"],
            "speed_kmh": row["speed_kmh"],
            "station": row["station_id"],
            "station_name": station.get("name", ""),
            "next_station": row["next_station_id"],
            "next_station_name": next_station.get("name", ""),
            # Del cruce con public.provinces si existe; si no, la de la estación donde está o a la que va
            "province": row.get("province") or station.get("province") or next_station.get("province") or "",
        }
        fields.update({k: v for k, v in optional.items() if v})
        key = f"train:{train}"
        pipe.hset(key, mapping=fields)
        missing = [k for k, v in optional.items() if not v]
        if missing:
            pipe.hdel(key, *missing)  # quita lo que valía el minuto anterior y ya no aplica
        pipe.expire(key, TRAIN_TTL)

        # Estela: lista con las últimas posiciones, la más nueva primero (LPUSH + LTRIM = lista con tope)
        trail = f"trail:{train}"
        if jumped:
            pipe.unlink(trail)
        if history and row["lat"]:
            pipe.lpush(trail, f"{row['lon']},{row['lat']},{t}")
            pipe.ltrim(trail, 0, TRAIL_LEN - 1)
        pipe.expire(trail, TRAIN_TTL)

        # Lo mismo para la foto, con números de verdad y null en lo que falta
        positions.append({
            "train_id": train, "trip_id": row["trip_id"] or None, "line": line, "operator": op,
            "service": optional["service"] or None, "color": route.get("color") or None,
            "train_number": optional["train_number"] or None, "headsign": optional["headsign"] or None,
            "lat": _number(row["lat"], float), "lon": _number(row["lon"], float),
            "delay_s": _number(row["delay_s"], int), "speed_kmh": _number(row["speed_kmh"], float),
            "movement": row["movement"],
            "station": row["station_id"] or None, "station_name": optional["station_name"] or None,
            "next_station": row["next_station_id"] or None,
            "next_station_name": optional["next_station_name"] or None,
            "province": optional["province"] or None,
        })

        if row["lat"]:
            geo += [row["lon"], row["lat"], train]
        by_line[f"line:{op}:{line}:trains"].append(train)
        if row["delay_s"]:
            delay = int(row["delay_s"])
            by_delay += [delay, train]
            line_delays[(op, line)].append(delay)
            line_service[(op, line)] = optional["service"] or "unknown"
            if row["trip_id"]:
                live_delays += [row["trip_id"], delay]
                if delay >= DELAY_EVENT_S and row["trip_id"] not in delayed:
                    delayed.add(row["trip_id"])
                    events.append(["type", "delay", "train", train, "trip", row["trip_id"],
                                   "line", line, "delay_s", delay, "time", t])
                elif delay < DELAY_EVENT_S:
                    delayed.discard(row["trip_id"])

    # Trenes del minuto anterior que ya no salen en este (o de antes de un salto): fuera. Así train:* y
    # idx:trains tienen exactamente los trenes del minuto, igual que la foto y trains:geo. Esperar a que
    # caduquen no vale: el TTL va en segundos reales y 180 s son hora y media simulada a x30.
    present = {row["train_id"]: row["trip_id"] for row in rows}
    gone = [train for train in state.present if train not in present]
    if gone:
        pipe.unlink(*[f"train:{train}" for train in gone], *[f"trail:{train}" for train in gone])
        trips_now = set(present.values())
        gone_trips = [state.present[train] for train in gone if state.present[train] not in ("", *trips_now)]
        if gone_trips:
            pipe.hdel("live:delays", *gone_trips)

    # Vistas "del minuto": se rehacen enteras
    pipe.delete("trains:geo", "trains:by_delay", *state.line_keys)
    if geo:
        pipe.execute_command("GEOADD", "trains:geo", *geo)
    if by_delay:
        pipe.execute_command("ZADD", "trains:by_delay", *by_delay)
    for key, members in by_line.items():
        pipe.sadd(key, *members)
    if live_delays:
        pipe.execute_command("HSETEX", "live:delays", "EX", TRAIN_TTL,
                             "FIELDS", len(live_delays) // 2, *live_delays)

    if history:
        # Historia corta: retraso medio y máximo por línea, el contador del día y las incidencias de retraso
        for (op, line), delays in line_delays.items():
            labels = ["operator", op, "line", line, "service", line_service[(op, line)]]
            for key, value, metric in ((f"ts:delay:line:{op}:{line}", round(statistics.fmean(delays)), "avg_delay"),
                                       (f"ts:delay_max:line:{op}:{line}", max(delays), "max_delay")):
                pipe.execute_command("TS.ADD", key, ts_ms, value, "RETENTION", TS_RETENTION_MS,
                                     "ON_DUPLICATE", "LAST", "LABELS", "metric", metric, *labels)
        if rows:
            pipe.pfadd(f"hll:trains:{day}", *[row["train_id"] for row in rows])
            pipe.expire(f"hll:trains:{day}", HLL_TTL)
        for event in events:
            pipe.execute_command("XADD", "events:trains", "IDMPAUTO", "replay", "MAXLEN", "~", 10000, "*", *event)

    # La foto entera del minuto, para el backend: un JSON.GET y tiene todo el mapa.
    # Un solo comando ya es atómico, y además va dentro de la misma transacción que lo demás.
    snapshot = {
        "version": SNAPSHOT_VERSION,
        "snapshot_id": int(time.time() * 1000),  # cambia en cada publicación
        "simulated_at": t,
        "published_at": iso(datetime.now(timezone.utc)),
        **meta,  # status, speed, range
        "count": len(positions),
        "positions": positions,
    }
    pipe.execute_command("JSON.SET", SNAPSHOT_KEY, "$", json.dumps(snapshot, ensure_ascii=False,
                                                                   separators=(",", ":")))
    pipe.expire(SNAPSHOT_KEY, TRAIN_TTL)

    # Incidencias oficiales activas en este minuto, del mismo minuto que la foto
    pipe.execute_command("JSON.SET", INCIDENTS_KEY, "$", json.dumps(_incidents_doc(t, incidents, net),
                                                                    ensure_ascii=False, separators=(",", ":")))
    pipe.expire(INCIDENTS_KEY, TRAIN_TTL)

    pipe.set("sim:clock", t)
    # El aviso lleva lo justo para que la web actualice el reloj y decida si pide la foto otra vez
    pipe.publish("ocemt:clock", json.dumps({"simulated_at": t, "status": meta["status"], "speed": meta["speed"],
                                            "snapshot_id": snapshot["snapshot_id"]}, separators=(",", ":")))
    pipe.execute()
    state.line_keys = list(by_line)
    state.present = present
    if history:
        state.delayed = delayed
        state.last_t = t


@dataclass(frozen=True)
class Control:
    status: str  # playing | paused
    speed: float  # minutos simulados por minuto real (30 = un minuto cada 2 s)

    @property
    def interval(self) -> float:
        return 60 / self.speed

    def __str__(self) -> str:
        return "en pausa" if self.status == "paused" else f"reproduciendo x{self.speed:g}"


class Controller:
    """Lee sim:control, que escribe el backend. Si falta un campo, vale lo de la línea de comandos.
    Si Redis no responde, se sigue con lo último que se sabía: el reloj no depende de Redis."""

    def __init__(self, default: Control):
        self.default = default
        self.current = default
        self._last_raw: dict | None = None

    def poll(self, r: redis.Redis) -> tuple[bool, datetime | None]:
        """Devuelve (ha cambiado status o speed, minuto al que saltar o None)."""
        try:
            raw = r.hgetall(CONTROL_KEY)
            # seek es una orden de una sola vez: HGETDEL (Redis 8.0) la lee y la borra en un solo paso
            seek_raw = r.execute_command("HGETDEL", CONTROL_KEY, "FIELDS", 1, "seek")[0] if "seek" in raw else None
        except REDIS_DOWN:
            return False, None

        seek = None
        if seek_raw:
            try:
                seek = parse(seek_raw)
            except ValueError:
                print(f"sim:control: seek «{seek_raw}» no es una fecha ISO (2026-11-05T07:00:00Z)", flush=True)

        settings = {k: v for k, v in raw.items() if k != "seek"}
        if settings == self._last_raw:  # status y speed como estaban: nada que revisar
            return False, seek
        self._last_raw = settings

        status = settings.get("status", self.default.status)
        if status not in ("playing", "paused"):
            print(f"sim:control: status «{status}» no vale (playing o paused), lo ignoro", flush=True)
            status = self.current.status
        speed = self.default.speed
        if "speed" in settings:
            try:
                speed = float(settings["speed"])
                if not math.isfinite(speed):
                    raise ValueError
            except ValueError:
                print(f"sim:control: speed «{settings['speed']}» no es un número, lo ignoro", flush=True)
                speed = self.current.speed
            else:
                clamped = min(max(speed, SPEED_MIN), SPEED_MAX)
                if clamped != speed:
                    print(f"sim:control: speed {speed:g} fuera de {SPEED_MIN:g}–{SPEED_MAX:g}, uso {clamped:g}",
                          flush=True)
                speed = clamped

        new = Control(status, speed)
        changed, self.current = new != self.current, new
        return changed, seek


def run(r: redis.Redis, source, net: Network, start: datetime, loop: bool, control: Controller) -> None:
    state = State()
    data_range = {"first": iso(source.first), "last": iso(source.last)}
    minutes = source.minutes(start, loop)
    current: tuple[str, list[dict], list[dict]] | None = None  # (minuto, posiciones, incidencias activas)
    finished = False  # solo con --no-loop, al llegar al final de los datos
    redis_ok = True
    last_tick = time.monotonic() - control.current.interval  # el primer minuto sale ya
    last_publish = 0.0

    def publish(history: bool) -> None:
        nonlocal redis_ok, last_publish
        last_publish = time.monotonic()
        if current is None:  # no hay datos que enseñar
            return
        t, rows, incidents = current
        status = "finished" if finished else control.current.status
        speed = control.current.speed
        meta = {"status": status, "speed": int(speed) if speed.is_integer() else speed, "range": data_range}
        try:
            if not redis_ok:
                setup(r, net)  # Redis ha vuelto: por si ha vuelto vacío. Deja los trenes a cero
                state.line_keys, state.present = [], {}
            started = time.perf_counter()
            write_minute(r, t, rows, incidents, net, state, meta, history=history)
        except REDIS_DOWN as exc:
            if redis_ok:
                print(f"Redis no responde ({type(exc).__name__}): el reloj sigue y reintento cada minuto", flush=True)
            redis_ok = False
            return
        if not redis_ok:
            print("Redis ha vuelto: estaciones e índices recargados, sigo escribiendo", flush=True)
            redis_ok = True
        if history:
            ms = (time.perf_counter() - started) * 1000
            print(f"{stamp(t)}  {len(rows):4d} trenes  {len(incidents):3d} incidencias  escrito en {ms:5.1f} ms",
                  flush=True)

    while True:
        changed, seek = control.poll(r)
        if changed:
            print(f"Control: {control.current}", flush=True)
        now = time.monotonic()
        if seek:
            seek = min(max(seek, source.first), source.last)
            print(f"Salto a {stamp(seek)}", flush=True)
            minutes = source.minutes(seek, loop)
            finished = False
            last_tick = now - control.current.interval  # el minuto pedido sale ya, aunque esté en pausa

        playing = control.current.status == "playing" and not finished
        due = last_tick + control.current.interval
        if current is None or seek or (playing and now >= due):
            try:
                t, rows = next(minutes)
            except StopIteration:
                finished = True
                print("Fin de los datos: me quedo en el último minuto (sim:control seek para volver)", flush=True)
                publish(history=False)
            else:
                current = (t, rows, source.incidents(t))
                # Sin acumular retraso: si una vuelta ha ido lenta, se sigue desde ahora
                last_tick = due if now - due < control.current.interval else now
                publish(history=True)
        elif changed or now - last_publish >= PAUSED_REFRESH_S:
            # En pausa (o con Redis caído): se reescribe el mismo minuto para que no caduque
            # y para que la foto diga el estado nuevo en cuanto cambia
            publish(history=False)

        wait = CONTROL_POLL_S
        if control.current.status == "playing" and not finished:
            wait = min(wait, max(0.0, last_tick + control.current.interval - time.monotonic()))
        time.sleep(wait)


def _stop(*_) -> None:
    raise KeyboardInterrupt  # docker compose stop manda SIGTERM: parar en el momento, sin esperar 10 s


def main() -> None:
    # Cada opción también se puede dar por variable de entorno (así la configura el docker-compose)
    parser = argparse.ArgumentParser(description="Reproduce en Redis los trenes grabados, minuto a minuto.")
    parser.add_argument("--start", default=os.getenv("REPLAY_START", "2026-11-05T05:00:00Z"),
                        help="primer minuto, en UTC (por defecto 06:00 en Barcelona del 5-nov)")
    parser.add_argument("--interval", type=float, default=float(os.getenv("REPLAY_INTERVAL", "2")),
                        help="segundos reales por cada minuto de datos (2 = 30 veces más rápido)")
    parser.add_argument("--source", choices=["postgres", "csv"], default=os.getenv("REPLAY_SOURCE", "postgres"),
                        help="de dónde leer las posiciones")
    parser.add_argument("--no-loop", action="store_true", help="parar al llegar al final de los datos")
    parser.add_argument("--redis-url", default=os.getenv("REDIS_URL", "redis://localhost:6379/0"))
    parser.add_argument("--database-url",
                        default=os.getenv("DATABASE_URL", "postgresql://root:root@localhost:5432/ocemt"))
    args = parser.parse_args()
    speed = min(max(60 / args.interval, SPEED_MIN), SPEED_MAX) if args.interval > 0 else 30.0

    signal.signal(signal.SIGTERM, _stop)
    try:
        r = connect_redis(args.redis_url)
        source = PostgresSource(args.database_url) if args.source == "postgres" else CsvSource()
        net = Network(source.routes(), source.stations(), source.trips())
        setup(r, net)
        control = Controller(Control("playing", speed))
        print(f"Replay desde {stamp(args.start)} ({args.source}), x{speed:g} (un minuto cada {60 / speed:g} s). "
              f"Se controla con {CONTROL_KEY}. Ctrl+C para parar.", flush=True)
        run(r, source, net, parse(args.start), not args.no_loop, control)
    except KeyboardInterrupt:
        print("\nReplay parado.", flush=True)


if __name__ == "__main__":
    main()
