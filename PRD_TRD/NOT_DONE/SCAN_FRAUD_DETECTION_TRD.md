# TRD — Scan Fraud & Abuse Detection

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-27
**Priority:** Platform integrity / billing correctness. Scans are the billing meter (`_enforce_scan_limit`, `internal.py:532`), so forged scans are a denial-of-service against our own customer — a Free workspace flooded past `max_scans` has **every** active dynamic QR flipped to `disabled` and synced to KV. This closes that path and makes the meter count only defensible scans.
**Tiers:** All tiers, ungated.
**Plan flags:** **None.** No `plans.features` key, no `FEATURE_ENFORCEMENT` entry, no `PlanFeatures` field. `test_feature_gate_coverage` is **untouched** by this feature — verify that as a review item, because it is unusual for a migration in this repo. Thresholds live in a config table, not in `plans`.
**Migration slot:** **`0047_scan_fraud_detection.sql` — PROVISIONAL, RE-VERIFY AT BUILD TIME.** Highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`; `0033`–`0043` are claimed by drafted-but-unapplied specs and `0044`–`0046` by concurrently drafted ones. Roadmap slot tables in this repo go stale (`AI_BUSINESS_CARD_OCR` was drafted for `0024` and shipped as `0026`). **`ls qr_backend/migrations/` before writing the file.**
**Services touched:** `qr_backend` (classifier utility + ingest stamping + billable-count helper + circuit breaker + operator endpoints + read-path disclosure + migration), `qr_frontend` (one disclosure line + popover). **`qr_cf_code`: NO CHANGE in v1** — every signal the classifier needs is already on the wire (`scan.js:44–62`, including `asn`). No KV change, no template, no new cron, **no `npm run deploy:prod` gate**.
**Implements PRD:** Scan Fraud & Abuse Detection. **Reuses** `is_unique` device dedupe (`internal.py:375–392`), the `_alert_once` ledger (`internal.py:854`), `ua_parser.py`, and the plan/limits engine. **Boundary:** `RATE_LIMITING_TRD.md` owns API/auth throttling; this spec owns the scan path only.

---

## 1. Overview & Architecture

### 1.1 Where detection lives, and why

Two candidate positions were considered. **We recommend the backend, at ingest, and no edge component in v1.**

**(a) Edge, pre-record (`qr_cf_code/src/utils/scan.js`) — rejected for v1.** It is the only place with the raw client IP and it could suppress a row before it is written. But the Worker has **no cross-request state**. The available options are all bad here:
- **KV** is eventually consistent (global propagation measured in tens of seconds) and rate-limits writes to roughly one per second per key. A per-`(qr_id, ip)` burst counter in KV would be wrong exactly when it matters — during a burst — and the write cadence a flood produces is the pathological case for KV. It is the wrong primitive for counting.
- **Durable Objects** would work correctly but are **not configured today** (no `[[durable_objects]]` in `wrangler.toml`), add new infra and a `deploy:prod` gate, and put a network round-trip on the scan hot path. The scan hot path is the one thing this product must never slow down — a QR must resolve in one hop.
- **The Workers rate-limit binding** is per-colo, not global, so a distributed flood evades it and a busy single-colo venue (a conference, exactly the false-positive case) trips it.

Stateless edge classification (UA/ASN) *is* possible, but the Worker already does the stateless part (`detectDevice`, `scan.js:2`) and the row is written anyway — moving more of it to the edge buys nothing without state.

**(b) Backend, at ingest (`POST /internal/scans` → `record_scan_event`, `internal.py:350`) — chosen.** It has:
- **Full history** in `qr_scan_events`, plus the plan/limits engine, the alert ledger, and the `resolve_plan` cache already in hand.
- **The enforcement decision in the same function.** `_enforce_scan_limit` is called from `record_scan_event:472`, *after* the insert. Classifying before the insert and counting after it is trivially correct in one handler — no cross-service coordination, no consistency window.
- **Zero user-visible latency.** The Worker's call is `ctx.waitUntil(fetch(...).catch(() => {}))` (`scan.js:75–84`) — fire-and-forget, after the response is served. Backend work here is invisible to the scanner by construction.
- **No `deploy:prod` gate**, no KV migration, no edge rollback risk. It can be rolled back with a backend deploy or, for the enforcement switch, a single SQL `UPDATE` (§3.5).

The "the row is already in flight" objection is **moot because we are not dropping rows**. Under a classification model the row is *supposed* to be written — the flag is metadata on it. That is the whole design (§1.2).

Phase 3 may add an edge pre-filter if volume ever justifies the infra. It is not in this spec's commitments.

### 1.2 Classify, never delete

Every scan row is inserted exactly as today and additionally stamped `integrity_flag` ∈ `{clean, bot, suspect, abuse}` plus a short `integrity_reason`. **No row is ever deleted, mutated away, or suppressed by this feature.** Deleting evidence makes disputes unresolvable ("prove those 4,000 scans were fake") and makes the abuse invisible to us. Flags then drive three consumers: the billing meter, the analytics read path, and the customer-facing disclosure.

`suspect` is a **measurement-only** flag: written to the row, visible in operator tooling, **no billing or analytics effect**. Every new rule enters at `suspect` and is promoted to `bot`/`abuse` only after measured precision in production (PRD §10).

### 1.3 Services touched

| Service | Change |
|---|---|
| `qr_backend` | New `src/utilities/scan_integrity.py` (classifier + config cache + billable predicate). `internal.py`: stamp the flag in `record_scan_event`, rewrite `_enforce_scan_limit`'s count + add the circuit breaker, update `_reenable_free_scan_disabled`'s count, add 4 operator endpoints. `subscription.py`: `_usage_max_scans` uses the shared helper. `scan.py`: generalize `exclude_bots` → integrity flags, add `excluded_scans` to `/analytics/summary`, add `GET /analytics/integrity`. New migration. |
| `qr_frontend` | One disclosure line + reason popover on the analytics header; `useAnalytics` extension. No new page, no new route, no gating call. |
| `qr_cf_code` | **None.** `asn`, `ip_hash`, `session_id`, `user_agent`, `language`, `referer`, `country_code` are already sent (`scan.js:44–62`). No `build_kv_content` branch, no new QR type, no template (so the Worker↔React template-mirroring rule does not apply), no new cron. |

### 1.4 Data flow

```
SCAN (unchanged up to the backend):
  user scans → Worker → env.QR_KV.get(shortCode) → status gate → render/redirect
    → ctx.waitUntil(recordScan(...))  [scan.js:75 — fire-and-forget, post-response]
    → POST /internal/scans  { qr_id, workspace_id, asn, ip_hash, session_id,
                              user_agent, language, referer, country_code, ... }

BACKEND record_scan_event (internal.py:350) — NEW steps marked ▶:
  1. resolve workspace_id                                        (unchanged, :367–372)
  2. is_unique via session_id dedupe                             (unchanged, :375–392)
▶ 2b. velocity = increment_scan_velocity(qr_id, ip_hash, minute) RPC → (hits, sessions)
▶ 2c. flag, reason = classify(payload, velocity, config)         [pure, no I/O]
  3. INSERT qr_scan_events (+ integrity_flag, integrity_reason)  (:393)
▶ 3b. if flagged: bump_scan_integrity_daily(ws, qr, day, reason) RPC
  4. update qr_scan_counters                                     (unchanged, :396–465)
  5. _enforce_scan_limit(db, workspace_id)                       (:472 — REWRITTEN)
▶      count = billable_scan_count(ws, period_start)   [excludes bot/abuse]
▶      if count < max_scans: return                    [unchanged semantics]
▶      if burst_anomaly(ws) or active_hold(ws):        [CIRCUIT BREAKER]
▶          place hold + alert once/ISO-week + RETURN WITHOUT DISABLING
       else: disable dynamic QRs + sync KV + _fire_scan_cap_alert  (unchanged)
  6. webhook dispatch + milestone check                          (unchanged v1; see §12 Q5)
  → {"status": "ok"}

READ:  FE → GET /analytics/summary  → total_scans (clean+suspect) + excluded_scans
       FE → GET /analytics/integrity → per-reason, per-day breakdown (popover)

OPS:   curl → POST /internal/scan-integrity/{reclassify|allowlist|hold|restore}
              (x-internal-secret, no Bearer — internal.py:21–35)
```

---

## 2. Data Model & Migrations

`migrations/0047_scan_fraud_detection.sql` — BEGIN/COMMIT-wrapped, idempotent (`IF NOT EXISTS`), applied **by hand in the Supabase SQL editor before the backend deploy** (no automated runner — `migrations/README.md`). The Supabase client uses the **service role key → RLS is bypassed**; every query below filters `workspace_id` explicitly and never relies on RLS.

**Note on the `ALTER TABLE`:** `ADD COLUMN ... NOT NULL DEFAULT '<constant>'` is a **metadata-only** operation in PostgreSQL 11+ (existing rows read the default via `pg_attribute.atthasmissing`) — no table rewrite, no long lock, and **no backfill needed** even if `qr_scan_events` is large. This matters: `qr_scan_events` is the highest-volume table in the system and a rewriting `ALTER` would be an outage. Do **not** "helpfully" add a backfill `UPDATE`.

```sql
-- Migration 0047: Scan Fraud & Abuse Detection
-- Classification-only. NO scan row is ever deleted or rewritten by this feature.
-- NO plans.features change, NO FEATURE_ENFORCEMENT change (feature is ungated).
-- Idempotent; apply in the Supabase SQL Editor BEFORE deploying the backend.
-- ⚠️ SLOT IS PROVISIONAL — re-verify against ls(migrations/) before shipping.

BEGIN;

-- ── 1. Classification on the scan row (additive, metadata-only ALTER) ─────────
-- PG11+: NOT NULL + constant DEFAULT does not rewrite the table. No backfill.
ALTER TABLE qr_scan_events
    ADD COLUMN IF NOT EXISTS integrity_flag   text NOT NULL DEFAULT 'clean';
ALTER TABLE qr_scan_events
    ADD COLUMN IF NOT EXISTS integrity_reason text;

-- Value domain (checked in app code; a CHECK constraint here would make adding a
-- future flag a locking migration, so it is deliberately omitted):
--   'clean'   — counts for billing + analytics
--   'suspect' — MEASUREMENT ONLY: counts for billing + analytics, visible to operators
--   'bot'     — excluded from billing + analytics
--   'abuse'   — excluded from billing + analytics, alerts the owner

-- Billing hot path: _enforce_scan_limit / _usage_max_scans count billable rows in a
-- period. Partial index matches the exact predicate the helper emits (§3.4).
CREATE INDEX IF NOT EXISTS idx_qr_scan_events_ws_billable
    ON qr_scan_events (workspace_id, scanned_at)
    WHERE integrity_flag IN ('clean', 'suspect');

-- Operator/read path: "show me the flagged rows for this QR".
CREATE INDEX IF NOT EXISTS idx_qr_scan_events_flagged
    ON qr_scan_events (qr_id, scanned_at DESC)
    WHERE integrity_flag IN ('bot', 'abuse', 'suspect');

-- ── 2. Durable exclusion rollup (survives row pruning / retention) ────────────
-- The customer-facing "we excluded N scans on <day> because <reason>" claim and any
-- billing dispute must outlive the raw rows: analytics_retention_days is 7 on Free,
-- the tier most likely to be attacked and to dispute. Rows are a read clamp today,
-- but the concurrent retention spec may make it a real delete — this table is the
-- durable record either way.
CREATE TABLE IF NOT EXISTS scan_integrity_daily (
    workspace_id   uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    qr_id          uuid        NOT NULL,
    day            date        NOT NULL,
    reason         text        NOT NULL,   -- stable machine key, e.g. 'hosting_asn'
    flag           text        NOT NULL,   -- 'bot' | 'abuse' | 'suspect'
    scan_count     bigint      NOT NULL DEFAULT 0,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (workspace_id, qr_id, day, reason)
);
CREATE INDEX IF NOT EXISTS idx_scan_integrity_daily_ws_day
    ON scan_integrity_daily (workspace_id, day DESC);

-- ── 3. Velocity buckets (O(1) burst counter; disposable) ──────────────────────
-- UNLOGGED: this data is disposable telemetry with a 15-minute horizon. Unlogged
-- skips WAL (materially cheaper on the hot path) at the cost of being TRUNCATED on
-- an unclean shutdown — which is acceptable and even desirable here: worst case we
-- forget a burst in progress and fall back to no-flag (fail-open, PRD R1 direction).
-- If the deployment target forbids unlogged tables, drop the keyword; nothing else
-- changes. (IF NOT EXISTS will not convert an existing logged table — check first.)
CREATE UNLOGGED TABLE IF NOT EXISTS scan_velocity_buckets (
    qr_id          uuid        NOT NULL,
    ip_hash        text        NOT NULL,
    bucket_start   timestamptz NOT NULL,   -- truncated to the minute
    hits           int         NOT NULL DEFAULT 0,
    session_sample text[]      NOT NULL DEFAULT '{}',  -- capped at 16 distinct ids
    PRIMARY KEY (qr_id, ip_hash, bucket_start)
);
CREATE INDEX IF NOT EXISTS idx_scan_velocity_bucket_start
    ON scan_velocity_buckets (bucket_start);

-- ── 4. Operator config + overrides ───────────────────────────────────────────
-- Single-row global config so thresholds and the enforcement kill switch are
-- flippable in the SQL editor WITHOUT a backend deploy (Render deploys are slow;
-- a bad threshold must be revertable in seconds). Cached 60s in-process (§3.5).
CREATE TABLE IF NOT EXISTS scan_integrity_config (
    id                     int         PRIMARY KEY DEFAULT 1 CHECK (id = 1),
    mode                   text        NOT NULL DEFAULT 'shadow',  -- shadow|bot_only|full
    breaker_enabled        boolean     NOT NULL DEFAULT true,
    velocity_hits_per_min  int         NOT NULL DEFAULT 120,  -- per (qr_id, ip_hash)
    velocity_min_sessions  int         NOT NULL DEFAULT 3,    -- entropy floor: >= this
                                                              -- many distinct sessions
                                                              -- ⇒ looks like a crowd,
                                                              -- never flagged on volume
    burst_multiplier       numeric     NOT NULL DEFAULT 10.0, -- last hour vs baseline
    burst_absolute_floor   int         NOT NULL DEFAULT 200,  -- last-hour scans floor
    hosting_asns           int[]       NOT NULL DEFAULT '{}', -- overrides/extends code list
    exempt_asns            int[]       NOT NULL DEFAULT '{}', -- SASE/VPN never treated
                                                              -- as hosting (Zscaler,
                                                              -- Netskope, WARP, …)
    updated_at             timestamptz NOT NULL DEFAULT now()
);
INSERT INTO scan_integrity_config (id) VALUES (1) ON CONFLICT (id) DO NOTHING;

-- Per-workspace allowlist: a customer's known-good source is never flagged again.
-- Exactly one of ip_hash / asn / qr_id is set (scope of the exemption).
CREATE TABLE IF NOT EXISTS scan_integrity_allowlist (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    ip_hash       text,
    asn           int,
    qr_id         uuid,
    note          text,
    created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_scan_integrity_allowlist_ws
    ON scan_integrity_allowlist (workspace_id);

-- Circuit-breaker holds: while a hold is open, _enforce_scan_limit NEVER disables
-- this workspace's QRs. Cleared by an operator, not by a timer (§3.6 R-note).
CREATE TABLE IF NOT EXISTS scan_integrity_holds (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id  uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    reason        text        NOT NULL,
    held_at       timestamptz NOT NULL DEFAULT now(),
    cleared_at    timestamptz,
    cleared_by    text
);
CREATE INDEX IF NOT EXISTS idx_scan_integrity_holds_open
    ON scan_integrity_holds (workspace_id)
    WHERE cleared_at IS NULL;

-- ── 5. Atomic RPCs (mirrors the increment_ai_usage / increment_card_ocr_usage
--       pattern: one round-trip, no read-modify-write race across processes) ──
CREATE OR REPLACE FUNCTION increment_scan_velocity(
    p_qr_id uuid, p_ip_hash text, p_bucket timestamptz, p_session_id text
) RETURNS TABLE (hits int, sessions int) AS $$
DECLARE r scan_velocity_buckets%ROWTYPE;
BEGIN
    INSERT INTO scan_velocity_buckets (qr_id, ip_hash, bucket_start, hits, session_sample)
    VALUES (p_qr_id, p_ip_hash, p_bucket, 1,
            CASE WHEN p_session_id IS NULL THEN '{}' ELSE ARRAY[p_session_id] END)
    ON CONFLICT (qr_id, ip_hash, bucket_start) DO UPDATE
        SET hits = scan_velocity_buckets.hits + 1,
            session_sample = CASE
                WHEN p_session_id IS NULL
                  OR p_session_id = ANY(scan_velocity_buckets.session_sample)
                  OR coalesce(array_length(scan_velocity_buckets.session_sample, 1), 0) >= 16
                THEN scan_velocity_buckets.session_sample
                ELSE scan_velocity_buckets.session_sample || p_session_id END
    RETURNING * INTO r;

    -- Amortized GC: ~1 scan in 1000 prunes expired buckets. Avoids a new cron
    -- (which would need a Worker deploy) and bounds the table without a sweeper.
    IF random() < 0.001 THEN
        DELETE FROM scan_velocity_buckets WHERE bucket_start < now() - interval '15 minutes';
    END IF;

    RETURN QUERY SELECT r.hits, coalesce(array_length(r.session_sample, 1), 0);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION bump_scan_integrity_daily(
    p_workspace_id uuid, p_qr_id uuid, p_day date, p_reason text, p_flag text
) RETURNS void AS $$
BEGIN
    INSERT INTO scan_integrity_daily (workspace_id, qr_id, day, reason, flag, scan_count)
    VALUES (p_workspace_id, p_qr_id, p_day, p_reason, p_flag, 1)
    ON CONFLICT (workspace_id, qr_id, day, reason) DO UPDATE
        SET scan_count = scan_integrity_daily.scan_count + 1,
            updated_at = now();
END;
$$ LANGUAGE plpgsql;

COMMIT;

-- Sanity:
--   SELECT mode, breaker_enabled, velocity_hits_per_min FROM scan_integrity_config;
--   SELECT integrity_flag, count(*) FROM qr_scan_events GROUP BY 1;  -- all 'clean' pre-deploy
--   SELECT indexname FROM pg_indexes WHERE tablename = 'qr_scan_events';
```

**No `plans` table change.** `max_scans` keeps its current values (`0009_pricing_v3_4tier_collapse.sql:97`: Free `2000`, Starter/Pro/Agency `-1`). No `FEATURE_ENFORCEMENT` entry is added, so `test_feature_gate_coverage` neither gains nor loses a key. *(The stale "Free (500)" comment at `0007_billing_foundations.sql:24` predates `0009` and should be corrected in this PR's diff for the next reader.)*

---

## 3. Backend Design

### 3.1 `src/utilities/scan_integrity.py` (new)

The whole classifier. Pure functions plus one cached config read; no framework coupling, so it is directly unit-testable without a request.

```python
FLAG_CLEAN, FLAG_SUSPECT, FLAG_BOT, FLAG_ABUSE = "clean", "suspect", "bot", "abuse"
BILLABLE_FLAGS = (FLAG_CLEAN, FLAG_SUSPECT)   # single source of truth (§3.4)
```

- `get_config(db) -> dict` — reads the single `scan_integrity_config` row through a **60-second module-level TTL cache** (same shape as `resolve_plan`'s cache in `subscription.py`). **Fails open on any error: returns `mode='shadow'`, which is exactly today's behaviour.** A config outage must never change enforcement.
- `classify(payload, velocity, config, allowlist) -> tuple[str, str | None]` — pure; returns `(flag, reason)`. Rule order in §3.2.
- `is_allowlisted(payload, allowlist) -> bool` — short-circuits everything to `clean`.
- `bucket_start(now) -> datetime` — `now` truncated to the minute (UTC).
- `billable_scan_count(db, workspace_id, since_iso, config) -> int` — **the one predicate** every quota counter uses (§3.4).
- `record(db, payload, flag, reason)` — the `bump_scan_integrity_daily` RPC call, wrapped so a rollup failure never touches the scan write.

Reason keys are stable machine strings (`hosting_asn`, `known_crawler`, `ip_burst_low_entropy`, `ua_incoherent`) mapped to customer-facing prose in **one** place (§5.2) so support, the popover, and the logs all say the same thing.

### 3.2 Classification rules (ordered; first match wins)

Every rule runs against fields already on `ScanEventPayload` (`internal.py:329–347`). **No new data collection.**

| # | Rule | Signals | Flag | Reason | Notes |
|---|---|---|---|---|---|
| 0 | **Allowlisted** | `scan_integrity_allowlist` match on `ip_hash` / `asn` / `qr_id` for this workspace | `clean` | — | Absolute short-circuit. The operator's override always wins. |
| 1 | **Known crawler** | `user_agent` matches the crawler set (the `scan.js:2` list, widened: `bingbot`, `duckduckbot`, `yandex`, `applebot`, `ahrefs`, `semrush`, `python-requests`, `curl`, `wget`, `go-http-client`, `headlesschrome`, `okhttp`, link-unfurlers) | `bot` | `known_crawler` | Same class the Worker already labels `device_type='bot'`. Widening the list here (not at the edge) avoids a Worker deploy. |
| 2 | **Hosting ASN + non-human profile** | `asn ∈ hosting_asns` **AND** `asn ∉ exempt_asns` **AND** at least one of: UA not a real browser (`ua_parser.parse_ua` → `Other`/`Unknown` browser), `language` empty, `device_type == 'desktop'` with no `referer` and no `language` | `bot` | `hosting_asn` | **Never fires on ASN alone.** Corporate VPN/SASE egress (Zscaler, Netskope, Cloudflare WARP, corporate cloud NAT) puts *genuine human* scans on hosting-like ASNs with perfectly normal browser UAs — those ASNs go in `exempt_asns` **and** would fail the second-signal test anyway. Two independent guards, because this rule is the highest-volume one. |
| 3 | **Per-IP burst with collapsed entropy** | `velocity.hits >= velocity_hits_per_min` for `(qr_id, ip_hash, minute)` **AND** `velocity.sessions < velocity_min_sessions` | `suspect` → `abuse` on promotion | `ip_burst_low_entropy` | **This is the NAT-safe rule.** Many distinct `session_id`s behind one `ip_hash` = a crowd (trade show, restaurant, classroom, CGNAT) and is **never** flagged, at any velocity. Few distinct sessions at high volume = one client hammering. |
| 4 | **UA/geo incoherence at volume** | rule 3's volume condition **AND** a UA/`language`/`country_code` combination `ua_parser` cannot reconcile (e.g. randomized UAs with a single `Accept-Language` and a single country) | `suspect` | `ua_incoherent` | Anti-evasion for rule 3 (UA rotation inflates `sessions`). Enters at `suspect`; promotion needs measured precision. |
| — | otherwise | | `clean` | `NULL` | |

**Accidental duplicates are not a rule.** A repeat scan by the same human is already handled: `is_unique=False` (`internal.py:375–392`) keeps it out of unique counts. It stays `clean` and **stays billable** — we rendered a real page for a real person.

**Rule-promotion protocol.** New rules land emitting `suspect` (no billing/analytics effect). Promotion to `bot`/`abuse` is a code change, made only after the rule's precision has been measured on production traffic (PRD §10 Phase 2). The `mode` config gates the *effect*, not the *classification*: flags are always written, so shadow data accumulates from day one.

### 3.3 `record_scan_event` changes (`internal.py:350–529`)

Insert three steps; touch nothing else in the handler.

**Before the insert (`:393`)** — the flag must be on the row as it is written, not a second UPDATE:

```python
integrity_flag, integrity_reason = FLAG_CLEAN, None
try:
    cfg = get_config(db)
    allow = load_allowlist(db, payload.workspace_id)      # cached 60s per workspace
    vel = None
    if payload.ip_hash and needs_velocity(payload, cfg, allow):
        rpc = db.rpc("increment_scan_velocity", {...}).execute()
        vel = _first(rpc.data)
    integrity_flag, integrity_reason = classify(payload, vel, cfg, allow)
except Exception:
    logger.error("scan-integrity classification failed for qr %s", payload.qr_id, exc_info=True)
    # fail OPEN: the scan stays 'clean'. A classifier bug must never cost a customer
    # a scan, and must never break scan recording. Same posture as the documented
    # fail-open at internal.py:473-483.
```

`needs_velocity()` skips the RPC entirely when a cheaper rule has already decided (allowlisted, or rules 1–2 matched), so the extra round-trip does not run for every scan.

Then `event_data["integrity_flag"] = integrity_flag` / `["integrity_reason"] = integrity_reason` alongside the existing `event_data["is_unique"] = is_unique` at `:391–392`.

**After the insert**, best-effort rollup (flagged rows only):

```python
if integrity_flag != FLAG_CLEAN:
    try:
        record(db, payload, integrity_flag, integrity_reason)   # bump_scan_integrity_daily
    except Exception:
        logger.error("scan-integrity rollup failed for qr %s", payload.qr_id, exc_info=True)
```

`qr_scan_counters` (`:396–465`) is **deliberately left alone**: it is the lifetime/dashboard counter, not the billing meter, and it stays a raw total. The divergence is intentional and must be labelled in the UI (PRD R9) — "total scans" and "billable scans this period" are different numbers and the disclosure line (§5.1) is what reconciles them. *(Splitting the counters into clean/flagged JSONB keys is the alternative; deferred to §12 Q2 because it changes a shipped read shape.)*

The webhook dispatch (`:492–508`) and `check_scan_milestones` (`:519`) are **unchanged in v1** — they still fire for flagged scans. That is a known gap (§12 Q5): fixing it changes an outbound contract customers' automations may already depend on, so it needs an announcement, not a silent behaviour change.

### 3.4 The one billable predicate — three call sites, zero drift

Three functions count scans for quota purposes and they currently do it independently. If they ever disagree, a workspace can be disabled by one and never re-enabled by another — and because a disabled QR receives **zero edge traffic** (the Worker returns `getScanLimitPage` at `index.js:372–374` *before* `recordScan`), it can never re-trigger enforcement. **The drift would be permanent.** `_reenable_free_scan_disabled`'s docstring already says exactly this (`internal.py:622–624`).

All three now call one helper:

```python
def billable_scan_count(db, workspace_id: str, since_iso: str, cfg: dict) -> int:
    q = (db.table("qr_scan_events").select("id", count="exact")
           .eq("workspace_id", workspace_id).gte("scanned_at", since_iso))
    if cfg["mode"] != "shadow":
        q = q.in_("integrity_flag", _billable_flags(cfg))   # ('clean','suspect') [+ 'abuse' if bot_only]
    return q.execute().count or 0
```

| Call site | Today | After |
|---|---|---|
| `_enforce_scan_limit` (`internal.py:551–558`) | raw `count="exact"`, no filter | `billable_scan_count(...)` |
| `_usage_max_scans` (`subscription.py:367–375`) | raw `count="exact"`, no filter | `billable_scan_count(...)` |
| `_reenable_free_scan_disabled` (`internal.py:670–677`) | raw `count="exact"`, no filter | `billable_scan_count(...)` |

Two correctness details that are easy to get wrong:

- **`.in_()` not `.neq()`.** PostgREST `neq` on a NULL column also excludes NULL rows (`NULL <> 'bot'` is `NULL`, i.e. not true). The column is `NOT NULL DEFAULT 'clean'` so NULLs cannot occur — but the positive `.in_()` form is both NULL-proof and matches the partial index predicate, so the planner uses `idx_qr_scan_events_ws_billable`.
- **`mode` is read once per enforcement pass** and passed down, so a config flip mid-request cannot make two counts in the same request disagree.

### 3.5 Enforcement modes (kill switch without a deploy)

`scan_integrity_config.mode` is a single `UPDATE` in the SQL editor and takes effect within the 60-second cache TTL. **No backend deploy, no Worker deploy.**

| `mode` | Flags written? | Billing effect | Analytics effect | Circuit breaker |
|---|---|---|---|---|
| `shadow` (default at launch) | yes | **none** — counts everything, exactly today | none | independent (`breaker_enabled`) |
| `bot_only` (Phase 1) | yes | excludes `bot` | excludes `bot` | on |
| `full` (Phase 2) | yes | excludes `bot` + `abuse` | excludes `bot` + `abuse` | on |

Rolling back a bad rule is `UPDATE scan_integrity_config SET mode='shadow'`. That property is the reason this config lives in the database and not in `settings` — Render env changes require a redeploy, and the failure mode we are protecting against (a rule wrongly capping customers) needs a seconds-scale revert.

### 3.6 Circuit breaker in `_enforce_scan_limit` (`internal.py:532`)

Once exclusion is live, a flood cannot push the *billable* count over the cap — so the breaker is **defence-in-depth against misclassification**: the attack traffic we failed to flag. It therefore triggers on the *shape* of the period, not on any flag.

```python
def _enforce_scan_limit(db, workspace_id: str) -> None:
    ...
    cfg = get_config(db)
    total_workspace_scans = billable_scan_count(db, workspace_id, period_start_iso(resolved), cfg)
    if total_workspace_scans < max_scans:
        return

    # ── CIRCUIT BREAKER ──────────────────────────────────────────────────────
    # We are about to take EVERY printed QR this customer owns offline. Do not do
    # that while the workspace is in an anomalous burst — that is the signature of
    # an attack we failed to classify, and the action is irreversible in the
    # physical world (you cannot un-print a poster).
    if cfg["breaker_enabled"] and (_has_open_hold(db, workspace_id)
                                   or _burst_anomaly(db, workspace_id, cfg)):
        _open_hold(db, workspace_id, "burst_at_cap")          # idempotent
        _fire_integrity_hold_alert(db, workspace_id)          # once per ISO week
        logger.error("ALERT: scan-cap disable SUPPRESSED for ws %s (integrity hold)", workspace_id)
        return                                                # ← QRs stay ACTIVE

    ... existing disable + KV sync + _fire_scan_cap_alert, unchanged ...
```

`_burst_anomaly(db, ws, cfg)`: scans in the last 60 minutes vs the workspace's trailing-7-day median hourly rate. Fires when `last_hour >= burst_multiplier × baseline` **and** `last_hour >= burst_absolute_floor` (the floor stops a low-traffic workspace tripping on three scans against a baseline of zero). Two indexed `count="exact"` queries, run **only** at the moment of a would-be disable — i.e. at most once per scan for a workspace already at cap, never on the normal path.

**The hold does not auto-expire.** It is cleared by an operator (§3.7). A timer would silently re-arm the disable a day later and take the customer's QRs down anyway — turning a caught false positive into a delayed outage. Converting a customer-facing outage into an internal ticket is the trade this feature exists to make. Holds should be rare: a workspace must be simultaneously at cap *and* in a 10× burst.

**Escape-hatch guard (PRD R3):** a hold suppresses only the *automatic* disable. It grants no extra quota, and `billable_scan_count` keeps accruing — an operator clearing the hold on a workspace that is genuinely over cap on clean scans lets the next pass disable normally.

**Fail direction:** any exception inside the breaker path is caught by the existing `try/except` around `_enforce_scan_limit` (`internal.py:471–483`), which is documented fail-open (do not disable). That is the correct direction here and requires no change.

### 3.7 Operator endpoints (`internal.py`, `x-internal-secret` via the router dependency at `:21–35`)

No Bearer auth, no UI, runbook-driven. All four are idempotent.

| Endpoint | Body | Behaviour |
|---|---|---|
| `POST /internal/scan-integrity/reclassify` | `{workspace_id, qr_id?, day, from_flag, to_flag, reason}` | Bulk-update `qr_scan_events.integrity_flag` for the window **in both directions**, and adjust `scan_integrity_daily`. **This is an UPDATE of a metadata column, never a DELETE** — the §1.2 invariant holds. |
| `POST /internal/scan-integrity/allowlist` | `{workspace_id, ip_hash?|asn?|qr_id?, note}` | Insert into `scan_integrity_allowlist`; that source is `clean` from the next scan onward. |
| `POST /internal/scan-integrity/hold` | `{workspace_id, action: "open"\|"clear", reason}` | Open/clear a `scan_integrity_holds` row. `open` pins a workspace against auto-disable during an investigation. |
| `POST /internal/scan-integrity/restore` | `{workspace_id}` | Single-workspace `_reenable_free_scan_disabled` — the "give them their QRs back **now**" button, instead of waiting for the `0 0 1 * *` cron. Reuses the existing function's per-workspace body verbatim, including the KV re-sync (`internal.py:695–705`). |

`restore` is the single highest-value operator capability here. Today a wrongly-capped workspace waits up to a month.

### 3.8 Read path (`scan.py`)

- Generalize the existing bot filter. `_scan_count` (`:1353–1358`) currently does `q.neq("device_type", "bot")`; it gains the integrity predicate. The in-Python filters at `:599`, `:1641`, `:1888` gain the matching `integrity_flag` check. The public-API `exclude_bots` param (`api_public.py:1028`) and every `exclude_bots`/`include_bots` query param (`:1392`, `:1753`, `:1955`) keep their **current names and defaults** — `exclude_bots=True` already means "hide non-human traffic", which is exactly what it now does more completely. No breaking API change.
- `GET /analytics/summary` (`scan.py:839`) — `AnalyticsSummaryResponse` (`:26–30`) gains `excluded_scans: int`, read from `scan_integrity_daily` for the window. One extra indexed query on an already-cheap endpoint; no second FE request for the headline number.
- **New** `GET /analytics/integrity` — the popover payload: `{total_excluded, by_reason: [{reason, label, count}], by_day: [{day, count}]}`, scoped to the workspace (and optionally `qr_id`), windowed by `analytics_retention_days` like every other reader. Reads `scan_integrity_daily` only, so it works even after raw rows age out.
- **Not gated by `advanced_analytics`.** The disclosure must be visible on Free — Free is the tier that gets attacked (PRD §8).

---

## 4. Cloudflare Worker / Edge Design

**No change. Zero lines.** This is a deliberate architectural outcome, not an oversight:

- Every signal the classifier consumes is **already on the wire**: `asn`, `ip_hash`, `session_id`, `user_agent`, `language`, `referer`, `country_code`, `device_type`, `timezone` (`scan.js:44–62`). We are reusing collection, not adding it.
- The scan hot path stays exactly as fast: `ctx.waitUntil(fetch(...).catch(() => {}))` (`scan.js:75–84`) is already fire-and-forget after the response.
- **No `npm run deploy:prod` gate.** No new cron (`wrangler.toml` `[env.production.triggers]` unchanged — velocity GC is amortized inside the RPC, §2), no new KV key, no `build_kv_content` branch, no new QR type, no template. The Worker↔React template-mirroring rule does not apply because nothing renders.
- **The `detectDevice` regex at `scan.js:2` stays as-is.** Widening the crawler list backend-side (rule 1, §3.2) supersedes it functionally without touching the edge — and keeps `device_type='bot'` meaning the same thing it has always meant for existing rows and existing analytics.

**Explicitly deferred (Phase 3, not committed):** an edge pre-filter using Durable Objects or the Workers rate-limit binding. It would need new infra, a `deploy:prod` gate, and a round-trip on the hot path, and it solves a volume problem we have not measured yet. §1.1 has the full rejection reasoning.

---

## 5. Frontend Design

Small by design — one line and a popover. No new page, no new route, no gating call, no `PlanFeatures` change.

### 5.1 `ScanIntegrityNote.tsx` (`src/components/org/analytics/`, new)

- Renders nothing when `excluded_scans === 0` (the common case for a quiet workspace).
- Otherwise a single muted line under the analytics header: **"1,204 scans excluded as automated traffic."** with an info affordance. Muted/secondary tone — **not** an alert colour. Most workspaces will carry a small nonzero number forever because bots are ambient, and styling ambience as an alarm trains people to ignore real alarms.
- The popover lazy-fetches `GET /analytics/integrity` on open (a new `useScanIntegrity` query in `src/hooks/`, keyed off the existing `useAnalytics` key factory) and lists reason + count + affected days.
- shadcn `Popover` + `Button`; no raw HTML elements where a primitive exists; no inline styles; typed props, no `any`; one export; kebab-case filename; well under the 200-line limit.

### 5.2 Reason → prose mapping (`src/lib/constants/scan-integrity-reasons.ts`, new)

```ts
export const SCAN_INTEGRITY_REASONS: Record<string, string> = {
  known_crawler:        'Search engine or link preview bot',
  hosting_asn:          'Automated traffic from a hosting provider',
  ip_burst_low_entropy: 'Repeated requests from a single source',
  ua_incoherent:        'Requests with inconsistent device information',
};
```

Backend returns both the stable `reason` key **and** a rendered `label`, so support tickets, server logs, and the customer's screen use identical wording. The frontend map is the fallback for an unknown key (render the label from the API). No thresholds, no scores, no rule names ever reach the UI (PRD §6.4).

### 5.3 Placement

Wired into the analytics page (`src/app/[slug]/(dash)/analytics/`) beside `AnalyticsHeader.tsx`, and into `QRDetails` for the per-QR case. It sits near — but is distinct from — `ScanLimitAlert.tsx` (`src/components/org/ScanLimitAlert.tsx`), which is the amber "limit reached" banner. If a workspace is under an integrity hold, `ScanLimitAlert` must **not** render: their QRs are still live, and telling them otherwise is worse than saying nothing.

*(Note: the route is `src/app/[slug]/(dash)/analytics/`, not the `src/app/org/[slug]/...` path recorded in `CLAUDE.md` — the repo layout has moved on from the doc.)*

---

## 6. AI / External-Service Integration

**None.** No AI, no third-party fraud/IP-reputation service, no new env var, no new PyPI or npm dependency, no new secret.

**Email (existing path only):** the integrity-hold alert reuses `send_alert_email` (`src/utilities/email.py`) through `_alert_once` (`internal.py:854`) with a new `alert_type` — the same mechanism already in production for `scan_cap` (`_fire_scan_cap_alert`, `internal.py:896`). Per the standing mail note, `_dmarc.qravio.app` is still unpublished, so this inherits an existing deliverability risk rather than creating one. **The email is not a launch gate:** the protection is that the QRs stay up; the email is the courtesy. If it does not deliver, the customer is still protected and the operator still sees the loud `logger.error`.

The **hosting ASN list** is the only external-ish dependency: seeded from a public hosting-ASN dataset into `scan_integrity_config.hosting_asns`, maintained as **data, not code**, so it is updatable with one `UPDATE`. Honest limitation: an ASN list is permanently incomplete and permanently stale — which is precisely why rule 2 requires a second signal and never fires on ASN alone.

---

## 7. API Contracts

**Internal (operator; `x-internal-secret`, no Bearer):**

```http
POST /internal/scan-integrity/reclassify
{ "workspace_id":"uuid", "qr_id":"uuid", "day":"2026-08-12",
  "from_flag":"abuse", "to_flag":"clean", "reason":"false positive — trade show" }
200 → { "status":"ok", "rows_updated": 4102, "rollup_adjusted": true }

POST /internal/scan-integrity/allowlist
{ "workspace_id":"uuid", "asn": 64512, "note":"customer's office SASE egress" }
201 → { "status":"ok", "id":"uuid" }

POST /internal/scan-integrity/hold
{ "workspace_id":"uuid", "action":"open", "reason":"under investigation" }
200 → { "status":"ok", "hold_id":"uuid", "open": true }

POST /internal/scan-integrity/restore
{ "workspace_id":"uuid" }
200 → { "status":"ok", "reenabled": 7, "skipped_over_cap": 0 }
401 → { "detail":"Invalid or missing internal secret" }
```

**Customer-facing (JWT, existing analytics router `prefix="/analytics"`):**

```http
GET /analytics/summary?workspace_id=…&range=30        (unchanged params)
200 → { "total_scans": 8421, "unique_visitors": 6103,
        "scans_wow_change": 12.4,
        "excluded_scans": 1204 }                       ← NEW field, additive

GET /analytics/integrity?workspace_id=…&range=30[&qr_id=…]    ← NEW
200 → { "total_excluded": 1204,
        "by_reason": [
          { "reason":"hosting_asn",   "label":"Automated traffic from a hosting provider", "count":1180 },
          { "reason":"known_crawler", "label":"Search engine or link preview bot",         "count":24 } ],
        "by_day":   [ { "day":"2026-08-12", "count":1102 }, { "day":"2026-08-13", "count":102 } ] }
```

`excluded_scans` is **additive** — existing clients ignoring the field keep working. `exclude_bots`/`include_bots` keep their names, defaults, and semantics everywhere (`scan.py:1392`, `:1753`, `:1955`; `api_public.py:1028`); only the underlying predicate broadens. **No breaking API change in this feature.**

---

## 8. Security, Privacy & Abuse

**Auth.** Operator endpoints live on the internal router and inherit `Depends(verify_internal_secret)` (`internal.py:21–35`) — they are **not** reachable with a customer JWT, and they are excluded from Bearer auth by the `auth_bearer.py` `/internal/*` rule. Customer-facing reads go through the normal JWT + `require_can_read` path. Every query filters `workspace_id` explicitly because the **service role key bypasses RLS**.

**`ip_hash` is pseudonymous, not anonymous — and the scan path is not the salted one.** This correction matters for anyone reasoning about the design:

- The salted hash at `internal.py:1332` (`sha256(ip + settings.HASHING_SALT)`) is the **lead-submit** path. **The scan path does not use `HASHING_SALT` at all.**
- The scan `ip_hash` is computed at the edge as `hashString(\`${ip}:${today}\`)` (`scan.js:37`), where `hashString` is SHA-256 **truncated to 16 hex characters** and **unsalted** (`scan.js:8–14`).
- **Consequence 1 — within-day only.** The date component means `ip_hash` is a stable per-IP key *within a UTC day* and unlinkable across days. Every rule in this spec is therefore a within-day rule, and cross-day IP reputation is impossible without changing the edge derivation — which would break the shipped scan↔lead↔click session join (`scan.js:16–24`). A flood spanning midnight UTC splits across two hash spaces; accepted, and the daily rollup still records both halves.
- **Consequence 2 — the raw IP is unavailable to us.** At `POST /internal/scans` the backend's `request.client.host` is Cloudflare's egress, not the visitor's. **Confirmed: every per-IP signal here works on the hash, by necessity, not by choice.**
- **Consequence 3 — privacy, stated plainly.** An unsalted, truncated SHA-256 of an IPv4 address is **not anonymization**: the IPv4 space is 2³² and a rainbow table is minutes of laptop time. `ip_hash` is pseudonymous personal data under GDPR and should be described that way internally and in the DPA. Daily rotation limits cross-day linkability — a genuine but partial mitigation. **This feature does not change the edge and does not worsen the position, but it does make us newly *rely* on that field, so we should stop calling it anonymized.** Remediation (own ticket, out of scope): add a second `ip_hash_stable` at the edge, salted with a Worker secret, kept *alongside* the existing field so the session join survives.

**No new PII and no new collection.** Every signal is already collected and already stored. The EU consent posture is unchanged (consent gates scan-page marketing tags, not server-side analytics). `integrity_reason` is a fixed enum, never free text derived from user data. Logs record `ip_hash` and `asn`, never a raw IP (we do not have one).

**Abuse of the feature itself.**
- *Quota evasion (PRD R2):* excluded scans delivered no human value — a hosting-ASN request still received the page, so nothing is withheld. To farm free quota a customer would have to route real customers through a hosting provider. Flagged-share per workspace is monitored as an abuse signal in its own right.
- *Breaker abuse (PRD R3):* a hold suppresses only the automatic disable; it grants no quota, requires an operator to clear, and puts a human on the account — which is the desired outcome for anyone gaming it.
- *Evasion:* thresholds and rule names are never exposed to customers (PRD §6.4). A paced-below-threshold attack takes orders of magnitude longer, and the breaker is a backstop that does not depend on classification succeeding.
- *Operator endpoint abuse:* `INTERNAL_SECRET` compromise already implies full scan-ingest forgery, so these endpoints add no new attack surface class. Every reclassify/hold/restore is logged with the reason at `logger.warning`.

**Data retention.** `scan_integrity_daily` holds aggregate counts only — no IP, no UA, no session — so it can be retained past the raw-row window without a privacy cost, and it is what makes a billing dispute resolvable after `analytics_retention_days` has elapsed (7 days on Free, the tier most likely to be attacked). `scan_velocity_buckets` holds `ip_hash` for **15 minutes** and is amortized-GC'd.

---

## 9. Performance, Scale & Cost

**Per-scan cost.** `record_scan_event` today does ~4–5 Supabase round-trips (uniqueness check, insert, counter select, counter update, scan-limit count). This adds:

| Step | When | Cost |
|---|---|---|
| `get_config` | every scan | ~0 — 60 s in-process TTL cache |
| `load_allowlist` | every scan | ~0 — 60 s per-workspace TTL cache; most workspaces have zero rows |
| `increment_scan_velocity` RPC | only when rules 1–2 have not already decided and `ip_hash` is present | **1 round-trip**, O(1) upsert on a PK |
| `bump_scan_integrity_daily` RPC | flagged scans only (a small % in steady state) | 1 round-trip, O(1) upsert on a PK |
| `_burst_anomaly` | only at a would-be disable | 2 indexed counts, never on the normal path |

**Steady state: ≤ 1 extra round-trip per scan.** Budget: `POST /internal/scans` p95 **+≤ 15 ms**. It is `ctx.waitUntil`-detached (`scan.js:75`), so this is never visible to the person scanning — but it is real backend capacity and it is budgeted.

**The detector must not amplify the attack (PRD R5).** The rejected naive design — `count(*)` over recent `qr_scan_events` per `(qr_id, ip_hash)` — is O(n) in the flood we are defending against, so the detector's cost grows with the attack. The bucketed RPC is O(1) per scan regardless of volume, and `UNLOGGED` removes the WAL cost of the hottest write. Bucket rows are bounded by `(distinct qr × distinct ip × 15 minutes)` and amortized-GC'd inside the RPC.

**Index strategy.** `idx_qr_scan_events_ws_billable` is **partial**, matching the exact `.in_('integrity_flag', ...)` predicate the helper emits, so the billing count stays index-only and does not regress against today's `idx_qr_scan_events_workspace_scanned` (`0007:45–46`). Read-path aggregations reuse the existing `_fetch_windowed_events` 50k window cap; `/analytics/integrity` reads the small pre-aggregated rollup rather than raw rows, so it is cheap at any workspace size.

**Storage.** Two `text` columns on `qr_scan_events` (one short enum, one nullable short enum — negligible), plus three small tables. `scan_integrity_daily` grows at most one row per `(qr, day, reason)` — bounded and tiny.

**No new infrastructure, no new service, no new cron, no new external call.** Zero incremental vendor cost.

---

## 10. Testing Strategy

**pytest (`qr_backend/tests/unit_tests/test_scan_integrity.py`, new)**

*False positives first — these are the tests that matter most, and they are written before the attack tests:*

- **Trade-show booth:** 600 scans in 3 hours, **one** `ip_hash`, **many** distinct `session_id`s, consumer/mobile ASN → **all `clean`**, at every velocity, with the breaker never arming.
- **Restaurant dinner rush:** 200 scans/hour sustained on one NAT'd `ip_hash`, many sessions → **all `clean`**; repeated across days → still `clean` (no accumulating penalty).
- **Classroom burst:** 40 scans in 90 seconds from one school Wi-Fi → **all `clean`** (highest instantaneous velocity in the product).
- **Worst-case session collapse:** the classroom case where identical devices collapse into **few** `session_id`s (the `session_id = hash(ip:ua:day)` limitation, §3.2 rule 3) → **still `clean`**, because `velocity_hits_per_min` is above any plausible human burst. *This is the test that proves the threshold is set honestly rather than optimistically.*
- **Corporate VPN / SASE:** hosting-like ASN, normal Chrome UA, `Accept-Language` present → **`clean`** (rule 2's second-signal requirement), and again via `exempt_asns`. Both guards asserted independently so removing either fails a test.
- **Carrier-grade NAT:** many sessions, one `ip_hash`, mobile ASN → **`clean`**.

*Attack + correctness:*

- Hosting ASN + `python-requests` UA + no language → **`bot`**, `hosting_asn`.
- Known-crawler UA (each entry in the widened list) → **`bot`**, `known_crawler`.
- Single-session flood at 10× the threshold → **`suspect`** in default config; **`abuse`** after promotion; **excluded from `billable_scan_count`** in `full` mode only.
- **End-to-end DoS scenario (the acceptance test):** seed a Free workspace, drive 3,000 flood scans past `max_scans=2000` → **quota not exhausted, every QR still `status='active'`, a hold row exists, the owner alert fired exactly once.**
- **Repeat human scan stays billable:** same `session_id` twice → `is_unique=False` **and** `integrity_flag='clean'` **and** counted by `billable_scan_count`. (Guards against someone "helpfully" deduping billing.)
- **Three-counter agreement:** property test asserting `_enforce_scan_limit`, `_usage_max_scans`, and `_reenable_free_scan_disabled` return the identical count for the same workspace/period across all three `mode` values (R6 / §3.4).
- **`.in_()` not `.neq()`:** a row with `integrity_flag='clean'` is counted; assert the query builder emits the `in` form (regression guard for the PostgREST NULL-semantics trap).
- **Shadow mode changes nothing:** `mode='shadow'` → flags written, `billable_scan_count` identical to the pre-feature raw count, no workspace behaviour change. *The Phase-0 safety property, asserted.*
- **Fail-open:** classifier raises → scan is inserted as `clean`, `record_scan_event` still returns `{"status":"ok"}`; config read raises → `mode='shadow'`; velocity RPC raises → no flag, no exception escapes.
- **Never deletes:** assert no code path in `scan_integrity.py` or the operator endpoints issues a `DELETE` against `qr_scan_events`. *(Invariant, §1.2.)*
- **Breaker escape-hatch:** a workspace over cap on **clean scans alone**, with no burst, **is** disabled normally — the breaker does not grant unlimited quota (R3).
- **Operator round-trip:** flag → reclassify to `clean` → rollup adjusted → `billable_scan_count` increases correspondingly; `restore` re-enables and re-syncs KV.
- **Idempotency:** replaying every operator endpoint twice is a no-op.

**Existing suites that must stay green:** `test_scan_limit_reenable.py`, `test_free_scan_reset.py`, `test_limits_engine.py`, `test_scan_readers.py`, `test_funnel.py`, `test_campaign_rollup.py`, `test_scan_milestones.py`, `test_webhooks_internal_hooks.py`, and **`test_feature_gate_coverage.py`** — which should be *unaffected*, since this feature adds no plan flag. Any movement there means a flag crept in.

⚠️ **Do not "fix" `test_limits_engine.py:20` while you are in there.** Its `FREE_PLAN` fixture carries `max_scans: 500` (0005-era) — an arbitrary test value, not the shipped Free tier. The live cap is `2000` (`0009_pricing_v3_4tier_collapse.sql:97`). New tests for `billable_scan_count` should assert *relationships* between the three counters, not absolute plan numbers, so they stay correct across repricing.

**Vitest (`qr_frontend`):** `ScanIntegrityNote` renders nothing at zero; renders the count and popover breakdown; renders on a Free workspace (ungated); `ScanLimitAlert` suppressed under an active hold. Note the **~29 pre-existing FE test failures** are the documented baseline — not regressions.

**Worker:** none. No edge change.

---

## 11. Observability & Rollout

**Deploy order (strict):**

1. **Apply `0047` in the Supabase SQL editor** (after re-verifying the slot number). Run the sanity SELECTs — `mode` must read `shadow`, and `SELECT integrity_flag, count(*) FROM qr_scan_events GROUP BY 1` must return one `clean` row. Verify the `ALTER` returned instantly (a slow one means the PG11+ fast path did not apply — stop and investigate before deploying).
2. **Deploy the backend.** Classification starts; `mode='shadow'` means **zero behaviour change** — the meter counts exactly what it counted yesterday. The one immediately-live change is the circuit breaker (`breaker_enabled=true`), which can only ever *prevent* a disable.
3. **Observe for two weeks** (PRD §10 Phase 0 gate) — flagged-share distribution, the four false-positive scenarios located in real traffic, ASN list validated.
4. `UPDATE scan_integrity_config SET mode='bot_only'` → Phase 1. **No deploy.**
5. Frontend disclosure line ships with or after step 4 (it reads zero until then, so ordering is free).
6. `mode='full'` → Phase 2, per-rule, after measured precision in `suspect`.

**Rollback:** `UPDATE scan_integrity_config SET mode='shadow', breaker_enabled=false` — seconds, no deploy, no Worker touch. This is the whole reason the config is in the database.

**Observability:**

- `logger.warning` on every `abuse` classification with `(workspace_id, qr_id, reason, ip_hash, asn, hits, sessions)` — never a raw IP (we do not have one).
- `logger.error("ALERT: scan-cap disable SUPPRESSED …")` on every breaker trip. This is a P1-adjacent signal and must be alertable — matching the existing loud-log discipline at `internal.py:478` and `:601`.
- `logger.warning` on every operator reclassify/hold/restore, with the reason. **Reclassification rate is the false-positive metric** — it is the health signal for the whole feature.
- Watchlist: flagged share platform-wide (a step change is an incident, in either direction); open holds (should be ~0); workspaces above 20% flagged share (Phase 1 review queue); `POST /internal/scans` p95 vs baseline.

**Explicit non-gates:** no `deploy:prod` (no Worker change), no DMARC dependency for the protection itself (§6), no new cron.

---

## 12. Open Technical Questions & Risks

1. **Velocity-bucket GC: amortized-in-RPC (`random() < 0.001`) vs a sweep?** *Recommend amortized.* A cron would mean either a Worker deploy (new trigger in `wrangler.toml`, `deploy:prod` gate) or bolting an unrelated prune onto the existing 5-minute `/internal/webhook-sweep` handler. Amortized GC is self-contained, bounded, and needs neither. Revisit only if bucket-table growth is observed.
2. **Should `qr_scan_counters` split clean/flagged?** *Recommend not in v1.* It is the lifetime/dashboard counter, not the meter; splitting it changes a shipped read shape consumed by the dashboard, `/analytics/summary`, and the milestone gate (`counter_total_scans`, `internal.py:522`). The divergence between "total scans" and "billable scans this period" is real and must be **labelled** in the UI rather than papered over (PRD R9). If customer confusion shows up in support, revisit.
3. **`UNLOGGED` for `scan_velocity_buckets` — is it available and acceptable on the deployment target?** *Recommend yes if permitted.* Truncation on unclean shutdown means forgetting an in-flight burst, which fails in the safe direction. Verify against the Supabase instance before shipping; if unavailable, drop the keyword — nothing else changes. *(Note `CREATE UNLOGGED TABLE IF NOT EXISTS` will not convert an existing logged table.)*
4. **Threshold seeds (`velocity_hits_per_min=120`, `velocity_min_sessions=3`, `burst_multiplier=10`, `burst_absolute_floor=200`) are placeholders.** They must be **derived from shadow-mode data, not shipped as guesses**. The Phase-0 → Phase-1 gate exists exactly to replace them. `120/min from one ip_hash with <3 distinct sessions` is deliberately far above any human burst we can construct; expect to lower it only with evidence.
5. **Exclude flagged scans from webhook dispatch (`internal.py:492–508`) and `check_scan_milestones` (`:519`)?** *Recommend yes, Phase 2, announced.* Customers' Zapier/Make automations may already be tuned to current volumes; silently changing what fires is worse than the junk events. Milestones are the sharper problem — a flood burning a "10,000 scans" milestone is irreversible in the customer's system.
6. **Does the breaker need an auto-expiry?** *Recommend no.* A timer would silently re-arm the disable and turn a caught false positive into a delayed outage. Operator-cleared holds convert a customer-facing outage into an internal ticket, which is the trade this feature exists to make. Revisit if hold volume becomes an operational burden — which would itself be evidence the thresholds are wrong.
7. **`suspect` rows count toward billing — is that right?** *Yes, and it is load-bearing.* `suspect` exists to measure a rule's precision in production without that rule being able to hurt anyone. A `suspect` flag with a billing effect is not a measurement, it is an enforcement.
8. **Boundary with `RATE_LIMITING_{PRD,TRD}` (concurrent).** That spec owns request throttling on the **public API and auth endpoints**; this spec owns the **scan path** (`/:shortCode` → `POST /internal/scans`) and only the scan path. **No shared code, no shared tables, no shared config row.** If platform-level throttling of scan traffic is ever wanted, it belongs there as infrastructure; the classification of a scan that *was* served belongs here. Duplicated ownership of the scan path across the two specs is the live merge hazard — this is the contract.
9. **Migration slot `0047` is provisional.** `ls qr_backend/migrations/` at build time. `0033`–`0046` are claimed by drafted-but-unapplied and concurrently-drafted specs, and this repo has shipped a spec into the wrong slot before (`AI_BUSINESS_CARD_OCR`: drafted `0024`, shipped `0026`).

### Appendix — Key Files

| Concern | File |
|---|---|
| Classifier + config cache + billable predicate | `qr_backend/src/utilities/scan_integrity.py` (**new**) |
| Ingest stamping | `qr_backend/src/api/routes/internal.py` (`record_scan_event`, `:350–529`; flag set beside `is_unique` at `:391–392`) |
| Billing enforcement + circuit breaker | `qr_backend/src/api/routes/internal.py` (`_enforce_scan_limit`, `:532`; count at `:551–558`; disable at `:575`) |
| Re-enable sweep + operator restore | `qr_backend/src/api/routes/internal.py` (`_reenable_free_scan_disabled` `:618`, count at `:670–677`, KV re-sync `:695–705`; `free_scan_reset` `:719`) |
| Usage meter (2nd counting site) | `qr_backend/src/api/routes/subscription.py` (`_usage_max_scans`, `:367–375`; `_QUOTA_SPEC` `:429`) |
| Plan resolution + period window | `qr_backend/src/api/routes/subscription.py` (`resolve_plan` `:283`, `period_start_iso` `:332`, `_limit_value` `:457`) |
| Alert ledger + scan-cap alert to mirror | `qr_backend/src/api/routes/internal.py` (`_alert_once` `:854`, `_fire_scan_cap_alert` `:896`, `_iso_week_start_iso` `:747`) |
| Operator endpoints (internal router) | `qr_backend/src/api/routes/internal.py` (`verify_internal_secret` `:21–35`) |
| Read-path bot filter to generalize | `qr_backend/src/api/routes/scan.py` (`:599`, `_scan_count` `:1353–1358`, `:1392`, `:1641`, `:1753`, `:1888`, `:1955`); `api_public.py:1028` |
| Analytics response shape | `qr_backend/src/api/routes/scan.py` (`AnalyticsSummaryResponse` `:26–30`, `/summary` `:839`) |
| UA parser to reuse | `qr_backend/src/utilities/ua_parser.py` (`parse_ua`); `tests/unit_tests/test_ua_parser.py` |
| Today's entire defence (1 regex) — unchanged | `qr_cf_code/src/utils/scan.js:2` (`detectDevice`) |
| Edge hash derivation (the `ip_hash` constraint) | `qr_cf_code/src/utils/scan.js:8–24`, `:37` |
| Signals already on the wire (incl. `asn`) | `qr_cf_code/src/utils/scan.js:44–62`; dispatched at `qr_cf_code/src/index.js:415` |
| Edge status gate (why a disabled QR never recovers) | `qr_cf_code/src/index.js:372–374` (`getScanLimitPage`) |
| Cron config (unchanged — no new trigger) | `qr_cf_code/wrangler.toml` (`[env.production.triggers]`) |
| Migration | `qr_backend/migrations/0047_scan_fraud_detection.sql` (**new; slot PROVISIONAL**) |
| Current `max_scans` seed — **authority** (Free 2000 / paid -1) | `qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql:97` |
| Stale 500 values — **not** sources of truth | `0005_pricing_v2_dual_currency.sql:59` (superseded), `0007_billing_foundations.sql:24` (stale comment, fix in passing), `tests/unit_tests/test_limits_engine.py:20` (arbitrary fixture) |
| FE disclosure line + reason map | `qr_frontend/src/components/org/analytics/ScanIntegrityNote.tsx` (**new**), `src/lib/constants/scan-integrity-reasons.ts` (**new**), `src/hooks/useAnalytics.ts` |
| FE placement + the banner to suppress under a hold | `qr_frontend/src/app/[slug]/(dash)/analytics/`, `src/components/org/analytics/AnalyticsHeader.tsx`, `src/components/org/ScanLimitAlert.tsx` |
| Tests | `qr_backend/tests/unit_tests/test_scan_integrity.py` (**new**); keep green: `test_scan_limit_reenable.py`, `test_free_scan_reset.py`, `test_limits_engine.py`, `test_scan_readers.py`, `test_feature_gate_coverage.py` |
