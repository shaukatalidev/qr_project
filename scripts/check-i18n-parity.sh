#!/usr/bin/env bash
#
# Cross-repo i18n parity: the only check that can see BOTH repos.
#
# qr_cf_code and qr_frontend are independent git repos. Each has unit tests pinning its own
# English dictionary to its own copy of keys.json, and its own dictionaries to its own
# locale list — but nothing inside either repo can notice that the OTHER repo disagrees.
# Two failures live in exactly that blind spot:
#
#   1. keys.json drifting between repos → the builder preview shows one label and the live
#      scan page shows another, which is the bug that makes people stop trusting previews.
#   2. A locale added to one repo and not the other → the builder offers, say, Chinese, the
#      Worker refuses the ?lang=zh it has never heard of, and the visitor silently gets the
#      default language. No error is raised anywhere.
#
# This is a MANUAL pre-merge step. It is not CI, because no CI job in this monorepo sees
# both repos. Run it before merging any change that touches a chrome string or the locale
# set.
#
#   ./scripts/check-i18n-parity.sh
#
# Exit 0 = the two repos agree. Exit 1 = they do not, and the diff shows what to reconcile.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker_keys="$root/qr_cf_code/src/i18n/keys.json"
frontend_keys="$root/qr_frontend/src/lib/i18n/keys.json"
worker_index="$root/qr_cf_code/src/i18n/index.js"
frontend_index="$root/qr_frontend/src/lib/i18n/index.ts"
worker_dir="$root/qr_cf_code/src/i18n"
frontend_dir="$root/qr_frontend/src/lib/i18n"

for f in "$worker_keys" "$frontend_keys" "$worker_index" "$frontend_index"; do
    if [[ ! -f "$f" ]]; then
        echo "error: missing $f" >&2
        exit 1
    fi
done

failed=0

# ── 1. The canonical chrome map ───────────────────────────────────────────────
# Compared semantically, not byte-wise: key ORDER and whitespace are irrelevant, and the
# _comment block is prose that is allowed to differ between repos.
normalise_keys() {
    python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("_comment", None)
print(json.dumps(d, ensure_ascii=False, indent=2, sort_keys=True))
' "$1"
}

if ! diff -u --label "qr_cf_code/src/i18n/keys.json" --label "qr_frontend/src/lib/i18n/keys.json" \
    <(normalise_keys "$worker_keys") <(normalise_keys "$frontend_keys"); then
    failed=1
    echo >&2
    echo "^^ keys.json disagrees: the preview and the live page would render different text." >&2
fi

# ── 2. The supported-locale list ──────────────────────────────────────────────
# Extracted from the SUPPORTED_LOCALES array in each barrel rather than hand-maintained
# here, so this script cannot itself become a third thing that drifts. ORDER MATTERS: it
# drives switcher and builder chip order, so a reordering is a real UI difference.
locale_list() {
    python3 -c '
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"SUPPORTED_LOCALES[^=]*=\s*(?:Object\.freeze\()?\[(.*?)\]", src, re.S)
if not m:
    sys.exit("could not find SUPPORTED_LOCALES in " + sys.argv[1])
print("\n".join(re.findall(r"[\x27\"]([a-z]{2})[\x27\"]", m.group(1))))
' "$1"
}

if ! diff -u --label "qr_cf_code SUPPORTED_LOCALES" --label "qr_frontend SUPPORTED_LOCALES" \
    <(locale_list "$worker_index") <(locale_list "$frontend_index"); then
    failed=1
    echo >&2
    echo "^^ locale lists disagree. If the builder offers a locale the Worker does not" >&2
    echo "   support, ?lang= for it is refused and the visitor silently gets the default" >&2
    echo "   language — no error is raised anywhere. Reconcile both barrels." >&2
fi

# ── 3. The dictionary files on disk ───────────────────────────────────────────
# Catches the half-done change: a locale added to the list in both repos but with the
# dictionary file only written in one. That repo's own key-set test would pass, because it
# only checks the dictionaries it can import.
dict_files() {
    find "$1" -maxdepth 1 -name '*.js' -o -maxdepth 1 -name '*.ts' \
        | xargs -n1 basename \
        | sed -E 's/\.(js|ts)$//' \
        | grep -vE '^(index|.*\.test)$' \
        | sort
}

if ! diff -u --label "qr_cf_code/src/i18n/*" --label "qr_frontend/src/lib/i18n/*" \
    <(dict_files "$worker_dir") <(dict_files "$frontend_dir"); then
    failed=1
    echo >&2
    echo "^^ dictionary files differ. A locale listed in both barrels but written in only" >&2
    echo "   one repo still passes that repo's own tests." >&2
fi

if [[ "$failed" -eq 0 ]]; then
    keys=$(normalise_keys "$worker_keys" | grep -c '":')
    locales=$(locale_list "$worker_index" | wc -l | tr -d ' ')
    echo "i18n parity OK — $keys chrome keys and $locales locales agree across both repos."
    exit 0
fi

cat >&2 <<'MSG'

i18n parity FAILED.

Reconcile the files above, then re-run each repo's own tests:

  cd qr_cf_code  && npm test
  cd qr_frontend && npx vitest run src/lib/__tests__/i18n-parity.test.ts
MSG
exit 1
