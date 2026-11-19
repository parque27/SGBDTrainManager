# OCEMT
OCEMT is a train manager web application to monitor train data.

[Wiki](https://github.com/parque27/SGBDTrainManager/wiki)

## Run it

```bash
cp .env.example .env
docker compose up -d --build
docker compose ps
```

Starts PostgreSQL + PostGIS, Redis and the backend API (http://localhost:8080/docs).
See [backend/README.md](backend/README.md) for loading the data, endpoints and tests.
