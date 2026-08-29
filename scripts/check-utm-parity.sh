#!/usr/bin/env bash
#
# UTM behaviour is implemented TWICE, on purpose:
#
#   qr_cf_code/src/utils/utm.js   runs at the edge and builds the URL scanners actually get
#   qr_frontend/src/lib/utm.ts    runs in the builder and shows the owner what that will be
#
# They are separate git repos, so no shared import is possible. A preview computed by
# different logic than the edge is worse than no preview at all: it turns an invisible
# failure into a confidently-wrong promise. The owner reads the URL, recognises it, prints
# 5,000 flyers, and scanners land somewhere else.
#
# The two are pinned to a case table committed to BOTH repos, with each repo asserting its
# own implementation against its own copy. That is deliberately different from the maps.js
# mirror, which imports the sibling repo off disk: that only works in a full monorepo
# checkout and SKIPS in CI, where a skip reads exactly like a pass. Pinning to a committed
# artefact keeps each repo's own CI meaningful — but nothing inside either repo can see the
# OTHER repo's copy, so the tables drifting apart is the one failure neither suite catches.
#
# That is what this script is for. Run it before merging any change to either
# implementation or to the case table.
#
#     ./scripts/check-utm-parity.sh

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

worker="$root/qr_cf_code/src/integration/utm_cases.json"
frontend="$root/qr_frontend/src/lib/utm_cases.json"

for f in "$worker" "$frontend"; do
    if [[ ! -f "$f" ]]; then
        echo "error: missing $f — both repos must carry the case table" >&2
        exit 1
    fi
done

status=0

if diff -u "$worker" "$frontend" > /tmp/utm-parity-diff.$$ 2>&1; then
    n=$(node -e "console.log(require('$worker').cases.length)")
    echo "✓ utm_cases.json identical in both repos ($n cases)"
else
    echo "✗ utm_cases.json DIFFERS between the repos:" >&2
    cat /tmp/utm-parity-diff.$$ >&2
    echo >&2
    echo "  A drifted table means each repo is happily asserting against a different" >&2
    echo "  contract, and the builder preview can lie about the live redirect." >&2
    echo "  Fix: copy the intended version to the other repo and re-run both suites." >&2
    status=1
fi
rm -f /tmp/utm-parity-diff.$$

# Run both suites against their own copy, so "identical tables" also means "both
# implementations still satisfy them".
echo
echo "→ qr_cf_code: node src/utils/utm.test.mjs"
if (cd "$root/qr_cf_code" && node src/utils/utm.test.mjs > /tmp/utm-worker.$$ 2>&1); then
    echo "  ✓ $(grep -c '^ok ' /tmp/utm-worker.$$) worker assertions passed"
else
    echo "  ✗ worker suite FAILED:" >&2
    grep -E '^not ok|Error' /tmp/utm-worker.$$ >&2 || cat /tmp/utm-worker.$$ >&2
    status=1
fi
rm -f /tmp/utm-worker.$$

echo "→ qr_frontend: vitest src/lib/__tests__/utm-mirror.test.ts"
if (cd "$root/qr_frontend" && npx vitest run src/lib/__tests__/utm-mirror.test.ts > /tmp/utm-fe.$$ 2>&1); then
    echo "  ✓ frontend mirror suite passed"
else
    echo "  ✗ frontend mirror suite FAILED:" >&2
    tail -40 /tmp/utm-fe.$$ >&2
    status=1
fi
rm -f /tmp/utm-fe.$$

echo
if [[ $status -eq 0 ]]; then
    echo "UTM parity OK — the builder preview and the edge agree."
else
    echo "UTM parity BROKEN — do not merge." >&2
fi
exit $status
