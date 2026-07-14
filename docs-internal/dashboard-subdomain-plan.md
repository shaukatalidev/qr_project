# Plan: Split `dashboard.qravio.app` off the marketing site

**Status:** Not started — implementation plan for later.
**Date:** 2026-07-14

## Decisions locked in
- **Keep `/docs` on the apex** (`qravio.app/docs`, subdirectory) — better long-tail SEO than a `docs.` subdomain. No docs migration.
- **Fully separate auth (Option A).** Auth pages live on the dashboard host; Supabase session cookies are host-only (naturally scoped to `dashboard.qravio.app`). Marketing does **not** know login state — its "Log in / Get started" buttons link across to the dashboard.
- **Keep the `/org` prefix for v1** (URLs like `dashboard.qravio.app/org/acme/qrs`) — zero route refactor. Dropping `/org` → `dashboard.qravio.app/acme/qrs` is a possible later enhancement (rename `org/[slug]` routes + all internal links).

## Scope
Only `dashboard.qravio.app` gets carved out. `qravio.app` (marketing + `/docs`) and `api.qravio.app` (backend) stay as-is. No cross-subdomain cookie work needed.

## Architecture
One Next.js app, one Vercel project, **host-based routing in `src/middleware.ts`**.

**Path ownership:**
- `dashboard.qravio.app` → `(auth)` (`/login`, `/signup`, `/callback`, `/forgot-password`, `/reset-password`, `/invite`) + `/org/*` (+ `/app`, `/qrs`, `/analytics`, `/billing`, `/settings`).
- `qravio.app` → everything else (marketing, `/docs`, `/embed`, `/r`, blog, `/pricing`, …).
- Wrong-host hits → 301 to the correct host (prevents duplicate-content SEO issues and broken deep links).

---

## Part 1 — Frontend: host-aware middleware (`src/middleware.ts`)
Rewrite middleware to branch on `request.headers.get('host')`:
- **Dashboard host:** any marketing path → 301 to `qravio.app<path>`; `/` → `/org`; then run the existing Supabase session-refresh + protect-`/org` + bounce-logged-in-from-`/login` logic. Add `X-Robots-Tag: noindex, nofollow` on all responses so the app is never indexed.
- **Apex host:** any app/auth path → 301 to `dashboard.qravio.app<path>`; keep currency-cookie logic; **drop** the "logged-in on `/` → `/org`" redirect (apex can't see the dashboard-scoped cookie anyway).
- **Localhost/dev (host matches neither):** passthrough = today's exact single-host behavior, so local dev is unchanged.

Path sets to define:
- **App/auth paths:** `/login`, `/signup`, `/callback`, `/forgot-password`, `/reset-password`, `/invite`, `/org`, `/app`, `/qrs`, `/analytics`, `/billing`, `/settings`.
- Everything else = marketing (served on apex).

## Part 2 — Frontend: env + URL helper + marketing link updates
- Add env `NEXT_PUBLIC_APP_URL=https://dashboard.qravio.app` (keep `NEXT_PUBLIC_SITE_URL=https://qravio.app`).
- New `src/lib/app-url.ts` → `appUrl(path)` (absolute in prod, relative fallback in dev).
- Repoint marketing CTAs that link into the app/auth from relative → `appUrl(...)`. Confirmed targets:
  - `src/components/landing/Hero.tsx` (`/signup`)
  - `src/components/landing/CTABanner.tsx` (`/signup`)
  - `src/components/landing/QRCodeTypes.tsx` (`/app/builder`)
  - `src/components/marketing/PublicQRTypeSelector.tsx` (`/login`)
  - `src/components/marketing/BlogPostContent.tsx` (×2, `/signup`)
  - `src/components/marketing/CompetitorAlternativeContent.tsx` (×2, `/signup`)
  - `src/components/layout/Header.tsx`
  - `src/components/pricing/PricingCTA.tsx`
  - `src/components/pricing/PricingCards.tsx`
  - `src/components/marketing/QrTypePageContent.tsx`
  - `src/components/marketing/PublicQRBuilder.tsx`
  - `src/components/developers/DevelopersClient.tsx`
  - Marketing `page.tsx` files: `qr-code`, `dynamic-qr-code-generator`, `about`, `vs/[competitor]`, `compare`, `blog` (all `/signup`).
- Links **inside** `src/components/org/**` stay relative — they already render on the dashboard host. (Re-grep at edit time to catch any new ones: `grep -rn "'/login'\|/signup\|href=\"/org" src/components src/app/\(marketing\)`.)

## Part 3 — Frontend: auth redirect wiring
- `getSiteUrl()` in `src/lib/site-url.ts` (used only for Supabase `emailRedirectTo`/`redirectTo` in login/signup/callback/forgot) → read `NEXT_PUBLIC_APP_URL` instead of `NEXT_PUBLIC_SITE_URL`, so confirmation/reset/OAuth callbacks land on the dashboard host. The `window.location.origin` fallback already resolves correctly since these pages only run on the dashboard host.
- Callers to verify: `LoginClient.tsx`, `SignupClient.tsx`, `CallbackClient.tsx`, `ForgotPasswordClient.tsx` — their internal `router.push('/org/...')` calls are relative and fine on the dashboard host.

## Part 4 — Backend: split `FRONTEND_URL`
- Add `APP_URL` (dashboard) alongside `SITE_URL`/`FRONTEND_URL` (apex) in `qr_backend/src/config/settings/base.py`.
- `src/utilities/email.py`: invite / analytics / CTA links → `APP_URL`; logo asset → `SITE_URL`.
- `src/api/routes/mor_routes.py`: checkout success redirect → `APP_URL`.
- `src/api/routes/reports.py`: `/r/{token}` public report link → `SITE_URL`.
- Add `https://dashboard.qravio.app` to `ALLOWED_ORIGINS`.

---

## Part 5 — Infra / console (manual, no code)
- **DNS:** CNAME `dashboard` → Vercel; attach the domain to the existing Vercel project (keep it one project).
- **Supabase console:** set Site URL to `https://dashboard.qravio.app`; add `https://dashboard.qravio.app/callback` and `https://dashboard.qravio.app/reset-password` to the Redirect URLs allowlist.
- **Env vars:**
  - Frontend: `NEXT_PUBLIC_APP_URL=https://dashboard.qravio.app`
  - Backend: `APP_URL=https://dashboard.qravio.app`, and add `https://dashboard.qravio.app` to `ALLOWED_ORIGINS`.

## Part 6 — Verify (deploy a preview and walk through)
- Signup → confirmation email → callback lands on dashboard.
- Marketing "Get started" → `dashboard/signup`.
- Apex `/org` → 301 to dashboard.
- Dashboard `/pricing` → 301 to apex.
- Logged-out `dashboard/org` → `/login?redirect=…`.
- Dashboard responses carry `X-Robots-Tag: noindex`.
- Local dev still serves everything on one host (unchanged).

---

## Files to touch (summary)
**Frontend**
- `src/middleware.ts` (rewrite — host-aware)
- `src/lib/app-url.ts` (new)
- `src/lib/site-url.ts` (repoint to `NEXT_PUBLIC_APP_URL`)
- Marketing CTA components/pages listed in Part 2
- `.env.local` / Vercel env: `NEXT_PUBLIC_APP_URL`

**Backend**
- `src/config/settings/base.py` (`APP_URL`, `ALLOWED_ORIGINS`)
- `src/utilities/email.py`
- `src/api/routes/mor_routes.py`
- `src/api/routes/reports.py`

**Not touched:** `/docs` (stays on apex), `api.qravio.app`, `robots.ts` / `sitemap.ts` (already hardcode apex).
