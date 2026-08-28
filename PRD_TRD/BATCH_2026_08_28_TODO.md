# Feature batch — 2026-08-28

Eleven requested items, triaged against the codebase. **8 are net-new** (PRD + TRD each);
**2 are defects/gaps in shipped features** (FIX doc each). Items 5 and 6 collapsed into one
spec — they are the same column, the same KV field, the same Worker branch.

> ⚠️ **Migration slots below are RESERVATIONS, not facts.** On-disk numbering advances
> independently of planning docs (see `FUTURE_FEATURES.md`). Before running anything,
> `ls qr_backend/migrations/` and take the next free integer, and re-confirm the highest
> **applied** number against the DB. Highest on disk when this batch was written: `0054`.

---

## Todo list

| # | Item | Verdict | Doc | Migration | Repos |
|---|------|---------|-----|-----------|-------|
| 1 | Schedule-report detail page + `/reports` theme redesign | **FIX** — `scheduled_reports` shipped; detail page absent, page off-theme | [`FIXES/REPORTS_THEME_AND_SCHEDULE_DETAIL_FIX.md`](FIXES/REPORTS_THEME_AND_SCHEDULE_DETAIL_FIX.md) | none | FE |
| 2 | Duplicate QR button | ✅ **SHIPPED 08-29** | [`DONE/DUPLICATE_QR_PRD.md`](DONE/DUPLICATE_QR_PRD.md) · [TRD](DONE/DUPLICATE_QR_TRD.md) — see TRD §0 | none | BE, FE |
| 3 | Change history for a QR | **NEW** | [`NOT_DONE/QR_CHANGE_HISTORY_PRD.md`](NOT_DONE/QR_CHANGE_HISTORY_PRD.md) · [TRD](NOT_DONE/QR_CHANGE_HISTORY_TRD.md) | `0055` | BE, FE |
| 4 | Offline detection | **NEW** | [`NOT_DONE/OFFLINE_DETECTION_PRD.md`](NOT_DONE/OFFLINE_DETECTION_PRD.md) · [TRD](NOT_DONE/OFFLINE_DETECTION_TRD.md) | none | FE |
| 5+6 | Per-QR scan limit / expiry by scan count | **NEW** (plan-level `max_scans` exists; per-QR cap does not) | [`NOT_DONE/PER_QR_SCAN_LIMIT_PRD.md`](NOT_DONE/PER_QR_SCAN_LIMIT_PRD.md) · [TRD](NOT_DONE/PER_QR_SCAN_LIMIT_TRD.md) | `0056` | BE, Worker, FE |
| 7 | UTM campaign support | **NEW** (campaign *tags* shipped; UTM injection did not) | [`NOT_DONE/UTM_CAMPAIGN_SUPPORT_PRD.md`](NOT_DONE/UTM_CAMPAIGN_SUPPORT_PRD.md) · [TRD](NOT_DONE/UTM_CAMPAIGN_SUPPORT_TRD.md) | `0057` | BE, Worker, FE |
| 8 | QR templates by industry | **NEW** (templates exist, keyed by *aesthetic*, not industry) | [`NOT_DONE/INDUSTRY_QR_TEMPLATES_PRD.md`](NOT_DONE/INDUSTRY_QR_TEMPLATES_PRD.md) · [TRD](NOT_DONE/INDUSTRY_QR_TEMPLATES_TRD.md) | none | FE |
| 9 | Tooltips onboarding | **NEW** | [`NOT_DONE/ONBOARDING_TOOLTIPS_PRD.md`](NOT_DONE/ONBOARDING_TOOLTIPS_PRD.md) · [TRD](NOT_DONE/ONBOARDING_TOOLTIPS_TRD.md) | none (v1) | FE |
| 10 | Feature request board | **NEW** | [`NOT_DONE/FEATURE_REQUEST_BOARD_PRD.md`](NOT_DONE/FEATURE_REQUEST_BOARD_PRD.md) · [TRD](NOT_DONE/FEATURE_REQUEST_BOARD_TRD.md) | `0058` | BE, FE |
| 11 | Review-funnel responses on QR details | **FIX** — funnel shipped; responses readable only on `/leads`, and **only on Pro+** | [`FIXES/REVIEW_FUNNEL_RESPONSES_ON_QR_DETAILS_FIX.md`](FIXES/REVIEW_FUNNEL_RESPONSES_ON_QR_DETAILS_FIX.md) | none | BE (gate), FE |

---

## What the triage actually found

**Item 1 is two problems, not one.** The theme drift is measurable. Counting raw `blue-*` class
occurrences against `primary`-token occurrences per directory under `components/org/`:
`qrs/` 20 vs 191, `content-type/` 6 vs 105, `analytics/` 0 vs 58, `settings/` 0 vs 32 — and
**`reports/` 30 vs 5**. It is the only dashboard directory where the stock Tailwind blue
outnumbers the design system's indigo `#4648d4`, six to one. That is exactly the "doesn't match"
in the report. The 49 hardcoded `gray-*` classes are the second half: they pin the page to light
mode, so it will not survive the dark theme the tokens already support.

**Item 11 hides a paywall bug.** `review_funnel` is a *type*, ungated since `0027`
(free/starter got all 13 creatable types). Its below-threshold feedback arm writes to
`qr_lead_submissions`. But the only read path — `GET /workspaces/{id}/leads` — gates on the
`lead_forms` boolean, which `0039` sets **true on Pro+ only**. A Free or Starter workspace can
therefore build a review funnel, collect written feedback, and never be allowed to read a word
of it. The fix doc treats un-gating funnel-sourced rows as the load-bearing change and the
detail-page card as the visible half.

**Items 5 and 6 are one feature.** A per-QR cap and "expire after N scans" share the column,
the KV field, the Worker branch position and the system page. Split into two specs they would
contradict each other on the first edit. One spec, two configurable behaviours.

**Item 7 is not the campaign work that already shipped.** `CAMPAIGN_TAGS_ROLLUP` gave QRs
cross-folder tags and rollup analytics. It never touches the destination URL. UTM support is
the other half — stamping `utm_*` onto the outbound redirect so the customer's *own* GA4 can
attribute the traffic.

## Suggested build order

1. **Item 11 gate fix** — a live paywall bug on data customers already have. Hours, not days.
2. **Item 1** — visible, self-contained, frontend-only, no migration.
3. **Item 2 (duplicate)** — highest ratio of user-visible value to effort in the batch.
4. **Item 5+6 (scan limit)** — the parity checkbox; reuses the shipped expiry machinery end to end.
5. **Item 7 (UTM)** — same Worker touch-point as 5+6; batch the Worker deploy.
6. **Items 3, 8, 9, 10** — larger and independent; sequence by appetite.

---

## Detailed pass — 2026-08-28

All 8 new features rewritten from condensed drafts to full PRD + TRD pairs (**5,353 lines**).
Reading the code closely to write them turned up five things that were wrong or unknown in the
first drafts. They are recorded here because each one would have cost real time in implementation.

| # | Finding | Where it landed |
|---|---|---|
| 1 | **`update_qr`'s pre-write read is 9 columns and no relations** (`category, type, status, start_at, end_at, schedule_tz, daily_*`). The first draft said to "reuse that read" for the change-history diff — it cannot produce a destination diff, which is the entry the whole feature exists for. | `QR_CHANGE_HISTORY_TRD` §4.1 now presents two snapshot options with a recommendation. |
| 2 | **An append-only trigger on a table `account_purge` cascades through stalls every account deletion.** Not theoretical: `_NEVER_DELETE` lists `admin_audit_log` with exactly that reasoning — *"a purge attempting to touch it would RAISE and stall the whole run."* `qr_change_events` hangs off `qr_codes`, which the purge deletes in bulk. | `QR_CHANGE_HISTORY_TRD` §2.1 — resolve before applying the migration; prefer `BEFORE UPDATE` only. |
| 3 | **Adding a blocked-scan reason needs three lockstep changes**, and missing one is silent. `outside_hours` was POSTed by the Worker and dropped by the backend's Python allowlist for the whole daily-window feature's lifetime — the endpoint returns `{"status":"error"}` with HTTP 200 and `recordBlockedScan` swallows everything. | `PER_QR_SCAN_LIMIT_TRD` §3.4 + a dedicated test in §8.1. |
| 4 | **A hung GET can occupy the UI for ~6m20s.** Four interceptor attempts × 30s + 7s backoff = 127s, then TanStack retries the query twice more. Each layer is individually well-reasoned; the product was never multiplied out. | `OFFLINE_DETECTION_PRD` §2.2 — it became the feature's main motivation and the basis for the fail-fast goal. |
| 5 | **`@radix-ui/react-tooltip` is not installed.** Every `Tooltip` in the analytics components is Recharts'. The actual tooltip pattern in the app is the native `title=` attribute in 27 files — hover-only and invisible on touch. | `ONBOARDING_TOOLTIPS_PRD` §2.3 / `TRD` §2–3 — the dependency is now an explicit decision, not an assumption. |

**Cross-cutting patterns the TRDs lean on** (worth knowing before implementing any of them):

- **`sync_qr_to_kv`'s `select(...)` is explicit by design.** Omitting a new column does not fail —
  it silently strips the setting from KV on the next unrelated resync. Both the scan-limit and UTM
  TRDs make updating it a same-commit requirement, and both propose a KV-contract assertion that
  every Worker-read key appears in that select.
- **Worker deploys before backend** for anything that adds a KV field. An unknown key is ignored;
  the reverse means the UI promises enforcement that silently does not happen.
- **Cross-repo checks:** prefer a generated artefact committed to both repos (`keys.json`,
  `kv_contract.json`) over reaching across the filesystem. The `maps.js` runtime-import pattern
  works only on a developer's machine, and **skipping is not passing** —
  `./scripts/check-cross-repo-mirrors.sh` exists to fail on a vacuous skip.


---

## Progress

| Item | State | Branches |
|---|---|---|
| 11 — Review-funnel responses + the paywall bug | ✅ merged | `qr_backend#63`, `qr_frontend#86`, Worker `cdc14e9` |
| 1 — `/reports` theme + schedule detail page | ✅ merged | `qr_frontend#86` |
| 2 — Duplicate QR | ✅ pushed, PRs open | `feat/duplicate-qr` in `qr_backend` + `qr_frontend` |

### What building #2 taught us about the specs

Seven of the Duplicate TRD's claims were wrong, and two would have shipped silent data loss.
The full list is `DONE/DUPLICATE_QR_TRD.md` §0, but the **pattern** is worth carrying into the
remaining six items, because every one of them was written the same way:

- **`create_qr` owns more than the specs credit it with.** It already copies a file belonging
  to another QR — object, PDF thumbnails, `page_count`, metadata — keyed off `file_id`. A whole
  hand-rolled storage step with its own compensation logic was written for a problem that did
  not exist. **Before specifying a mechanism, grep for it.**
- **Read paths and write paths disagree about names.** `daily_start_time` (column) vs
  `daily_start` (field); `size` (column) vs `size_bytes` (model). Both type-check either way and
  both lose data silently. The `PER_QR_SCAN_LIMIT` and `UTM_CAMPAIGN_SUPPORT` TRDs specify new
  columns and will hit exactly this.
- **KV is published mid-flow, not at the end.** `create_qr` writes KV inline, so anything
  written to a child table *after* the create — translations, in this case — is absent from the
  edge until something else resyncs. Any spec that adds a child table read by
  `build_kv_content` needs to say when the republish happens.
- **A table named in a spec may not exist.** There is no routing-rules table (it is jsonb on
  `qr_destinations`) and `qr_passwords` is dead (the columns live on `qr_codes`).
- **Some hazards are only reachable through the new feature.** Duplicating a menu QR would have
  hard-failed on the original's primary keys, and shared menu photo paths meant deleting either
  QR destroyed the other's images. Neither is visible from reading the create path alone.
