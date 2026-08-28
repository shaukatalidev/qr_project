# TRD — UTM campaign support

**Spec:** `UTM_CAMPAIGN_SUPPORT_PRD.md` · **Status:** Draft (detailed) · **Date:** 2026-08-28
**Migration slot (RESERVATION):** `0057_qr_utm_params.sql`. Highest on disk when written: `0054`. **`ls qr_backend/migrations/` and take the next free integer.**
**Repos:** `qr_backend`, `qr_cf_code`, `qr_frontend`. **KV payload changes → regenerate `kv_contract.json` and run the parity script.**
**New plan flags:** none.

---

## 1. Architecture

```
qr_codes.utm (jsonb)   ·   qr_destinations.utm_content (text)
        │
        └── sync_qr_to_kv ──▶ KV { utm: {...}, destinations: [{ …, utm_content }] }
                                     │
                                     ▼
                        applyUtm(url, utm, variantContent)     ← ONE pure function
                                     │
      ┌──────────────────────────────┼───────────────────────────────┐
  websiteRedirect.js            landing page CTAs            list_links items
  (after ensureScheme)          (template render time)       (template render time)

        mirrored, byte-for-byte, by:  qr_frontend/src/lib/utm.ts  → the builder preview
```

**One function is the entire behavioural surface.** `applyUtm` is pure, synchronous,
dependency-free and **never throws**. Everything else in this document is plumbing around it.

## 2. Migration `0057`

```sql
-- Migration 0057: per-QR UTM campaign parameters.
--
-- Stored SEPARATELY from the destination URL, which is the whole point: a dynamic QR's
-- destination changes after printing, and UTMs baked into the URL are lost or retyped
-- on every edit.
--
-- Idempotent; safe to re-run. Re-confirm the highest APPLIED migration first.

BEGIN;

ALTER TABLE qr_codes ADD COLUMN IF NOT EXISTS utm jsonb;

ALTER TABLE qr_codes DROP CONSTRAINT IF EXISTS qr_codes_utm_is_object_chk;
ALTER TABLE qr_codes ADD CONSTRAINT qr_codes_utm_is_object_chk
    CHECK (utm IS NULL OR jsonb_typeof(utm) = 'object');

-- Only the five standard keys. An unknown key is a typo the user must see, not a value
-- we silently drop (see §3.1).
ALTER TABLE qr_codes DROP CONSTRAINT IF EXISTS qr_codes_utm_keys_chk;
ALTER TABLE qr_codes ADD CONSTRAINT qr_codes_utm_keys_chk
    CHECK (
        utm IS NULL
        OR NOT EXISTS (
            SELECT 1 FROM jsonb_object_keys(utm) AS k
            WHERE k NOT IN ('source', 'medium', 'campaign', 'term', 'content')
        )
    );

-- Per-variant utm_content for A/B destinations.
ALTER TABLE qr_destinations ADD COLUMN IF NOT EXISTS utm_content text;

COMMIT;

-- Sanity:
--   SELECT id, name, utm FROM qr_codes WHERE utm IS NOT NULL LIMIT 20;
```

### 2.1 Short keys, not `utm_`-prefixed

Stored shape:

```json
{"source": "qr", "medium": "qr_code", "campaign": "spring-launch", "term": null, "content": null}
```

**Not** `{"utm_source": …}`. The `utm_` prefix is added at render time. Storing it invites
`utm_utm_source` the first time anyone refactors, and it makes the CHECK constraint above twice as
long for no benefit.

Nullable, no default, no backfill: `NULL` ⇒ the KV `utm` key is omitted entirely ⇒ existing QRs'
KV values stay byte-identical until republished for another reason.

## 3. Backend

### 3.1 Validation — `src/api/schemas/qr.py`

Add `utm: Optional[UtmParams]` to `QRCodeCreate` and `QRCodeUpdate`, with a pure validator beside
the existing ones.

Per value:
- strip whitespace; empty → `None`;
- max 200 characters;
- reject control characters and newlines.

Reject **nothing else**. Campaign names legitimately contain spaces, `+`, `&`, and non-Latin
scripts (a Hindi or Tamil campaign name is entirely realistic here). Over-validating pushes users
back to hand-typing into the destination field, which is the behaviour this feature exists to
replace.

Whole object: at most the five known keys; **unknown keys rejected with a 422**, not silently
dropped. A `utm_soruce` typo that vanishes without complaint is a support ticket and an
untrackable campaign.

### 3.2 KV publish — `src/utilities/cloudflare_kv.py`

**(a)** Add `utm` to `sync_qr_to_kv`'s explicit `select(...)`. That select's own comment states the
hazard: omitting a column *"does not fail loudly — it silently drops that setting from KV on the
next resync (scan-limit disable, billing re-enable, branding save…), which is exactly how
page_design once caused permanent DB↔KV drift."* A customer's UTM set vanishing when they save
their logo is precisely that failure.

**(b)** Pass `utm=qr.get("utm")` to `write_to_kv`, **omitting the key when falsy**.

**(c)** `sync_qr_to_kv` already selects `qr_destinations` with named columns
(`target_url, weight, is_active, variant_key, label`). Add `utm_content` there **and** carry it
into each destination dict in the comprehension that builds `destinations`. Both edits, or the
per-variant value silently never reaches the edge.

### 3.3 Defaults — computed at create, persisted

In `create_qr`, when `utm` is absent from the payload:

```python
utm = {
    "source": "qr",
    "medium": "qr_code",
    "campaign": campaign_slug_from_tags(tags) or slugify(payload.name),
}
```

**Compute at create time and store the result.** Never derive at read or render time: a default
computed at render would change under a printed QR when its name changes, which PRD §12 Q1
explicitly rejects.

`campaign_slug_from_tags` reads the QR's `campaign:`-namespaced tag, if any, from the tag system
`CAMPAIGN_TAGS_ROLLUP` shipped.

### 3.4 Public API

Expose `utm` on the public create/update schemas if they reuse these models — verify. If they do,
note in the PR that **the edge-side scheme allowlist is the only enforcement of PRD NG1**, because
the public API can set a UTM on a `upi` or `phone` QR that the dashboard would never offer.

## 4. KV contract

```bash
cd qr_backend && UPDATE_KV_CONTRACT=1 pytest tests/integration_tests/test_kv_contract.py
cp tests/integration_tests/kv_contract.json ../qr_cf_code/src/integration/
./scripts/check-kv-contract-parity.sh    # manual pre-merge; no CI job sees both repos
```

## 5. Worker — `src/utils/utm.js`

```js
const UTM_KEYS = ["source", "medium", "campaign", "term", "content"];
const MAX_URL_LENGTH = 2000;
const ALLOWED_PROTOCOLS = new Set(["http:", "https:"]);

export function applyUtm(rawUrl, utm, variantContent) { /* … */ }
```

### 5.1 Algorithm — each step maps to a PRD §6 rule and gets its own test

| Step | Rule | Implementation |
|---|---|---|
| 1 | fast path | No `utm` **and** no `variantContent` → `return rawUrl` **unchanged, reference-equal**. This is the path every pre-feature QR takes; it must not re-serialise. |
| 2 | M9 | `new URL(rawUrl)`; on throw → `return rawUrl` |
| 3 | M7 / NG1 | `ALLOWED_PROTOCOLS.has(url.protocol)` else → `return rawUrl` |
| 4 | M3, M5 | For each key with a non-empty value: `url.searchParams.set("utm_" + key, value)` |
| 5 | G4 | `variantContent` overrides `utm_content` |
| 6 | M1, M2, M4, M6 | `url.toString()` — places parameters before the fragment and encodes exactly once |
| 7 | M8 | Result longer than `MAX_URL_LENGTH` → `return rawUrl` |

**`searchParams.set`, not `append`** (M3): `append` produces duplicate keys, which GA4, Matomo and
Adobe each resolve differently.

**`url.toString()`, never string concatenation** (M6). Every double-encoding bug in this class of
feature comes from hand-building the query string. `URLSearchParams` encodes once, correctly, and
handles the fragment placement for free.

**Outermost guard:**

```js
export function applyUtm(rawUrl, utm, variantContent) {
  try { /* steps 1–7 */ } catch { return rawUrl; }
}
```

Belt and braces on top of step 2 — this function sits in the path of every redirect the product
serves, and no input should be able to break it.

## 6. Worker — call sites

### 6.1 `handlers/websiteRedirect.js` — the primary case

Apply **after** the existing `ensureScheme()` coercion. That helper exists because *"legacy KV rows
written before the backend normalized URLs"* can hold a bare `example.com`, which makes
`Response.redirect` throw. `new URL("example.com")` also throws, so applying UTMs before
`ensureScheme` would silently fail open on exactly the legacy rows most likely to need help.

Apply after variant selection — both the A/B `pickWeightedVariant` path and the `routeChoice` path
— so the per-variant `utm_content` corresponds to the destination actually served, and so
`recordScan`'s `destination_url` records the URL the scanner really received.

### 6.2 `handlers/linkClick.js` — decide deliberately

This handler reads its target from a **query parameter** (`url.searchParams.get("target")`) and
redirects to `decodeURIComponent(targetUrl)`. Before applying UTMs here, establish what validates
that target. If it is unvalidated, **this is an open-redirect surface and applying UTMs is the
least of its problems** — raise it separately rather than silently building on it.

Recommendation: leave `linkClick` out of v1 unless the validation is confirmed, and say so in the
PR. PRD §7 already flags it.

### 6.3 Landing-page templates

`src/pages/<type>/*Template.js` build outbound `href`s for CTAs and `list_links` items. Route each
through `applyUtm` at render time, passing the QR's `utm` down through the existing template
context. Keep `escapeHTML()` on the result — `applyUtm` produces a URL, not escaped HTML, and the
two concerns must not be conflated.

## 7. The mirrored pair — builder preview vs Worker

PRD §5.2 requires the preview to be truthful, which means **one logic, two runtimes**. Follow the
`maps.js` precedent exactly; it exists for the identical reason and its own docstring says so:

> *"These two files exist separately because one runs in the builder preview and one runs at the
> edge, but they must produce IDENTICAL URLs. If they drift, the … control in the builder starts
> lying — the owner clicks through, sees the right place, prints the poster, and scanners land
> somewhere else."*

Substitute "tracking" for "place" and it is this feature verbatim.

**Implementation:**

1. Port `applyUtm` to `qr_frontend/src/lib/utm.ts`, same algorithm, same constants.
2. Add a `worker-utm` alias in `qr_frontend/vitest.config.ts` pointing at
   `${MONOREPO_ROOT}/qr_cf_code/src/utils/utm.js` when present and at a **stub** when not. A static
   import cannot work: the path leaves the project root and Vite's resolver flattens it. The stub
   is what stops the test file failing at transform time in single-repo CI — which is exactly how
   the frontend's first CI run went red.
3. `qr_frontend/src/lib/__tests__/utm-mirror.test.ts` imports the **real Worker module** at runtime
   (`existsSync` + dynamic `import('worker-utm')`), runs a shared fixture table through both, and
   asserts byte-identical output.
4. It **skips** when the sibling repo is absent. **Skipping is not passing** — run
   `./scripts/check-cross-repo-mirrors.sh` before merging; it fails if the mirror test skips rather
   than reporting a vacuous pass. Extend that script to cover the new pair.

> Note the house guidance: prefer the `keys.json` / `kv_contract.json` pattern (a generated artefact
> committed to both repos) for **new** cross-repo checks, because reaching across the filesystem
> only works on a developer's machine. A UTM case-table JSON committed to both repos, with each
> repo asserting its own implementation against it, is the stronger option here and should be
> preferred if the fixture table can be expressed as data. Fall back to the `maps.js` runtime-import
> pattern only if it cannot.

## 8. Frontend

| File | Purpose |
|---|---|
| `components/qr-generator/content-types/utm-section.tsx` | The five inputs + presets. Under 200 lines. |
| `components/qr-generator/content-types/utm-preview.tsx` | The live final-URL preview + copy control |
| `src/lib/utm.ts` | The mirrored `applyUtm` |
| `src/lib/constants/utm-presets.ts` | Print / Poster / Flyer / Table tent / Packaging / Business card |
| `components/org/qrs/details/ab-testing-card.tsx` | Per-variant `utm_content` input |
| `components/org/qrs/details/` | Effective-UTM display, copyable |

RHF + zod (`max(200)`, no control characters), no uncontrolled inputs, no inline styles, no `any`.
Hidden for static and non-HTTP types with a one-line reason (PRD §5.4).

## 9. Tests

### 9.1 `qr_cf_code/src/utils/utm.test.mjs` — standalone `node` script (no runner, no `npm test`)

Table-driven, one row per PRD §6 rule, plus:

| Case | Expected |
|---|---|
| `https://x.com/p` + full UTM set | one `?`, five params |
| `https://x.com/p?ref=abc` | `?ref=abc&utm_...`, one `?` |
| `https://x.com/p?utm_source=old` | QR value wins, `utm_source` appears **once** |
| `https://x.com/p#section` | params **before** `#section` |
| campaign `Summer Sale 2026` | `Summer+Sale+2026` or `%20` — **never `%2520`** |
| campaign in Devanagari | encoded once; decodes back to the original |
| `term: "  "` | key omitted entirely |
| `tel:+911234567890` | returned **byte-identical** |
| `upi://pay?pa=x@y` | returned **byte-identical** |
| `mailto:a@b.com` | returned byte-identical |
| a 1,900-char URL that would cross 2,000 | returned unchanged |
| `applyUtm(url, null)` | **reference-equal** to the input |
| `applyUtm(null, utm)` | returns `null`, does not throw |
| `variantContent: "b"` with `content: "a"` | `utm_content=b` |

### 9.2 `qr_cf_code/src/integration/scanFlow.test.mjs`

- a `website` QR with `utm` in KV 302s to the merged URL;
- a `website` QR **without** `utm` 302s to a **byte-identical** URL to today (the regression that
  protects every existing QR);
- a scheme-less legacy destination gets `ensureScheme` **then** UTMs (§6.1);
- an A/B variant's `utm_content` reaches the served URL, and `recordScan` records that URL.

### 9.3 `qr_frontend/src/lib/__tests__/utm-mirror.test.ts`

The shared fixture table through both implementations; byte-identical assertions; skip-when-absent
with `./scripts/check-cross-repo-mirrors.sh` as the guard against a vacuous pass.

### 9.4 Backend

- unknown key → 422 (not silently dropped);
- a 201-character value → 422;
- newline in a value → 422;
- a Devanagari campaign name → accepted;
- `sync_qr_to_kv` emits `utm` and omits it when `NULL`;
- **`utm_content` reaches the KV `destinations[]` entries** (§3.2(c) — two edits, one silent failure);
- defaults are computed at create from the `campaign:` tag, and **do not change** when the QR is
  later renamed (PRD §12 Q1).

### 9.5 Frontend — Vitest

- the section is hidden for static and for non-HTTP types;
- the preview updates as fields change and matches `applyUtm`'s output;
- presets fill the expected fields;
- zod rejects over-long and control-character values.

## 10. Rollout

1. **Apply `0057`.**
2. **Deploy the Worker.** A KV `utm` key the Worker ignores is harmless; a backend writing UTMs with
   no Worker support means the UI promises tracking that silently does not happen.
3. **Deploy the backend.**
4. **Ship the frontend.**

**Week-one watch:** "my link is broken" tickets. This feature edits the most load-bearing string in
the product. `applyUtm`'s fail-open behaviour is what makes a bad week recoverable by fixing forward
rather than rolling back a Worker deploy.

## 11. Risks

| Risk | Mitigation |
|---|---|
| A merge bug breaks printed QRs | Pure function, table-driven per-rule tests, outermost try/catch, Worker-first deploy, fail-open everywhere. |
| Double-encoding | `URLSearchParams` + `toString()`, never concatenation; explicit `%2520` assertion. |
| Preview and Worker drift | §7 mirrored pair + `check-cross-repo-mirrors.sh`; prefer the committed-fixture pattern over the filesystem reach. |
| UTMs on `upi:`/`tel:` | Scheme allowlist **at the edge**, because the public API is a second writer. |
| `sync_qr_to_kv` select not updated | §3.2(a); plus the KV-contract assertion that every Worker-read key is named there. |
| `utm_content` never reaches KV | §3.2(c) requires two edits; §9.4 tests it. |
| `linkClick` turns out to be an open redirect | §6.2 — investigate before building on it; keep it out of v1 otherwise. |
| Users expect our dashboard to report UTMs | Section copy points at campaign tags. |
