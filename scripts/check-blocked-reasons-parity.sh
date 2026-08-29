#!/usr/bin/env bash
#
# Cross-repo blocked-scan reason parity: the third leg of a three-place lockstep.
#
# A scan the edge refuses is counted by POSTing a `blocked_reason` to the backend. Three
# places have to agree on that vocabulary:
#
#   1. the DB CHECK  qr_blocked_scans_reason_chk         (qr_backend/migrations)
#   2. BLOCKED_SCAN_REASONS                              (qr_backend/src/api/routes/internal.py)
#   3. the recordBlockedScan() call sites                (qr_cf_code/src/index.js)
#
# Missing one is INVISIBLE from both ends: record_blocked_scan answers an unknown reason
# with {"status":"error"} and HTTP 200, and the Worker's recordBlockedScan is
# fire-and-forget with every failure swallowed. Nothing logs. The counts simply never
# appear, and the owner's "still being scanned 42x since it expired" reads zero forever.
#
# That is not hypothetical: 0048 taught the DB about 'outside_hours' and the Python
# allowlist was never updated, so recurring-window blocks went uncounted for the entire
# life of the daily-window feature.
#
# (1) vs (2) is pinned inside qr_backend by tests/unit_tests/test_blocked_scan_reasons.py,
# which is where the historic drift happened and which works in that repo's own CI.
# This script covers the leg no single repo can see — (2) vs (3) — by diffing the
# generated artefact checked into both. Same arrangement as keys.json and
# kv_contract.json, and for the same reason: CI clones one repo, so a cross-repo test
# would skip, and a skip reads exactly like a pass.
#
# MANUAL pre-merge step.
#
#   ./scripts/check-blocked-reasons-parity.sh
#
# Exit 0 = the two repos agree. Exit 1 = they do not, and the diff shows what to reconcile.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
backend="$root/qr_backend/tests/integration_tests/blocked_reasons.json"
worker="$root/qr_cf_code/src/integration/blocked_reasons.json"

for f in "$backend" "$worker"; do
    if [[ ! -f "$f" ]]; then
        echo "missing: $f" >&2
        echo "Both repos must carry a copy. Regenerate from BLOCKED_SCAN_REASONS." >&2
        exit 1
    fi
done

if diff -u "$backend" "$worker"; then
    echo "blocked_reasons.json: qr_backend and qr_cf_code agree ✓"
else
    echo >&2
    echo "blocked_reasons.json has DRIFTED between the two repos." >&2
    echo "The backend copy is generated from BLOCKED_SCAN_REASONS; copy it over:" >&2
    echo "  cp $backend $worker" >&2
    exit 1
fi
