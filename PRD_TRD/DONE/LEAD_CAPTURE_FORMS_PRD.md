# PRD — Lead Capture Forms

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-14
**Priority:** 3rd (after API Access + White-label) — **consent-gated**: build after the shared consent/cookie gate (eng-review D1). Lead forms collect PII.
**Tiers:** Pro+ (`lead_forms`) — seeded `false` everywhere by migration 0009; this feature's migration flips Pro/Agency on.
**Split from:** `PLAN_LIMITS_ENFORCEMENT_PRD.md`.

---

## 1. Background
Sold at Pro+, not built (flag-only, classified `inert`). A lead-capture QR shows a form on scan, stores submissions, and (optionally) emails the owner — turning a scan into a contact. Fits the existing "dynamic QR type + worker-rendered landing page" architecture cleanly.

## 2. Goals & Non-Goals
**Goals:** a new **`lead_form` dynamic QR type** with a builder (define fields), a worker-rendered form page, a submissions store + dashboard viewer (+ CSV export), optional email notification, gated behind `lead_forms`.
**Non-Goals:** CRM integrations/Zapier (future), multi-step forms, file-upload fields (Phase 2+), payment collection.

## 3. Design (follows CLAUDE.md "Adding a new QR type")
1. **Type + dispatch:** add `case "lead_form"` to `handleQRCode` (`qr_cf_code/src/handlers/qrRouter.js`) → new `src/pages/leadForm/…` template(s) selected by `page_design.templateId`.
2. **KV content:** add a `build_kv_content` branch (`qr_backend/src/utilities/cloudflare_kv.py`) packaging `{ fields:[{name,label,type,required}], success_message, redirect_url }` so the worker renders the form without a backend round-trip.
3. **Submission flow:** worker form `POST`s to a new **`POST /internal/lead-submit`** (x-internal-secret) — mirror the password-gate proxy pattern (`pw-verify`). Backend validates against the QR's field config, inserts a submission, and best-effort emails the owner via Resend (`utilities/email.py`).
4. **Builder UI:** a content-type form in `qr_frontend/src/components/qr-generator/content-types/` to define fields + success behavior; a React preview template mirroring the worker template (keep the two in sync — house rule).
5. **Submissions viewer:** a dashboard page listing submissions per QR with CSV export, gated.

## 4. Data Model (migration)
```sql
CREATE TABLE qr_lead_forms (
  qr_id uuid PRIMARY KEY REFERENCES qr_codes(id) ON DELETE CASCADE,
  fields jsonb NOT NULL DEFAULT '[]',        -- [{name,label,type,required}]
  success_message text,
  redirect_url text,
  notify_email text
);
CREATE TABLE qr_lead_submissions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  qr_id uuid NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
  workspace_id uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
  data jsonb NOT NULL,
  submitted_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_lead_submissions_qr ON qr_lead_submissions(qr_id, submitted_at DESC);
```
Plus add `lead_form` to Pro/Agency `dynamic_qr_types` and flip `lead_forms` true for Pro/Agency.

## 5. Gating
- BE: `check_feature(workspace_id,'lead_forms')` on create/configure of a `lead_form` QR; flip `FEATURE_ENFORCEMENT['lead_forms'] inert→enforced` in the same PR (coverage test enforces this).
- FE: `canAccessFeature(sub,'lead_forms')` gates the type card (`QRTypeSelector`) + the builder + the submissions page.
- The `lead_form` type also rides the existing `dynamic_qr_types` gate (so non-Pro can't even select it).

## 6. Phases
- **Phase 1:** type + worker render + KV branch + submission endpoint + storage + basic builder (text/email/phone fields) + gate + **honeypot field + per-IP/per-QR rate-limit** (a public unauthenticated form floods with spam on day one — eng-review D4). **Acceptance:** Pro creates a lead-capture QR; a scan submits; the row appears + owner email fires; a bot-style flood is rate-limited; non-Pro can't select the type.
- **Phase 2:** submissions viewer + CSV export · more field types (select, textarea, consent checkbox) · success redirect.
- **Phase 3:** captcha/Turnstile (targeted-abuse hardening beyond the Phase-1 honeypot), webhook/CRM out.

## 7. Testing
Field validation (required/missing) → 400; submission persists + scoped to workspace; gate denies non-Pro on create + submit; worker form renders from KV; React/worker templates parity.

## 8. Open Questions
1. **Consent/PII:** lead forms collect PII — add a consent checkbox + a data-retention/erase story? (Ties to the EU/consent decision flagged in the Mixpanel PRD.)
2. Spam protection at launch (honeypot + rate-limit) or Phase 3?
3. New top-level `lead_form` type vs an add-on form section on existing landing types? (Recommend a dedicated type for a clean MVP.)

## 9. Appendix — Key Files
| Concern | File |
|---|---|
| Worker dispatch / pages | `qr_cf_code/src/handlers/qrRouter.js`, `src/pages/` |
| KV content build | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content`) |
| Submission proxy pattern | `qr_cf_code` `pw-verify` flow, `qr_backend/src/api/routes/internal.py` |
| Email | `qr_backend/src/utilities/email.py` |
| Builder + preview | `qr_frontend/src/components/qr-generator/content-types/`, `.../templates/` |
| Gating | `qr_backend/src/api/routes/subscription.py`, `qr_frontend/src/lib/plan-features.ts` |
