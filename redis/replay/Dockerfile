# Imagen del replay: Postgres → Redis minuto a minuto. La construye el docker-compose (servicio replay).
FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY replay.py .

CMD ["python", "-u", "replay.py"]
