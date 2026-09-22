# Why we build MLflow instead of pulling ghcr.io/mlflow/mlflow:
#   1. We need psycopg2 (Postgres backend) and boto3 (S3 artifact store) in the
#      image. The published image ships neither, so it cannot use the backends
#      this platform is built on.
#   2. Building here guarantees an arm64 image on an arm64 machine. No
#      "exec format error" surprises on the Jetson.
#
# python:3.11-slim is multi-arch and small. Pin the MLflow version: an
# unpinned tracking server that silently upgrades will one day refuse to read
# a run logged by an older client, and you will lose an afternoon to it.
FROM python:3.11-slim

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# build-essential and libpq-dev are needed to compile psycopg2 on arm64,
# where a prebuilt wheel is not always available. They are removed in the same
# RUN layer so they never reach the final image.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential libpq-dev curl \
 && pip install --no-cache-dir \
      "mlflow==2.22.0" \
      "psycopg2-binary==2.9.10" \
      "boto3==1.38.0" \
 && apt-get purge -y --auto-remove build-essential libpq-dev \
 && rm -rf /var/lib/apt/lists/*

EXPOSE 5000

# No CMD: the command comes from docker-compose.yml so the backend URIs stay
# next to the rest of the platform config rather than baked into the image.
