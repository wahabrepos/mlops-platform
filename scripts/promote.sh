#!/usr/bin/env bash
# Champion/contender promotion decision, made from metrics rather than opinion.
#
# THE RULE, and it is worth stating this precisely in an interview:
#   promote the contender only if, over the evaluation window,
#     - it served at least MIN_REQUESTS  (below that, the numbers are noise)
#     - its error rate is <= the champion's + tolerance
#     - its p95 latency is <= the champion's * (1 + tolerance)
#   otherwise roll back.
#
# Rolling back is `kubectl apply` of the champion manifest. It is fast because
# the champion revision was never deleted — canary traffic splitting means both
# revisions exist the whole time. That is the operational argument for
# canarying over blue/green rebuilds.
set -euo pipefail

NAMESPACE=${NAMESPACE:-models}
SERVICE=${SERVICE:-alpr-classifier}
PROM=${PROM:-http://localhost:9090}
WINDOW=${WINDOW:-10m}
MIN_REQUESTS=${MIN_REQUESTS:-100}
TOLERANCE=${TOLERANCE:-0.10}

q() {
  # Query Prometheus and return the scalar value, or "NaN" if there is no data.
  curl -sG "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | python3 -c 'import json,sys; r=json.load(sys.stdin)["data"]["result"]; print(r[0]["value"][1] if r else "NaN")'
}

latest=$(kubectl get inferenceservice "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath='{.status.components.predictor.latestCreatedRevision}')
previous=$(kubectl get inferenceservice "$SERVICE" -n "$NAMESPACE" \
  -o jsonpath='{.status.components.predictor.previousRolledoutRevision}')

echo "champion : $previous"
echo "contender: $latest"
echo

requests=$(q "sum(increase(revision_request_count{revision=\"$latest\"}[$WINDOW]))")
c_err=$(q "sum(rate(revision_request_count{revision=\"$latest\",response_code=~\"5..\"}[$WINDOW])) / clamp_min(sum(rate(revision_request_count{revision=\"$latest\"}[$WINDOW])),0.001)")
p_err=$(q "sum(rate(revision_request_count{revision=\"$previous\",response_code=~\"5..\"}[$WINDOW])) / clamp_min(sum(rate(revision_request_count{revision=\"$previous\"}[$WINDOW])),0.001)")
c_p95=$(q "histogram_quantile(0.95, sum by (le) (rate(revision_request_latencies_bucket{revision=\"$latest\"}[$WINDOW])))")
p_p95=$(q "histogram_quantile(0.95, sum by (le) (rate(revision_request_latencies_bucket{revision=\"$previous\"}[$WINDOW])))")

printf 'requests (contender) : %s\n' "$requests"
printf 'error rate           : contender %s  champion %s\n' "$c_err" "$p_err"
printf 'p95 latency (ms)     : contender %s  champion %s\n' "$c_p95" "$p_p95"
echo

verdict=$(python3 - "$requests" "$c_err" "$p_err" "$c_p95" "$p_p95" "$MIN_REQUESTS" "$TOLERANCE" <<'PY'
import math, sys
req, ce, pe, cl, pl, minreq, tol = sys.argv[1:8]
def f(x):
    try:
        v = float(x)
        return None if math.isnan(v) else v
    except ValueError:
        return None
req, ce, pe, cl, pl = f(req), f(ce), f(pe), f(cl), f(pl)
tol, minreq = float(tol), float(minreq)

if req is None or req < minreq:
    print(f"HOLD|only {req} requests, need {minreq:.0f} before the numbers mean anything")
elif ce is None or pe is None:
    print("HOLD|no error-rate data for one of the revisions")
elif ce > pe + tol:
    print(f"ROLLBACK|contender error rate {ce:.4f} exceeds champion {pe:.4f} + {tol}")
elif cl is not None and pl is not None and cl > pl * (1 + tol):
    print(f"ROLLBACK|contender p95 {cl:.1f} exceeds champion {pl:.1f} by more than {tol:.0%}")
else:
    print("PROMOTE|contender meets the error and latency budget")
PY
)

decision=${verdict%%|*}
reason=${verdict#*|}
echo "DECISION: $decision — $reason"

case "$decision" in
  PROMOTE)
    echo "promoting: routing 100% of traffic to $latest"
    kubectl patch inferenceservice "$SERVICE" -n "$NAMESPACE" --type=merge \
      -p '{"spec":{"predictor":{"canaryTrafficPercent":null}}}'
    ;;
  ROLLBACK)
    echo "rolling back: routing 100% of traffic to $previous"
    kubectl apply -f models/serving/isvc-champion.yaml
    exit 1
    ;;
  *)
    echo "no action taken"
    ;;
esac
