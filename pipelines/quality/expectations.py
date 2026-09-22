"""A minimal expectation engine with a Great Expectations-compatible vocabulary.

WHY NOT GREAT EXPECTATIONS ITSELF?

You should use it in production, and you should say so. This module exists for
three practical reasons:

1. GE's API changed substantially between 0.18 and 1.x. A tutorial pinned to
   the wrong one fails on install, and debugging someone else's framework is
   not what you are here to learn.
2. GE brings ~80 transitive dependencies. On arm64 several of them build from
   source. That is a long first run for a pipeline whose point is the *idea*
   of a quality gate.
3. Writing the engine makes the idea concrete. An "expectation suite" is a
   list of assertions over a dataframe, each producing a pass/fail with a
   count of offending rows. That is the whole concept. Once you have written
   it, GE's docs read as configuration rather than magic.

The expectation names and the result JSON shape below deliberately match GE's,
so swapping in the real thing is a change to this file and nothing else. The
DAG calls `run_suite()` and reads `success` — that contract does not move.

To use real GE instead (optional, after the pipeline works):

    pip install "great_expectations==0.18.19"

then reimplement run_suite() with a Validator. Keep the return shape.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from typing import Any, Callable

import pandas as pd


@dataclass
class ExpectationResult:
    """One assertion's verdict.

    `unexpected_count` matters as much as `success`: "this failed" sends you
    looking, "this failed on 3 of 40,000 rows" tells you whether it is a bug
    or a catastrophe. A gate that only reports a boolean makes every failure
    look equally urgent, which is how teams learn to ignore it.
    """

    expectation_type: str
    column: str | None
    success: bool
    unexpected_count: int = 0
    element_count: int = 0
    details: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "expectation_config": {
                "expectation_type": self.expectation_type,
                "kwargs": {"column": self.column, **self.details},
            },
            "success": self.success,
            "result": {
                "element_count": self.element_count,
                "unexpected_count": self.unexpected_count,
                "unexpected_percent": (
                    round(100 * self.unexpected_count / self.element_count, 4)
                    if self.element_count
                    else 0.0
                ),
            },
        }

    def label(self) -> str:
        """Short human label, used when reporting failures back to the catalog."""
        col = f"({self.column})" if self.column else "()"
        return f"{self.expectation_type}{col}"


# --------------------------------------------------------------------------
# The expectations themselves.
#
# Each is a plain function over a dataframe. That is deliberate: they are
# trivially unit-testable, and a new domain rule is a new function rather than
# a subclass and a registration.
# --------------------------------------------------------------------------


def expect_column_to_exist(df: pd.DataFrame, column: str) -> ExpectationResult:
    return ExpectationResult(
        "expect_column_to_exist", column, success=column in df.columns,
        element_count=len(df),
    )


def expect_column_values_to_not_be_null(df: pd.DataFrame, column: str) -> ExpectationResult:
    if column not in df.columns:
        return ExpectationResult("expect_column_values_to_not_be_null", column, False, len(df), len(df))
    bad = int(df[column].isna().sum())
    return ExpectationResult(
        "expect_column_values_to_not_be_null", column,
        success=bad == 0, unexpected_count=bad, element_count=len(df),
    )


def expect_column_values_to_be_unique(df: pd.DataFrame, column: str) -> ExpectationResult:
    if column not in df.columns:
        return ExpectationResult("expect_column_values_to_be_unique", column, False, len(df), len(df))
    # duplicated(keep=False) marks every member of a duplicate group, which is
    # the number you want to report — not the count of "extra" copies.
    bad = int(df[column].duplicated(keep=False).sum())
    return ExpectationResult(
        "expect_column_values_to_be_unique", column,
        success=bad == 0, unexpected_count=bad, element_count=len(df),
    )


def expect_column_values_to_be_between(
    df: pd.DataFrame, column: str, min_value: float, max_value: float
) -> ExpectationResult:
    if column not in df.columns:
        return ExpectationResult("expect_column_values_to_be_between", column, False, len(df), len(df))
    series = pd.to_numeric(df[column], errors="coerce")
    # NaN counts as a violation: a value that will not parse as a number is
    # not "out of range" but it is certainly not in range either, and silently
    # excluding it is how bad rows survive a quality gate.
    bad = int(((series < min_value) | (series > max_value) | series.isna()).sum())
    return ExpectationResult(
        "expect_column_values_to_be_between", column,
        success=bad == 0, unexpected_count=bad, element_count=len(df),
        details={"min_value": min_value, "max_value": max_value},
    )


def expect_column_values_to_match_regex(df: pd.DataFrame, column: str, regex: str) -> ExpectationResult:
    if column not in df.columns:
        return ExpectationResult("expect_column_values_to_match_regex", column, False, len(df), len(df))
    pattern = re.compile(regex)
    values = df[column].astype("string")
    ok = values.map(lambda v: bool(pattern.fullmatch(v)) if pd.notna(v) else False)
    bad = int((~ok).sum())
    return ExpectationResult(
        "expect_column_values_to_match_regex", column,
        success=bad == 0, unexpected_count=bad, element_count=len(df),
        details={"regex": regex},
    )


def expect_column_values_to_be_in_set(df: pd.DataFrame, column: str, value_set: list) -> ExpectationResult:
    if column not in df.columns:
        return ExpectationResult("expect_column_values_to_be_in_set", column, False, len(df), len(df))
    bad = int((~df[column].isin(value_set)).sum())
    return ExpectationResult(
        "expect_column_values_to_be_in_set", column,
        success=bad == 0, unexpected_count=bad, element_count=len(df),
        details={"value_set": value_set},
    )


def expect_table_row_count_to_be_between(
    df: pd.DataFrame, min_value: int, max_value: int
) -> ExpectationResult:
    n = len(df)
    return ExpectationResult(
        "expect_table_row_count_to_be_between", None,
        success=min_value <= n <= max_value, element_count=n,
        unexpected_count=0 if min_value <= n <= max_value else 1,
        details={"min_value": min_value, "max_value": max_value},
    )


# --------------------------------------------------------------------------
# Suites
# --------------------------------------------------------------------------

# A suite is a list of (function, kwargs). Storing it as data rather than code
# means a suite can be loaded from YAML later without changing the runner —
# which is exactly how GE stores them.
Suite = list[tuple[Callable[..., ExpectationResult], dict[str, Any]]]


def alpr_suite(min_rows: int = 1, max_rows: int = 10_000_000) -> Suite:
    """Expectations for the ALPR (plate read) dataset.

    Each rule below is a real failure mode of licence-plate recognition data,
    not a generic null check. That distinction is what an interviewer probes:
    anyone can assert "not null", the value is in knowing which columns break
    and how.
    """
    return [
        (expect_table_row_count_to_be_between, {"min_value": min_rows, "max_value": max_rows}),

        # Structure: if these columns are missing, nothing downstream works.
        (expect_column_to_exist, {"column": "plate"}),
        (expect_column_to_exist, {"column": "camera_id"}),
        (expect_column_to_exist, {"column": "captured_at"}),
        (expect_column_to_exist, {"column": "confidence"}),

        # A null plate is an OCR failure that leaked out of the recogniser.
        (expect_column_values_to_not_be_null, {"column": "plate"}),
        (expect_column_values_to_not_be_null, {"column": "camera_id"}),
        (expect_column_values_to_not_be_null, {"column": "captured_at"}),

        # Confidence outside [0,1] means someone changed the model's output
        # scale — a silent, model-breaking change that only a range check
        # catches. This is the highest-value expectation in the suite.
        (expect_column_values_to_be_between,
         {"column": "confidence", "min_value": 0.0, "max_value": 1.0}),

        # Plate format. Deliberately permissive (3-10 chars, uppercase
        # alphanumeric with optional spaces/hyphens) because plate formats vary
        # by country and an over-tight regex fails on legitimate data — which
        # trains people to ignore the gate.
        (expect_column_values_to_match_regex,
         {"column": "plate", "regex": r"[A-Z0-9][A-Z0-9 \-]{1,8}[A-Z0-9]"}),

        # Split labels must be exactly these three. A typo'd "trian" silently
        # shrinks the training set and is nearly invisible without this check.
        (expect_column_values_to_be_in_set,
         {"column": "split", "value_set": ["train", "val", "test"]}),
    ]


def run_suite(df: pd.DataFrame, suite: Suite) -> dict[str, Any]:
    """Run every expectation and return a GE-shaped validation result.

    Note that it runs ALL of them rather than stopping at the first failure.
    A gate that reports one problem per run costs one pipeline cycle per bug;
    a gate that reports all of them costs one cycle total.
    """
    results = [fn(df, **kwargs) for fn, kwargs in suite]
    failed = [r for r in results if not r.success]

    return {
        "success": len(failed) == 0,
        "statistics": {
            "evaluated_expectations": len(results),
            "successful_expectations": len(results) - len(failed),
            "unsuccessful_expectations": len(failed),
            "success_percent": round(100 * (len(results) - len(failed)) / len(results), 2) if results else 100.0,
        },
        "failed_expectations": [r.label() for r in failed],
        "results": [r.to_dict() for r in results],
    }


def render_html_report(result: dict[str, Any], title: str) -> str:
    """A single self-contained HTML file, no assets, no CDN.

    This is what gets written to object storage and linked from the dataset
    version's `quality_report_uri`. Self-contained matters: a report that
    depends on a stylesheet somewhere is a report that renders as unstyled
    text in six months.
    """
    rows = []
    for r in result["results"]:
        ok = r["success"]
        cfg = r["expectation_config"]
        rows.append(
            f"<tr class='{'ok' if ok else 'bad'}'>"
            f"<td>{'PASS' if ok else 'FAIL'}</td>"
            f"<td>{cfg['expectation_type']}</td>"
            f"<td>{cfg['kwargs'].get('column') or '-'}</td>"
            f"<td>{r['result']['unexpected_count']}</td>"
            f"<td>{r['result']['unexpected_percent']}%</td>"
            "</tr>"
        )
    stats = result["statistics"]
    verdict = "PASSED" if result["success"] else "FAILED"
    return f"""<!doctype html>
<meta charset="utf-8">
<title>{title}</title>
<style>
 body{{font:14px/1.5 system-ui,sans-serif;margin:2rem;max-width:64rem}}
 table{{border-collapse:collapse;width:100%;margin-top:1rem}}
 th,td{{border:1px solid #ddd;padding:.4rem .6rem;text-align:left}}
 th{{background:#f4f4f5}}
 .ok td:first-child{{color:#166534;font-weight:600}}
 .bad td:first-child{{color:#b91c1c;font-weight:600}}
 .verdict{{font-size:1.4rem;font-weight:700;color:{'#166534' if result['success'] else '#b91c1c'}}}
</style>
<h1>{title}</h1>
<p class="verdict">{verdict}</p>
<p>{stats['successful_expectations']} of {stats['evaluated_expectations']} expectations passed
 ({stats['success_percent']}%).</p>
<table>
 <tr><th>Result</th><th>Expectation</th><th>Column</th><th>Unexpected rows</th><th>%</th></tr>
 {''.join(rows)}
</table>
"""


if __name__ == "__main__":
    # A tiny self-check so `python pipelines/quality/expectations.py` proves the
    # module works before you wire it into Airflow. Running a module standalone
    # before integrating it is the habit that keeps DAG debugging short.
    good = pd.DataFrame({
        "plate": ["KR 12345", "WA 99887"],
        "camera_id": ["cam-07", "cam-11"],
        "captured_at": ["2026-09-01T08:00:00Z", "2026-09-01T08:05:00Z"],
        "confidence": [0.98, 0.81],
        "split": ["train", "val"],
    })
    bad = good.copy()
    bad.loc[0, "confidence"] = 1.7      # out of range
    bad.loc[1, "plate"] = None          # null plate

    for name, frame in (("clean", good), ("dirty", bad)):
        res = run_suite(frame, alpr_suite())
        print(f"{name:6s} success={res['success']!s:5s} failed={res['failed_expectations']}")
    print(json.dumps(run_suite(good, alpr_suite())["statistics"], indent=2))
