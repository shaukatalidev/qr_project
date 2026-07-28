# PRD — Org-Enforced MFA + Admin Audit Log

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** **Deal-gated enabler, not a growth bet.** Fit 2 / Impact 2 in the competitive analysis (item #11). Nobody upgrades *to* Qravio for an audit log — but a mid-market or white-label buyer's security questionnaire will ask for both, and today we answer "no" to one of them. Build it when a **named deal** needs it; do not sequence it ahead of #1/#2/#5–#9.
**Tiers:** **Agency + custom (enterprise/white-label) plans.** Two new bool flags gate the *read* surfaces only — the audit write path is **ungated and always on** so a workspace that upgrades doesn't inherit an empty, useless trail.
**Plan flags:** `mfa_enforcement` (bool, NEW) · `audit_log` (bool, NEW) · `audit_log_retention_days` (int, NEW — a **read-window clamp**, mirroring `analytics_retention_days`, *not* a delete job). All three registered `inert` in `FEATURE_ENFORCEMENT` and flipped `enforced` in the **same PR** (house convention; `test_feature_gate_coverage` stays green).
**Split from:** the three sub-features the market bundles as "enterprise security". **User-level MFA is already built** (Supabase TOTP — `useSecurity.ts` `useEnrollTOTP`/`useVerifyTOTP`/`useUnenrollTOTP`, `TwoFactorPanel.tsx`, `TwoFactorModal.tsx`) and is **not** rebuilt here. **SCIM is explicitly out** (§3 Non-Goals) — it is gated on SSO/SAML, on which the team already recorded a deliberate "not now" (`PRD_TRD/NOT_DONE/SSO_SAML_PRD.md`, `FEATURE_ENFORCEMENT['sso'] = 'inert'`). What's left is exactly two things: **org-enforced MFA** (a policy + an AAL2 check on the workspace-auth seam) and an **admin audit log** (a new append-only table + write-path instrumentation + a gated read/export surface).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships **as-drafted**, with one sequencing decision that **overrides** the PRD's own "build only when a named deal needs it" framing: **build the full feature now** — Phase 0 (re-expose TOTP) **plus** org-enforced MFA **plus** the audit log — rather than shipping Phase 0 alone and parking the rest. Rationale accepted: being ready *before* a procurement review beats scrambling during one. Trade-off recorded honestly: this front-loads a **Fit 2 / Impact 2** enabler ahead of the growth items (#1 WhatsApp reminders, #2 QR expiry) with **no organic demand signal** from the ₹399–₹2,499 India-SMB ICP — revisit the ordering if a growth item becomes time-critical. **The §9 blocker is a hard, non-negotiable gate regardless:** `TwoFactorPanel` is commented out (`SecuritySection.tsx:18`) and the security route calls `notFound()`, so **no user can enroll a factor today** — enabling org-enforcement against that state locks out 100% of members with no self-serve recovery. Ship and **verify the enroll→verify→status→unenroll loop end-to-end** before the policy switch exists in any environment. Other calls confirmed: SCIM stays out (correctly gated on the recorded SSO "not now"); **write ungated / read gated** so an upgrade reveals real history instead of an empty table; `audit_log_retention_days` is a **read-window clamp** (the `analytics_retention_days` pattern), never a delete job; the `403 mfa_required` must **not** be a `401` (a 401 trips the client's refresh/sign-out path into a redirect loop); the policy governs **JWT/dashboard sessions only** — `/api/public/v1` API-key traffic carries no assurance level, which must be stated plainly in-product and in the security write-up; enabling requires the enabling owner's **own** session to be AAL2, enforced server-side (409) with the UI hint as convenience only; and immutability must be **DB-enforced** (UPDATE/DELETE revoked *and* trigger-blocked) or the trail isn't worth reading. All three flags seed as a full-object `'{...}'::jsonb` blob and flip `inert`→`enforced` in the same PR.

**Blocker found during exploration (read this before scoping):** the user-level 2FA UI that this feature depends on is **built but currently unreachable in production**. `qr_frontend/src/components/org/settings/SecuritySection.tsx:18` has `{/* <TwoFactorPanel onEnroll2FA={onEnroll2FA} /> */}` commented out, and the standalone `qr_frontend/src/app/[slug]/(dash)/security/page.tsx` calls `notFound()` (the route is deliberately 404'd, sidebar entry commented out too). The hooks, the modal, and the Supabase wiring all exist and work — nothing renders them. **No user can enroll a TOTP factor today.** Turning on org-enforced MFA against that state would lock out **100% of members with no self-serve way back in**. Re-exposing `TwoFactorPanel` is therefore **Phase 0, step 1** of this PRD and a hard gate on everything downstream (§10).

---

## 1. TL;DR / Summary

Two independent capabilities, shipped together because they answer the same security questionnaire and share one migration:

**(a) Org-enforced MFA.** A workspace **owner** flips one switch — *"Require two-factor authentication for everyone in this workspace."* From then on, any member whose current session has **not** cleared a second factor is refused on every workspace-scoped API call with a `403 mfa_required`, and the app routes them into enrollment (no factor yet) or a one-tap step-up challenge (factor exists, session is stale). Nothing about the *user-level* TOTP feature changes — we are adding a **policy** on top of the enrollment that already exists.

**(b) Admin audit log.** Every consequential admin action in a workspace — member invited/joined/removed, role changed, workspace renamed, MFA policy toggled, API token minted/revoked, custom domain added/removed, QR created/updated/deleted — writes one row to a new **append-only** `audit_log` table capturing *who, what, to what, from→to, when, from where*. Owners on an entitled plan read it in a filterable page and **export it as CSV**.

Deliberately small: **one migration** (three columns on `workspaces`, one new table, three plan-flag keys), **one new dependency helper** on the existing `get_workspace_role` seam, **one small `record_audit()` utility** called from a curated list of mutation sites, **two new read endpoints**, and a handful of frontend surfaces. **No Cloudflare Worker change. No KV change. No cron. No email. No new external service.** The scan hot path is untouched.

## 2. Problem & Motivation

**We fail one line of the security questionnaire, and we don't know it until a deal is in flight.** Mid-market and white-label buyers run a standard checklist: *SSO? MFA? enforced MFA? audit trail? export?* Today Qravio answers: SSO — contact sales (a recorded, defensible decision); MFA — yes (user-level TOTP, though see the blocker above); **enforced MFA — no**; **audit trail — no**. The last two are the ones that stall a procurement review, and neither is expensive.

**"MFA exists" and "MFA is enforceable" are different products.** Individual TOTP protects the individual. What a buyer's security team is actually asking is: *can you guarantee that nobody on our account is a password away from your dashboard?* Today the answer is no — enrollment is per-user and voluntary, and an owner has no visibility into who has enrolled, let alone a way to require it. One member with a reused password is the whole workspace's blast radius: every QR destination is a live redirect that can be silently repointed.

**The audit log is a real, checkable gap.** We have `login_events` (`security.py:87` `/security/login-history`) — but it is **per-user, self-service, and login-only**. It answers "where did *I* sign in from," never "**who** changed **that QR's destination** on Tuesday," "**who** promoted a viewer to owner," or "**who** minted the API token that's been hammering the public API." There is no workspace-scoped, immutable, exportable trail of *administrative* actions anywhere in the product. For a white-label reseller managing client campaigns, or an agency answering to a client, that absence is disqualifying.

**It's cheap, and it's mostly leverage we already own.** The enforcement seam already exists: **every** workspace-scoped route funnels through `get_workspace_role()` (`src/api/dependencies/deps.py:33`), which already does the per-workspace membership lookup — the policy check rides that same query as an embedded column, costing **zero extra round-trips**. The AAL signal already exists: the middleware already decodes the Supabase JWT locally (`auth_bearer.py:99` `_local_claims`), and Supabase puts the assurance level in the `aal` claim — we just aren't reading it. The audit table is ~300 bytes a row on an event class that is orders of magnitude rarer than scans.

**But it earns its place only when a deal asks for it.** There is no organic demand signal from the India-SMB ICP paying ₹399–₹2,499. This is an **enabler** — it unblocks revenue that already exists in the pipeline, it does not create revenue. Sequence it behind the growth work (#1 WhatsApp reminders, #2 QR expiry) and pull it forward the moment a named white-label or mid-market deal makes it a condition of close.

## 3. Goals & Non-Goals

**Goals**
- **Re-expose user-level TOTP enrollment** (uncomment `TwoFactorPanel`; verify the enroll→verify→status→unenroll loop end-to-end). Prerequisite, not a feature.
- **Org MFA policy:** an owner-only, per-workspace `require_mfa` switch. When on, every workspace-scoped API call from a session that has not cleared a second factor is refused with a structured `403 mfa_required`.
- **Never lock the owner out:** enabling the policy requires the enabling owner's *own* session to already be at AAL2. Disabling it is always reachable.
- **A first-class enrollment/step-up path:** a blocked member is routed to enroll (no factor) or to a one-tap challenge (has a factor, stale session) — never to a dead 403 or a logout loop.
- **Member 2FA visibility:** an owner can see, per member, whether a factor is enrolled — before flipping the switch.
- **Append-only `audit_log`:** who / what / target / before→after / when / IP+UA, written at a curated set of admin mutation sites, **immutable at the database level** (UPDATE/DELETE revoked *and* trigger-blocked).
- **Gated read + CSV export:** an owner on an entitled plan filters by actor/action/date and downloads a CSV.
- **Write ungated, read gated** — so upgrading reveals real history rather than an empty table.
- Ship all three flags `inert`→`enforced` in one PR with a full-object `'{...}'::jsonb` seed; `test_feature_gate_coverage` stays green.

**Non-Goals**
- **SCIM — explicitly out, and not a "later maybe" in this PRD.** SCIM directory-sync only makes sense on top of SSO/SAML, and SSO/SAML is a **recorded decision to not build** (`SSO_SAML_PRD.md`: *"Do NOT build self-serve SSO… handle as enterprise / contact-sales"*; `sso` stays `inert`). Shipping SCIM without SSO would mean hand-rolling a provisioning protocol for an IdP we don't integrate with. The gap analysis reaches the same conclusion (*"SCIM: skip"*). If SSO is ever revisited, SCIM gets re-scoped **there**, not here.
- **No SSO / SAML / OIDC.** Unchanged decision; unchanged `inert` flag.
- **No new authentication factors.** TOTP only — exactly what Supabase Auth gives us. No WebAuthn/passkeys, no SMS/voice OTP, no backup-code system beyond Supabase's own.
- **No per-role or per-user MFA exemptions.** The policy is workspace-wide and all-or-nothing in v1. ("Require MFA for owners/editors only" is a plausible v2; it doubles the test matrix for a buyer who asked for "everyone".)
- **No MFA coverage of API-key traffic.** `/api/public/v1` authenticates with an API key, carries no JWT, and therefore has no assurance level. The policy governs **dashboard/JWT sessions only** — stated plainly in-product and in the security write-up (§11 R4). *Minting* a key is itself behind the policy.
- **No IP allowlisting, session-duration policy, or forced-reauth interval.** Adjacent questionnaire lines; separate features.
- **No tamper-evident hash chaining, WORM archival, or notarization.** "Append-only, DB-enforced" is the v1 bar. Cryptographic chaining is a genuinely different (and rarely-asked-for) product.
- **No SIEM streaming** (Splunk/Datadog/S3 drop). CSV export is v1; a webhook/stream is future and would ride the existing `outbound_webhooks` machinery.
- **No scan-event auditing.** Scans are analytics (`qr_scan_events`), not admin actions. The audit log records *who changed the QR*, never *who scanned it*.
- **No retention purge job.** `audit_log_retention_days` clamps the **visible/exportable window** (exactly how `analytics_retention_days` clamps analytics reads) — rows are never deleted by the product. Purge is future ops work.
- **No email notifications** ("MFA policy enabled", "your role changed"). Keeps the unpublished `_dmarc.qravio.app` record off the critical path (§10).

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **White-label Reseller ("Kabir")** | Resells Qravio under his own brand to 30 client SMBs | Pass his clients' security review; prove *his* staff can't quietly repoint a client's QR | Nothing to show. No enforced MFA, no admin trail — the review stalls |
| **Mid-market IT Admin ("Priya")** | Runs IT for a 120-person firm evaluating Qravio | Tick "enforced MFA" + "audit trail with export" on the vendor checklist | Both are hard "no"s; the evaluation dies before pricing |
| **Agency Ops Lead ("Farhan")** | Manages 8 staff across many client workspaces | Answer "who changed this client's destination?" without guessing | `login_events` shows logins only; QR history is unattributed |
| **Workspace Owner ("Meera")** | SMB owner with 4 editors | Know her team actually enabled 2FA, and force it if not | No visibility into member 2FA state; no way to require it |
| **Blocked Member ("Arjun")** | Editor on a workspace that just turned the policy on | Get back to work in under a minute | Would face an opaque 403 — *unless* we ship the enrollment/step-up path (we do) |

Primary buyer is **Agency-tier and custom/white-label**. This is a **retention and deal-unblocking** feature, not an acquisition one.

## 5. User Stories

- As a **white-label reseller**, I want to require 2FA for every member of my workspace, so that my client's security review has a real answer instead of a promise.
- As a **workspace owner**, I want to see which members have 2FA enrolled **before** I flip the switch, so that I don't surprise-lock my own team out mid-campaign.
- As a **workspace owner**, I want the system to refuse to let me enable the policy unless *I* am already on 2FA, so that I can't lock myself out of my own workspace.
- As a **blocked member**, I want a clear "this workspace requires 2FA — set it up now" screen with the enrollment flow one click away, so that I'm unblocked in a minute, not in a support ticket.
- As a **member who already has 2FA but an older session**, I want a single step-up prompt (enter my 6-digit code) rather than a full logout, so that the policy doesn't feel like a punishment.
- As an **agency ops lead**, I want to see exactly who changed a QR's destination and what it was before, so that I can answer a client's question with a record instead of a recollection.
- As an **IT admin**, I want to filter the audit log by person, action, and date range and **download it as CSV**, so that I can hand it to an auditor or drop it into our own systems.
- As a **compliance reviewer**, I want assurance that the trail cannot be edited or deleted through the product, so that it's worth reading at all.
- As a **Free/Starter user**, I want none of this in my way — the switch and the log simply aren't part of my plan.

## 6. UX / Product Flow

**6.1 Prerequisite — user 2FA becomes reachable again**
`TwoFactorPanel` is un-commented in `SecuritySection.tsx` so **Settings → Security** shows the "Authenticator App (TOTP)" row with its real state ("Active" badge + Disable, or "Enable 2FA"). `TwoFactorModal` already handles enroll → QR/secret → verify. **This ships first and independently** — it is worth shipping on its own merits even if the rest of this PRD is deferred (see §10 Phase 0).

**6.2 Owner turns on the org policy — Settings → Organization (new section)**
1. A new **Organization** item in the settings nav (alongside Profile / Security / Account) renders an **Organization Security** panel, visible to **owners only** and gated on `mfa_enforcement`.
2. The panel shows a **member 2FA roster** — each member with an Enrolled / Not enrolled chip — above the switch, so the owner sees the blast radius first. A plain-language warning states: *"N of M members have not set up 2FA. They'll be asked to set it up the next time they use this workspace."*
3. **Guard rail:** if the owner's own session isn't at AAL2, the switch is disabled with *"Set up 2FA on your own account first"* linking to Settings → Security. The backend independently refuses (`409`) — the UI hint is convenience, not the control.
4. Flipping it on shows a confirm dialog naming the not-yet-enrolled members. Flipping it **off** is always available to an owner and needs no confirmation.
5. Non-entitled plans see the panel as a compact **upgrade card** ("Require 2FA for your team — Agency"), mirroring how other gated surfaces tease.

**6.3 A member hits the policy**
- **No factor enrolled:** a full-page interstitial — *"This workspace requires two-factor authentication."* — with the enrollment flow (the existing `TwoFactorModal`) inline. On successful verify, Supabase upgrades the session to AAL2 and the app retries the failed request automatically.
- **Factor enrolled, stale session:** a **step-up dialog** asking only for the 6-digit code (`supabase.auth.mfa.challengeAndVerify`). One field, one tap, session upgraded in place — **no logout, no re-password**.
- **Never a dead end:** the block is a `403` with a structured `mfa_required` code, deliberately **not** a `401` (a `401` would trip the client's token-refresh/sign-out path and produce a redirect loop — see §11 R2). Signing out, switching to another workspace that doesn't require MFA, and Settings → Security all remain reachable.

**6.4 Reading the audit log — new page**
- A new **Audit Log** entry in the workspace sidebar (owner-only, gated on `audit_log`) opens a dense, filterable table: **When · Who · Action · Target · Details**, newest first, cursor-paginated.
- Filters: actor, action type, date range. A row expands to show the before→after diff (e.g. `role: viewer → owner`, `destination: https://a.com → https://b.com`) plus IP and user agent.
- **Export CSV** downloads the current filter selection.
- The visible window is clamped to `audit_log_retention_days`; older rows exist but aren't served, with an honest inline note *("Showing the last 365 days on your plan")* rather than a silent truncation.
- Non-entitled plans: the sidebar entry is hidden; a direct visit shows the upgrade state.

**6.5 What gets recorded (v1 curated list)**
Member invited · member joined · member removed · **role changed (before→after)** · invitation revoked · workspace renamed · **MFA policy enabled/disabled** · API token created · API token revoked · custom domain added · custom domain removed · **QR created / updated / deleted** (destination changes carry before→after) · **bulk QR create → one summary row**, not N rows.
Deliberately **not** recorded in v1: scans, analytics reads, billing webhooks, per-field design tweaks. (§7 Out of scope.)

## 7. Scope

**In scope (v1)**
- Re-enable `TwoFactorPanel` in Settings → Security (prerequisite).
- `workspaces.require_mfa` + `require_mfa_enabled_at` + `require_mfa_enabled_by`; owner-only `GET`/`PATCH /workspaces/{id}/security-policy` with the AAL2-to-enable guard.
- AAL propagation in `BearerTokenAuthMiddleware` (both the local-decode fast path **and** the `get_user()` fallback path) → enforcement helper invoked from `get_workspace_role`, plus explicit coverage of the ~15 call sites that do their own inline `workspace_members` lookup instead of using the shared dependency (§11 R1).
- Member 2FA roster on the member list (enrolled / not enrolled).
- `audit_log` table (append-only, DB-enforced), `record_audit()` utility, instrumentation at the §6.5 sites.
- `GET /workspaces/{id}/audit-log` (filter + cursor paginate) and `GET /workspaces/{id}/audit-log/export.csv`, both owner-only and gated on `audit_log`, clamped by `audit_log_retention_days`.
- Frontend: Organization Security panel, MFA interstitial + step-up dialog + auto-retry, Audit Log page + hook, plan-flag plumbing.
- Three plan flags seeded as one full-object `'{...}'::jsonb` blob and flipped `inert`→`enforced` in the same PR.

**Out of scope / Future**
- **SCIM** *(see §3 — blocked on SSO/SAML, which is a decided no)*.
- SSO / SAML / OIDC *(unchanged decision)*.
- WebAuthn/passkeys, SMS OTP, backup-code management *(TOTP only)*.
- Per-role / per-user MFA exemptions; grace periods with deadlines *(v2)*.
- MFA over API-key traffic *(architecturally out — no JWT, no AAL)*.
- Audit rows for billing events, scheduled-report runs, and per-field design edits *(v1.1 — the write helper takes them without schema change)*.
- SIEM streaming / audit webhooks / S3 drop *(future; would ride `outbound_webhooks`)*.
- Hash-chaining, WORM, signed exports *(future)*.
- Retention **purge** job *(v1 clamps reads only)*.
- Email/in-app notification on policy change or role change *(future; would make DMARC a gate)*.
- Any Cloudflare Worker or KV change *(none needed, ever, for this feature)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| User-level TOTP 2FA (re-exposed) | **All plans, ungated** | none — it's account security, never sold |
| Require 2FA for all members | **Agency + custom/white-label** | `mfa_enforcement` (NEW bool) |
| Admin audit log — read + CSV export | **Agency + custom/white-label** | `audit_log` (NEW bool) |
| Audit visible window | per tier | `audit_log_retention_days` (NEW int; `-1` = unlimited, custom plans only) |
| Audit **write** path | **all plans, always on** | *(intentionally ungated — see below)* |

**Suggested seed values** (tunable in `plans.features` without a deploy): Free / Starter / Pro → `mfa_enforcement:false`, `audit_log:false`, `audit_log_retention_days:0`. Agency → `true / true / 365`. Custom (enterprise/white-label, `is_custom=true`) → granted per deal, `-1` retention where negotiated.

**Why user-level 2FA stays free forever.** Charging for the ability to secure your own account is a bad look and a support liability. What we sell is **the org-level guarantee** — the policy, the roster, the enforcement — not the factor.

**Why Agency-only, and not Pro.** This is a **deal-gated enabler**, not a conversion lever. Nobody on Pro upgrades because they wanted an audit log; a white-label reseller *cannot close* without one. Putting it at Agency keeps the sales story clean ("enterprise security is Agency and up") and keeps the seed to a single tier. *(A Pro rung — `audit_log:true` with a 30-day window as a second upsell step — is Open Q1: it's one extra `UPDATE` and costs nothing, since rows are written for every workspace anyway. **Recommendation: hold it back for v1** so the Agency story stays unambiguous, and add it later if Pro users ask.)*

**Why the write path is ungated.** If we only wrote rows for entitled workspaces, upgrading would reveal an **empty log** — the exact moment the buyer wants history is the moment they'd have none. It also would mean a `resolve_plan()` call on the hot path of every admin mutation. So: **write always, read by plan.** The cost is bounded — admin mutations are orders of magnitude rarer than scans, and a row is ~300 bytes.

**Migration flag-flip (house convention):** seed all three keys as a **full-object `'{...}'::jsonb` blob** where absent (`features || blob`, guarded by `NOT (features ? 'audit_log')` and `coalesce(is_custom,false)=false`), then enable per tier with `jsonb_set` on `lower(name)`. The blob form is mandatory: `test_feature_gate_coverage._seed_feature_keys()` discovers feature keys **only** by regex-scanning `'{...}'::jsonb` blobs, so a path-only seed leaves all three keys undiscovered and the coverage test fails them as "stale" (the same trap `0026`/`card_ocr` documented).

## 9. Success Metrics & KPIs

**Deal outcome (the only metric that actually matters)**
- **≥ 1 named white-label / mid-market deal unblocked** where "enforced MFA" and/or "audit trail with export" was a stated condition. If this feature ships and no deal cites it, we built it too early — that's the honest bar.
- Security-questionnaire coverage: "Enforced MFA" and "Admin audit log (exportable)" flip from ✗ to ✓ in the sales collateral.

**Correctness / trust (the bar that gates GA)**
- **Zero wrongful lockouts.** No member is refused while holding a genuine AAL2 session, and no owner is ever locked out of their own workspace. Measured by a per-environment canary workspace + a `mfa_required`-403 rate that drops to ~0 within 72h of a policy flip.
- **Zero silent audit gaps.** Every instrumented mutation writes exactly one row (no dupes, no misses) — asserted per site in tests, and a nightly count-parity spot check between `workspace_members` role changes and `member.role_changed` rows.
- **Immutability holds:** an `UPDATE` or `DELETE` against `audit_log` from the service-role client **fails** (verified in CI, not by inspection).
- **Audit-write failures never break a mutation** — and are never silent: an audit write failure logs at ERROR with the action name.

**Adoption / usage (secondary — expect small numbers, that's fine)**
- Among Agency+custom workspaces, ≥ 40% enable `require_mfa` within 60 days of GA.
- ≥ 1 CSV export per entitled workspace per quarter (proof the log is actually consulted, not decorative).
- Member 2FA enrollment on enforced workspaces reaches ~100% within 7 days of the flip (the enrollment path works).

**Performance (must be a non-event)**
- **Zero added DB round-trips** on the authenticated hot path — the policy rides the existing `get_workspace_role` membership query as an embedded column (§11 R3). p95 API latency unchanged within noise.

## 10. Rollout Plan

**Phase 0a — Re-expose user 2FA (ships alone, immediately).**
Uncomment `TwoFactorPanel` in `SecuritySection.tsx:18`. Verify the full loop against a real authenticator: `listFactors` → `enroll` → `challenge` + `verify` → status shows Active → `unenroll`. Confirm the Supabase project has TOTP enrolment enabled for the environment. **This is worth shipping on its own even if the rest of this PRD is deferred** — we currently advertise 2FA that no user can turn on.
- **Acceptance:** a user enrolls TOTP from Settings → Security, signs out, signs back in, is challenged, and the panel shows Active.

**Phase 0b — Migration + audit write path (internal, invisible).**
Apply migration `0040` (three `workspaces` columns, `audit_log` table + immutability, three plan-flag keys). Ship `record_audit()` and instrument the §6.5 sites. **No read surface, no enforcement yet** — the log quietly accumulates so that Phase 2 has real history to show. Register all three flags `inert`→`enforced` in this PR.
- **Acceptance:** a role change, an invite, a QR destination edit, and a token mint each produce exactly one correct row; `UPDATE`/`DELETE` on `audit_log` is rejected; a forced audit-write failure does **not** break the underlying mutation.

**Phase 1 — MFA enforcement + audit read, closed (internal + design partners).**
AAL propagation in the middleware, the enforcement helper on `get_workspace_role` plus every inline-membership-check site, the security-policy endpoints, the Organization Security panel, the interstitial + step-up dialog + auto-retry, the Audit Log page and CSV export. Behind a FE flag for internal workspaces and 2–3 design partners.
- **Acceptance:** owner without 2FA cannot enable the policy (`409`); owner with 2FA enables it; an AAL1 member gets the interstitial, enrolls, and is auto-retried through; an enrolled-but-stale member gets the step-up dialog and one-taps through; a **second** workspace without the policy stays fully usable in the same session; Settings → Security and sign-out stay reachable while blocked; the audit log lists and exports; a non-entitled workspace sees the upgrade state; **API-key traffic is unaffected**.

**Phase 2 — GA (deal-triggered).**
Remove the FE flag; the three flags are already `enforced` from Phase 0b. Update the security collateral and the comparison matrix. **GA gate: a named deal is asking**, plus zero wrongful lockouts on the design-partner cohort and the immutability + coverage tests green.

**Cross-service gates — all clear:**
- **No Worker change → `npm run deploy:prod` is NOT required.** No KV key, no template, no `handlers/` case, no `scheduled()` cron.
- **No email → the unpublished `_dmarc.qravio.app` record is NOT a gate.**
- **Deploy order:** apply `0040` **before** the backend deploys (the enforcement helper reads `workspaces.require_mfa`; the audit helper writes `audit_log`), then backend, then frontend. A frontend deployed early simply shows a panel whose `PATCH` 404s — harmless; a backend deployed before the migration would 500 on the first mutation, so **the migration is a hard prerequisite**.

## 11. Risks, Edge Cases & Open Questions

**R1 — Enforcement coverage is not automatic (the #1 correctness risk).** Hooking the check into `get_workspace_role` covers every route that uses the shared dependency — but exploration found **~15 endpoints that do their own inline `workspace_members` lookup instead**: `scan.py` (7 sites: L920, L1010, L1094, L1242, L1271, L1298, L1546), `storage.py` (L174, L367, L549), `security.py` (L198, L247, L327, L360), `ai_analyst.py` (L76), `workspace.py:192`. Those would silently bypass the policy — an "enforced" control with holes is worse than none. **Mitigation:** one shared `enforce_org_mfa()` helper, called from `get_workspace_role` **and** from each inline site (or convert the site to the dependency), plus a **coverage guardrail test** in the spirit of `test_feature_gate_coverage` that greps for `table("workspace_members")` outside the dependency and fails on any site that neither uses the dep nor calls the helper. Two of those sites (`workspace.py:192` slug lookup, and the `security.py` user-scoped ones) must be **deliberately exempt** so a blocked user can still load the shell and reach enrollment — the exemptions are an explicit allowlist, not an oversight.

**R2 — Lockout, in four distinct flavours (the #2 risk).**
*(a) Owner locks themselves out* → server-side refusal to enable unless the enabling owner's session is AAL2 (`409`), independent of the UI hint.
*(b) The whole team is blocked with no enrollment path* → this is exactly today's state (§ blocker), which is why Phase 0a ships first and is a hard gate.
*(c) A `401` instead of `403` triggers the client's refresh/sign-out interceptor and loops* → the block is a **`403` with a structured code**, and the interceptor must be verified to pass `403` through untouched.
*(d) Every owner loses their authenticator* → no self-serve bypass by design (a bypass defeats the control). **Break-glass is a documented support runbook**: a manual `UPDATE workspaces SET require_mfa = false` by an operator after out-of-band identity verification — and that operation is itself recorded as a system-actor audit row.

**R3 — Latency on the hottest path.** The policy must be read on essentially every authenticated request. A naive extra `SELECT` on `workspaces` would add a round-trip to every API call. **Mitigation:** fold it into the membership query PostgREST already runs as an embedded resource (`select("role, workspaces(require_mfa)")` — the same embed style `workspace.py:143` already uses), giving **zero** extra round-trips. If the embed proves awkward, fall back to a 30-second in-process TTL cache mirroring `_PLAN_CACHE` (`subscription.py:207`) — with the documented consequence that disabling the policy can take up to 30s to take effect.

**R4 — The policy does not cover API keys (a real hole; we disclose it).** `/api/public/v1` authenticates with an API key and carries no JWT, so it has no assurance level. A workspace with enforced MFA still has key-based access that MFA cannot gate. **Mitigation:** say so plainly in the panel copy and the security write-up; note that *minting* a key is a workspace-scoped action and therefore **is** behind the policy, key creation/revocation is audited, and owners can revoke. Deliberately **not** solved by auto-revoking keys on policy enable (that would break running integrations without warning).

**R5 — `aal` semantics are subtler than "has 2FA".** Supabase issues `aal2` only for a session that has **cleared a factor challenge in that session**. A user who enrolled last week but whose current session predates the challenge is `aal1` — *enrolled but not stepped up*. Treating `aal1` as "no 2FA" and dumping them into enrollment would be wrong and confusing. **Mitigation:** the frontend distinguishes the two with `listFactors()` (already wired in `useTwoFactorStatus`): **factors > 0 → step-up dialog**; **factors == 0 → enrollment interstitial**. Also: the `aal` claim is only readable on the middleware's local-decode fast path; the `get_user()` fallback returns a user object with no assurance level, so that branch must read `aal` from the (already server-verified) token separately — a missed detail there would make the policy silently inert for any project on asymmetric JWT keys.

**R6 — Audit-write failure semantics.** If `record_audit()` raises, does the member removal fail? **Mitigation:** **no** — the audit write is best-effort and never blocks the user's action (mirroring `_log_login_event`'s `except: pass` at `auth.py:29`), **but** unlike that precedent it logs at **ERROR** with the action name and feeds a failure-rate metric. Silently swallowing an audit failure is how a trail becomes untrustworthy. *(A strict "no action without its audit row" mode is a real alternative for a compliance-hard buyer — Open Q3.)*

**R7 — Immutability vs. the deletion cascade.** An `ON DELETE CASCADE` from `workspaces` would collide head-on with a DELETE-blocking trigger: deleting a workspace would fail. Worse, cascading deletes on user removal would erase exactly the trail an auditor wants. **Mitigation:** `audit_log` carries **no foreign keys** — `workspace_id` and `actor_user_id` are plain UUIDs with denormalized `actor_email` / `target_label` snapshots, so the trail survives both member removal and workspace deletion intact. This must be coordinated with the pending account-deletion-cascade fix (gap analysis, "Recommended sequence" item 1) so that work doesn't add a cascade here.

**R8 — Audit-log volume and PII.** Rows accrue for every workspace on every plan, including Free (write is ungated). They also contain IP addresses and emails — personal data under DPDP. **Mitigation:** volume is bounded by admin-action frequency (orders of magnitude below scans) and bulk operations collapse to **one summary row**; a purge job is future work, not v1. On PII: the log is service-role-only, owner-read-only, never exposed at the edge, and stores no scan-side or end-user data — only the actions of authenticated members of that workspace. Retention is a **read clamp**, so a shorter plan window narrows exposure without deleting the record.

**R9 — Building it too early.** Fit 2 / Impact 2. There is no organic pull from the ICP. **Mitigation:** it stays in `NOT_DONE` until a named deal asks. Phase 0a (re-expose 2FA) is the one piece worth doing unconditionally — it's a bug fix, not a feature.

**Open Questions**
1. **Does Pro get a 30-day audit window as a second upsell rung?** *Recommend **no** for v1 — keep "enterprise security = Agency" unambiguous. It's one `UPDATE` to add later, and rows are already being written, so nothing is lost by waiting.*
2. **Owner-only audit read, or owners + editors?** *Recommend **owner-only**. The log contains other members' actions, IPs, and user agents; an editor reading their colleagues' IPs is a privacy problem we don't need.*
3. **Best-effort audit writes, or a strict "no action without its row" mode?** *Recommend **best-effort + loud ERROR log** for v1 (never break a user's action over telemetry). Revisit only if a specific buyer's contract demands strict mode — at which point it's a per-workspace setting, not a global change.*
4. **Does the policy have a grace period ("enforced starting in 7 days", with reminders)?** *Recommend **no** in v1 — immediate enforcement plus a good step-up path is simpler and safer than a deadline system that needs a cron and email (both currently off the critical path).*
5. **Should QR create/update/delete be in v1, or member/settings actions only?** *Recommend **include QR mutations** — "who repointed this destination" is the single most-asked audit question for our product, and it costs one helper call per handler. Bulk operations write one summary row.*
6. **Owner-visible member 2FA state — is that a privacy issue?** *Recommend **no, it's fine**: "has a factor / doesn't" is a security posture within a workspace the owner administers, not personal data. We surface the boolean only — never the factor, device, or enrollment time.*

## 12. Dependencies

- **Supabase Auth MFA (shipped, but currently unreachable):** `supabase.auth.mfa.{listFactors,enroll,challenge,verify,unenroll}` via `qr_frontend/src/hooks/useSecurity.ts` (L45–L112), `TwoFactorPanel.tsx`, `TwoFactorModal.tsx`. **Must be re-exposed (Phase 0a) before anything else.** Confirm TOTP enrollment is enabled on the Supabase project per environment.
- **Bearer auth middleware (shipped):** `qr_backend/src/api/middlewares/auth_bearer.py` — the local HS256 decode at `_local_claims` (L99) is where the `aal` claim becomes available; the `get_user()` fallback (L175) needs its own AAL read.
- **Workspace-auth seam (shipped):** `get_workspace_role` (`src/api/dependencies/deps.py:33`) + `require_can_read/create/update/delete` (`permissions.py`) — the single enforcement hook, **plus** the ~15 inline-lookup sites in R1.
- **Gating engine (shipped):** `FEATURE_ENFORCEMENT` + async `check_feature` + `get_limit`/`_QUOTA_SPEC` (`subscription.py`); `canAccessFeature` / `PlanFeatures` (`plan-features.ts`, `useSubscription.ts`); guardrail `tests/unit_tests/test_feature_gate_coverage.py`.
- **CSV export pattern (shipped reference):** `lead_forms.py:135–203` (`export_leads_csv` → `csv.DictWriter` → `StreamingResponse`, `text/csv` + `Content-Disposition`) — the audit export mirrors it exactly.
- **Best-effort event-logging precedent (shipped reference):** `_log_login_event` (`auth.py:29`) — same shape, upgraded from silent `pass` to an ERROR log.
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; provisional slot **`0040`** (highest on disk = `0032`; `0033`+ are claimed by specs in flight — **re-verify at build time**).
- **No AI, no Cloudflare Worker, no KV, no cron, no email, no new external service, no new environment variable.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Policy columns + audit table + flag seed | `qr_backend/migrations/0040_org_mfa_audit_log.sql` (NEW — `workspaces.require_mfa`, `audit_log`, 3 plan keys) |
| AAL propagation | `qr_backend/src/api/middlewares/auth_bearer.py` (`_local_claims` ~L99; `get_user()` fallback ~L175) |
| MFA enforcement hook | `qr_backend/src/api/dependencies/deps.py` (`get_workspace_role` L33 — member branch L58, owner-fallback branch L74) + NEW `src/api/dependencies/mfa.py` |
| Inline-membership bypass sites (R1) | `scan.py` L920/L1010/L1094/L1242/L1271/L1298/L1546 · `storage.py` L174/L367/L549 · `security.py` L198/L247/L327/L360 · `ai_analyst.py` L76 · `workspace.py` L192 (**exempt**) |
| Security-policy endpoints | `qr_backend/src/api/routes/workspace.py` (NEW `GET`/`PATCH /{workspace_id}/security-policy`; `update_workspace` ~L749) |
| Audit write helper | `qr_backend/src/utilities/audit.py` (NEW — mirrors `_log_login_event`, `auth.py:29`) |
| Audit instrumentation sites | `workspace.py` L278/L367/L550/L651/L701/L723/L763 · `security.py` L277/L341 · `qr.py` create/update/delete · `custom_domain.py` |
| Audit read + CSV export | `qr_backend/src/api/routes/audit.py` (NEW — mirrors `lead_forms.py:135` export) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` ~L541 + `_QUOTA_SPEC` ~L429) |
| Coverage guardrails | `qr_backend/tests/unit_tests/test_feature_gate_coverage.py` (must stay green) + NEW enforcement-coverage test |
| Re-enable user 2FA | `qr_frontend/src/components/org/settings/SecuritySection.tsx:18` (uncomment `TwoFactorPanel`) |
| Org security panel | `qr_frontend/src/components/org/settings/` (NEW `org-security-section.tsx`) + `settings/page.tsx` (`Section` union L25, `baseSections` L27) |
| MFA interstitial + step-up | `qr_frontend/src/lib/api-client.ts` (403 `mfa_required` interceptor) + NEW `mfa-step-up-dialog.tsx`; reuses `TwoFactorModal.tsx` |
| Audit log page | `qr_frontend/src/app/[slug]/(dash)/audit-log/page.tsx` (NEW) + NEW `src/hooks/useAuditLog.ts` |
| FE gating | `qr_frontend/src/lib/plan-features.ts`, `src/hooks/useSubscription.ts` (`PlanFeatures.mfa_enforcement` / `.audit_log` / `.audit_log_retention_days`) |
| SCIM/SSO decision record (why SCIM is out) | `PRD_TRD/NOT_DONE/SSO_SAML_PRD.md` |
| Worker | **No change** (no KV, no type, no template, no cron) |
