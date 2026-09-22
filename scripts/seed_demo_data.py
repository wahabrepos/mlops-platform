#!/usr/bin/env python3
"""Generate synthetic ALPR plate reads and upload them to the raw bucket.

The platform needs data before any of it is demonstrable, and using real
camera footage or real plate numbers for a portfolio project would be both
impractical and a privacy problem. Synthetic data solves that, and the
generator itself is useful: it can produce *deliberately broken* data on
demand, which is how you prove the quality gate works rather than asserting it.

    # a clean day — the pipeline should freeze the version
    python scripts/seed_demo_data.py --date 2026-09-01

    # a broken day — the pipeline should refuse to freeze
    python scripts/seed_demo_data.py --date 2026-09-02 --corrupt

Object layout, which the DAG's discover() task depends on:

    s3://raw/alpr/<YYYY-MM-DD>/<site>/<camera-id>.csv

Requires:  pip install minio pandas
"""

from __future__ import annotations

import argparse
import io
import random
import sys
from datetime import datetime, timedelta, timezone

RAW_BUCKET = "raw"

SITES = {
    "gate-north": ["cam-07", "cam-08"],
    "gate-south": ["cam-11"],
}

# Plate shapes loosely modelled on Polish registrations: a 2-3 letter regional
# prefix, then 4-5 alphanumerics. Realistic enough that the format expectation
# in the quality suite is exercising something meaningful.
PREFIXES = ["KR", "WA", "GD", "PO", "WR", "KA"]
ALNUM = "ABCDEFGHIJKLMNPRSTUVWXYZ0123456789"


def make_plate(rng: random.Random) -> str:
    return f"{rng.choice(PREFIXES)} {''.join(rng.choices(ALNUM, k=5))}"


def build_day(date: str, corrupt: bool, rows_per_camera: int, seed: int):
    """Return {object_key: csv_bytes} for one day across all cameras."""
    import pandas as pd

    rng = random.Random(seed)
    day_start = datetime.strptime(date, "%Y-%m-%d").replace(tzinfo=timezone.utc)

    # A pool of plates reused across cameras, so the same vehicle is seen at
    # more than one gate. That is what makes deduplication and the hash-based
    # split do something visible.
    plates = [make_plate(rng) for _ in range(max(20, rows_per_camera // 2))]

    out = {}
    for site, cameras in SITES.items():
        for cam in cameras:
            records = []
            for _ in range(rows_per_camera):
                ts = day_start + timedelta(seconds=rng.randint(0, 86_399))
                records.append({
                    "plate": rng.choice(plates),
                    "camera_id": cam,
                    "site": site,
                    "captured_at": ts.isoformat().replace("+00:00", "Z"),
                    # Confidence skewed high, as a real recogniser's would be.
                    "confidence": round(min(0.999, rng.betavariate(8, 2)), 3),
                    "direction": rng.choice(["in", "out"]),
                })

            df = pd.DataFrame(records)

            # Deliberate duplicates: the same event written twice. The DAG's
            # dedup step should remove these, and the row count it reports is
            # how you show it did.
            df = pd.concat([df, df.head(max(1, rows_per_camera // 20))], ignore_index=True)

            if corrupt:
                # Three realistic failure modes, one per expectation we want to
                # see fire. Each is something that genuinely happens:
                #   - a rescaled confidence column (model output changed)
                #   - an OCR miss that leaked through as null
                #   - a malformed plate string
                df.loc[df.index[0], "confidence"] = 1.7
                df.loc[df.index[1], "plate"] = None
                df.loc[df.index[2], "plate"] = "??"

            out[f"alpr/{date}/{site}/{cam}.csv"] = df.to_csv(index=False).encode()

    return out


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--date", default=datetime.now(timezone.utc).strftime("%Y-%m-%d"),
                   help="logical date to generate for (YYYY-MM-DD)")
    p.add_argument("--corrupt", action="store_true",
                   help="inject quality violations so the gate blocks the freeze")
    p.add_argument("--rows", type=int, default=200, help="rows per camera")
    p.add_argument("--seed", type=int, default=42, help="RNG seed; same seed gives the same data")
    p.add_argument("--endpoint", default="localhost:9000")
    p.add_argument("--access-key", default="minioadmin")
    p.add_argument("--secret-key", default="minioadmin")
    p.add_argument("--out-dir", default=None,
                   help="write CSVs here instead of uploading (offline mode)")
    args = p.parse_args()

    files = build_day(args.date, args.corrupt, args.rows, args.seed)

    if args.out_dir:
        import os
        for key, data in files.items():
            path = os.path.join(args.out_dir, key)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            with open(path, "wb") as fh:
                fh.write(data)
            print(f"wrote {path} ({len(data):,} bytes)")
        return 0

    try:
        from minio import Minio
    except ImportError:
        print("minio client not installed. Either:\n"
              "  pip install minio pandas\n"
              "or write files locally with --out-dir ./data/raw", file=sys.stderr)
        return 1

    client = Minio(args.endpoint, access_key=args.access_key,
                   secret_key=args.secret_key, secure=False)

    if not client.bucket_exists(RAW_BUCKET):
        print(f"bucket '{RAW_BUCKET}' does not exist. Start the local stack first:\n"
              "  make local-up", file=sys.stderr)
        return 1

    for key, data in files.items():
        client.put_object(RAW_BUCKET, key, io.BytesIO(data), length=len(data),
                          content_type="text/csv")
        print(f"uploaded s3://{RAW_BUCKET}/{key} ({len(data):,} bytes)")

    total = sum(len(d) for d in files.values())
    print(f"\n{len(files)} objects, {total:,} bytes, date={args.date}, "
          f"corrupt={args.corrupt}")
    print("next: unpause 'alpr_dataset_pipeline' at http://localhost:8081 and trigger it")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
