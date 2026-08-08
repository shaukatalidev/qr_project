#!/usr/bin/env bash
#
# Run the frontend tests that can only work in a full monorepo checkout.
#
# Two test files in qr_frontend read their sibling repos directly:
#
#   src/lib/__tests__/maps-mirror.test.ts        imports qr_cf_code/src/utils/maps.js and
#                                                asserts both implementations build byte-
#                                                identical map URLs — the builder's "exact
#                                                link scanners get" preview depends on it.
#   src/lib/__tests__/location-templates.test.ts checks the location templateId default
#                                                agrees across the frontend, the Worker
#                                                dispatcher and the backend KV shim.
#
# GitHub Actions clones one repo at a time, so both SKIP there. That is deliberate — the
# alternative was a red CI job on every run — but skipping is not the same as passing, and
# a drift they would have caught now reaches production unopposed. This script is where
# they actually get run, alongside the other cross-repo checks:
#
#   ./scripts/check-i18n-parity.sh
#   ./scripts/check-kv-contract-parity.sh
#   ./scripts/check-cross-repo-mirrors.sh
#
# Fails if the tests skip, because a vacuous pass here would be worse than no script.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for sibling in qr_frontend qr_cf_code qr_backend; do
    if [[ ! -d "$root/$sibling" ]]; then
        echo "error: $sibling is not checked out beside this script — these tests need all three" >&2
        exit 1
    fi
done

output=$(cd "$root/qr_frontend" && npx vitest run \
    src/lib/__tests__/maps-mirror.test.ts \
    src/lib/__tests__/location-templates.test.ts 2>&1) || {
    echo "$output"
    echo >&2
    echo "^^ a cross-repo mirror has drifted. The frontend and the Worker (or the backend)" >&2
    echo "   no longer agree, and neither repo's own CI can see it." >&2
    exit 1
}

# vitest colourises its summary, so strip ANSI before matching on it.
plain=$(sed -E $'s/\x1b\\[[0-9;]*[a-zA-Z]//g' <<<"$output")

if grep -qE "[0-9]+ skipped" <<<"$plain"; then
    echo "$output"
    echo >&2
    echo "^^ these tests SKIPPED, which means they verified nothing. They skip when a" >&2
    echo "   sibling repo is missing — check the paths above." >&2
    exit 1
fi

# `|| true` matters: under `set -o pipefail` a missed match would exit 1 here and report
# failure for a run that actually passed.
passed=$(grep -oE "Tests +[0-9]+ passed" <<<"$plain" | grep -oE "[0-9]+" | head -1 || true)
echo "cross-repo mirrors OK — ${passed:-?} checks ran against the real sibling repos."
