#!/usr/bin/env bash
#
# Diff the two checked-in canonical chrome-string maps.
#
# qr_cf_code and qr_frontend are independent git repos. Each has a unit test pinning its
# OWN English dictionary to its OWN copy of keys.json — but nothing inside either repo
# can notice if the two copies of keys.json drift apart, and a preview that disagrees
# with the live page is the exact bug that makes people stop trusting the preview.
#
# This is a MANUAL pre-merge step. It is not CI, because no CI job in this monorepo sees
# both repos. Run it before merging any change that touches a chrome string.
#
#   ./scripts/check-i18n-parity.sh
#
# Exit 0 = the two maps agree. Exit 1 = they do not; the diff shows what to reconcile.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="$root/qr_cf_code/src/i18n/keys.json"
frontend="$root/qr_frontend/src/lib/i18n/keys.json"

for f in "$worker" "$frontend"; do
    if [[ ! -f "$f" ]]; then
        echo "error: missing $f" >&2
        exit 1
    fi
done

# Compare semantically, not byte-wise: key ORDER and whitespace are irrelevant, and the
# _comment block is prose that is allowed to differ between repos.
normalise() {
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("_comment", None)
print(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True))
' "$1"
}

if diff -u --label "qr_cf_code/src/i18n/keys.json" --label "qr_frontend/src/lib/i18n/keys.json" \
    <(normalise "$worker") <(normalise "$frontend"); then
    keys=$(normalise "$worker" | grep -c '":')
    echo "i18n parity OK — $keys chrome keys agree across both repos."
else
    cat >&2 <<'MSG'

i18n parity FAILED.

The Worker and the frontend disagree about a chrome string, so the builder preview and
the live scan page would render different text. Reconcile both keys.json files, then
update the matching dictionary in each repo (qr_cf_code/src/i18n/, qr_frontend/src/lib/i18n/)
and re-run each repo's own tests:

  cd qr_cf_code  && npm test
  cd qr_frontend && npx vitest run src/lib/__tests__/i18n-parity.test.ts
MSG
    exit 1
fi
