"""ALPR dataset pipeline — the end-to-end path of Project 1.

WHAT THIS DAG PROVES

It takes raw plate-read files sitting in object storage and turns them into a
frozen, quality-checked, versioned dataset that a training run can pin to —
and it refuses to publish anything that fails the quality suite.

    discover  ->  register  ->  build  ->  validate  ->  publish  ->  freeze
      (S3)        (catalog)    (split)      (GE)       (verdict)    (gate)

The last step is the one that matters. `freeze` calls an endpoint that returns
409 unless quality passed, so a bad dataset does not become a citable version.
The gate is enforced by the catalog service, not by the pipeline's good
manners — a pipeline can be edited by anyone, a server-side invariant cannot.

WHY TASKFLOW (@task) RATHER THAN PythonOperator

@task functions return values, and Airflow passes them between tasks through
XCom automatically. Written with PythonOperator you would push and pull XComs
by hand, and the data dependency between tasks would live in `>>` arrows rather
than in the function signatures. Here the dependency graph is derived from
which function's output feeds which function's argument — the code reads like
Python and the DAG picture is a consequence.

IDEMPOTENCY

Re-running a task must be safe. Airflow retries on failure and backfills over
past dates, so any task that is not idempotent will eventually corrupt
something. Here: `build` writes to a path keyed by the run's logical date, and
`register` skips sources whose URI is already catalogued. Say this out loud if
asked what makes a DAG production-ready — it is the first thing that separates
a scheduled script from a pipeline.
"""

from __future__ import annotations

import io
import json
import logging
import os
from datetime import datetime, timedelta, timezone

import pendulum
from airflow.decorators import dag, task
from airflow.exceptions import AirflowFailException

log = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration. Read from the environment so the same DAG file runs against
# the local MinIO stack and against Azure Data Lake with no edit.
# ---------------------------------------------------------------------------
DATASET_API = os.getenv("DATASET_API_URL", "http://host.docker.internal:8080")
S3_ENDPOINT = os.getenv("MLFLOW_S3_ENDPOINT_URL", "http://minio:9000")
S3_KEY = os.getenv("AWS_ACCESS_KEY_ID", "minioadmin")
S3_SECRET = os.getenv("AWS_SECRET_ACCESS_KEY", "minioadmin")

RAW_BUCKET = "raw"
CURATED_BUCKET = "curated"
DATASET_NAME = "gate-entry-alpr"


def _s3():
    """MinIO client. Imported lazily so DAG parsing never fails on a missing
    dependency — a DAG that will not import is invisible in the UI, which is a
    far more confusing failure than a task that errors with a clear message."""
    from minio import Minio

    return Minio(
        S3_ENDPOINT.replace("http://", "").replace("https://", ""),
        access_key=S3_KEY,
        secret_key=S3_SECRET,
        secure=S3_ENDPOINT.startswith("https"),
    )


def _api(method: str, path: str, payload: dict | None = None) -> dict:
    """Call the dataset catalog. Raises with the server's message on failure.

    Surfacing the API's own error text into the Airflow log is the difference
    between "task failed, exit 1" and "task failed: quality_gate_failed" — the
    second one you can act on without opening another tab.
    """
    import requests

    url = f"{DATASET_API}{path}"
    resp = requests.request(method, url, json=payload, timeout=30)
    if resp.status_code >= 400:
        raise AirflowFailException(
            f"{method} {path} -> {resp.status_code}: {resp.text[:500]}"
        )
    return resp.json() if resp.content else {}


@dag(
    dag_id="alpr_dataset_pipeline",
    # A fixed, past start_date plus catchup=False is the combination you want.
    # A start_date of "now" makes the first run never trigger; catchup=True on a
    # start_date months back schedules hundreds of backfill runs the moment you
    # unpause the DAG, which is the classic way to melt a laptop.
    start_date=pendulum.datetime(2026, 9, 1, tz="UTC"),
    schedule="@daily",
    catchup=False,
    max_active_runs=1,
    default_args={
        "owner": "abdiwahab",
        "retries": 2,
        "retry_delay": timedelta(minutes=1),
    },
    tags=["project-1", "data-platform", "quality-gate"],
    doc_md=__doc__,
)
def alpr_dataset_pipeline():

    @task
    def discover(**context) -> list[dict]:
        """List raw objects for this run's logical date.

        `logical_date` (not `datetime.now()`) is what makes a backfill
        meaningful: re-running the DAG for 2026-09-01 must process 2026-09-01's
        data, whenever you run it. A task that reads the wall clock cannot be
        backfilled and cannot be re-run to reproduce a past result.
        """
        client = _s3()
        if not client.bucket_exists(RAW_BUCKET):
            raise AirflowFailException(
                f"bucket '{RAW_BUCKET}' missing — run `make local-up` (minio-init creates it)"
            )

        day = context["logical_date"].strftime("%Y-%m-%d")
        prefix = f"alpr/{day}/"

        found = []
        for obj in client.list_objects(RAW_BUCKET, prefix=prefix, recursive=True):
            if not obj.object_name.endswith(".csv"):
                continue
            found.append({
                "uri": f"s3://{RAW_BUCKET}/{obj.object_name}",
                "object": obj.object_name,
                "size": obj.size,
                # Path convention: alpr/<date>/<site>/<camera>.csv
                "site": obj.object_name.split("/")[2] if len(obj.object_name.split("/")) > 3 else "unknown",
                "camera_id": obj.object_name.split("/")[-1].removesuffix(".csv"),
                "day": day,
            })

        if not found:
            raise AirflowFailException(
                f"no objects under s3://{RAW_BUCKET}/{prefix} — "
                "seed some with: python scripts/seed_demo_data.py"
            )
        log.info("discovered %d raw objects under %s", len(found), prefix)
        return found

    @task
    def ensure_dataset() -> str:
        """Create the dataset if it does not exist. Idempotent by design.

        409 (conflict) is treated as success: "it already exists" is the state
        we wanted. Treating a conflict as an error here would make every run
        after the first one fail.
        """
        import requests

        resp = requests.get(f"{DATASET_API}/api/v1/datasets/{DATASET_NAME}", timeout=30)
        if resp.status_code == 200:
            return DATASET_NAME

        _api("POST", "/api/v1/datasets", {
            "name": DATASET_NAME,
            "description": "Licence-plate reads from perimeter gate cameras.",
            "owner": "abdiwahab",
            # Plate numbers identify a vehicle and, in practice, a person.
            # Classifying this honestly at creation is what makes the
            # governance gates in Project 6 meaningful rather than decorative.
            "pii": "direct",
            "retention_days": 90,
        })
        log.info("created dataset %s", DATASET_NAME)
        return DATASET_NAME

    @task
    def register(objects: list[dict]) -> list[str]:
        """Register each raw object as a Source, skipping ones already known."""
        import requests

        existing = requests.get(
            f"{DATASET_API}/api/v1/sources", params={"limit": 1000}, timeout=30
        ).json()
        known = {item["uri"] for item in existing.get("items", [])}

        ids: list[str] = []
        for o in objects:
            if o["uri"] in known:
                # Find and reuse the existing id rather than creating a duplicate.
                match = next(i for i in existing["items"] if i["uri"] == o["uri"])
                ids.append(match["id"])
                continue

            day = datetime.strptime(o["day"], "%Y-%m-%d").replace(tzinfo=timezone.utc)
            created = _api("POST", "/api/v1/sources", {
                "kind": "alpr",
                "camera_id": o["camera_id"],
                "site": o["site"],
                "uri": o["uri"],
                "captured_from": day.isoformat().replace("+00:00", "Z"),
                "captured_to": (day + timedelta(days=1)).isoformat().replace("+00:00", "Z"),
                "size_bytes": o["size"],
            })
            ids.append(created["id"])

        log.info("registered/resolved %d sources", len(ids))
        return ids

    @task
    def build(objects: list[dict], source_ids: list[str], **context) -> dict:
        """Concatenate, deduplicate, split, and write the curated table.

        The split is deterministic: rows are assigned by a hash of the plate,
        not by a random shuffle. This matters more than it looks. A random
        split re-run tomorrow puts different rows in test, so yesterday's test
        score is no longer comparable — and worse, a plate seen in training can
        reappear in test, leaking information and inflating the metric. Hashing
        a stable key fixes both. This is the kind of detail an interviewer
        remembers.
        """
        import hashlib

        import pandas as pd

        client = _s3()
        frames = []
        for o in objects:
            data = client.get_object(RAW_BUCKET, o["object"]).read()
            df = pd.read_csv(io.BytesIO(data))
            df["source_uri"] = o["uri"]
            frames.append(df)

        raw = pd.concat(frames, ignore_index=True)
        before = len(raw)

        # Dedup on the natural key. The same plate read by the same camera at
        # the same instant is one event, however many files it landed in.
        raw = raw.drop_duplicates(subset=["plate", "camera_id", "captured_at"])
        deduped = len(raw)

        def assign_split(plate: str) -> str:
            h = int(hashlib.sha256(str(plate).encode()).hexdigest(), 16) % 100
            if h < 70:
                return "train"
            if h < 85:
                return "val"
            return "test"

        raw["split"] = raw["plate"].map(assign_split)

        day = context["logical_date"].strftime("%Y-%m-%d")
        key = f"{DATASET_NAME}/{day}/data.csv"

        buf = io.BytesIO(raw.to_csv(index=False).encode())
        client.put_object(CURATED_BUCKET, key, buf, length=buf.getbuffer().nbytes,
                          content_type="text/csv")

        splits = raw["split"].value_counts().to_dict()
        log.info("built %d rows (deduped %d) -> s3://%s/%s | splits=%s",
                 deduped, before - deduped, CURATED_BUCKET, key, splits)

        return {
            "storage_uri": f"s3://{CURATED_BUCKET}/{key}",
            "object": key,
            "row_count": int(deduped),
            "duplicates_removed": int(before - deduped),
            "splits": {k: int(v) for k, v in splits.items()},
            "source_ids": source_ids,
        }

    @task
    def create_version(built: dict) -> dict:
        """Cut a new dataset version. The server assigns the number."""
        v = _api("POST", f"/api/v1/datasets/{DATASET_NAME}/versions", {
            "source_ids": built["source_ids"],
            "row_count": built["row_count"],
            "splits": built["splits"],
            "storage_uri": built["storage_uri"],
            # Stamping the code version onto the data version is what closes
            # the reproducibility loop. Without it you know what the data was
            # but not what produced it.
            "git_commit": os.getenv("GIT_COMMIT", "unknown"),
            "created_by": "airflow:alpr_dataset_pipeline",
        })
        log.info("created %s version %d", DATASET_NAME, v["version"])
        return {"version": v["version"], "object": built["object"]}

    @task
    def validate(built: dict, version: dict) -> dict:
        """Run the expectation suite and write an HTML report to object storage."""
        import sys

        import pandas as pd

        # /opt/airflow/quality is the compose mount of pipelines/quality/.
        sys.path.insert(0, "/opt/airflow/quality")
        from expectations import alpr_suite, render_html_report, run_suite  # noqa: E402

        client = _s3()
        data = client.get_object(CURATED_BUCKET, built["object"]).read()
        df = pd.read_csv(io.BytesIO(data))

        result = run_suite(df, alpr_suite(min_rows=1))

        report_key = f"{DATASET_NAME}/reports/v{version['version']}.html"
        html = render_html_report(
            result, f"{DATASET_NAME} v{version['version']} — data quality"
        ).encode()
        client.put_object(CURATED_BUCKET, report_key, io.BytesIO(html),
                          length=len(html), content_type="text/html")

        log.info("quality: %s (%s)", "PASSED" if result["success"] else "FAILED",
                 result["statistics"])
        if not result["success"]:
            log.warning("failed expectations: %s", result["failed_expectations"])

        return {
            "success": result["success"],
            "failed": result["failed_expectations"],
            "report_uri": f"s3://{CURATED_BUCKET}/{report_key}",
            "version": version["version"],
        }

    @task
    def publish_quality(verdict: dict) -> dict:
        """Record the verdict on the version. Recording is not gating."""
        _api("PUT",
             f"/api/v1/datasets/{DATASET_NAME}/versions/{verdict['version']}/quality",
             {
                 "status": "passed" if verdict["success"] else "failed",
                 "report_uri": verdict["report_uri"],
                 "failed_checks": verdict["failed"],
             })
        return verdict

    @task
    def freeze(verdict: dict) -> str:
        """Freeze the version — refused by the server unless quality passed.

        If this raises, that is the gate working. A failed pipeline here is the
        correct outcome for bad data, and the dataset version stays in the
        catalog unfrozen, with its report attached, for someone to look at.
        """
        if not verdict["success"]:
            raise AirflowFailException(
                "quality gate blocked the freeze: "
                f"{verdict['failed']} — report at {verdict['report_uri']}"
            )

        frozen = _api(
            "POST",
            f"/api/v1/datasets/{DATASET_NAME}/versions/{verdict['version']}/freeze",
        )
        msg = (f"{DATASET_NAME} v{frozen['version']} frozen "
               f"({frozen['row_count']} rows) — safe to train on")
        log.info(msg)
        return msg

    # ---- the graph ---------------------------------------------------------
    # Dependencies come from the data flow: ensure_dataset() must finish before
    # register() because register writes into that dataset, and that ordering
    # is expressed with an explicit arrow since no value passes between them.
    objects = discover()
    ds = ensure_dataset()
    ids = register(objects)
    ds >> ids

    built = build(objects, ids)
    version = create_version(built)
    verdict = validate(built, version)
    freeze(publish_quality(verdict))


alpr_dataset_pipeline()
