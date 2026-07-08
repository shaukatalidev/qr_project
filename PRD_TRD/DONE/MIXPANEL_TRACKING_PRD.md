# PRD — Mixpanel Click Tracking for Qravio Frontend

**Status:** Draft · **Author:** Engineering · **Date:** 2026-06-14
**Scope:** `qr_frontend` (Next.js 14 App Router) only
**Objective:** Instrument **every link click and button click** across the app with Mixpanel, attributed to the right user / workspace / plan, with a clean event taxonomy and a phased, low-risk rollout.

---

## 1. Background & Problem

The frontend currently ships **no product analytics**. The only telemetry is `@vercel/analytics` (`<Analytics/>` in `src/app/layout.tsx:82`) and `@vercel/speed-insights` — both are passive page-view/perf beacons. There are **zero** `track()` calls, no Mixpanel/PostHog/Segment/GA, and no event taxonomy anywhere in `src/`.

Consequences today:
- We cannot answer basic funnel questions: How many landing visitors click "Start Free"? What % of signups create a QR? Which upgrade CTA converts?
- We cannot segment behavior by **plan** (Free/Starter/Pro/Agency), **role** (owner/editor/viewer), or **workspace**.
- We have no data to inform pricing, builder UX, or growth decisions.

**This PRD covers the narrow, high-leverage first step the team asked for: tracking _all_ link and button clicks** — not pageview-heavy instrumentation, not server-side events, not scan analytics (which already exists in the Worker). Clicks are the highest-signal, lowest-effort user-intent events, and capturing them comprehensively unlocks funnel and engagement analysis immediately.

---

## 2. Goals & Non-Goals

### 2.1 Goals
1. **Capture 100% of meaningful clicks** — every `<button>`, every `next/link` `<Link>`, every `<a>`, and every `role="button"` element — with one resilient mechanism, not 200 hand-edited call sites.
2. **Attribute every click** to a stable identity (`distinct_id` = Supabase user UUID) and enrich with **super-properties**: `workspace_id`, `plan`, `role`, `billing_cycle`.
3. **Clean semantic naming** for the ~20 highest-value CTAs (signup, login, create-QR, download, upgrade, delete, invite) layered on top of raw capture, so we can build funnels without parsing noisy DOM text.
4. **Zero-friction adoption** — instrumenting a new important button must be a one-line `data-track-id="..."` attribute, never a refactor.
5. **Privacy-safe** — no PII, passwords, tokens, or QR payloads ever leave the client in event properties.
6. **Safe-by-default** — if the Mixpanel token is absent (local dev, preview), tracking is a silent no-op; it must never break the app or throw.
7. **Two bounded outcome events** — beyond clicks, fire exactly **`QR Created`** and **`Subscription Activated`** so funnels measure *outcomes*, not just intent (see §6.8). This is the single, deliberate, explicitly-bounded exception to "clicks only" — a click tells us a user *tried*; the outcome tells us they *succeeded*, and a funnel needs both ends.

### 2.2 Non-Goals (explicitly out of scope for this initiative)
- ❌ Page-view / route-change tracking as a primary deliverable (covered passively by Vercel; may be added later).
- ❌ Server-side / backend event tracking (FastAPI). Frontend only.
- ❌ QR **scan** analytics — already handled by the Cloudflare Worker (`recordScan`) and the backend analytics tables.
- ❌ Session replay, heatmaps, A/B experiment assignment.
- ❌ Form-field-level input tracking (only the **submit button click** is in scope).
- ❌ Reworking any existing UI. Tracking is additive and invisible to users.

---

## 3. Success Metrics

| Metric | Target |
|---|---|
| **Coverage** — clickable elements emitting a tracked event | ≥ 95% of `<button>`/`<a>`/`<Link>` in authenticated + marketing surfaces |
| **Identity rate** — events from logged-in users carrying a real `distinct_id` (not anonymous) | ≥ 99% |
| **Named-event coverage** — clicks on priority CTAs carrying a clean `track_id` | 100% of the Phase 3 list |
| **Funnel readiness** — ability to build `Landing → Signup → QR Created → Upgrade` funnel in Mixpanel | Yes, end of Phase 3 |
| **Performance** — added main-thread blocking time | < 5 ms per click; SDK loaded async, no LCP/INP regression |
| **Reliability** — runtime errors caused by tracking | 0 |

---

## 4. Current-State Analysis (verified against the codebase)

| Area | Finding | Implication for design |
|---|---|---|
| **Root layout** | `src/app/layout.tsx:61` wraps children in `<Providers>`, mounts `<Analytics/>`+`<SpeedInsights/>` as siblings | New provider goes inside `Providers`, not in layout |
| **Provider tree** | `src/app/providers.tsx` — `QueryClientProvider` → `ConfirmProvider` → `CurrencyProvider` (`'use client'`) | Insert `MixpanelProvider` inside `QueryClientProvider` so it can use Query hooks |
| **Button primitive** | `src/components/ui/Button.tsx` — `forwardRef`, **spreads `...props` onto the root DOM node** (line 61), supports `asChild`/Slot | ✅ `data-track-*` attributes flow to the DOM with **zero changes to Button.tsx**. A global delegated listener can read them. |
| **Button usage** | 52 files import it (via `@/components/ui/Button` and barrel `@/components/ui`) | Per-call-site editing is infeasible → favor delegation |
| **Links** | `next/link` used in 59 files (~35 `<Link>`), raw `<a>` in 32 files. **No shared `NavLink`/CTA wrapper.** `Header.tsx` uses raw `<Link>` for all nav CTAs | A per-link wrapper would require touching 90+ files → delegation is the right call |
| **Env config** | `src/lib/env.ts` — Zod-validated, parsed at import. `NEXT_PUBLIC_*` consumed via `env.*` | Add `NEXT_PUBLIC_MIXPANEL_TOKEN` (optional) here + `.env.example` |
| **Identity** | `useUser()` (`src/hooks/useUser.ts`) → Supabase `User` (`id`, `email`, `created_at`). `useMyProfile()` (`src/hooks/useUsers.ts`) → `full_name`. **`user.id` (Supabase UUID) is the stable cross-session id and matches backend `user_id`.** | `distinct_id = user.id` |
| **Workspace** | `src/store/workspaceStore.ts` (Zustand) → `currentWorkspace { id, workspace_name, workspace_slug, member_role }`. No plan field. | super-props: `workspace_id`, `workspace_name`, `role` |
| **Plan/tier** | Only via `useCurrentSubscription(workspaceId)` (`src/hooks/useSubscription.ts`). `getPlanName(sub)` (`src/lib/plan-features.ts`) normalizes to `Free/Starter/Pro/Agency`. Canonical ids `free/starter/pro/agency` in `src/lib/constants/pricing.ts`. Returns `null` for Free tier. | super-props: `plan`, `plan_id`, `plan_status`, `billing_cycle` — null-safe |
| **Existing analytics** | None. No `track()` anywhere. | Greenfield; no migration needed |

**Architectural takeaway:** Because `Button` spreads `...props` to the DOM and there is **no link-wrapper abstraction**, the only sane way to "track all links and buttons" is a **single global delegated click listener** + a **`data-track-*` attribute convention** for enrichment — *not* editing each call site.

---

## 5. Proposed Architecture

### 5.1 The core decision: how do we capture "all clicks"?

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **A. Mixpanel Autocapture** (`autocapture: true` in init) | Zero code per element; captures all clicks/inputs/submits | Noisy; captures element text/values (PII risk); high-cardinality; opaque event names; harder to govern; couples us to Mixpanel internals | ❌ Not as primary |
| **B. Per-element instrumentation** (`onClick={track(...)}` everywhere, or a `<TrackedLink>`/Button prop) | Precise, clean names | Requires editing 90+ files; new buttons silently untracked; violates "no refactor" goal | ❌ |
| **C. Custom global delegated listener + `data-track-*` enrichment** ✅ | One listener catches every bubble-phase click; full control over property shape & PII scrubbing; new elements auto-covered; clean names via opt-in `data-track-id` | We write the extraction logic (~120 LOC) | ✅ **Recommended** |

**Recommendation: Option C** — a single `document`-level click listener registered in `MixpanelProvider`, firing a canonical **`Element Clicked`** event for every clickable element, enriched by optional `data-track-*` attributes for the CTAs that matter. This is the industry-standard "track everything, name what matters" pattern and fits this codebase's constraints exactly.

> Mixpanel **Autocapture (Option A)** can optionally be enabled **in the dev project only** during Phase 4 as a cross-check to confirm our custom listener isn't missing clicks — but it will not be the production mechanism.

### 5.2 System diagram

```
                         ┌─────────────────────────────────────────┐
                         │  src/app/providers.tsx                    │
                         │  QueryClientProvider                      │
                         │   └─ MixpanelProvider  ◄── NEW            │
                         │       ├─ mixpanel.init() (once)           │
                         │       ├─ identify + super-props (effects) │
                         │       ├─ reset() on logout                │
                         │       └─ document click listener (capture)│
                         │   └─ ConfirmProvider → CurrencyProvider   │
                         └─────────────────────────────────────────┘
                                          │
   any <button>/<a>/<Link>/[role=button] click bubbles to document
                                          │
                                          ▼
            extractClickProps(target)  ──►  analytics.track('Element Clicked', props)
                                          │
          reads: data-track-id, data-track-*, text, href, page, section
                                          │
                                          ▼
                                  Mixpanel (dev | prod project)
```

### 5.3 Module layout (new files)

```
src/lib/analytics/
  index.ts            # public API: init, identify, reset, track, register
  mixpanel.ts         # SDK init + safe no-op guard + token from env
  click-capture.ts    # extractClickProps() + global listener attach/detach
  events.ts           # canonical event-name constants + TS prop types
  sanitize.ts         # PII scrubbing + path/text normalization helpers
src/components/providers/
  mixpanel-provider.tsx   # 'use client' — wires init/identify/listener
```

`src/lib/env.ts` — add `NEXT_PUBLIC_MIXPANEL_TOKEN`.
`.env.example` / `.env` — add the token var.

---

## 6. Technical Design

### 6.1 Environment & config

Add to `src/lib/env.ts` `envSchema` (optional so builds never fail without it):

```ts
// Optional: Mixpanel
NEXT_PUBLIC_MIXPANEL_TOKEN: z
  .string()
  .optional()
  .describe('Mixpanel project token (client-side). Absent = tracking disabled.'),
```
…and add `NEXT_PUBLIC_MIXPANEL_TOKEN: process.env.NEXT_PUBLIC_MIXPANEL_TOKEN` to the `envSchema.parse({...})` call. Add `NEXT_PUBLIC_MIXPANEL_TOKEN=` to `.env.example`.

**Two projects:** use distinct tokens for **dev/preview** and **production** so test traffic never pollutes prod data. Vercel: set the prod token only on the Production environment; leave dev/preview pointed at the dev project (or unset → no-op).

### 6.2 `analytics/mixpanel.ts` — safe singleton

```ts
import mixpanel, { type Mixpanel } from 'mixpanel-browser';
import { env, isProduction } from '@/lib/env';

let client: Mixpanel | null = null;

export function initMixpanel(): void {
  if (client || typeof window === 'undefined') return;
  const token = env.NEXT_PUBLIC_MIXPANEL_TOKEN;
  if (!token) return; // no-op when unconfigured
  mixpanel.init(token, {
    debug: !isProduction,
    persistence: 'localStorage',
    track_pageview: false,          // out of scope — clicks only
    ignore_dnt: false,              // respect Do-Not-Track
    api_host: 'https://api-eu.mixpanel.com', // if EU residency required (decide in §11)
    autocapture: false,             // we use our own delegated listener
  });
  client = mixpanel;
}

export function getClient(): Mixpanel | null {
  return client;
}
```

### 6.3 `analytics/index.ts` — public API (every call null-guarded)

```ts
export function track(event: string, props?: Record<string, unknown>): void {
  const mp = getClient();
  if (!mp) return;
  try { mp.track(event, sanitizeProps(props)); } catch { /* never throw */ }
}

export function identify(userId: string): void { /* getClient()?.identify(userId) */ }

export function setProfile(props: Record<string, unknown>): void {
  /* getClient()?.people.set(sanitizeProps(props)) */
}

export function registerSuperProps(props: Record<string, unknown>): void {
  /* getClient()?.register(sanitizeProps(props)) */
}

export function resetAnalytics(): void { getClient()?.reset(); } // on logout
```

Design rules:
- **Every export is a no-op if the SDK is uninitialized.** Components can call `track()` unconditionally.
- **Plain module, not a hook** — callable from form handlers, mutation callbacks, and the global listener alike.
- **Wrapped in try/catch** — analytics must never crash the app.

### 6.4 Global click capture — `analytics/click-capture.ts`

A single listener in the **capture or bubble phase** on `document`. For each click, walk up from `event.target` to the nearest "interactive" element and emit one event.

```ts
const INTERACTIVE = 'a, button, [role="button"], [data-track-id]';

export function attachClickCapture(): () => void {
  const handler = (e: MouseEvent) => {
    const el = (e.target as HTMLElement | null)?.closest<HTMLElement>(INTERACTIVE);
    if (!el) return;
    track('Element Clicked', extractClickProps(el));
  };
  document.addEventListener('click', handler, true); // capture phase: fires before nav
  return () => document.removeEventListener('click', handler, true);
}
```

`extractClickProps(el)` returns a normalized, PII-safe shape:

```ts
{
  // identity of the element
  element_type: 'button' | 'link' | 'role-button',
  track_id:      el.dataset.trackId ?? null,        // clean name when present
  element_text:  normalizeText(el.innerText),        // trimmed, ≤80 chars, PII-scrubbed
  // link specifics
  href:          isLink ? el.getAttribute('href') : null,
  is_external:   isLink ? isExternalHost(href) : null,
  // page context (low-cardinality)
  page_path:     normalizePath(location.pathname),   // /org/[slug]/qrs/[id]
  page_section:  el.closest('[data-track-section]')?.dataset.trackSection ?? null,
  // any extra data-track-* attributes, namespaced
  ...collectDataTrackProps(el),                       // data-track-plan="pro" -> { plan: 'pro' }
}
```

Key safeguards in `sanitize.ts`:
- **`normalizePath`** collapses workspace slugs and UUIDs: `/org/acme/qrs/3f2a…` → `/org/[slug]/qrs/[id]`. Prevents cardinality explosion and leaks of workspace names.
- **`normalizeText`** trims, caps at 80 chars, and **drops** text that looks like an email, URL with query string, or long token. Inputs/passwords are never read (we only read `innerText` of buttons/links, never field values).
- Capture phase (`true`) ensures the event fires even when the click triggers a `<Link>` navigation that unmounts the page.

### 6.5 Identity & super-properties — `mixpanel-provider.tsx`

```tsx
'use client';
export function MixpanelProvider({ children }: { children: ReactNode }) {
  const { user } = useUser();                         // Supabase user (id, email, created_at)
  const { data: profile } = useMyProfile();           // full_name
  const currentWorkspace = useWorkspaceStore(s => s.currentWorkspace);
  const { data: subscription } = useCurrentSubscription(currentWorkspace?.id);

  // 1. init once + attach global click listener
  useEffect(() => { initMixpanel(); return attachClickCapture(); }, []);

  // 2. identify + profile when user resolves
  useEffect(() => {
    if (!user) { resetAnalytics(); return; }          // logout / anon
    identify(user.id);
    setProfile({
      $email: user.email,
      $name: profile?.full_name ?? undefined,
      $created: user.created_at,
    });
  }, [user?.id, profile?.full_name]);

  // 3. workspace + plan super-properties (attached to EVERY event)
  useEffect(() => {
    registerSuperProps({
      workspace_id: currentWorkspace?.id ?? null,
      workspace_name: currentWorkspace?.workspace_name ?? null,
      role: currentWorkspace?.member_role ?? null,
      plan: getPlanName(subscription ?? null),         // 'Free' | 'Starter' | 'Pro' | 'Agency'
      plan_id: subscription?.plan_id ?? 'free',
      plan_status: subscription?.status ?? 'none',
      billing_cycle: subscription?.billing_cycle ?? null,
    });
  }, [currentWorkspace?.id, subscription?.plan_id, subscription?.status]);

  return <>{children}</>;
}
```

Mounted in `src/app/providers.tsx` immediately inside `QueryClientProvider`:

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

> **Reset on logout** is critical: without `mixpanel.reset()`, the next user on a shared device inherits the previous `distinct_id`. Wire it into the existing logout handler **and** the `useEffect` above (when `user` becomes null).

### 6.6 Event taxonomy & naming convention

- **Event names:** Title Case, verb-object, present tense — `Element Clicked`, `Signup Submitted`, `QR Downloaded`, `Upgrade Clicked`.
- **Property keys:** `snake_case` — `track_id`, `page_path`, `plan_id`.
- **`track_id` values** (the `data-track-id` attribute): `snake_case`, namespaced by surface — `nav_signup_cta`, `hero_signup_cta`, `pricing_select_pro`, `builder_download_png`, `billing_upgrade_pro`, `qr_delete`.
- **Two-layer model:**
  - Layer 1 — **`Element Clicked`**: fired for *every* click. The catch-all. Filter in Mixpanel by `track_id` / `page_path` / `element_text`.
  - Layer 2 — **named events** for the ~20 priority CTAs (optional, Phase 3+): same click also fires a clean semantic event for funnel building. Implemented either by the listener promoting known `track_id`s to named events via a small map, or by a direct `track()` at the call site for non-DOM-click actions (e.g. mutation success).

### 6.7 Common property schema (auto-attached to all events)

| Property | Source | Example |
|---|---|---|
| `distinct_id` | Supabase `user.id` | `3f2a…` |
| `workspace_id` | Zustand `currentWorkspace.id` | `a1b2…` |
| `plan` / `plan_id` | `getPlanName(sub)` / `sub.plan_id` | `Pro` / `pro` |
| `role` | `currentWorkspace.member_role` | `owner` |
| `billing_cycle` | `sub.billing_cycle` | `yearly` |
| `page_path` | normalized pathname | `/org/[slug]/build` |
| `element_type` | derived | `button` |
| `track_id` | `data-track-id` | `builder_download_png` |
| `$current_url`, `$referrer`, device/browser | Mixpanel default props | auto |

### 6.8 Outcome events (DECIDED — the bounded exception to "clicks only")

Two outcome events complete the funnels. **Critical design rule: fire these at the _single source of truth_ (the mutation `onSuccess` / success confirmation), NOT on the triggering button.** A button click can fail, retry, or be one of several entry points; the outcome must fire **exactly once per real success**, regardless of which button or flow triggered it. This is a deliberate override of the general "instrument at the call site, not in the hook" rule — and it applies *only* to these two events.

**Event 1 — `QR Created`**
- **Where:** `src/hooks/useQRs.ts` → `useCreateQR` `onSuccess` (line 94). Also `useBulkCreateQR` `onSuccess` (line 142) with `{ count }`.
- **Why here:** every creation path (builder wizard at `build/page.tsx`, anonymous `/create` save-to-account) funnels through these mutations — one instrumentation point covers all.
- **Props:** `{ qr_id, qr_type, is_dynamic, source: 'builder' | 'bulk' | 'anonymous_import' }`. Read `qr_type`/`is_dynamic` from the returned `newQR`. Never include destination URLs or QR payload content.

**Event 2 — `Subscription Activated`**
- **Where:** primary — the billing success page mount, `src/app/org/[slug]/(dash)/billing/success/page.tsx` (the existing `useEffect`, ~line 16). Secondary/optional — `useVerifySubscription` `onSuccess` (`src/hooks/useSubscription.ts:262`), the Razorpay client-side verification point.
- **Why here:** the success page is **provider-agnostic** (both Razorpay and Lemon Squeezy land here), so one event covers both checkout providers.
- **Props:** `{ plan, plan_id, billing_cycle, provider }` — already available as super-properties; read the post-checkout plan from `useCurrentSubscription`.
- **Caveat (must document):** the *authoritative* activation is the server-side Razorpay/LS **webhook** (`qr_backend`), not the frontend. This frontend event means **"user reached the post-checkout success state."** For billing-revenue accuracy, a server-side `Subscription Activated` should eventually be the source of truth (out of scope — backend), and we should de-dupe on `subscription_id` if both are ever sent. For funnel/UX analysis, the frontend event is the right and sufficient signal for v1.

> Guard against double-firing on the success page: fire once per mount, keyed off `subscription_id`, and rely on `force-dynamic` already set on that page. Do not also fire it from the `billing_select_*` click (that's the *intent* event, already captured).

---

## 7. Tracking Plan — priority CTAs (the `data-track-id` targets)

These get a `data-track-id` attribute (Phase 3). All file paths verified.

### Acquisition / Marketing
| `track_id` | File:line | Element |
|---|---|---|
| `hero_signup_cta` | `src/components/landing/Hero.tsx:49` | "Start Building Free" |
| `nav_signup_cta` | `src/components/layout/Header.tsx:79` | "Start Free" (header) |
| `nav_login` | `src/components/layout/Header.tsx:71` | "Log In" |
| `nav_link` | `src/components/layout/Header.tsx:55` | Features/Pricing/etc (`data-track-label`) |
| `cta_banner_signup` | `src/components/landing/CTABanner.tsx:33` | "Create My First QR" |
| `pricing_select_{plan}` | `src/components/pricing/PricingCards.tsx:294` | Plan card CTA (`data-track-plan`) |
| `pricing_cta_signup` | `src/components/pricing/PricingCTA.tsx:63` | "Start Free — No Card" |
| `public_save_to_account` | `src/components/marketing/PublicQRBuilder.tsx:200` | "Save to my account" |

### Activation / Auth
| `track_id` | File:line | Element |
|---|---|---|
| `signup_submit` | `src/app/(auth)/signup/SignupClient.tsx:286` | "Create account" |
| `signup_google` | `src/app/(auth)/signup/SignupClient.tsx:169` | Google OAuth |
| `login_submit` | `src/app/(auth)/login/LoginClient.tsx:222` | "Sign in" |
| `login_google` | `src/app/(auth)/login/LoginClient.tsx:130` | Google OAuth |

### Core product (builder)
| `track_id` | File:line | Element |
|---|---|---|
| `sidebar_create_qr` | `src/components/org/Sidebar.tsx:72` | "Create New QR" |
| `builder_type_select` | `src/components/qr-generator/QRTypeSelector.tsx` | type tile (`data-track-type`) |
| `builder_next` / `builder_back` | `src/components/qr-generator/NavButton.tsx:79/31` | wizard nav |
| `builder_complete_download` | `src/components/qr-generator/NavButton.tsx:47` | "Complete & Download" |
| `builder_download_{format}` | `src/components/qr-generator/DownloadOptions.tsx:91` | PNG/SVG/JPEG/WebP/PDF |
| `qr_copy_link` | `src/components/org/qrs/details/details-header.tsx:121` | "Copy Link" |
| `qr_delete` | `src/components/org/qrs/details/danger-zone.tsx:41` | "Delete QR Code" |

### Monetization (highest business value)
| `track_id` | File:line | Element |
|---|---|---|
| `billing_select_{plan}` | `src/components/org/billing/BillingPlans.tsx:320` | "Get {Plan}" |
| `billing_cycle_toggle` | `src/components/org/billing/BillingPlans.tsx:586` | Monthly/Yearly |
| `billing_cancel` | `src/components/org/billing/CurrentPlanCard.tsx:144` | "Cancel" |
| `billing_resume_payment` | `src/components/org/billing/CurrentPlanCard.tsx:204` | "Resume Payment" |
| `sidebar_upgrade` | `src/components/org/UsageTracker.tsx:79` | "Upgrade Plan" |
| `upsell_password_upgrade` | `src/components/org/qrs/details/password-protection-card.tsx:48` | "Upgrade to Starter" |
| `upsell_ab_upgrade` | `src/components/org/qrs/details/ab-testing-card.tsx:56` | "Upgrade to Pro" |
| `dashboard_pro_banner` | `src/components/org/dashboard/ProBanner.tsx:21` | "VIEW PRO PLANS" |

### Collaboration
| `track_id` | File:line | Element |
|---|---|---|
| `invite_send` | `src/components/org/users/InviteUserModal.tsx:193` | "Send Invite" (`data-track-role`) |
| `invite_copy_link` | `src/components/org/users/InviteUserModal.tsx:110` | "Copy" invite link |

### Outcome events (NOT clicks — fired at the success source of truth; see §6.8)
| Event | File:line | Trigger |
|---|---|---|
| `QR Created` | `src/hooks/useQRs.ts:94` (`useCreateQR.onSuccess`); `:142` (`useBulkCreateQR.onSuccess`) | Mutation resolves — covers builder, bulk, and anonymous-import paths |
| `Subscription Activated` | `src/app/org/[slug]/(dash)/billing/success/page.tsx` (~`:16`, mount effect); opt. `src/hooks/useSubscription.ts:262` (`useVerifySubscription.onSuccess`) | Post-checkout success state reached (provider-agnostic) |

> Note (non-tracking): `ProBanner.tsx:21` links to a non-slug-prefixed `/billing` — likely a routing bug. Flag to the owner; out of scope here.

---

## 8. Phase-Wise Implementation Plan

Each phase is independently shippable and leaves the app working. Estimates assume one engineer.

### Phase 0 — Foundation & Safety (½–1 day)
**Goal:** SDK wired, guarded, no-op safe. No events yet beyond a smoke test.
- Create Mixpanel **dev** and **prod** projects; obtain tokens.
- Add `NEXT_PUBLIC_MIXPANEL_TOKEN` to `src/lib/env.ts` (optional), `.env.example`, `.env`, and Vercel (prod token on Production only).
- `npm i mixpanel-browser` + `@types/mixpanel-browser`.
- Build `src/lib/analytics/{mixpanel,index,sanitize,events}.ts` with the safe no-op API (§6.2–6.3).
- Add `MixpanelProvider` shell (init only) to `src/app/providers.tsx`.
- Smoke test: fire one manual `track('Debug Ping')`, confirm it lands in the dev project Live View.

**Acceptance:** App builds and runs with token **absent** (no errors, no events) and with token **present** (ping visible in Mixpanel debug). `npm run lint` clean.

### Phase 1 — Identity & Context (1 day)
**Goal:** Every future event is attributable.
- Implement `identify` / `setProfile` / `registerSuperProps` / `resetAnalytics` (§6.3).
- Wire user/profile/workspace/subscription effects in `MixpanelProvider` (§6.5).
- Hook `resetAnalytics()` into the existing logout flow (find sign-out handler; also covered by the `user===null` effect).
- Null-safe handling of Free tier (`subscription === null`).

**Acceptance:** Logging in sets `distinct_id = user.id` + people profile; switching workspace/plan updates super-properties; logging out calls `reset()`. Verified in Mixpanel for a Free user, a Pro user, and a viewer-role member.

### Phase 2 — Global Click Auto-Capture (1–2 days)
**Goal:** **All** links and buttons emit `Element Clicked`. This is the headline deliverable.
- Implement `click-capture.ts` (`extractClickProps`, `attachClickCapture`) and `sanitize.ts` (`normalizePath`, `normalizeText`, `isExternalHost`, `collectDataTrackProps`).
- Attach/detach listener in `MixpanelProvider` mount effect (capture phase).
- Unit-test the extractors (path/text normalization, PII scrubbing, external detection).

**Acceptance:** Clicking buttons/links across marketing, auth, dashboard, and builder all produce `Element Clicked` with correct `element_type`, normalized `page_path`, and scrubbed `element_text`. No PII in any property. No INP regression (spot-check with DevTools).

### Phase 3 — Semantic Enrichment of Priority CTAs (1–2 days)
**Goal:** Clean named funnels on top of raw capture.
- Add `data-track-id` (and `data-track-*` context like `data-track-plan`, `data-track-type`, `data-track-role`) to the §7 list. **No component refactors** — `Button` and `<Link>` already pass `data-*` to the DOM.
- Add `data-track-section` to major layout regions (hero, pricing grid, billing plans, builder steps) for `page_section`.
- In the listener, promote a known set of `track_id`s to clean named events (`Signup Submitted`, `Upgrade Clicked`, `QR Downloaded`, etc.) via a small lookup map in `events.ts`.
- **Outcome events (§6.8) — in scope, not optional:** add `track('QR Created', …)` in `useCreateQR`/`useBulkCreateQR` `onSuccess`, and `track('Subscription Activated', …)` on the billing success page mount (keyed off `subscription_id` to avoid double-fire). These are the two non-click events the funnel requires.

**Acceptance:** Each §7 CTA fires with a stable `track_id`; `QR Created` fires once per successful creation; `Subscription Activated` fires once on post-checkout success. The full `Landing → Signup → QR Created → Upgrade Clicked → Subscription Activated` funnel is buildable in Mixpanel from real dev traffic.

### Phase 4 — Governance, QA & Production Rollout (1 day)
**Goal:** Trustworthy data in prod.
- Document the **event dictionary** (this PRD's §6–7) in Mixpanel **Lexicon**; mark `track_id` taxonomy as the source of truth.
- Optionally enable **Mixpanel Autocapture in the dev project only** for one day to diff against our custom capture and catch any missed surfaces; then disable.
- Build starter dashboards: Acquisition funnel, Activation (signup→first QR), Monetization (upgrade CTA → checkout), Top clicked elements by `track_id`.
- QA pass with `/qa` across key flows; verify identity + super-props on real events.
- Flip prod token on; monitor Live View + error logs for 48h (`/canary`-style watch).

**Acceptance:** Prod project receiving attributed events; dashboards populated; zero tracking-related runtime errors in logs.

### Phase 5 (Optional, later) — Depth
- Pageview/route-change events (if desired), scroll-depth on marketing, builder step-time, experiment exposure — explicitly deferred.

**Total core effort (Phases 0–4): ~5–7 working days.**

---

## 9. Testing & QA Strategy

- **Unit (Vitest):** `sanitize.ts` (path normalization collapses slug/UUID; text scrubbing drops emails/tokens; external-host detection), and `extractClickProps` against fixture DOM nodes (button vs link vs role-button, with/without `data-track-id`).
- **Component:** render `Button`/a `<Link>` with `data-track-id`, simulate click, assert `track` called once with expected props (mock the analytics module).
- **E2E (Playwright):** stub the Mixpanel network endpoint; walk signup → builder → download → upgrade; assert the expected `track_id` sequence was captured. Run with a fake token in CI so the SDK initializes but posts to a mock.
- **Manual:** Mixpanel **debug mode** (`debug: true` in non-prod) + Live View; click through every surface in §7.
- **No-op test:** unset token → confirm zero network calls and no console errors.

---

## 10. Privacy, Consent & Compliance

- **No PII in properties.** Only `element_text` (button/link labels, scrubbed + truncated) — never input values, passwords, tokens, emails, or QR payloads. People-profile `$email`/`$name` are sent to Mixpanel's user-profile store under our DPA, not as event properties.
- **Respect Do-Not-Track** (`ignore_dnt: false`).
- **Consent:** The site has a Cookies page (`src/app/(marketing)/cookies`) and Privacy page. **Open question (§13):** does GDPR/our cookie policy require gating analytics behind a consent banner? Recommended default: load Mixpanel only after consent for EU visitors, or use Mixpanel's EU residency endpoint + IP anonymization. Decide before prod flip.
- **Data residency:** if EU residency is required, set `api_host: 'https://api-eu.mixpanel.com'` (already stubbed in §6.2).
- Update the Privacy/Cookies copy to disclose Mixpanel as a processor.

---

## 11. Rollout & Feature-Flagging

- **Implicit flag = the token.** No token → no-op. This is the safest possible kill-switch.
- Ship Phases 0–3 to dev/preview (dev token) and validate before any prod token exists.
- Flip the **prod token** only at Phase 4, behind a single Vercel env change — instantly reversible by removing it.
- Optional belt-and-suspenders: a `NEXT_PUBLIC_ANALYTICS_ENABLED` boolean checked in `initMixpanel()` for a non-token kill switch.

---

## 12. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Tracking throws and breaks UI | Low | High | All exports null-guarded + try/catch; no-op when uninitialized |
| PII leakage via `element_text` | Med | High | Scrub + truncate; never read input values; only button/link text |
| High-cardinality `page_path` blows up Mixpanel | Med | Med | `normalizePath` collapses slugs/UUIDs |
| Shared-device identity bleed | Med | High | `reset()` on logout (effect + handler) |
| Capture-phase listener double-counts | Low | Med | Single listener; dedupe via `closest()` returning one element per click |
| SDK hurts performance | Low | Med | Async load, `track_pageview:false`, listener does ~O(1) DOM walk |
| Dev traffic pollutes prod data | Med | Med | Separate dev/prod projects + token-per-environment |
| New buttons added later go untracked | Low | Low | Delegation covers them automatically; only clean naming needs `data-track-id` |

---

## 13. Open Questions (need a decision before/within Phase 4)

1. **Consent gating** — Do we need a consent banner before loading Mixpanel for EU users, or is legitimate-interest + DNT sufficient under our current Privacy policy? *(Recommend: consult policy; default to consent-gated for EU.)*
2. **Data residency** — US or EU Mixpanel project? *(Recommend EU endpoint if any EU traffic.)*
3. **Named events vs pure `Element Clicked`** — Is the two-layer model (§6.6) wanted, or is raw capture + Mixpanel-side filtering by `track_id` enough for v1? *(Recommend two-layer for the ~20 money/funnel CTAs only.)*
4. ~~Should QR-create/upgrade *success* be tracked?~~ **DECIDED (2026-06-14): YES.** `QR Created` and `Subscription Activated` are in scope as the two bounded outcome events — see §6.8 and §7. Fired at the success source of truth (mutation `onSuccess` / success-page mount), not at the button. Remaining sub-question for later: should `Subscription Activated` move to a server-side webhook event for billing-revenue accuracy? *(Recommend yes, as a separate backend ticket; frontend event is sufficient for v1 funnels.)*
5. **Anonymous (logged-out) `/create` builder** — track with an anonymous `distinct_id` and alias on signup, or leave anonymous-only? *(Recommend track + `mixpanel.alias` on signup to stitch the funnel.)*

---

## 14. Appendix — Integration Point Quick Reference

| Concern | File |
|---|---|
| Provider insertion | `src/app/providers.tsx` |
| Env token | `src/lib/env.ts`, `.env.example` |
| User identity | `src/hooks/useUser.ts` (`user.id`, `email`, `created_at`) |
| User name | `src/hooks/useUsers.ts` → `useMyProfile()` |
| Workspace/role | `src/store/workspaceStore.ts` (`currentWorkspace`) |
| Plan/tier | `src/hooks/useSubscription.ts` + `src/lib/plan-features.ts` (`getPlanName`) |
| Plan id constants | `src/lib/constants/pricing.ts` (`free/starter/pro/agency`) |
| Button primitive (spreads `...props`) | `src/components/ui/Button.tsx` |
| Public nav/CTAs | `src/components/layout/Header.tsx` |
| New analytics module | `src/lib/analytics/*` (to create) |
| New provider | `src/components/providers/mixpanel-provider.tsx` (to create) |

---

*This is a planning document. No code has been written yet — implementation begins at Phase 0 upon approval.*
