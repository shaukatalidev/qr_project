# PRD — Account Deletion & Data Erasure (Right to Erasure)

**Status:** Draft · **Author:** Product · **Date:** 2026-07-27
**Priority:** **P0 compliance debt, not a feature.** We publicly promise a Right to Erasure (`qr_frontend/src/app/(marketing)/privacy/page.tsx:228`) and a 30-day response SLA (`:243`), and the product's own Settings → Account panel tells users to email `support@qravio.app` to delete their account (`qr_frontend/src/components/org/settings/AccountSection.tsx:104-116`). **No code path anywhere in the monorepo deletes a user.** Every promise is currently kept by hand, if at all.
**Tiers:** **All tiers, including Free.** Erasure is a statutory right, never a paid feature and never a plan flag. Deletion must work for a lapsed, downgraded, past-due, or never-paid account identically.
**Plan flags:** **None. No new flag, no `FEATURE_ENFORCEMENT` entry, no `plans.features` key.** Gating erasure behind a plan would itself be the compliance violation. (Consequence: `test_feature_gate_coverage` is untouched by this spec.)
**Split from:** the GDPR-portability half already shipped — `GET /api/v1/security/export-data` (`qr_backend/src/api/routes/security.py:347`) and its `useExportData` hook. This PRD is the missing second half of the same panel: portability exists, erasure does not.

**Blocking dependency for four eng-reviewed specs.** `WHATSAPP_REVIEW_REMINDERS_PRD.md:229` ("fix the cascade before or with this feature, not after"), `EMAIL_SIGNATURE_EMBED_PRD.md:321`, `GST_INVOICE_BILLING_PRD.md:9` ("must be included in the account-deletion cascade fix"), and `LOYALTY_STAMP_CARD_PRD.md:416` all name this work as a prerequisite. Three of them add **new third-party PII tables** (phone numbers, loyalty members, business/GST identity). Shipping any of them before this one makes an existing liability materially worse.

---

## 1. TL;DR / Summary

A signed-in user can **delete their own account, end to end, without emailing support**. The flow is a **soft-delete with a 30-day grace period, then an irreversible purge**:

- **T+0 (request).** The user confirms in Settings → Account (typing their email to confirm). We immediately: mark the account `pending_deletion`, **cancel every active subscription**, **pause every QR they solely own** (KV `status: "paused"` → the Worker's existing paused page — scans stop resolving *now*, processing stops *now*), revoke their sessions, and send a confirmation email with a one-click **Cancel deletion** link. The account is still fully recoverable.
- **T+0 → T+30 (grace).** Login is blocked with an "account scheduled for deletion — restore?" interstitial. One click restores everything: QRs re-sync live, sessions work again. Nothing is destroyed.
- **T+30 (purge).** A cron-driven, **idempotent and resumable** purge worker permanently destroys the account: DB rows, Supabase Storage objects, Cloudflare KV keys, Cloudflare-for-SaaS custom hostnames, and finally the Supabase Auth user. Billing records survive in **pseudonymised** form under GDPR Art. 17(3)(b) / Indian statutory retention.

Two things make this genuinely hard, and both are load-bearing requirements rather than nice-to-haves:

1. **Cloudflare KV is not transactional with Postgres.** A `DELETE FROM workspaces` cascade would drop `qr_codes` rows while their `shortCode` keys keep serving content at the edge, forever, with no row left to tell us which keys to remove. **The purge must enumerate every `short_code` and `domain:<hostname>` key *before* it deletes any row.** This is a ship-blocker, not an open question (§11 R1).
2. **Ownership is workspace-scoped and plans resolve owner-scoped** (`resolve_plan`, `qr_backend/src/api/routes/subscription.py:283`). Deleting an owner can silently destroy a co-worker's workspace *and* downgrade every other workspace that owner holds. §6.4 specifies the sole-owner / co-owned / member-only policy explicitly, including the forced-transfer fallback that keeps us inside the statutory deadline without letting one person nuke a team.

## 2. Problem & Motivation

**We assert the right and cannot execute it.** Our published privacy policy commits, in writing, to:

| Promise | Source | Reality today |
|---|---|---|
| "Right to Erasure — request deletion of your personal data" | `privacy/page.tsx:228` | No deletion code exists |
| "We will respond within 30 days" | `privacy/page.tsx:243` | Manual, unmeasured, unlogged |
| "retained … for 90 days after account deletion to allow recovery. Permanently deleted thereafter." | `privacy/page.tsx:191-193` | Nothing is ever deleted |
| "Uploaded files … deleted within 30 days of account deletion" | `privacy/page.tsx:200-201` | Storage objects are never removed |
| "Billing records — retained for 7 years" | `privacy/page.tsx:204-205` | True by accident (nothing is deleted) |

Three of those five sentences describe behaviour that does not exist. That is the actual problem: not "we lack a feature" but "we have published a compliance claim our codebase cannot honour."

**The in-product surface is a `mailto:`.** `AccountSection.tsx:104-116` renders a red "Delete Account" card whose entire content is *"To request deletion, contact us at support@qravio.app."* Sitting immediately above it, the same component ships a fully working, one-click **Data Export** button (`:86-94`) backed by `GET /security/export-data`. Portability shipped; erasure got a mailto. The asymmetry is visible to every user who opens that panel.

**Verified: there is no deletion path anywhere in the monorepo.**
- No `DELETE /workspaces/{id}` route exists — `qr_backend/src/api/routes/workspace.py` deletes only *members* (`:677`) and *invitations* (`:717`).
- No user-deletion route exists in `security.py`, whose only routes are `/login-history`, `/preferences`, `/api-tokens*`, and `/export-data`.
- No Supabase Auth Admin `delete_user` call exists anywhere in `qr_backend/src`.
- The only deletes that clean up external state are per-QR (`qr.py:3403` single, `:3354` bulk, capped at 100 ids) and per-domain (`custom_domain.py:427`). Both are user-initiated, one object at a time.

**The debt compounds with every feature we ship.** Four specs already through eng review are blocked on this and each of them *adds* PII: `WHATSAPP_REVIEW_REMINDERS` stores consented third-party phone numbers, `LOYALTY_STAMP_CARD` stores OTP-verified member identities, `GST_INVOICE_BILLING` stores business legal name and address. Their own PRDs say so — `WHATSAPP_REVIEW_REMINDERS_PRD.md:229` reads *"Adding a phone-number table to a product that cannot actually delete a user's data makes that pre-existing gap materially worse — fix the cascade before or with this feature, not after."* This is the single highest-leverage unblock on the roadmap: one spec releases four.

**Storage and edge state are the parts nobody remembers.** Beyond Postgres, a deleted account leaves behind Supabase Storage objects under at least five distinct path shapes and two Cloudflare surfaces (KV entries and Cloudflare-for-SaaS custom hostnames). A "just add `ON DELETE CASCADE`" answer deletes the rows and orphans everything else — including **live QR landing pages that keep serving a deleted user's vCard, PDF, and business content at the edge indefinitely.** That is the failure mode this spec exists to prevent.

## 3. Goals & Non-Goals

**Goals**
- **Self-serve, end-to-end account deletion** for every tier, replacing the `mailto:` in `AccountSection.tsx`. No support ticket, no human in the loop for the happy path.
- **Soft-delete + 30-day grace + irreversible purge.** Reversible until purge; genuinely irreversible after. Processing (scan resolution, analytics collection, billing) stops at **T+0**, not at T+30.
- **Complete erasure across all four stores**: Postgres rows, Supabase Storage objects, Cloudflare KV keys (`<shortCode>` **and** `domain:<hostname>`), Cloudflare-for-SaaS custom hostnames, and the Supabase Auth user itself.
- **Idempotent and resumable.** A purge that dies halfway through must be safely re-runnable to completion; a re-run of a completed purge must be a no-op. Progress is checkpointed per step.
- **Explicit, documented multi-tenant policy** for sole-owner, co-owned, and member-only workspaces (§6.4) — including what happens to collaborators.
- **Subscription cancellation is part of the request, not a follow-up.** Nobody gets billed after asking to be deleted.
- **Legally-defensible billing retention**: invoice/subscription records survive in pseudonymised form (Art. 17(3)(b)), and we say so on the confirmation screen rather than pretending everything is gone.
- **An auditable trail**: every request, state transition, and purge outcome is logged with timestamps, so "did we honour the 30-day SLA" is a query, not a guess.
- **Code and published policy agree.** The privacy page's "90 days" (`privacy/page.tsx:192`) is amended to match the implemented grace period in the same PR.

**Non-Goals**
- **No admin/support console** for operator-initiated deletion in v1. Support continues to act on the user's behalf by having the user run the self-serve flow. *(Future — and it needs its own authorisation model.)*
- **No per-workspace "delete this workspace" feature.** Related, genuinely useful, and out of scope: this spec deletes *accounts*, and only touches workspaces as a consequence. *(Future, separate PRD.)*
- **No selective/partial erasure** ("delete my scan analytics but keep my QRs"). All-or-nothing in v1. *(Future.)*
- **No backup/PITR erasure.** Supabase point-in-time-recovery snapshots are outside application control; we document the backup retention window instead of pretending to reach into it (§11 R6).
- **No retroactive purge of pre-existing orphans.** Storage objects and KV keys already orphaned by past QR deletes are a separate cleanup job. *(Future; the same helpers make it easy.)*
- **No plan flag, no tier gate, no metering.** Erasure is free and unlimited by law.
- **No new QR type, no new scan-page template, no Worker code change.** The purge reuses the Worker's existing `status: "paused"` branch (`qr_cf_code/src/index.js:368`); nothing at the edge needs to learn a new state.
- **No hard-deletion of another controller's data.** Lead submissions, loyalty members, and reminder contacts belonging to a *deleted merchant's* end-customers are destroyed with the workspace — but we do not attempt to reach into third-party systems the merchant exported them to.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Churned solo user ("Ravi")** | Free/Starter, one workspace, tried it, moving on | "Close my account and take my data off your servers" | Must email support; gets no confirmation anything happened |
| **Privacy-exercising user ("Meera")** | Any tier; wants a DPDP/GDPR erasure right honoured | Formal Right-to-Erasure request with proof it completed | We promise 30 days (`privacy/page.tsx:243`) with no mechanism to meet or measure it |
| **Agency owner with a team ("Arjun")** | Pro/Agency, owns 3 workspaces with 6 collaborators | Leave the platform without destroying his team's live QRs | Undefined. Today nothing happens; tomorrow, done naively, his colleagues' campaigns die silently |
| **Collaborator on someone else's workspace ("Divya")** | Editor in a workspace she doesn't own | Delete *her* account without touching the client's workspace | Her membership row would be the only thing that should go — but there is no path at all |
| **Support/compliance operator** | Us, answering `support@qravio.app` | Answer a rights request inside the SLA, with an audit trail | Manual SQL against prod, no record, no repeatability, high blast radius |
| **The Data Protection regulator** | DPB (India) / a DPA (EU) | Evidence the published policy is implemented | We would currently have to say "it's manual" |

Primary user is **Ravi** by volume and **Meera** by risk. **Arjun** and **Divya** define the hard case: the multi-tenant policy in §6.4 is written for them, and getting it wrong is the difference between a clean feature and a support incident that destroys a paying customer's live campaigns.

## 5. User Stories

- As **any user**, I want to delete my account from Settings without emailing anyone, so that the product honours the right it already claims to grant.
- As **a user who changed their mind**, I want a 30-day window and a one-click undo, so that a moment of frustration doesn't cost me my QR codes permanently.
- As **a user with an active subscription**, I want deletion to cancel my billing immediately, so that I am never charged after asking to leave.
- As **a user**, I want my QR codes to stop resolving the moment I request deletion, so that "delete my account" doesn't quietly mean "keep serving my business card to strangers for another month."
- As **a privacy-conscious user**, I want an honest, specific list of what is destroyed and what is legally retained (invoices, for 7 years), so that I am not misled by a blanket "everything is deleted."
- As **an agency owner**, I want to be told *before* I confirm that 2 workspaces have 6 collaborators, and be made to choose transfer-or-destroy, so that I never accidentally delete my team's work.
- As **a collaborator**, I want deleting my account to remove me from workspaces I don't own without harming them, so that leaving a client project is safe.
- As **a collaborator whose workspace owner deleted their account**, I want to be emailed and offered ownership, so that a campaign I depend on doesn't vanish without warning.
- As **an operator**, I want every deletion request and purge outcome recorded with timestamps, so that I can answer "did we meet the 30-day SLA" with a query.
- As **an engineer on call**, I want a purge that crashed at 03:00 to resume safely on the next cron tick, so that a partial purge is never a permanent inconsistency.

## 6. UX / Product Flow

### 6.1 Entry point — Settings → Account

`AccountSection.tsx`'s red "Delete Account" card (`:98-117`) keeps its position and visual treatment (`bg-red-50`, `border-red-100`, the `bg-red-400` rule) but the `mailto:` paragraph is replaced by a **"Delete my account"** destructive `Button` that opens a confirmation dialog. The card is extracted into its own file — `AccountSection.tsx` is already 120 lines and the house rule is a 200-line ceiling with one export per file.

### 6.2 Pre-flight — the impact summary

Opening the dialog fires a **read-only pre-flight** (`GET /security/deletion/preflight`) that returns exactly what this account's deletion will touch. The dialog renders it as a plain list, not a scare-sheet:

> **This will permanently delete:**
> · 2 workspaces you own — *Acme Marketing*, *Acme Events*
> · 47 QR codes (they will stop working immediately)
> · 12,480 scan records and all analytics
> · 3 uploaded files
> · 1 custom domain — *go.acme.com*
>
> **You will be removed from** 1 workspace owned by someone else — *Client Co* (that workspace is not affected).
>
> **We will keep** your invoices and payment records for 7 years, as Indian tax law requires. They will no longer be linked to your name or email.
>
> **Your subscription (Pro, ₹999/mo) will be cancelled immediately.**

**Blocking conditions** are surfaced here, before confirmation, each with an inline resolution (§6.4):
- *"**Acme Marketing** has 4 other members. Choose: transfer ownership to a member, or delete the workspace and remove everyone."*

The user types their **email address** to confirm (not the word "DELETE" — the email is account-specific and defeats muscle memory), then presses **Schedule deletion**.

### 6.3 T+0 — the immediate effects

On `POST /security/deletion`, before the response returns:
1. A `deletion_requests` row is created (`status = 'pending'`, `purge_after = now() + 30 days`).
2. **Every active subscription the user owns is cancelled** — Razorpay via the existing cancel path (`razorpay_routes.py:415`); the USD/MoR rail is flagged for manual cancellation because `MoRProvider` has no cancel method (§11 R4, an honest known gap).
3. **Every QR in every solely-owned workspace flips to `status: "paused"`** in Postgres and is re-synced to KV via `sync_qr_to_kv` (`cloudflare_kv.py:307`). The Worker already renders `getPausedPage` for that status (`qr_cf_code/src/index.js:368`) — **zero Worker change**, and it is reversible by re-syncing.
4. All of the user's sessions are revoked; subsequent logins hit the restore interstitial.
5. A confirmation email is sent (Resend, `src/utilities/email.py`) stating the purge date and carrying a one-click **Cancel deletion** link.
6. If any owned workspace has other members, each member is emailed: *"Arjun has scheduled deletion of their account. Acme Marketing will be transferred to you on 26 Aug 2026 unless…"*

The panel now shows a persistent banner: **"Your account is scheduled for deletion on 26 August 2026. Cancel deletion."**

### 6.4 The multi-tenant policy (the hard case — decided, not deferred)

Ownership is `workspaces.owner_id` plus `workspace_members` roles (viewer/editor/owner), and plans resolve **owner-scoped** across every workspace an owner holds (`_best_active_subscription_for_owner`, `subscription.py:248`). Three distinct cases, three distinct answers:

| Case | Policy | Rationale |
|---|---|---|
| **A. Sole owner, no other members** | Workspace and all its data are purged with the account. | It is entirely the requester's data. Nothing to protect. |
| **B. Non-owner member** (viewer/editor, or co-owner who isn't `owner_id`) | Only the `workspace_members` row is deleted. The workspace is untouched. | The workspace is not the requester's personal data. Removing them is complete erasure of *their* relationship to it. |
| **C. Sole `owner_id` **with** other members** | **Blocked at request time.** The user must explicitly choose per workspace: **(i) transfer ownership** to a named member, or **(ii) delete the workspace and remove all members** (with a second confirmation naming the member count). | Silently destroying collaborators' live campaigns on one person's request is both a product catastrophe and an over-reach: the other members' work is not the requester's personal data to erase. |

**The deadline escape hatch (required — a permanent block would breach the statutory deadline).** If a case-C workspace is still unresolved at **T+21** (nine days before purge), the system **force-transfers** ownership to, in order: the longest-tenured remaining `owner`; else the longest-tenured `editor`; else — if no members remain — it purges the workspace. The new owner is emailed. **The requester's own personal data is erased on schedule in every branch**; only the workspace's business data survives, now owned by someone else. This keeps us inside "without undue delay" (GDPR Art. 12(3): one month) while never destroying a third party's data on someone else's say-so.

> **Consequence to call out explicitly:** a force-transferred workspace inherits the *new* owner's plan, because `resolve_plan` reads the owner's subscriptions. A workspace transferred from a Pro owner to a Free member **downgrades**, which can lock QRs above `max_qr` via the existing downgrade machinery. The transfer email must say so. (§11 R5.)

### 6.5 T+0 → T+30 — grace and restore

Logging in during grace shows a dedicated interstitial rather than the dashboard: *"This account is scheduled for deletion on 26 August 2026. Restore account / Continue with deletion."* **Restore** (`DELETE /security/deletion`, or the emailed one-click link) sets `status = 'cancelled'`, un-pauses every QR via `resync_workspace_qrs` (`cloudflare_kv.py:262`), and returns the user to a fully working account. Subscriptions are **not** auto-resubscribed — they were genuinely cancelled at the provider; the restore screen says so and links to billing.

### 6.6 T+30 — the purge

A daily cron sweep (the Worker's existing `0 6 * * *` branch, `qr_cf_code/src/index.js:73-77`) calls a new `/internal/deletion-purge`, which claims due requests and destroys them **in a strictly ordered, checkpointed sequence** — external state first, so a crash never leaves a live edge artifact with no DB row pointing at it:

```
1. enumerate + record every short_code and domain:<hostname>   ← BEFORE any delete
2. Cloudflare: delete_custom_hostname()  (Cloudflare-for-SaaS)
3. Cloudflare KV: delete_from_kv(short_code) × N, delete_domain_from_kv(host) × M
4. Supabase Storage: remove objects under every path prefix (§ TRD 3.4)
5. Postgres: delete workspace-scoped rows, then workspaces, then user rows
6. Billing: pseudonymise (never delete) subscriptions + invoice records
7. Supabase Auth: admin delete_user(user_id)
8. mark status='purged'; retain the request row (audit) with all PII stripped
```

Each step writes a checkpoint, so a re-run resumes rather than restarting. Every step is individually idempotent (a KV key already gone, a storage object already removed, a row already deleted are all no-ops). A step that exhausts its retries moves the request to `dead_letter` and pages us — **it never silently marks the account purged.**

Finally: a **completion email** to the address on file (the last message we will ever send them), stating what was destroyed and what was retained.

### 6.7 What the user never sees

The `deletion_requests` row survives the purge as a **PII-free audit record** — `user_id_hash` (salted with the existing `HASHING_SALT`, `src/config/settings/base.py:131`), requested/purged timestamps, counts. This is how we evidence SLA compliance without retaining the identity we just erased.

## 7. Scope

**In scope (v1)**
- `deletion_requests` table + state machine (`pending` → `purging` → `purged` | `cancelled` | `dead_letter`), with a claim-lease and backoff modelled on `webhook_deliveries` (`src/utilities/webhook_dispatch.py`).
- Backend routes: `GET /security/deletion/preflight`, `POST /security/deletion`, `GET /security/deletion` (status), `DELETE /security/deletion` (cancel), plus `POST /internal/deletion-purge` (cron, `x-internal-secret`).
- **T+0 side-effects**: subscription cancellation, QR pause + KV re-sync, session revocation, notification emails (requester + affected members).
- **Ordered, checkpointed, resumable purge** covering Postgres, Supabase Storage (all path shapes), Cloudflare KV (`<shortCode>` + `domain:`), Cloudflare-for-SaaS hostnames, and the Supabase Auth user.
- **Complete cascade inventory** (TRD §2) — every user- or workspace-scoped table, its current cascade state, and the purge's action for each. Any table whose cascade is *unverified* is deleted explicitly rather than assumed.
- **Case-C workspace policy** with transfer/destroy choice at request time and the T+21 forced-transfer fallback.
- **Billing pseudonymisation** with a documented retention basis.
- Frontend: replace the `mailto:` card, confirmation dialog with pre-flight impact summary, scheduled-deletion banner, restore interstitial, `useAccountDeletion` TanStack hook.
- **Privacy-policy correction**: `privacy/page.tsx:192` "90 days" → the implemented grace period, in the same PR.
- Tests: cascade completeness, KV-teardown-before-row-delete, idempotent re-run, partial-purge resume, case A/B/C policy, forced transfer, no-billing-after-request.

**Out of scope / Future**
- Admin/support-initiated deletion console *(future; needs its own authz model)*.
- Standalone "delete this workspace" *(future, separate PRD)*.
- Selective/partial erasure *(future)*.
- Retroactive cleanup of pre-existing orphaned storage objects and KV keys *(future; reuses these helpers)*.
- Erasure inside Supabase PITR backups *(not application-controllable; documented, not implemented)*.
- Data-transfer-on-deletion ("export everything one last time automatically") — the user can already self-serve `GET /security/export-data` before confirming, and the dialog links to it. *(Auto-export at purge time is future.)*
- Fixing the pre-existing `/internal/reclamation-sweep` 404 (`qr_cf_code/src/index.js:77` pings an endpoint that does not exist in the backend). **Referenced as a known bug so the implementer isn't surprised when adding a sibling cron target — explicitly not fixed here.**

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Account deletion & erasure | **Free, Lite, Starter, Pro, Business, Agency — all** | **None** |
| Grace period length | all | Config constant, not a plan value |

**There is no packaging decision to make, and that is itself the decision.** Erasure is a statutory right under GDPR Art. 17 and India's DPDP Act 2023 (which our own privacy page invokes by name, `privacy/page.tsx:213`). Gating it — by tier, by flag, by quota — would be the violation. Concretely this spec adds **no** `plans.features` key, **no** `FEATURE_ENFORCEMENT` entry, and **no** `PlanFeatures` field, so `test_feature_gate_coverage` is untouched.

**Revenue interaction, stated honestly:** deletion cancels subscriptions, so this feature *reduces* revenue on the margin. It is worth it — an unhonoured erasure claim is a regulatory and reputational exposure far larger than the churn it accelerates, and users who cannot leave cleanly say so publicly. The 30-day grace is the only lever that touches retention, and it is there for operational safety (a recoverable mistake), not as a dark pattern: the restore path is one click, offered in the email, and never buried.

**One deliberate anti-pattern avoidance:** we do **not** put a "downgrade to Free instead?" upsell in the confirmation dialog. The impact summary is informational only. A retention offer at the moment of an exercised legal right reads as obstruction, and regulators treat obstruction of a rights request as a finding in its own right.

## 9. Success Metrics & KPIs

**Correctness (these are release gates, not dashboards)**
- **Zero orphaned KV keys.** After a purge, `GET` on every recorded `shortCode` and `domain:<hostname>` returns 404. Verified by the purge's own post-check and by an integration test. *(The single most important number in this spec.)*
- **Zero orphaned storage objects** under any purged workspace/user prefix.
- **Zero orphaned rows** — a post-purge query across the full cascade inventory (TRD §2) returns 0 for every table.
- **100% of purges idempotent**: re-running a completed purge is a no-op; re-running an interrupted purge completes it. Measured by a deliberate mid-purge kill in the test suite.
- **0 accounts marked `purged` with an incomplete purge.** A failed step must land in `dead_letter`, never in `purged`.

**Compliance**
- **100% of deletion requests purged within 30 days ± 1** of request (SLA evidence, queryable from `deletion_requests`).
- **0 charges** to any account after its deletion request timestamp.
- **Time-to-first-effect < 5s**: subscription cancelled and QRs paused within the `POST` request.
- Median support handling time for erasure requests → **0** (self-serve replaces the ticket).

**Product**
- **≥ 90% of deletions self-serve** (vs `support@` email) within 60 days of GA.
- **Grace-period restore rate tracked** — this is the "was this a mistake?" signal. A rate above ~15% means the confirmation flow is too easy to trigger and needs friction, not that the feature is working.
- **0 support tickets from collaborators** whose workspace disappeared without warning (case-C policy working).
- **0 `dead_letter` requests** outstanding at any weekly check.

## 10. Rollout Plan

**Phase 0 — Schema + purge engine, no UI (internal).**
Apply the migration (`deletion_requests` + the cascade `ON DELETE CASCADE` corrections the inventory turns up). Build the purge worker, the storage/KV/CF teardown helpers, and `/internal/deletion-purge`. Wire the daily cron branch. **Test against seeded throwaway accounts in staging only** — including one with 2 workspaces, 6 members, files, a custom domain, and an active subscription. Verify the post-purge zero-orphan checks. No user-facing route is exposed yet.
*Exit gate:* a staging account with every artifact type purges cleanly, twice (second run = no-op), and once with a deliberate mid-purge process kill that resumes to completion.

**Phase 1 — Request/cancel API + UI behind a flag (closed).**
Ship `preflight`/`POST`/`GET`/`DELETE`, the confirmation dialog, banner, and restore interstitial behind `NEXT_PUBLIC_ACCOUNT_DELETION_BETA`. Internal accounts only. Exercise all three ownership cases and the forced transfer (with a shortened grace constant in staging so T+21/T+30 are reachable in a test run).
*Acceptance:* Ravi (case A) deletes cleanly; Divya (case B) is removed from a client workspace that keeps working; Arjun (case C) is blocked until he chooses, and the forced transfer fires at T+21 with the new owner emailed; a restore at T+15 brings back every QR live at the edge; no charge lands after T+0.

**Phase 2 — GA.**
Remove the FE flag. **Amend `privacy/page.tsx:192`** so the published retention window matches the shipped grace period. Publish a short help-centre page. Update `AccountSection.tsx` copy to name the retained billing records explicitly.
*GA gates:* zero-orphan checks green across ≥ 10 staging purges; `dead_letter` alerting wired; the case-C member-notification email verified deliverable.

**Cross-service gates (be honest about these):**
- **Email is on the critical path** — this feature sends confirmation, member-notification, and completion emails via Resend. **The unpublished `_dmarc.qravio.app` record is therefore a real GA gate here** (unlike card-OCR, which sends nothing). A deletion confirmation landing in spam is a support incident and a compliance risk.
- **A prod Worker deploy is required** only if we add a new cron trigger. We do **not**: the purge joins the existing `0 6 * * *` branch (`qr_cf_code/src/index.js:73-77`), so `wrangler.toml`'s `crons` array is unchanged. The `scheduled()` handler still needs the one-line dispatch addition and a `npm run deploy:prod`.
- **`CF_API_TOKEN` needs KV **and** Cloudflare-for-SaaS delete permissions** in every environment — verify before Phase 0, because a token that can write but not delete produces exactly the silent-orphan failure this spec exists to prevent.
- **Supabase service-role key must permit Auth Admin `delete_user`.** Verify per environment.

## 11. Risks, Edge Cases & Open Questions

**R1 — Orphaned Cloudflare KV keys (SHIP-BLOCKER, highest-risk item).** KV is not transactional with Postgres and there is no delete trigger. A cascade delete from `workspaces` → `qr_codes` destroys the rows that hold `short_code`, after which **the KV keys are unreachable forever and the Worker keeps serving a deleted user's vCard, PDF, and business content at the edge.** Note the per-QR routes *do* clean up correctly today (`qr.py:3313`, `:3386`, `:3430` all call `delete_from_kv`) — the danger is precisely that a bulk/cascade purge bypasses them. **Mitigation (hard requirement):** the purge **enumerates and persists** every `short_code` and `domain:<hostname>` into the `deletion_requests` checkpoint **before deleting any row**, tears down KV from that recorded list, and **post-verifies** each key is gone. A KV teardown failure blocks the row delete and moves the request to `dead_letter` — we never delete the rows that are our only handle on the edge state.

**R2 — Orphaned Supabase Storage objects.** Objects live under **at least five distinct path shapes**, and the `storage.py` module docstring (`:9`) is stale — it claims `{bucket}/{user_id}/{uuid}_{filename}`, but the actual writers are workspace-prefixed: `{workspace_id}/temp/{uuid}/{name}` (`storage.py:237`), `{workspace_id}/{qr_id}/{file_name}` (`qr.py:1706`, `:1737`, `:1803`, `:1858`), `{workspace_id}/{qr_id}/logo.{ext}` (`qr.py:2357`), `{workspace_id}/branding/logo-*.{ext}` (`branding.py:164`), plus genuinely user-prefixed `avatars/{user_id}/avatar.{ext}` (`storage.py:143`) and legacy `{user_id}/…` uploads still honoured by `list_files` (`storage.py:497`) and the signed-URL guard (`:552-554`). **Mitigation:** the purge sweeps **both** a per-workspace prefix and a per-user prefix, recursively, and cross-checks against `qr_files.file_path` + `qr_files.metadata.thumbnail_paths` + `workspace_branding.logo_url` so a path shape we missed still gets caught by the row-derived list. Both passes, belt and braces.

**R3 — Multi-tenant blast radius.** Deleting an owner can destroy a co-worker's workspace and, via owner-scoped plan resolution (`subscription.py:283`), downgrade every other workspace that owner holds. **Mitigation:** the §6.4 policy — block case C at request time, force-transfer at T+21, never auto-destroy a workspace with other members without an explicit second confirmation. Pre-flight surfaces the member counts *before* the user commits.

**R4 — The USD/MoR rail cannot be cancelled programmatically (verified gap).** `MoRProvider` (`src/integrations/mor/base.py`) defines only `variant_id_for`, `create_checkout`, `verify_signature`, and `parse_event` — **there is no cancel method**, so a Lemon Squeezy subscriber's billing cannot be stopped by our code. Razorpay is fine (`razorpay_routes.py:415`). **Mitigation for v1:** on a MoR subscription, mark the local row `canceled`, **flag the request for manual provider-side cancellation**, alert ops, and block the purge from reaching `purged` until an operator confirms. Ugly but honest. *(Proper fix: add `cancel_subscription` to `MoRProvider` — a small, separable PR that this spec recommends but does not bundle.)*

**R5 — Forced transfer causes a silent downgrade.** A case-C workspace transferred to a Free member re-resolves to the Free plan and can trip the existing excess-QR lock. **Mitigation:** the transfer email states the plan consequence plainly and links to billing; the pre-flight warns the departing owner too. We do **not** attempt to migrate the subscription — it was cancelled at T+0, and moving a payment instrument between people is not something to do implicitly.

**R6 — Backups outlive the purge.** Supabase PITR snapshots retain deleted rows for the project's backup window. **Mitigation:** we don't pretend otherwise. The completion email and privacy policy state that residual copies persist in encrypted backups for up to the documented retention window and are not restored into production. This is the standard, defensible position; it does require the privacy page to actually say it (currently it doesn't).

**R7 — Accidental deletion / social-engineered deletion.** A destructive, irreversible-by-design action on a live paying account. **Mitigation:** re-typing the account email (not a generic word), the 30-day grace with a one-click restore, an immediate email to the address on file, and member notifications that give collaborators an independent chance to raise a flag. Session revocation at T+0 means a hijacked session cannot *also* dismiss the warning banner.

**R8 — Purge crashes leave inconsistent state.** A half-run purge is worse than none. **Mitigation:** strictly-ordered steps (external state before rows), a per-step checkpoint on the request row, idempotent operations throughout, and a claim-lease + backoff copied from `webhook_dispatch._claim` (`:231`) / `BACKOFF_SCHEDULE_SECONDS` (`:57`) with a terminal `dead_letter` (`:301`). **Explicit anti-pattern to avoid:** `webhook_dispatch.sweep()` (`:516`) selects due rows with **no `LIMIT`** — an unbounded sweep. The purge sweep must be bounded (batch size + per-run time budget), because a purge batch is thousands of times heavier than a webhook POST.

**R9 — The cascade inventory is incomplete because most of the schema isn't in the repo.** Only tables created by migrations `0010`+ have verifiable FK definitions in `qr_backend/migrations/`. The base schema — `qr_codes`, `qr_destinations`, `qr_scan_events`, `qr_scan_counters`, `qr_files`, `qr_designs`, `qr_link_items`, `qr_link_pages`, every `qr_*_details` table, `workspaces`, `workspace_members`, `workspace_invitations`, `users`/`profiles`, `subscriptions`, `custom_domains`, `login_events`, `security_preferences`, `api_tokens`, `folders` — was created directly in Supabase and **its cascade state cannot be verified from source.** **Mitigation:** TRD §2 ships an `information_schema` introspection query as a **mandatory pre-implementation step**, and the purge **deletes every inventoried table explicitly** rather than trusting an unverified cascade. Belt-and-braces: correct cascades make it fast, explicit deletes make it correct.

**R10 — Retention-vs-erasure tension on billing.** Indian tax/accounting law (and the 7-year claim at `privacy/page.tsx:204-205`) requires invoice retention; GDPR Art. 17(3)(b) expressly permits retention for compliance with a legal obligation. **Mitigation:** retain the *financial* record (amount, currency, dates, provider IDs, plan) and **pseudonymise the identity** (`user_id` → salted hash via the existing `HASHING_SALT`, `base.py:131`; name/email/address nulled). Say exactly this in the confirmation dialog and the completion email. Do not claim total erasure — an over-claim is its own violation.

**Open Questions**
1. **Grace period: 30 days (our recommendation) or 90 days (what `privacy/page.tsx:192` currently promises)?** *Recommend **30**, with the policy amended in the same PR.* GDPR Art. 12(3) requires action "without undue delay and in any event within one month"; a 90-day purge sits outside that window even though processing stops at T+0, and defending it is unnecessary work. 30 days keeps us clearly compliant, still gives a generous undo, and matches the file-deletion promise already published at `:200-201`. **Whichever we pick, code and policy must agree — the current mismatch is the actual defect.**
2. **Should `POST /security/deletion` require password / fresh-session re-authentication?** *Recommend **yes** for GA* — Supabase `reauthenticate()` or a recent-login check. Email-typing plus grace is adequate for Phase 1 beta; a destructive irreversible action on a paying account deserves proof of presence before GA.
3. **Are lead submissions, and (once shipped) loyalty members and reminder contacts, destroyed with the workspace?** *Recommend **yes, destroyed**.* We are the processor and the merchant is the controller; when the controller's account ends, the lawful basis for us holding their end-customers' data ends with it. This is also what the four dependent specs assume. Worth a legal read before GA, and worth stating on the deletion screen so the merchant knows to export first.
4. **What happens to a workspace's `custom_domain` DNS on the customer's side?** *Recommend: we delete our Cloudflare-for-SaaS hostname and the `domain:` KV key; we cannot and should not touch their DNS.* The completion email tells them to remove the CNAME. Leaving our side up would be the worse failure.
5. **Should the pre-flight offer a one-click data export before confirming?** *Recommend **yes** — a link to the existing `GET /security/export-data` in the dialog.* Zero new backend work, materially better UX, and it strengthens the "we didn't obstruct you" position.
6. **Do we hard-delete or pseudonymise `login_events`?** *Recommend **hard-delete**.* It is pure personal data (IP, user agent, city) with no statutory retention basis. The security-audit argument for keeping it dies with the account.

## 12. Dependencies

- **Named prerequisite of four eng-reviewed specs — this unblocks all of them.** `WHATSAPP_REVIEW_REMINDERS` (`_PRD.md:229`, "fix the cascade before or with this feature"; `reminder_contacts` is a hard Phase-0 exit-gate item), `EMAIL_SIGNATURE_EMBED` (`_PRD.md:321`, "should not add a second uncascaded public artifact"), `GST_INVOICE_BILLING` (`_PRD.md:9`, "`workspace_billing_profile` … must be included in the account-deletion cascade fix"), `LOYALTY_STAMP_CARD` (`_PRD.md:416`). **Each adds a new PII table that must join the inventory in TRD §2 when it lands** — the inventory is a living table, and every future PRD that adds a user- or workspace-scoped table must add a row to it.
- **GDPR portability half (shipped):** `GET /api/v1/security/export-data` (`security.py:347`) + `useExportData` (`qr_frontend/src/hooks/useSecurity.ts`) — the sibling surface, linked from the confirmation dialog.
- **Cloudflare KV teardown helpers (shipped, reuse verbatim):** `delete_from_kv` (`src/utilities/cloudflare_kv.py:519`), `delete_domain_from_kv` (`:508`), `sync_qr_to_kv` (`:307`), `resync_workspace_qrs` (`:262`) — pause at T+0, restore on cancel, destroy at purge.
- **Cloudflare-for-SaaS teardown (shipped):** `delete_custom_hostname` (`src/utilities/cloudflare_saas.py:123`), already used by `custom_domain.py:427` and by `_revoke_custom_domains_for_workspace` (`razorpay_routes.py:1071`) — the latter is the closest existing precedent for a bulk teardown loop and should be read before writing the purge.
- **Queue/retry precedent (shipped):** `src/utilities/webhook_dispatch.py` — the `_claim` conditional-UPDATE lease (`:231`), `BACKOFF_SCHEDULE_SECONDS` (`:57`), `MAX_ATTEMPTS` (`:58`), terminal `dead_letter` (`:301`). Copy the shape; **do not copy the unbounded `sweep()` (`:516`).**
- **Cron seam (shipped):** the Worker's `scheduled()` dispatch by `event.cron` (`qr_cf_code/src/index.js:44-81`). The purge joins the **existing** `0 6 * * *` branch — **no new trigger, `wrangler.toml` `crons` unchanged.** ⚠️ That same branch already pings `/internal/reclamation-sweep` (`:77`), which **does not exist in the backend and 404s daily** — a known, pre-existing bug, referenced here so it isn't mistaken for a regression. Not fixed by this spec.
- **Internal-endpoint auth (shipped):** `verify_internal_secret` (`src/api/routes/internal.py:21`) + the router-level dependency (`:34`) + the `/internal/` excluded prefix (`src/main.py:70`).
- **Billing lifecycle (shipped, partial):** Razorpay `POST /razorpay/subscriptions/cancel` (`razorpay_routes.py:415`) — usable. **MoR/Lemon Squeezy has no cancel method** (`src/integrations/mor/base.py`) — R4's gap.
- **Owner-scoped plan resolution (shipped):** `resolve_plan` (`subscription.py:283`), `_owner_of_workspace` (`:237`), `_owned_workspace_ids` (`:242`), `_best_active_subscription_for_owner` (`:248`), `invalidate_plan_cache` (`:211`) — must be invalidated after any ownership transfer.
- **Permissions (shipped):** `require_workspace_role(["owner"])` (`src/api/dependencies/deps.py:95`), `get_current_user_id` (`:15`).
- **Email (shipped):** Resend via `src/utilities/email.py`. **New templates required** (confirmation, member notification, transfer notice, completion). ⚠️ `_dmarc.qravio.app` is unpublished — a **real GA gate for this feature**.
- **Hashing (shipped):** `settings.HASHING_SALT` (`src/config/settings/base.py:131`), used the same way as `ip_hash` (`internal.py:1332`), for billing and audit pseudonymisation.
- **Supabase Auth Admin API:** `auth.admin.delete_user(user_id)` via the service-role client (`src/database/supabase.py:28`). Confirm the key permits it per environment.
- **No AI. No new QR type. No new scan template. No new external service. No new plan flag.**

### Migration decision — ship **`0044_account_deletion_erasure.sql`** (provisional)

A migration **is** required: the `deletion_requests` table plus whatever `ON DELETE CASCADE` corrections the §2 inventory turns up. **The slot number is provisional and MUST be re-verified against `qr_backend/migrations/` at build time.** Highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`; `0033`–`0043` are claimed by drafted-but-unapplied specs in `PRD_TRD/NOT_DONE/` (`0033` QR expiry, `0034` UPI, `0035` location, `0036` phone, `0037` GA4, `0038` WhatsApp, `0039` GST, `0040` org MFA, `0041` restaurant menu, `0042` multilingual, `0043` loyalty). This repo has a commit history of fixing stale slot numbers — `AI_BUSINESS_CARD_OCR` reserved `0024` and shipped as `0026`; `WALLET_PASSES` reserved `0023` and lost it to `0023_outbound_webhooks.sql`. **Treat this header as a hint, never as truth: run `ls qr_backend/migrations/` immediately before applying and renumber to the lowest free slot.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Existing GDPR portability (sibling surface) | `qr_backend/src/api/routes/security.py:347` (`GET /security/export-data`) |
| New deletion routes | `qr_backend/src/api/routes/security.py` (`/security/deletion*`) |
| New purge engine | `qr_backend/src/utilities/account_purge.py` (NEW) |
| Cron entry point | `qr_backend/src/api/routes/internal.py` (`POST /internal/deletion-purge`, NEW) |
| Migration | `qr_backend/migrations/0044_account_deletion_erasure.sql` (NEW — **re-verify slot**) |
| KV teardown (reuse) | `qr_backend/src/utilities/cloudflare_kv.py:519`, `:508`, `:307`, `:262` |
| CF-for-SaaS teardown (reuse) | `qr_backend/src/utilities/cloudflare_saas.py:123` |
| Bulk-teardown precedent | `qr_backend/src/api/routes/razorpay_routes.py:1071` (`_revoke_custom_domains_for_workspace`) |
| Queue/retry precedent | `qr_backend/src/utilities/webhook_dispatch.py:231` (`_claim`), `:57`, `:301`, `:516` (**unbounded — don't copy**) |
| Storage path shapes | `qr_backend/src/api/routes/storage.py:143`, `:237`, `:497`; `qr.py:1706`, `:2357`; `branding.py:164` |
| Billing cancellation | `qr_backend/src/api/routes/razorpay_routes.py:415`; `qr_backend/src/integrations/mor/base.py` (**no cancel — R4**) |
| Owner-scoped plan resolution | `qr_backend/src/api/routes/subscription.py:283`, `:237`, `:242`, `:248` |
| Worker cron dispatch | `qr_cf_code/src/index.js:44-81` (join the `0 6 * * *` branch; `:77` = the known 404) |
| Worker paused-status branch (reused, unchanged) | `qr_cf_code/src/index.js:368` (`getPausedPage`) |
| Settings UI (the `mailto:` to replace) | `qr_frontend/src/components/org/settings/AccountSection.tsx:98-117` |
| New deletion UI | `qr_frontend/src/components/org/settings/delete-account-card.tsx` + `delete-account-dialog.tsx` (NEW) |
| New hook | `qr_frontend/src/hooks/useAccountDeletion.ts` (NEW) |
| Privacy policy (**must be amended**) | `qr_frontend/src/app/(marketing)/privacy/page.tsx:188-207`, `:228`, `:243` |
| Email | `qr_backend/src/utilities/email.py` (4 new templates) — ⚠️ `_dmarc` GA gate |
