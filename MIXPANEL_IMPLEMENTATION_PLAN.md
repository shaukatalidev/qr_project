# Grand Implementation Plan — Mixpanel Click Tracking (qr_frontend)

**Status:** Phases 0–3 implemented · **Phase 4a (consent gate) DEFERRED — see banner below** · Phase 4 (ops) pending · **Date:** 2026-06-14

> ### ⚠️ CURRENT STATE (updated 2026-06-14) — consent gate removed, do not flip the EU prod token
> Phases 0–3 (foundation, identity, click capture, CTA tags, outcome events) are **implemented in `qr_frontend`**. Phase 4a (CMP/Cookiebot consent gate) was built and then **deliberately removed** at the user's request — **no banner, no Cookiebot** for now. Today, Mixpanel is **token-gated only**: absent `NEXT_PUBLIC_MIXPANEL_TOKEN` ⇒ silent no-op; present ⇒ tracking runs for **everyone, with no consent prompt**.
>
> **This is fine while the prod token is unset** (nothing tracks). **It is NOT fine to enable the prod token for EU/EEA/UK traffic** until the consent gate is re-added — that would store `localStorage` + send device/IP data to Mixpanel without prior opt-in (ePrivacy Art. 5(3) / GDPR breach). **Phase 4a remains a hard prod blocker for EU.** Re-add it via the **"Re-add checklist"** in the Phase 4a section before any EU-facing prod-token flip. (Non-EU-only launch can proceed without it.)
**Provenance — this plan is the union of three sources:**
1. `MIXPANEL_TRACKING_PRD.md` — the approved design (*what & why*).
2. The `/plan-eng-review`-approved execution plan (`~/.claude/plans/majestic-herding-blossom.md`) — **7 architecture decisions** (A1/A2/A3/C1/C2/P1 + 5-file scope), verdict **ENG CLEARED**.
3. A fresh line-by-line **code verification** (2026-06-14) that corrected ~50 drifted `file:line` references and found 3 issues the earlier plan didn't have.

> **Precedence:** eng-review **decisions** (A*/C*/P*) are settled architecture — build to them. Where this plan's **verified** facts (V*) disagree with a PRD/eng-plan *file:line or field name*, the verified fact wins (re-checked today). Where they disagree on *intent*, the PRD/eng-review wins.

---

## 1. Settled architecture — the 7 eng-review decisions (build to these)

| # | Decision | Why |
|---|---|---|
| **Scope** | Keep the **5-file** `src/lib/analytics/` split (`mixpanel`, `index`, `click-capture`, `events`, `sanitize`). | Reviewed; user kept it. |
| **A1** | **Split the provider.** Root `MixpanelProvider` (in `providers.tsx`) does **init + global click-capture only** — no auth deps, runs on every page incl. marketing/auth. A child **`MixpanelIdentity`** mounted in **`src/app/org/layout.tsx`** does identify + super-props. | Stops `useMyProfile` (`useUsers.ts:41-50`, no `enabled`, `retry:2`) firing `GET /users/me` ×3 on public pages. |
| **A2** | **Broaden selector + track `onSelect`.** Capture selector also matches `role=menuitem/menuitemcheckbox/menuitemradio/switch/tab`; AND call `track()` inside Radix `onSelect` for high-value menu actions (Delete / View Details / Move-folder in `QRCodesTable.tsx`/`QRCard.tsx`). | Keyboard activation fires `onSelect`, not a DOM click — delegation alone misses it. |
| **A3** | **ID-Merge + `identify(user.id)` only. NO `alias()`.** Confirm ID Merge is enabled in the Mixpanel project; anonymous `/create` device-id events auto-link on identify. | `alias()` is a legacy footgun; ID-Merge stitches anon→known cleanly. (Supersedes PRD §13 Q5's alias suggestion.) |
| **C1** | **Reset only on true sign-out.** Fire `reset()` *only* on a logged-in→null transition (track `prevUserId` ref **or** subscribe to Supabase `SIGNED_OUT`). **Never** on the startup null tick. | `useUser.ts` resolves async — a startup reset mints a new device id before `identify()` and orphans anonymous→signup clicks (breaks A3). |
| **C2** | **Capture `element_text` only when tagged.** Read text only when `data-track-id` is present (curated static CTAs); suppress inside data rows / `data-track-private`. `track_id` carries the meaning. | Dynamic labels (QR names, folder/workspace names) must never reach Mixpanel. |
| **P1** | **Dynamic-import the SDK.** `const mixpanel = (await import('mixpanel-browser')).default` inside `initMixpanel` (already in a post-paint `useEffect`). | Keeps ~25–30 KB out of the shared bundle on LCP-critical marketing pages. |

**Architecture (revised):**
```
ROOT  src/app/providers.tsx  (inside QueryClientProvider)
  └ MixpanelProvider ── init (dynamic import P1) + attach capture-phase click listener
                         • ALL pages incl. marketing/auth (anonymous device id)
                         • init is TOKEN-GATED only today (no consent gate — Phase 4a deferred/removed); PROD-EU must re-add CONSENT gating before flipping the token
                         • reset() on true sign-out via auth-state listener (C1 — see V6)
                         • NO useMyProfile / useCurrentSubscription here (A1)

ORG SHELL  src/app/org/layout.tsx
  └ MixpanelIdentity ── identify(user.id) on true login (A3)
                        • setProfile($email,$name,$created)
                        • registerSuperProps(workspace_id, workspace_name, role, plan, plan_id, plan_status, billing_cycle)

CLICK → document capture-phase listener, closest(SELECTOR_WITH_ROLES) (A2)
        → extractClickProps: track_id · element_type · href/is_external
          · page_path (slug/UUID normalized) · page_section · data-track-* 
          · element_text ONLY if data-track-id present (C2)
        → track('Element Clicked', props)  [+ promote known track_id → named event]
RADIX MENU onSelect (Delete/View/Move) → track() at handler (A2)
OUTCOMES (source of truth, not the button): QR Created · Subscription Activated
```

---

## 2. Verified corrections from the 2026-06-14 code check (V*)

The architecture above is confirmed sound. These are factual code corrections layered on top — **treat all PRD/eng-plan line numbers as approximate; these are re-checked.**

| # | Earlier docs said | Verified reality | Action |
|---|---|---|---|
| **V1** | Button spreads props at `Button.tsx:61` | ✅ Spread at **`:66`**; `asChild` works (Radix `Slot.mergeProps` spreads `data-*` onto the cloned child) | **Architecture confirmed. Zero `Button.tsx` changes.** |
| **V2** | `QR Created` reads `{ qr_type, is_dynamic }` | Object has **`type`** + **`category:'dynamic'\|'static'`** (no `qr_type`, no boolean) | Derive `qr_type: newQR.type`, `is_dynamic: newQR.category==='dynamic'` |
| **V3** | `Subscription Activated` on `billing/success/page.tsx` mount, reading the sub | **Page has NO subscription data** — `useEffect:15` is animation-only, no `useCurrentSubscription`, no `subscription_id`, hardcodes "Razorpay" `:73` | **Primary = `useVerifySubscription.onSuccess` (V4).** Success-page path requires *adding* the hook first — see §Phase 3B |
| **V4** | `useVerifySubscription.onSuccess` at `useSubscription.ts:262` | Actually **`:286`** (`:262` is inside `useUpgradeSubscription`) | Instrument at `:286` |
| **V5** | `getPlanName` → `Free\|Starter\|Pro\|Agency` | Returns `plan_name` capitalized; grandfathered `lite`/`business` leak as `Lite`/`Business` | Normalization map in Phase 1 |
| **V6** | "hook reset into the logout handler" | **No shared handler** — 4 sites: `DashboardHeader.tsx:37`, `TeamManagement.tsx:89`, `DataPrivacyCard.tsx:32`, `api-client.ts:151`. And the `MixpanelIdentity` child (A1) **unmounts** when logout navigates away from `/org/*` | **Implement C1 via `supabase.auth.onAuthStateChange('SIGNED_OUT')` in the always-mounted ROOT provider** (cheap, no `GET /users/me`, A1-safe) rather than per-site patches or the org-only child. See §Phase 1 |
| **V7** | `builder_type_select` is a trackable tile | It's a **`<div onClick>`**, no `role="button"` → invisible to auto-capture | Add `data-track-id` (the listener's `[data-track-id]` branch then catches it) |
| **V8** | `billing_cancel` = one button | Two surfaces: **"Cancel Subscription"** `CurrentPlanCard.tsx:356` (initiate) + **"Confirm Cancel"** `:342` | Two track_ids: `billing_cancel_initiate` / `billing_cancel_confirm` |
| **V9** | Counts: Button 52, `<a>` 32, Link ~59 | Button **37**, `<a>` **15**, Link **62** files | Less surface; delegation still correct |
| **V10** | `nav_link`: 2 items | **4** (Features, QR Types, QR Generator, Pricing) via `map()` at `Header.tsx:8-13`/`:44-52` | One tagging strategy covers all 4 |
| **V11** | `ProBanner` CTA fine | **`href="/billing"` (no slug) → 404 confirmed** | **User chose SKIP** (out of analytics scope) — leave as-is, but it's a real bug worth a separate ticket |

**Also confirmed good:** greenfield (zero existing analytics); `env.ts` Zod-validated, exports `env`+`isProduction`; provider tree `QueryClientProvider→ConfirmProvider→CurrencyProvider` (Toaster sibling of CurrencyProvider); no shared link wrapper (delegation is the only path); `stopPropagation` in ~8 components is defeated by **capture-phase** listening; test infra = Vitest (happy-dom, co-located `__tests__/`) + Playwright (`e2e/`).

---

## 3. Files

**Create:** `src/lib/analytics/{mixpanel,index,events,sanitize,click-capture}.ts` (+ `__tests__/`), `src/components/providers/mixpanel-provider.tsx`, `src/components/providers/mixpanel-identity.tsx`.
**Modify:** `src/lib/env.ts`, `.env.example`, `src/app/providers.tsx` (root provider), `src/app/org/layout.tsx` (identity child), `src/hooks/useQRs.ts` (onSuccess ×2), `src/hooks/useSubscription.ts:286` (primary outcome), `QRCodesTable.tsx`+`QRCard.tsx` (onSelect, A2).
**Attribute-only (`data-track-id`):** the ~25 CTAs in §7 (verified table below).

---

## Phase 0 — Foundation & Safety (½–1 day) · Task T1

**Goal:** SDK wired, token-gated, dynamic-imported (P1), provably no-op when unconfigured.

1. Create Mixpanel **dev** + **prod** projects; **confirm ID-Merge is enabled** (A3). Dev token → `.env.local`; prod token deferred to Phase 4.
2. `npm i mixpanel-browser && npm i -D @types/mixpanel-browser` (neither present today).
3. **`src/lib/env.ts`** — two edits: add `NEXT_PUBLIC_MIXPANEL_TOKEN: z.string().optional().describe(...)` in `envSchema` (after `NEXT_PUBLIC_STRIPE_KEY`, before `NODE_ENV`); add `NEXT_PUBLIC_MIXPANEL_TOKEN: process.env.NEXT_PUBLIC_MIXPANEL_TOKEN` to the `.parse({...})` call (~`:47`). `isProduction` already exported (`:63`).
4. **`.env.example`** — append `NEXT_PUBLIC_MIXPANEL_TOKEN=` (blank → builds pass).
5. **`mixpanel.ts`** — safe singleton with **dynamic import (P1)**: `initMixpanel()` early-returns if already initialized / `window` undefined / token absent; otherwise `(await import('mixpanel-browser')).default.init(token, { track_pageview:false, autocapture:false, ignore_dnt:false, debug:!isProduction, persistence:'localStorage', api_host: <per Decision #2> })`.
6. **`index.ts`** — public API (`track/identify/setProfile/registerSuperProps/resetAnalytics`), **every export null-guarded + try/catch**; plain module (not a hook).
7. **`mixpanel-provider.tsx`** (root shell) — `'use client'`, `useEffect(() => { void initMixpanel() }, [])`, renders children; follow `currency-provider.tsx` conventions.
8. **`providers.tsx`** — insert between `QueryClientProvider` and `ConfirmProvider`, preserving the `<Toaster/>` position:
   ```tsx
   <QueryClientProvider client={queryClient}>
     <MixpanelProvider>
       <ConfirmProvider>
         <CurrencyProvider>{children}</CurrencyProvider>
         <Toaster />
       </ConfirmProvider>
     </MixpanelProvider>
   </QueryClientProvider>
   ```
9. Smoke: temporary `track('Debug Ping')` → confirm in dev Live View → remove.

**Acceptance:** builds/runs with token **absent** (no errors, no network) and **present** (ping in dev). SDK **not in the initial bundle** (`next build` analyze — P1 proof). `npm run lint` clean.

---

## Phase 1 — Identity & Context (1 day) · Tasks T2, T3

**Goal:** every event attributable; identity resets only on true sign-out.

**Verified source shapes:** `useUser()`→`{ user, loading, isLoggedIn }` (`user.id/email/created_at`); `useMyProfile()`→`{ data: profile }` (`profile?.full_name`); `useWorkspaceStore(s=>s.currentWorkspace)`→`{ id, workspace_name, workspace_slug, member_role }`; `useCurrentSubscription(workspaceId)`→`CurrentSubscription|null` (null=Free/404), fields `subscription_id, plan_id, plan_name, status, billing_cycle, provider`; `getPlanName(sub)` capitalizes `plan_name`.

1. **T2 — split providers (A1):** root `MixpanelProvider` keeps init + capture only. Create **`mixpanel-identity.tsx`** and mount it in **`src/app/org/layout.tsx`**. The identity child uses `useUser`/`useMyProfile`/`useWorkspaceStore`/`useCurrentSubscription`. *Verify:* no `GET /users/me` on `/` or `/pricing` (network tab).
2. **T3 — identity + super-props:**
   - `identify(user.id)` on login; `setProfile({ $email, $name: profile?.full_name, $created: user.created_at })`.
   - `registerSuperProps({ workspace_id, workspace_name, role: member_role, plan: <normalized>, plan_id, plan_status: status ?? 'none', billing_cycle: billing_cycle ?? null })` on `[currentWorkspace?.id, subscription?.plan_id, subscription?.status]`.
   - **Plan normalization (V5):** coerce `getPlanName` output to `Free|Starter|Pro|Agency` (map `Lite`/`Business`→nearest, or pass-through + document).
3. **Reset on true sign-out (C1 + V6):** put a `supabase.auth.onAuthStateChange` listener in the **root provider** (always mounted, survives logout navigation) and call `resetAnalytics()` on the `SIGNED_OUT` event only. This implements C1 without the org-only child's unmount gap and without patching the 4 scattered `signOut()` sites. (The `api-client.ts:151` 401 path also emits `SIGNED_OUT`, so it's covered.) Do **not** reset on the startup null tick.

**Acceptance:** login sets `distinct_id=user.id` + profile; workspace/plan switch updates super-props; **logout fires exactly one `reset`** (all paths); login-as-different-user shows no identity bleed. The **2 C1 regression tests** pass (no reset on startup null; exactly one reset on true sign-out).

---

## Phase 2 — Global Click Auto-Capture (1–2 days) · Task T4 — headline deliverable

**Goal:** every interactive element emits `Element Clicked`; broadened for Radix; PII-safe by tagging.

1. **`sanitize.ts`:** `normalizePath` (collapse slug/UUID → `/org/[slug]/qrs/[id]`), `normalizeText` (trim, ≤80, drop email/url-with-query/token), `isExternalHost`, `collectDataTrackProps`.
2. **`click-capture.ts`:** **broadened selector (A2)** `'a, button, [role="button"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="switch"], [role="tab"], [data-track-id]'`; capture-phase (`true`) `document` listener; `closest(SELECTOR)` → one el/click → `track('Element Clicked', extractClickProps(el))`. **`element_text` only when `data-track-id` present (C2).**
3. Attach in the **root** provider mount (`return attachClickCapture()`).
4. **Unit tests:** path/text normalization, PII scrub, external detection; `extractClickProps` over button / link / role-button / **menuitem (A2)**; **text captured only when tagged (C2)** — assert a QR-name row click carries no title.

**Document the limitation:** plain `<div onClick>` with neither role nor `data-track-id` (e.g. `QRTypeSelector` tile, V7) is captured only after Phase-3 tagging. Capture-phase guarantees clicks on `stopPropagation` elements are still seen.

**Acceptance:** clicks across marketing/auth/dashboard/builder produce `Element Clicked` with correct `element_type`, normalized `page_path`; **no PII** in any property (C2 proof). No INP regression. Zero errors token-present or absent.

---

## Phase 3 — Semantic Enrichment + Outcome Events (1–2 days) · Tasks T5, T6, T7, T8

### 3A — Tag priority CTAs (verified table — re-grep before editing; lines drifted 4–24)

| `track_id` | Verified location | Note |
|---|---|---|
| `hero_signup_cta` | `landing/Hero.tsx:52` | "Start Building Free" |
| `nav_signup_cta` | `layout/Header.tsx:71` (+mobile `:123`) | tag both |
| `nav_login` | `layout/Header.tsx:61` (+mobile `:116`) | tag both |
| `nav_link` | `Header.tsx:44-52` (map, **4 items**, V10) | add `data-track-id`+`data-track-label` in map |
| `cta_banner_signup` | `landing/CTABanner.tsx:36` | |
| `pricing_select_{plan}` | `pricing/PricingCards.tsx:321-348` | plan id in `data-track-plan`, not text |
| `pricing_cta_signup` | `pricing/PricingCTA.tsx:71` | "Start Free — No Card Required" |
| `public_save_to_account` | `marketing/PublicQRBuilder.tsx:206` (+modal `:275`) | distinguish via `data-track-context` |
| `signup_submit` | `signup/SignupClient.tsx:286` (text `:297`) | tag the `<Button type=submit>` not the `:162` heading |
| `signup_google` | `signup/SignupClient.tsx:169` | ✅ exact |
| `login_submit` | `login/LoginClient.tsx:233` | |
| `login_google` | `login/LoginClient.tsx:130` | ✅ exact |
| `sidebar_create_qr` | `org/Sidebar.tsx:72` (text `:86`) | tag the `<Link>` |
| `builder_type_select` | `qr-generator/QRTypeSelector.tsx:194` | **`<div onClick>`** — add `data-track-id`+`data-track-type` (V7) |
| `builder_back`/`builder_next` | `NavButton.tsx:31` / `:80` | |
| `builder_complete_download` | `NavButton.tsx:48` (text `:67`) | |
| `builder_download_{format}` | `DownloadOptions.tsx:91` + map `:102` | `data-track-format` |
| `qr_copy_link` | `details/details-header.tsx:122` | dynamic + has short link only |
| `qr_delete` | `details/danger-zone.tsx:41` | |
| `billing_select_{plan}` | `billing/BillingPlans.tsx:320` (text `:344`) | `data-track-plan`; actionable only `!isFree && !isCurrentPlan` |
| `billing_cycle_toggle` | `billing/BillingPlans.tsx:588` (map) | `data-track-cycle` |
| `billing_cancel_initiate` | `billing/CurrentPlanCard.tsx:356` | V8 split |
| `billing_cancel_confirm` | `billing/CurrentPlanCard.tsx:342` | V8 split |
| `billing_resume_payment` | `billing/CurrentPlanCard.tsx:204` | `status==='created'` only |
| `sidebar_upgrade` | `org/UsageTracker.tsx:104` + `:165` | tag both |
| `upsell_password_upgrade` | `details/password-protection-card.tsx:48` | |
| `upsell_ab_upgrade` | `details/ab-testing-card.tsx:56` | |
| `dashboard_pro_banner` | `dashboard/ProBanner.tsx:21` | tag only; **routing bug V11 deferred per user** |
| `invite_send` | `users/InviteUserModal.tsx:240` (text `:249`) | `data-track-role` |
| `invite_copy_link` | `users/InviteUserModal.tsx:122` (text `:129`) | |

Add `data-track-section` to hero, pricing grid, billing plans, builder steps.

### 3B — Outcome events (corrected)
- **`QR Created`** — `useQRs.ts`: `useCreateQR.onSuccess` (**`:94`**) `track('QR Created', { qr_id: newQR.id, qr_type: newQR.type, is_dynamic: newQR.category==='dynamic', source:'builder' })` (V2); `useBulkCreateQR.onSuccess` (**`:142`**) fire once with `{ count, qr_type: newQRs[0]?.type ?? null, is_dynamic: newQRs[0]?.category==='dynamic', source:'bulk' }`.
- **`Subscription Activated`** — **primary = `useSubscription.ts:286` `useVerifySubscription.onSuccess`** (V3/V4): `track('Subscription Activated', { plan: getPlanName(sub), plan_id, billing_cycle, provider })`. *If* the success-page signal is also wanted: first add `useCurrentSubscription` (resolve `workspaceId` from `useWorkspaceStore`) + fix the hardcoded "Razorpay" copy (`:73`), then a `useEffect([sub?.subscription_id])` guarded by a `sessionStorage` flag keyed on `subscription_id` (StrictMode double-mount safe). Never fire from `billing_select_*`.

### 3C — onSelect (A2) + promotion map
- **T5:** `track()` in Radix `onSelect` for menu actions in `QRCodesTable.tsx`/`QRCard.tsx` (Delete/View/Move) — mouse + keyboard both tracked.
- **T7:** `events.ts` promotion map (`signup_submit→'Signup Submitted'`, `billing_select_*→'Upgrade Clicked'`, `builder_download_*→'QR Downloaded'`, …) firing the named event alongside `Element Clicked`.
- **T8:** confirm ID-Merge (A3); E2E anon `/create`→signup stitch.

**Acceptance:** each CTA fires a stable `track_id`; menu actions tracked via mouse+keyboard; `QR Created` once per real creation (correct derived fields); `Subscription Activated` once post-checkout; full `Landing → Signup → QR Created → Upgrade Clicked → Subscription Activated` funnel buildable.

---

## Phase 4a — Consent Gate (CMP) (½–1 day) · Task T10 — ⏸️ **DEFERRED (removed 2026-06-14); prod blocker for EU; gates the token flip**

> ### 🔁 DEFERRED — built, then removed by user request (2026-06-14)
> The Cookiebot consent gate was fully implemented and then **reverted** — the user does **not** want a cookie banner or Cookiebot right now. Mixpanel is currently **token-gated only** (no consent prompt; runs for everyone once a token is set). **Re-add this entire phase before enabling the prod token for any EU/EEA/UK traffic.**
>
> **Why it's safe to defer:** with no prod token set, nothing tracks at all. **Why it's still mandatory before EU prod:** Mixpanel uses `persistence:'localStorage'` + sends device-id/IP, so EU law requires *prior* opt-in. A non-EU-only launch can ship without it.
>
> #### Re-add checklist — the exact reverted changes (do all; nothing else was touched)
> The earlier implementation was clean and these are the precise files to restore. The Mixpanel side is unchanged from how it was built, so re-adding is mechanical:
>
> 1. **`src/lib/env.ts`** — re-add the optional `NEXT_PUBLIC_COOKIEBOT_CBID` zod field to the schema **and** to the `envSchema.parse({…})` object. (`NEXT_PUBLIC_MIXPANEL_API_HOST` for residency was **kept** — already present.)
> 2. **`.env.example`** — re-add the `NEXT_PUBLIC_COOKIEBOT_CBID=` line (with comment).
> 3. **Recreate `src/lib/analytics/consent.ts`** — Cookiebot adapter: `isConsentManaged()` (CBID set?), `hasAnalyticsConsent()` (`window.Cookiebot.consent.statistics`), `onConsentChange(cb)` (subscribe to `CookiebotOnAccept`/`CookiebotOnDecline`/`CookiebotOnConsentReady`, returns detach), `openConsentSettings()` (`window.Cookiebot.renew()`), plus the `window.Cookiebot` global type. *(If switching CMP vendors, this is the only file whose internals change — keep the four function signatures identical so nothing else needs editing.)*
> 4. **`src/components/providers/mixpanel-provider.tsx`** — replace the unconditional `void initMixpanel()` in the mount effect with the consent-gated block: if `isConsentManaged()` → `applyConsent()` (grant ⇒ `void initMixpanel()`, else `optOutMixpanel()`) immediately + `detachConsent = onConsentChange(applyConsent)`; else fall back to `void initMixpanel()`. Re-import `optOutMixpanel` from `@/lib/analytics` and `{ hasAnalyticsConsent, isConsentManaged, onConsentChange }` from `@/lib/analytics/consent`; call `detachConsent()` in cleanup. **Keep** the C1 `SIGNED_OUT` reset listener (untouched). *(`optOutMixpanel()` is still exported from `mixpanel.ts`/`index.ts` — no need to recreate it.)*
> 5. **`src/app/layout.tsx`** — re-add `import Script from 'next/script'` and `import { env } from '@/lib/env'`, and the conditional Cookiebot loader at the top of `<head>`: `{env.NEXT_PUBLIC_COOKIEBOT_CBID && <Script id="Cookiebot" src="https://consent.cookiebot.com/uc.js" data-cbid={…} data-blockingmode="auto" strategy="beforeInteractive" />}`.
> 6. **Recreate `src/components/marketing/CookieSettingsButton.tsx`** — `'use client'` Button calling `openConsentSettings`, `data-track-id="cookie_settings_open"`.
> 7. **`src/app/(marketing)/cookies/page.tsx`** — (a) re-import `isConsentManaged` + `CookieSettingsButton`; (b) restore the `{isConsentManaged() && (…)}` withdraw-consent block in "How to Manage Cookies" (currently replaced by a token-gated DNT paragraph); (c) restore the Mixpanel table row's consent wording ("With your consent to statistics cookies…" / duration "Until cleared or consent is withdrawn") — it's presently reworded to DNT language. **Keep** the `env.NEXT_PUBLIC_MIXPANEL_TOKEN` gate on the row (added 2026-06-14 so the row only shows when Mixpanel is actually live).
> 8. **Tests** — recreate `src/lib/analytics/__tests__/consent.test.ts` (5 cases: not-managed w/o CBID, `hasAnalyticsConsent` reflects `window.Cookiebot`, `onConsentChange` subscribe/detach, `openConsentSettings` calls `renew` + safe no-op when absent) and re-add the 4 consent cases to `src/components/providers/__tests__/mixpanel-provider.test.tsx` (granted⇒init, denied⇒optOut, later-grant-via-event⇒init, detach-on-unmount) with their `vi.hoisted` mocks for `@/lib/analytics/consent` + `optOutMixpanel`.
>
> Everything below is the original, still-valid plan (CMP choice, steps, acceptance). Cookiebot is the assumed vendor for the checklist above; swap in step 3 only if you change vendors.

**Decision (settled):** use a **Consent Management Platform**, not a self-built banner. For EU/EEA/UK visitors, Mixpanel must **not load, init, or write localStorage** until they opt in to the analytics/statistics category. (Legal basis: ePrivacy Art. 5(3) prior consent for device storage — Mixpanel uses `persistence:'localStorage'`; GDPR consent for IP/device-id/`distinct_id`. Consent must be prior, opt-in, granular, informed, freely given with Reject as prominent as Accept, withdrawable, and logged.)

**Pick a CMP.** Criteria: category- or IAB-TCF-based **consent API + change event**, automatic **geo-detection** (EU opt-in / configurable elsewhere), **consent-log storage** (your legal proof), customizable Reject-equal-to-Accept UI, and a withdrawal widget. Viable: **Cookiebot, CookieYes, iubenda, Usercentrics, OneTrust, Termly**.

**Recommendation for Qravio's profile** (India-first / Razorpay-₹ + premium $ ROW tier, likely modest-but-real EU/UK traffic, want turnkey compliance + consent logging at low cost) — *advisory; override as you see fit:*
- **Primary: Cookiebot (by Usercentrics).** Best balance — rigorous GDPR/UK-GDPR + IAB TCF v2.2, automatic cookie scanning, clean `CookiebotOnAccept`/`CookiebotOnDecline` events + `window.Cookiebot.consent.statistics` to gate the dynamic-import init, built-in consent logging, and a free tier for small sites. Simple `next/script` load.
- **Alt (bundles policy docs): iubenda.** Choose if you want Cookie/Privacy *policy generation* + consent DB in one tool alongside your existing `/cookies` + Privacy pages; pay-as-you-grow.
- **Budget: CookieYes.** Cheapest usable free tier; lighter TCF rigor — fine if EU volume stays low.
- **Skip for now:** OneTrust / Usercentrics-enterprise (cost/overkill at current scale).

> **Critical integration note:** Mixpanel here is an **npm module dynamically imported (P1)**, *not* a `<script>` tag — so the CMP's automatic **script-tag blocking will NOT catch it**. You **must** gate via the CMP's **consent API/callback**, not rely on auto-blocking.

**Steps**
1. **Install the CMP** per its Next.js guide — load its loader script in `app/layout.tsx` `<head>` (ahead of app JS so the banner gates before any tracking). Configure: EU/EEA/UK = opt-in; register a custom "Mixpanel / analytics" cookie+localStorage item under the **Statistics/Analytics** category.
2. **Gate `initMixpanel()` on the analytics-consent signal** (replaces the unconditional mount-init in the root `MixpanelProvider`):
   - On load, read the CMP's current analytics-category state; if granted (or the CMP marks the region as not-consent-required) → `void initMixpanel()`.
   - Subscribe to the CMP's consent-change event and react:
     - **grant** → `void initMixpanel()`
     - **revoke** → `getClient()?.opt_out_tracking()` + `resetAnalytics()`
   - Vendor event hooks (use whichever CMP you pick): Cookiebot `window.addEventListener('CookiebotOnAccept', …)` + `window.Cookiebot.consent.statistics`; Usercentrics `onConsentUpdated` / `window.UC_UI`; OneTrust `OptanonWrapper` + `OnConsentChanged` / `OnetrustActiveGroups`; iubenda callback API.
   - The **click listener still attaches on mount** (it no-ops until init) — so nothing leaks pre-consent.
3. **Withdrawal:** add the CMP's "Cookie settings" link to the footer + the `/cookies` page; revocation flows through the same subscribe handler in step 2.
4. **Residency (Decision #2):** set `api_host` in `initMixpanel()` (`https://api-eu.mixpanel.com` if EU project). Consent ≠ residency — both are required.
5. **Copy:** update `app/(marketing)/cookies` + Privacy page to name **Mixpanel as a processor** and disclose the analytics category.
6. **Consent logging:** confirm the CMP retains consent records (your audit proof) — no extra work if it does; that's a core reason for choosing CMP over self-built.

**Acceptance:** From an EU IP/VPN — **no Mixpanel network calls, no Mixpanel localStorage, SDK bundle not fetched** until *Accept*; after Accept → events flow with identity; after Reject/withdraw → `opt_out_tracking()` fires, no further events, Mixpanel storage cleared. From a non-EU IP — tracking per the chosen non-EU posture. Banner shows **equal-prominence Accept/Reject** and the CMP logs consent.

---

## Phase 4 — Governance, QA & Rollout (1 day) · Task T9 — **gated by Phase 4a (consent + residency)**

1. **Pre-req: Phase 4a complete** (consent gate live + `api_host` set + policy copy updated). Do not flip the prod token before this.
2. **Lexicon** — document §6–7 taxonomy; mark `track_id` as source of truth.
3. **Cross-check** — optionally enable Autocapture in **dev project only** ~1 day, diff vs custom capture (catches div-onClick stragglers), then disable.
4. **Dashboards** — Acquisition / Activation / Monetization / Top elements by `track_id`.
5. **QA** — `/qa` across signup→builder→download→upgrade; verify identity+super-props on real events; Playwright E2E (fake token + stubbed endpoint) asserting `track_id` sequence; no-op test (unset token → zero network/console).
6. **Flip prod token** (Vercel Production only) → 48h `/canary`-style watch. Kill switch = remove the env var.

**Acceptance:** prod project receiving attributed events; dashboards populated; zero tracking-related runtime errors over the watch window.

---

## 4. Decisions required (gate Phase 4 only — Phases 0–3 proceed on dev today)
1. **Consent gating (EU)** — ✅ **DECIDED (2026-06-14): use a CMP** (not self-built). EU/EEA/UK = opt-in; Mixpanel does not load until consent. Implemented in **Phase 4a**. Remaining sub-pick: *which* CMP vendor (see Phase 4a).
2. **Data residency** — US vs EU project (`api_host`). *Default: EU if any EU traffic.* **Prod blocker** (set in Phase 4a step 4).
3. (Settled by A3: **no alias**, ID-Merge stitches the anon `/create` funnel.)

## 5. Tests (write alongside code)
- **CRITICAL (C1):** `reset()` NOT on startup null tick; `reset()` exactly once on true sign-out.
- `sanitize`: path slug/UUID collapse; text cap-80 + email/url/token drop; external host.
- `extractClickProps`: button/link/role-button/**menuitem (A2)**; **text only when tagged (C2)**; `data-track-*`; href/is_external.
- `index`: every fn no-ops when client null; `track` swallows throws; `initMixpanel` idempotent + no-op without token; **dynamic-import-failure no-op (P1)**.
- Outcome: `Subscription Activated` once per `subscription_id`; `QR Created` once per success.
- **E2E:** anon `/create`→signup ID-merge stitch; full funnel.
- **Consent (Phase 4a):** EU-region session with consent denied → `initMixpanel()` never runs (no SDK fetch, no network, no Mixpanel localStorage); grant → init fires once; revoke → `opt_out_tracking()` + `reset()` fire and events stop.

## 6. Verification gates
1. `build`+`lint` clean token absent (zero events) and present (debug ping). SDK not in initial bundle (P1).
2. No `GET /users/me` on `/` and `/pricing` (A1 proof).
3. Live View: button/link/menuitem → `Element Clicked`, normalized `page_path`, **no PII** in `element_text` (C2 — click a QR-name row, title absent).
4. Login → identify+super-props; logout → exactly one `reset`; re-login + anon→signup attributed (A3+C1).
5. `npm test` + `npm run test:e2e` green incl. the 2 C1 regression tests.
6. **Consent (Phase 4a):** EU IP/VPN with no consent → zero Mixpanel network/localStorage + SDK not fetched; Accept → events flow; Reject/withdraw → `opt_out_tracking()` + storage cleared.

## 7. Task DAG & parallelization
- **Lane A (sequential, touch analytics module/providers):** T1 → T2 → T3 → T4.
- **Lane B (parallel after T1 freezes the `data-track-*` convention):** T6 attribute sprinkles across ~25 CTA files (emit once T4 is live).
- T5 (onSelect) + T7 (outcomes/promotion) depend on T4; T8 (ID-Merge) is config, independent.
- **T10 (consent gate, Phase 4a)** modifies the root provider's init effect (depends on T2); CMP account/config is independent and can be procured anytime. **T10 must complete before T9's prod-token flip.** T9 last.
- **Conflict flag:** Lane B touches `QRCodesTable.tsx` which T5 also edits — coordinate that file.

## 8. Out of scope (deferred, with rationale)
- **Server-side `Subscription Activated`** webhook — FE event sufficient for v1; revenue-accurate version is a separate `qr_backend` ticket. *(User: Skip.)*
- **`ProBanner.tsx:21` `/billing` routing bug (V11, confirmed real 404)** — unrelated to analytics. *(User: Skip; tag for tracking only.)*
- Page-view/route-change (Vercel covers it), backend events, scan analytics, session replay, form-field tracking, Autocapture-as-prod-mechanism.

## 9. Effort
Phases 0–4 + 4a ≈ **5.5–8 working days**, one engineer (T1–T9 ≈ ~19h human / ~2.5h CC per eng-review; + **T10 CMP consent gate ≈ ~0.5–1 day** incl. vendor setup; V9's lower file counts trim Phase 3A slightly). Phases 0–2 unblock today on the dev project. Decision #1 is settled (CMP); only the **CMP vendor pick** and **Decision #2 (residency)** remain before Phase 4a, which in turn gates the prod-token flip in Phase 4.

---
*ENG CLEARED. Authoritative for execution: build to the A*/C*/P* decisions; use the V* corrected file:line references (verified 2026-06-14).*
