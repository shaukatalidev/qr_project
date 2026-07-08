# PRD — Scheduled & PDF Analytics Reports + Anomaly Alerts

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-24
**Priority:** High — closes a live trust bug (dead `Download CSV/PDF` + `Schedule Weekly Report` buttons) AND a retention gap. Lowest-effort, highest-trust fix in the analytics surface.
**Tiers:** Raw export (CSV/PDF, on-demand) gates at **Pro** (`advanced_analytics`, already enforced). Scheduled emailed reports + anomaly alerts gate at **Starter+** (new flag `scheduled_reports`) — seeded `false` everywhere by migration 0018, flipped on for Starter/Pro/Agency.
**Plan flags:** `scheduled_reports` (bool) — new; `advanced_analytics` (bool, existing, already enforced in `scan.py`) reused to gate the raw on-demand export.
**Split from:** strategic gap #7 (lifecycle emails) + the analytics-surface placeholder-button bug.
**Rev (2026-06-24, post eng-review):** anomaly detection uses a **rolling trailing-7d-vs-prior-7d** window (daily-cron WoW-vs-Monday would false-fire mid-week drops); PDF renderer committed to **WeasyPrint**; migration `0018` flag-flip hardened to the `lower(name)`+`is_custom`+coalesce convention; scheduled reports **claim** each row so a duplicate cron can't double-send; external recipients allowed but bounce-monitored, with `_dmarc.qravio.app` a hard GA gate.

---

## 1. TL;DR / Summary

Qravio's analytics page ships two prominent CTAs — **Download CSV/PDF** and **Schedule Weekly Report** — with no `onClick` handler. They do nothing. This PRD wires them to real functionality and adds the missing lifecycle layer:

1. **On-demand export** — CSV (from existing `qr_scan_counters` aggregates) and PDF (rendered with WeasyPrint) of workspace and per-QR analytics.
2. **Scheduled emailed reports** — daily / weekly / monthly summaries delivered by Resend (already wired) with the PDF attached.
3. **Anomaly alerts** — threshold checks (scan spike, scan drop, scan-cap reached, QR auto-disabled) run by the existing Cloudflare `scheduled()` cron + an internal endpoint, deduped to avoid spam.

This is mostly polish on existing primitives — no new scan capture, no Worker template work, no new billing rail. It closes a documented bug and lands the highest-ROAS retention lever the product is missing.

## 2. Problem & Motivation

**The buttons lie.** `/src/app/org/[slug]/(dash)/analytics/page.tsx:148-151` renders "Download CSV/PDF" and "Schedule Weekly Report" buttons with no handlers. Every agency owner who clicks them and gets nothing loses trust in the analytics they're paying Pro for. This is a live credibility bug on the surface customers scrutinize most.

**Reporting is table-stakes Qravio is conspicuously missing.** The strategic audit lists this as a gap: "No 'Download CSV/PDF' analytics export… the CTA is a non-functional UI placeholder" and "No 'Schedule Weekly Report' feature — the button points nowhere; no email-delivery or report-scheduling backend/frontend exists." Bitly, QR Tiger, and Beaconstac all ship scheduled PDF reports. An agency owner cannot present Qravio numbers to a client without a clean PDF or CSV; today they screenshot the dashboard. That is an embarrassing gap for a "real analytics platform" positioning.

**No lifecycle emails despite a disable/re-enable cycle.** Resend is wired only for invitations and login alerts. Free QRs hard-disable at the 2k-scan cap and re-enable monthly via cron — and the owner is **never told**. The strategic audit calls lifecycle emails "the highest-ROAS retention lever for a self-serve SaaS at this price point." An SMB owner whose campaign QR went dark because it hit the cap finds out by accident, churns, and blames the product.

**The primitives already exist.** Counters live in `qr_scan_counters` (JSONB: `scans_by_device`, `scans_by_country`, `scans_by_date`, `scans_by_hour`). **WeasyPrint** renders HTML→PDF (a pinned Python lib in the backend image). Resend is wired in `utilities/email.py`. The Worker `scheduled()` cron + `POST /internal/free-scan-reset` pattern already runs monthly. We are assembling, not inventing.

## 3. Goals & Non-Goals

**Goals**
- Make the two placeholder buttons fully functional (CSV + PDF export, workspace + per-QR).
- Daily/weekly/monthly scheduled report delivery via Resend, with PDF attached.
- Four anomaly alert types: **scan spike**, **scan drop**, **scan-cap reached**, **QR auto-disabled** — emailed, deduped.
- Reuse the existing cron/internal-endpoint pattern; no new scheduler infra.
- Gate cleanly: raw export at Pro (`advanced_analytics`), scheduled/alerts at Starter+ (`scheduled_reports`).

**Non-Goals**
- A full drag-and-drop report builder / custom report layouts (future) — this is the stated scope-creep risk; v1 ships fixed templates.
- White-label/branded report PDFs (future — natural Agency upsell, Phase 3).
- Webhook/Slack outbound alerts (future — covered by the separate webhooks-out gap).
- New scan dimensions (UTM, browser, OS) — out of scope; reports use what the counters already hold.
- Per-recipient cohort segmentation or scheduled CSV-to-Google-Sheets (future).
- SMS/push alert channels (future) — email only in v1.

## 4. Target Users & Personas

- **Asha — Agency owner (Pro/Agency).** Runs 30–80 QRs across client campaigns. Needs a weekly PDF per client to forward, and a CSV to drop into her own deck. Wants to know the moment a client's QR spikes (campaign went viral → upsell) or drops (print run failed → fix before the client notices).
- **Ravi — SMB owner (Starter/Free).** One restaurant-menu QR and a few flyers. Doesn't open the dashboard daily. Wants an email when his menu QR hits the scan cap (it disabled mid-lunch-rush) or when scans crater (someone reprinted the wrong code).
- **Internal/Support.** Fewer "my QR stopped working" tickets because the scan-cap and auto-disable alerts proactively tell the owner why.

## 5. User Stories

- As an **agency owner**, I want to **download a PDF analytics report for a workspace or a single QR**, so that I can **forward a clean, branded-enough summary to my client without screenshotting**.
- As an **agency owner**, I want to **schedule a weekly emailed report**, so that **a fresh PDF lands in my inbox every Monday with zero effort**.
- As an **agency owner**, I want a **CSV of raw scan aggregates**, so that I can **pivot the data in my own spreadsheet/BI tool**.
- As an **SMB owner**, I want an **email when one of my QRs spikes or drops sharply week-over-week**, so that I can **react to a viral moment or a broken print run immediately**.
- As an **SMB owner**, I want an **email the moment a QR hits its scan cap or gets auto-disabled**, so that I **know why it went dark and can upgrade or wait for the monthly reset**.
- As a **workspace owner**, I want to **not be spammed**, so that **I get at most one alert per QR per condition per window**.

## 6. UX / Product Flow

**6.1 On-demand export (closes the dead buttons).**
On `/org/[slug]/(dash)/analytics`, the existing **Download CSV** / **Download PDF** buttons get real handlers. Clicking **Download CSV** calls `GET /workspaces/{id}/analytics/export.csv?range=30d` → streams a CSV (rows = `scans_by_date`, plus device/country/hour sheets concatenated or separate files in a small zip). **Download PDF** calls `GET …/export.pdf?range=30d` → backend renders an HTML report (totals, WoW change, daily series table, top countries, device mix) with WeasyPrint and returns `application/pdf`. A range selector (7/30/90/365, reusing the existing `useAnalyticsDays` selector) drives the export window. The same two buttons appear on the **per-QR analytics card** (`qr-analytics-card.tsx`), scoped to that `qr_id`.

**6.2 Schedule a report.**
The **Schedule Weekly Report** button opens a modal (shadcn `Modal`): frequency (Daily / Weekly / Monthly), recipients (defaults to the owner's email, comma-separated extras), scope (whole workspace or a chosen QR), format (PDF attached + inline summary). Saving `POST /workspaces/{id}/analytics/reports` persists a `scheduled_reports` row. The modal lists existing schedules with edit/delete. Gated by `scheduled_reports` (Starter+); Free users see an inline `UpgradeGate`.

**6.3 Alert configuration.**
A new **Alerts** card in the analytics page (Starter+). Toggles per alert type with thresholds: *Scan spike* (WoW increase ≥ X%, default 200%), *Scan drop* (WoW decrease ≥ X%, default 70%), *Scan-cap reached* (auto-on, Free/over-limit), *QR auto-disabled* (auto-on). Recipients default to owner. Saved via `PUT /workspaces/{id}/analytics/alerts`.

**6.4 Delivery (cron-driven).**
The Worker `scheduled()` handler gains daily/weekly/monthly cron triggers (in addition to the existing monthly free-scan-reset) that POST to **`POST /internal/run-reports`** and **`POST /internal/run-alerts`** with `x-internal-secret`. The backend: (a) for due report schedules, builds the PDF and emails it via Resend background task; (b) for alerts, reads `qr_scan_counters`, computes WoW deltas, and for any breach not already sent in the current window, inserts a dedupe row and emails the owner. Scan-cap/auto-disable alerts piggyback on the existing `_enforce_scan_limit()` path (fire an alert when a QR flips to `disabled`), still deduped through the same `alert_events` table.

## 7. Scope — In / Out

**In scope (v1)**
- CSV + PDF export endpoints (workspace + per-QR), real button handlers.
- Fixed PDF/CSV report template (totals, WoW, daily series, top countries, device mix).
- Report schedules table + CRUD + modal UI; Daily/Weekly/Monthly via cron.
- Four alert types with dedupe; Alerts card UI.
- Resend delivery (PDF attachment + inline HTML summary).
- New `scheduled_reports` flag (Starter+); reuse `advanced_analytics` for raw export.
- Worker cron triggers (daily/weekly/monthly) + two internal endpoints.

**Out of scope / Future**
- Custom report builder / layout designer (the scope-creep guardrail).
- White-label / branded report PDFs (Phase 3 Agency upsell).
- Slack/webhook/SMS alert channels.
- Scheduled CSV-to-Sheets / API-pull report data.
- New analytics dimensions (UTM, browser, OS, city) — reports surface only existing counters.
- Per-QR scheduled reports beyond a single chosen QR (multi-QR digest is Phase 2).

## 8. Pricing & Packaging

| Capability | Gate | Flag |
|---|---|---|
| On-demand CSV/PDF export | **Pro+** | `advanced_analytics` (existing, the analytics page is already Pro-gated) |
| Scheduled emailed reports | **Starter+** | `scheduled_reports` (new) |
| Anomaly alerts | **Starter+** | `scheduled_reports` (new) |
| Scan-cap / auto-disabled alert | **all tiers (incl. Free)** | always on — it's a lifecycle notification, not a premium feature |

**Rationale.** Raw data export is a "power" capability and naturally sits with the Pro analytics surface that already gates behind `advanced_analytics` — no new flag needed there. Scheduled delivery + proactive alerts are a clear retention/upsell lever worth pulling Free→Starter for, so they ride a new `scheduled_reports` flag flipped on at Starter/Pro/Agency. The **scan-cap / auto-disabled alert is deliberately ungated for everyone** — telling a Free user *why their QR went dark* is the conversion moment (the email CTA is "Upgrade to Starter for unlimited scans"). **Upsell angle:** Free user hits cap → alert email → upgrade; SMB wants the weekly PDF → Free→Starter; Agency wants branded client PDFs → Pro→Agency (Phase 3).

## 9. Success Metrics & KPIs

- **Bug closure / trust:** 0 dead-button clicks (instrument with the existing Mixpanel `ELEMENT_CLICKED` on both export buttons); export-button → successful-download rate ≥ 95%.
- **Activation:** ≥ 25% of Pro+ workspaces download at least one CSV/PDF within 30 days of GA.
- **Adoption:** ≥ 15% of Starter+ workspaces create at least one scheduled report within 60 days; ≥ 40% of created schedules still active after 90 days (not churned/deleted).
- **Alert engagement:** scheduled-report email open rate ≥ 35%; alert email click-through (to dashboard) ≥ 20%.
- **Revenue/retention:** scan-cap alert → upgrade conversion ≥ 8% of Free workspaces that receive it (this is the headline number); measurable lift in Starter+ logo retention among workspaces with ≥ 1 active schedule vs. those without.
- **Support:** ≥ 20% reduction in "my QR stopped working / why did it disable" tickets post-GA.

## 10. Rollout Plan

- **Phase 1 (MVP, behind a build flag):** export endpoints + real button handlers (CSV + PDF, workspace + per-QR) · `scheduled_reports` table + flag flip + `FEATURE_ENFORCEMENT` `inert→enforced` · schedule CRUD + modal · cron triggers + `/internal/run-reports` + `/internal/run-alerts` · the four alert types with dedupe · Resend delivery. **Acceptance criteria:** (a) a Pro workspace clicks Download PDF and receives a valid `application/pdf` with correct totals; (b) clicking Download CSV returns parseable CSV matching `scans_by_date`; (c) a Starter workspace schedules a weekly report and receives an emailed PDF on the next cron tick; (d) forcing a WoW spike fires exactly one spike alert (a second cron run within the window sends nothing — dedupe verified); (e) a QR hitting the scan cap fires one scan-cap alert to the owner including a Free→Starter CTA; (f) a Free workspace cannot create a schedule or configure spike/drop alerts (gate denies) but *does* receive scan-cap alerts.
- **Phase 2:** multi-QR digest reports · per-QR schedules · alert threshold tuning UI · CSV split into per-dimension sheets / zip.
- **Phase 3:** white-label/branded report PDFs (Agency) · Slack/webhook alert channels.
- **Beta → GA:** ship to internal + 5 design-partner agencies behind the build flag; watch Resend bounce/spam rates and cron timing; GA after one clean weekly cycle with no duplicate-alert reports.

## 11. Risks, Edge Cases & Open Questions

**Risks**
- **Scope creep into a report builder** (named risk). Mitigation: v1 is a *fixed* template; "custom layout" is explicitly Non-Goal/Phase-3.
- **Alert spam** (named risk). Mitigation: every alert writes an `alert_events` dedupe row keyed by `(workspace_id, qr_id, alert_type, window_anchor)`; the sender checks-then-inserts so a re-run in the same window is a no-op. **Detection uses a rolling trailing-7d vs prior-7d window** (eng-review — avoids partial-week false drops on a mid-week daily run); **dedupe `window_anchor` = the ISO-week Monday** so an ongoing spike alerts at most once per week.
- **PDF generation cost/latency.** On-demand PDF is synchronous; cap the range and counter rows rendered, and run scheduled PDFs in a background task so cron returns fast.
- **Resend deliverability** — reports are bulkier than transactional mail. Reuse the verified `send.qravio.app` MAIL FROM; monitor DMARC alignment (memory notes `_dmarc.qravio.app` not yet published — reports may hit the same Gmail "dangerous" banner until it is).

**Edge cases**
- Workspace with zero scans in the window → report still sends ("0 scans this week") rather than silently skipping; spike/drop alerts suppressed when prior-window base is below a floor (e.g. < 20 scans) to avoid noise on tiny numbers.
- Counter is a Python read-modify-write (`internal.py`) — reports read counters, not raw events, so they're eventually consistent; acceptable for daily/weekly cadence.
- Deleted QR / removed recipient → schedule references must null-guard and skip.
- `analytics_retention_days` clamp must apply to export windows too (a Starter 30-day plan can't export 365 days).

**Open Questions**
1. **Alert thresholds:** ship fixed defaults (spike ≥200%, drop ≥70%) or expose sliders in v1? (Recommend fixed defaults + a single "sensitivity" toggle; full sliders Phase 2.)
2. **PDF branding in v1:** plain Qravio-footer PDF for all, or hold white-label for Agency Phase 3? (Recommend plain for v1.)
3. **DMARC dependency:** do we block GA on publishing `_dmarc.qravio.app`, or ship with the known Gmail-banner caveat? (Recommend publish first.)
4. **Cron cadence anchor:** weekly = Monday 00:00 UTC for everyone, or per-workspace timezone? (Recommend fixed UTC for v1; the counters already bucket hours by CF timezone for the *content*.)

## 12. Dependencies

- **Resend** (`utilities/email.py`) — already wired; needs attachment support confirmed and the verified `send.qravio.app` sender.
- **WeasyPrint** (HTML/CSS→PDF, pinned in `requirements.txt`) — renders the report body; needs `libpango`/`libcairo` system libs in the Render image (eng-review — replaces the abstract "make-pdf path").
- **`qr_scan_counters`** — the data source; no schema change to counters.
- **Worker `scheduled()` cron** (`qr_cf_code/src/index.js` + `wrangler.toml` triggers, dev + prod) — add daily/weekly/monthly cron expressions alongside the existing `0 0 1 * *`; **the prod worker must be deployed** for new crons to register.
- **`_enforce_scan_limit()`** (`internal.py`) — hook the scan-cap/auto-disabled alert into the existing disable path.
- **Subscription engine** — `check_feature` + `FEATURE_ENFORCEMENT` flip (migration 0018); `get_limit('analytics_retention_days')` clamp on export windows.
- **Frontend** — `useAnalytics` hooks + `analyticsKeys` factory; new mutation hooks for schedules/alerts; shadcn `Modal`; `canAccessFeature(sub,'scheduled_reports')`.

## 13. Data Model (migration 0018)

```sql
BEGIN;

CREATE TABLE IF NOT EXISTS scheduled_reports (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  qr_id uuid REFERENCES qr_codes(id) ON DELETE CASCADE,  -- null = whole workspace
  frequency text NOT NULL,            -- 'daily' | 'weekly' | 'monthly'
  recipients text[] NOT NULL DEFAULT '{}',
  format text NOT NULL DEFAULT 'pdf', -- 'pdf' | 'csv'
  is_active boolean NOT NULL DEFAULT true,
  last_sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_sched_reports_ws ON scheduled_reports(workspace_id) WHERE is_active;

CREATE TABLE IF NOT EXISTS analytics_alert_configs (
  workspace_id uuid PRIMARY KEY REFERENCES workspaces(id) ON DELETE CASCADE,
  spike_enabled boolean NOT NULL DEFAULT false,
  spike_pct int NOT NULL DEFAULT 200,
  drop_enabled boolean NOT NULL DEFAULT false,
  drop_pct int NOT NULL DEFAULT 70,
  recipients text[] NOT NULL DEFAULT '{}',
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- dedupe ledger: one row per fired alert per window
CREATE TABLE IF NOT EXISTS alert_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  qr_id uuid REFERENCES qr_codes(id) ON DELETE CASCADE,
  alert_type text NOT NULL,           -- 'spike'|'drop'|'scan_cap'|'auto_disabled'
  window_anchor date NOT NULL,
  sent_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (workspace_id, qr_id, alert_type, window_anchor)
);

-- flag flip: seed scheduled_reports=false everywhere, on for Starter/Pro/Agency.
-- House convention: coalesce NULL features, idiomatic key-absence check, lower(name) + is_custom guard.
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{scheduled_reports}', 'false'::jsonb, true)
  WHERE NOT (coalesce(features,'{}'::jsonb) ? 'scheduled_reports')
    AND coalesce(is_custom, false) = false;
UPDATE plans SET features = jsonb_set(coalesce(features,'{}'::jsonb), '{scheduled_reports}', 'true'::jsonb, true)
  WHERE lower(name) IN ('starter','pro','agency') AND coalesce(is_custom, false) = false;

COMMIT;
```

The `UNIQUE (workspace_id, qr_id, alert_type, window_anchor)` constraint is the dedupe guarantee — an `ON CONFLICT DO NOTHING` insert before send makes re-runs idempotent.

## 14. Appendix — Key Files

| Concern | File |
|---|---|
| Analytics page (dead buttons → real handlers) | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx:148-151` |
| Per-QR export buttons | `qr_frontend/src/components/org/qrs/details/qr-analytics-card.tsx` |
| Analytics hooks + key factory | `qr_frontend/src/hooks/useAnalytics.ts` |
| Plan gating (FE) | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`) |
| Export + schedule routes (BE) | `qr_backend/src/api/routes/scan.py` (new export endpoints), new report router → `endpoints.py` |
| Cron internal endpoints | `qr_backend/src/api/routes/internal.py` (`/run-reports`, `/run-alerts`; reuse `/free-scan-reset` pattern) |
| Scan-cap alert hook | `qr_backend/src/api/routes/internal.py` (`_enforce_scan_limit`) |
| Email + PDF | `qr_backend/src/utilities/email.py` (Resend), `qr_backend/src/utilities/report_pdf.py` (WeasyPrint) |
| Gating registry | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT['scheduled_reports'] inert→enforced`) |
| Cron triggers | `qr_cf_code/src/index.js` (`scheduled()`), `qr_cf_code/wrangler.toml` (dev + prod triggers) |
| Migration | `qr_backend/migrations/0018_scheduled_reports.sql` |
