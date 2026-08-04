# PRD — Multilingual / Vernacular Landing Pages

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** The **one genuine differentiator** in the competitive analysis (item #3) — Uniqode/Bitly/QR Tiger/Flowcode/Beaconstac are all English-first, and multilingual is India's defining trait. But ~80% of the value is **already achievable today** (SMBs can type Devanagari/Tamil straight into existing content fields — UTF-8 renders fine end-to-end). The L-effort locale system buys exactly two things: (a) visitor-language **auto-detect / switcher** and (b) translated **static chrome**. Scope to those two; do not build a 23-type locale schema.
**Tiers:** **Pro, Agency** (`multilingual_pages` flag) with a per-QR locale cap (`multilingual_locales_max`) and a metered monthly machine-translation allotment (`multilingual_translations_per_month`). This is a differentiator, not a parity checkbox — unlike QR expiry (`qr_scheduling`, ungated) it is deliberately gated to be an upgrade driver.
**Plan flags:** `multilingual_pages` (bool, NEW) + `multilingual_locales_max` (int limit, NEW) + `multilingual_translations_per_month` (int limit, NEW). All three seeded as a full-object `'{...}'::jsonb` blob and registered `inert`→`enforced` in the **same PR** (house convention; `test_feature_gate_coverage` stays green).
**Split from:** the `page_design` → KV → Worker-template pipeline (`PageDesignCreate` in `qr.py:211`, `write_to_kv` payload in `cloudflare_kv.py:93`, dispatcher `pageDesign` assembly in `qrRouter.js`). Reuses the **existing edge `Accept-Language` parse** (`qr_cf_code/src/utils/routing.js:40`) and the **existing scan-event `language` capture** (`qr_cf_code/src/utils/scan.js:31`, persisted via `internal.py:343` → `qr_scan_events.language`). **Not** the routing-rules "language" dimension (that picks a *destination URL* variant for `website` QRs; this localizes *rendered content and chrome*) and **not** the `menu` QR type (analysis item #4 — a hard sequencing dependency, see §7).

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an outside-voice pass (all claims code-verified) that found **4 P0s** and disproved both numbers the scoping rests on. **Decision 1 — SHIP STAGE A ONLY IN v1, then B/C on evidence.** The spec admits 80% already works, then builds all three layers at once. Split it: **A = translated chrome + correct `<html lang>`** (one locale field, 6 dictionaries, the central post-processor); **B = per-locale content overrides + `?lang=` switcher**; **C = AI translation + meter**. **A alone drops**: the `qr_translations` table, `translation_usage` + 3 RPCs, `translations.py`/`translate.py`, all Anthropic COGS, **all three plan flags** and their coverage surface, both merges (flat *and* tree), the switcher, the scan-event locale column, `useTranslations`, `locale-content-panel.tsx`, and the entire R6/R7 risk class — while closing **2 of the 4 "Broken" rows** in this doc's own §2 gap table and fully delivering the "Lakshmi" persona (she already types Tamil; she wants the buttons to match). B and C ship only on evidence. **Decision 2 — the Phase-0 gate is now BINDING:** query the `qr_scan_events.language` data we already collect; **below the agreed threshold, edge auto-detect is CUT from v1** — the `Accept-Language` resolution step, the `locale_autodetect` column, the KV field, and the builder toggle all go, leaving switcher + owner-default. This deletes real surface *and* R1 itself, decided by data we already have, before any code. (Note: under Stage A this is moot for v1 and applies when B is scoped.)
**P0 corrections (must fix before implementation):** (1) **`qr_scan_events.locale` is never created and the blast radius is product-wide** — `internal.py:390` does `payload.dict()`, so adding `locale` to `ScanEventPayload` puts `locale: null` on **every** scan insert and PostgREST rejects the unknown column → **all scan analytics stop, for every QR**. Add the `ALTER TABLE` or (Stage A) drop the field entirely. (2) **The `?lang=` XSS defense rests on a constraint the migration doesn't create** — only scalar `default_locale` is constrained; the `locales` jsonb array (the array the edge allowlist is built from) is unconstrained, and `withDocumentLang` interpolates `${locale}` unescaped. Add the `CHECK (locales <@ …)` **and** a `/^[a-z]{2}$/` re-assert in the helper. (3) **`TRANSLATABLE_FIELDS` translates the address fields that build the Maps link** — `street_address/city/state/country` feed `mapsUrl`/`dirsHref` in the vcard/business templates, so Directions would query Google Maps in Devanagari. Drop all address components (they're geocoding input, not prose). (4) **§3.3 contradicts itself on proper nouns and names a non-existent column** — remove `business_name` from the allowlist (it also says never translate brand names), and use the real `street_address`/`city`/`state` columns or the business branch reduces to `{}` and 422s every request.
**Load-bearing claims that were false:** "`<html lang>` is a **one-file** fix" — it's **14 dispatcher call sites** (system pages and `mp3`/`video` never call `withMobileViewport`); the real single seam is **`index.js:426-431`**, where `injectPixelsIntoResponse`/`injectConsentIntoResponse` already do `.text()` → rewrite → `new Response`. Make `withDocumentLang` a third post-processor there: **one call site, covers all 23 types + system pages**, and the `.text()` cost is paid only when `locale !== 'en'`. "**~25 frozen keys**" is really **~45–50** (the audit missed "Save to Contacts", "No contact info", "Profile", "Phone · Mobile", "Email · Work", `<title>` chrome, and most of storefront/premium/minimal/directory) — re-run the audit before freezing the key set, because that number is what justified the duplicate-don't-share call. **Worker↔React drift already exists today** (`stackTemplate.js:127` "Save to Contacts" vs its React mirror's "Save Contact") and the proposed key-set comparison **cannot catch it** — check in a canonical key→English-value map and deep-equal both repos' `en` dictionaries against it. **`withDocumentLang` is unowned** across this spec and the menu spec (menu imports it; this spec claims nothing is owed) — **assign it: menu authors the ~6-line helper, multilingual consumes it.** Menu localization is "**two registrations + ~45 dictionary strings**", not "a locale-set change". **Free insurance to fold in:** emit `X-Robots-Tag: noindex` via the same central post-processor (otherwise Googlebot, which sends no `Accept-Language`, indexes whichever locale is the owner's default — a Marathi-default page becomes *the* indexed version), and set `Cache-Control: private, no-store` + `Vary: Accept-Language, Cookie` when `locales.length > 1` (landing pages set no `Cache-Control` at all today, so a zone-level Cache Rule set outside this repo would serve one visitor's language to everyone). Also: the switcher renders every enabled locale's name in its own script, so load Noto for **every** enabled locale (not just the resolved one) or use 2-letter codes — otherwise an `en` page shows `□□□`; `business/shared.js:32` `todayKey()` uses `new Date().getDay()` which is **UTC in a Worker** (wrong day 18:30–24:00 IST) — fix it while editing those exact lines or state it's a known pre-existing bug; the `.vcf` download is never localized (state as intended); `get_limit(workspace_id, db, field)` is **sync** with that arg order; only `card_ocr_scans_per_month` is the right `usage: None` precedent (not `api_calls_per_month`); and a test harness **does** exist (`qr_cf_code` has 9 `node *.test.mjs` suites incl. `routing.test.mjs`, the exact analogue for `resolveLocale`) — follow that convention, don't add Vitest.

---

## 1. TL;DR / Summary

A Pro+ user can mark a **dynamic `vcard` or `business` QR** as multilingual: pick a **default locale**, enable up to N **additional locales**, and (optionally, one click) have the backend **machine-translate** the content fields into each. At scan time the **Cloudflare Worker resolves one locale per request** — `?lang=` override → sticky cookie → `Accept-Language` → the QR's default — and renders that locale's content with a **translated chrome dictionary**, a correct `<html lang="xx">`, and an always-present **language switcher chip** so the visitor can override a wrong guess in one tap.

Three things make this cheap enough to be worth doing and honest enough to survive review:

1. **The content half already works.** Nothing today stops an SMB typing Hindi into the `business` tagline. What's broken is the *chrome* around it — 50 Worker templates hardcode `<html lang="en">` and English button labels ("Save Contact" `vcard/heroTemplate.js:87`, "Call" `vcard/denseTemplate.js:98`, "Directions" `vcard/denseTemplate.js:129`) — so a fully-Hindi vCard still shows English buttons. That's the actual gap.
2. **`lang`/`dir` is a one-file fix, not a 56-file fix.** Every dispatcher already post-processes its HTML string through `withMobileViewport()` (`qr_cf_code/src/utils/html.js`). A sibling `withDocumentLang(html, locale)` rewrites the `<html lang="en">` attribute centrally. Only the **chrome dictionary** has to be threaded per-template — and we scope that to **7 templates** (vcard ×3, business ×4), not 50.
3. **The premise is testable for free, before we build.** `qr_scan_events.language` already records every scanner's `Accept-Language` today. Querying it tells us what fraction of real Indian scans actually advertise a non-English locale — which decides whether **auto-detect** or the **manual switcher** is the headline mechanism. That query is a **hard Phase-0 gate** (§10).

**The permanent cost is real and we state it up front:** every localized Worker template and its mirrored React preview carries a translation dictionary and a fallback path forever, and the Worker↔React mirroring rule is already a known pain point. We buy that cost down by localizing **7 templates, not 50**, and by keeping the dictionary to ~25 frozen keys.

## 2. Problem & Motivation

**The differentiator nobody else has.** Every global QR platform is English-first. India is not an English-first market: a Chennai tea shop's customers read Tamil, a Nashik dealership's customers read Marathi. Vernacular reach into tier-2/tier-3 India is the single positioning claim no incumbent can copy quickly, because it isn't a feature they'd prioritize — it's a market they don't serve.

**What is actually broken today (and what isn't).** Be precise, because the gap is smaller than it sounds:

| | Today | Gap? |
|---|---|---|
| Owner types Hindi/Tamil into content fields | **Works.** UTF-8 through Postgres → KV → `escapeHTML()` → HTML. | No |
| Fonts render Indic glyphs | **Partly.** Templates load **Inter** from Google Fonts (`vcard/heroTemplate.js:28`, `denseTemplate.js:26`, `stackTemplate.js:25`, `business/*Template.js`), which has **no Devanagari/Tamil/Telugu glyphs** — the browser silently falls back to the OS font. Renders, but off-brand and inconsistent. | Partial |
| Static UI chrome | **Broken.** "Save Contact", "Call", "Directions", "Website", "Share" are hardcoded English in every template. A 100%-Hindi vCard still shows English buttons. | **Yes** |
| `<html lang>` | **Broken.** 56 files hardcode `lang="en"` — wrong for screen readers, translation prompts, and browser hyphenation. | **Yes** |
| Visitor-language detection | **Absent** for content. The Worker *does* read `Accept-Language` (`routing.js:40`) but only to pick a *redirect URL variant* on `website` QRs. | **Yes** |
| Multiple content variants per QR | **Absent.** One QR = one content row. An owner wanting Hindi + English must create two QRs and print two codes. | **Yes** |

**Why this is worth an L.** The owner-side pain is the last row: a restaurant that wants a Hindi and an English menu today prints **two QR codes**. That is the concrete, demoable "before/after" — one printed code, two languages, resolved automatically, switchable by the visitor. The chrome translation is what makes the localized page not look half-finished.

**Why we must not over-build it.** The analysis is emphatic and correct: a 23-type locale schema would multiply every content model, every `build_kv_content` branch, every template, and every React preview by the locale count, permanently. The value is concentrated in the **visitor-facing types where a stranger reads the page** — menu, business, vcard — and nowhere near evenly distributed across `apps`, `coupon`, `landing_page`, `list_links`, `images`, `mp3`, `pdf`.

## 3. Goals & Non-Goals

**Goals**
- Let a Pro+ owner set a **default locale** and enable **additional locales** on a dynamic `vcard` or `business` QR, with **per-locale content overrides** stored server-side.
- **One-click machine-translate defaults** so a price-sensitive SMB never hand-authors three language variants — generated **server-side (backend only)**, presented in an **editable review panel**, saved only on the owner's explicit action.
- **Resolve one locale per scan at the edge**, with a fixed precedence: `?lang=` → sticky cookie → `Accept-Language` → QR default. Pure CPU, no added KV read, no backend call, no LLM call on the scan path.
- **Translated static chrome + correct `<html lang>`** on the in-scope templates, with **English fallback for any missing key** — a missing translation must never render an empty button.
- **An always-visible language switcher** on multilingual pages, so a wrong auto-detect costs the visitor one tap, not the whole page.
- **Record the resolved locale on the scan event** so the owner can see which languages their scanners actually got — and so we can measure whether auto-detect is right.
- Keep the scan hot path's added cost to **a dictionary lookup and a string merge**.

**Non-Goals**
- **No LLM, no translation API, and no network call at the edge.** Translation happens backend-side at *edit* time and is snapshotted into KV, exactly like `build_kv_content`. The scan path stays pure-CPU. *(Non-negotiable.)*
- **No 23-type locale schema.** v1 localizes `vcard` + `business` only; `menu` joins when that type ships (§7). The other ~20 types render **English chrome regardless of locale** — an accepted, labeled v1 limitation, not a bug.
- **No RTL in v1.** Urdu (`ur`), Arabic, Hebrew are deferred — `dir="rtl"` would require re-auditing every in-scope template's CSS (flex directions, paddings, icon placement). The locale list is deliberately LTR-only so `dir` stays `ltr`.
- **No auto-publishing of machine output.** Generated translations land in an editable panel and are saved by the owner (mirrors the AI Business-Card OCR confirm-before-save invariant). Content liability on hosted pages — allergens, prices, health claims — is real.
- **No translation of user content at scan time**, no per-visitor personalization beyond locale, no locale-based *routing* to different destinations (that's the shipped routing-rules `language` dimension).
- **No hreflang / SEO multilingual work.** Scan landing pages sit behind opaque short codes and are not an organic search surface.
- **No locale-aware number/currency/date formatting** in v1 (Indic-digit rendering, ₹ lakh/crore grouping) — chrome strings and content only.
- **No translation memory, glossary, or per-workspace term overrides.** Future.

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Tier-2 Restaurateur ("Prakash")** | Nashik dining hall, mixed Marathi/Hindi/English walk-ins | One table QR that greets each guest in their language | Prints **two QR codes**, or picks one language and loses the other half of the room |
| **Local Retail Owner ("Lakshmi")** | Coimbatore storefront, Tamil-first customers | A `business` page that reads Tamil to Tamil customers and English to tourists | Types Tamil into the fields and the buttons still say "Call" / "Directions" |
| **Regional Field Sales ("Devendra")** | Sells across Maharashtra + Karnataka | One vCard that shows Marathi or Kannada by district | Keeps separate vCard QRs per territory |
| **Agency serving regional SMBs ("Nisha")** | Builds pages for 40 small clients | Ship a bilingual page per client without hand-authoring copies | Duplicates every QR per language; 2× the QRs against the plan's `max_qr` |
| **The scanner ("Anyone")** | Walks up to a poster | Read the page in a language they're comfortable in | Gets English, or gets a language they didn't ask for and can't change |

Primary buyer is the **regional-India SMB and the agency serving them** — for whom "one printed code, every customer's language" is the sentence that sells it. The **scanner** is the second, non-paying user whose experience decides whether the feature is real.

## 5. User Stories

- As a **restaurateur**, I want one printed QR to serve Marathi to Marathi speakers and English to everyone else, so that I stop printing two codes.
- As a **retail owner**, I want the *buttons and labels* translated too — not just my text — so the page doesn't look half-Tamil, half-English.
- As a **price-sensitive SMB**, I want a one-click machine translation of my content into the languages I enabled, so that I don't hand-type three variants — and I want to **read and fix it before it goes live**, because it's my storefront.
- As a **scanner**, I want to switch the page's language in one tap when the automatic guess is wrong, so that a bad guess isn't a dead end.
- As a **scanner using a screen reader**, I want `<html lang>` to match the text, so my reader pronounces it correctly.
- As an **owner**, I want to see which languages my scanners actually received, so that I know whether the extra locales were worth it — and which to add next.
- As an **owner whose QR type isn't localized yet**, I want the builder to tell me plainly that only vCard and Business support locales today, so that I'm not surprised by English chrome on my event page.
- As a **Free/Starter user**, I want a clear, honest "Multilingual pages — Pro" affordance, so that I know what upgrading buys.

## 6. UX / Product Flow

**6.1 Enabling locales — the builder (create + edit)**
1. In the QR builder's **Page Design** step, a new **"Languages"** section appears for `vcard` and `business` (collapsed by default, entitled workspaces only). It has: a **Default language** select, a multi-select of **Additional languages** (capped at `multilingual_locales_max`), and an **"Auto-detect visitor language"** toggle (default **on**).
2. Non-entitled workspaces see a compact **upgrade chip** ("Multiple languages — Pro"), mirroring how other gated builder affordances tease. Types outside the in-scope set see a one-line note: *"Language variants are available on vCard and Business pages today."* — no hidden failure.
3. Enabling a locale reveals a **per-locale content panel**: the same fields as the default-language form, pre-filled empty. A **"Translate with AI"** button per locale fills them from the default-locale content in one call.

**6.2 Machine translation — generate, review, save**
- **Translate with AI** POSTs the default-locale content to a backend endpoint, which calls Claude server-side and returns translated field values. They **pre-fill the panel; nothing is published**. A banner reads *"Machine-translated — please review before saving."* (Same posture as AI Business-Card OCR: confirm-before-save is the invariant, and here it also carries the content-liability argument — an SMB is responsible for what their page says.)
- Every field stays editable. A locale saved with all fields blank is treated as **not configured** and falls back to the default locale at the edge — never a blank page.
- Over the monthly allotment → an inline *"You've used all N AI translations this month — upgrade for more"* state; the owner can still type translations by hand (the cap gates the AI call, never the feature).

**6.3 Scanner experience (the edge)**
- **Locale resolution order** (first hit wins): `?lang=<code>` (validated against this QR's enabled set) → `qr_lang_<shortCode>` cookie → `Accept-Language` primary subtag → the QR's **default locale**. If auto-detect is off, `Accept-Language` is skipped entirely.
- The page renders that locale's content overrides merged over the default content, with the matching **chrome dictionary**, correct `<html lang="xx">`, and — for non-Latin locales — a **Noto script font** loaded alongside Inter so glyphs aren't left to OS fallback.
- A **language switcher chip** (compact, top-right, one row of language names in their own script — "मराठी · English") is present on every multilingual page. Tapping sets `?lang=` and the sticky cookie. **This is required, not optional** — see R1.
- **Single-locale QRs are byte-for-byte unchanged**: no switcher, no dictionary lookup, no extra markup. The overwhelming majority of scans take the untouched path.

**6.4 Dashboard — did it work?**
- The QR detail/analytics view gains a **"Languages served"** breakdown (share of scans per resolved locale), derived from the locale recorded on each scan event. This is both the owner's ROI answer and our honest measurement of auto-detect accuracy.
- The QR list shows a small **locale count chip** (e.g. "3 languages") on multilingual QRs.

**6.5 Interaction with existing behavior (precedence)**
- Status branches (`paused` / `disabled` / `locked`), the password gate, and the schedule window (if QR Expiry has shipped) all run **before** locale resolution — a paused QR shows its system page in whatever language those system pages speak (English in v1; system pages are **out of scope**, see §7).
- Routing-rules' `language` dimension is untouched and independent: it picks a destination URL on `website` QRs; this picks rendered content on `vcard`/`business`. They never both apply to the same QR type in v1.

## 7. Scope

**In scope (v1)**
- **Types: `vcard` (incl. `vcard_plus`) and `business` only** — 7 Worker templates (`vcard/{hero,dense,stack}Template.js`, `business/{storefront,premium,minimal,directory}Template.js`) and their 7 mirrored React previews.
- **Locales: 6, fixed, LTR-only** — `en`, `hi` (Hindi), `ta` (Tamil), `te` (Telugu), `bn` (Bengali), `mr` (Marathi). Covers the large majority of India by L1 speakers; adding a 7th is a dictionary file plus a constant, not a redesign.
- Per-QR **default locale**, **enabled locale set**, **auto-detect toggle**, and **per-locale content overrides**, snapshotted into KV.
- **Edge locale resolution** (`?lang=` / cookie / `Accept-Language` / default), **chrome dictionary** per locale, central **`<html lang>` rewrite**, conditional **Noto font** load, **language switcher**.
- **Backend machine-translation endpoint** (Claude, server-side, metered), generate→review→save.
- **Resolved locale recorded on the scan event** + a "Languages served" analytics breakdown.
- Gating: `multilingual_pages` (Pro+), `multilingual_locales_max`, `multilingual_translations_per_month`.

**Out of scope / Future**
- **The `menu` QR type — deferred by dependency, not by choice, and the dependency is now handled.** `menu` does not exist yet (analysis item #4). It is the *highest-value* multilingual surface, and the analysis sequences #4 and #3 together as the "restaurant bundle". The right call was to **build the `menu` templates i18n-native from day one** rather than retrofit them, and `RESTAURANT_MENU_QR_TRD.md` §4.5 now commits to exactly that: its three templates take the dictionary parameter and route all chrome through it from their first commit, shipping English-only with **no dependency on this spec landing**. Its ~9 chrome keys are reserved in our dictionary. **Menu localization therefore becomes a locale-set change plus translation, not an engineering retrofit** — see Open Q1.
- The other ~20 QR types and ~43 remaining Worker templates *(English chrome regardless of locale; labeled in-product)*.
- **Worker system pages** — `errorPage`, `scanLimitPage`, `disabledPage`, `planLimitPage`, `passwordGatePage` stay English *(they render before locale resolution and carry no QR content; localizing them is a cheap follow-up, not v1)*.
- **RTL locales** (`ur`, `ar`, `he`) — needs a `dir="rtl"` CSS audit of every in-scope template *(future)*.
- Locale-aware **number/currency/date formatting**; Indic-digit rendering *(future)*.
- **Translation memory / glossary / brand-term protection** *(future; v1 re-translates from scratch on demand)*.
- **Bulk "translate all QRs in this workspace"** *(future; v1 is per-QR, per-locale)*.
- Owner-facing **dashboard/app UI** translation — this feature localizes the **scan pages only**, not the Qravio product UI *(a much larger, separate effort)*.
- **hreflang / multilingual SEO**, locale-specific short codes or custom domains *(non-goals, §3)*.

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Multilingual landing pages (locales, auto-detect, switcher, chrome) | **Pro, Agency** | `multilingual_pages` (NEW bool) |
| Additional locales per QR (beyond the default) | per tier | `multilingual_locales_max` (NEW int) |
| Monthly AI translation allotment (per workspace) | per tier | `multilingual_translations_per_month` (NEW int) |

**Suggested seed values** (tunable in `plans.features` without a deploy): Free = `false / 0 / 0`; Starter = `false / 0 / 0`; **Pro = `true / 3 / 200`**; **Agency = `true / 6 / 1000`**. `-1`/unlimited is **not** offered on the translation meter — every generation is a metered Claude call and margin must be protected (mirrors the deliberate no-unlimited stance of AI_SCAN_ANALYST and AI_BUSINESS_CARD_OCR).

- **Why Pro+ and not ungated:** this is the opposite case from QR expiry. Expiry is a table-stakes checkbox where gating undercuts the strategic goal (stop losing the comparison), so it ships ungated. Multilingual is a **differentiator with real recurring COGS** (Claude calls) and real permanent maintenance cost. Gating it makes it an upgrade driver and funds its own upkeep. Starter stays the "one person, one QR" tier; multilingual is a multi-audience capability.
- **Why a locale cap rather than unlimited locales:** each enabled locale multiplies the owner's authoring surface *and* the KV payload. 3 on Pro covers the realistic case (regional + Hindi + English); 6 on Agency covers a multi-state client book. The cap is also the natural upsell rung.
- **Why the translation meter is separate from the locale cap:** the locale cap bounds *storage and payload*; the translation meter bounds *AI spend*. An owner re-generating translations after every copy edit is the cost risk, and the locale cap doesn't bound it. **Open Q4** asks whether product wants to collapse these into one key.
- **Migration flag-flip (house convention):** seed all three keys as a **full-object `'{...}'::jsonb` blob** where absent (non-custom plans only), then enable per tier with `jsonb_set` path writes guarded by `lower(name)` + `coalesce(is_custom,false)=false`. The blob form is mandatory: `test_feature_gate_coverage._seed_feature_keys()` discovers feature keys **only** by regex-scanning `'{...}'::jsonb` blobs, so a path-only seed would leave all three undiscovered and the coverage test would fail them as stale.

## 9. Success Metrics & KPIs

**Premise validation (the gate that comes first — §10 Phase 0)**
- From existing `qr_scan_events.language` data: **what share of India-geo scans advertise a non-`en` primary `Accept-Language`?** This is free to measure today and it decides the feature's shape. If the share is low (the likely outcome — most Indian Android/iOS devices ship an English UI even for vernacular-preferring users), **auto-detect is demoted to an assist and the manual switcher becomes the headline mechanism.** Either result is actionable; not measuring is the only wrong answer.

**Adoption**
- ≥ 15% of **newly created** `vcard`/`business` QRs in entitled workspaces enable ≥1 additional locale within 60 days of GA.
- ≥ 60% of enabled locales are populated via **AI translation** rather than hand-typed (proves the machine-translate default is doing its job — the whole reason it exists).
- Competitive claim substantiated: "vernacular landing pages" ships to the comparison matrix and the `/beaconstac-alternative` SEO page.

**Scanner outcome (does it actually reach anyone?)**
- On multilingual QRs, **share of scans resolved to a non-default locale** — the direct measure of value delivered. If this is near zero, the feature is decoration.
- **Language-switcher tap rate.** A *high* rate is a warning that auto-detect is wrong, not a success; a *zero* rate on a QR where non-default resolution is also zero means the extra locales were never reached. Both are read together.

**Quality / trust**
- **Zero blank-field regressions**: no scan renders an empty label or an empty content field because a translation key or locale override was missing (fallback chain works). Canary QR per environment + a fallback unit test as a release gate.
- **Machine-translation edit rate** — share of AI-generated fields the owner edits before saving. High (>50%) means quality is too low to be a "default" and the model or prompt needs work.

**Margin / cost**
- Translation cost per QR-locale within target (Haiku, small text payloads, cached system prefix); per-call token usage recorded for margin monitoring. Cap-hit rate tracked as an upsell signal.
- **Scan-path latency unchanged** — added edge work is a dictionary lookup and an object merge; p95 landing-page TTFB must not regress measurably. Non-Latin font load is the only added byte cost, and only on non-Latin locales.

## 10. Rollout Plan

**Phase 0 — Premise validation (no code).**
Run the `qr_scan_events.language` distribution query for India-geo scans. Decide, on data: is auto-detect the headline mechanism or an assist behind the switcher? **This is a hard gate — the copy, the default of the auto-detect toggle, and the switcher's prominence all depend on the answer.** Also confirm `ANTHROPIC_API_KEY` is provisioned per environment (shared with AI_SCAN_ANALYST / card OCR; the binding default in `base.py` is empty).

**Phase 1 — Backend + data model (internal).**
Migration (locale columns + `qr_translations` + the three-flag seed). Locale fields on the QR create/update models; `qr_translations` CRUD; the machine-translation endpoint (metered, server-side Claude). Extend `write_to_kv` / `sync_qr_to_kv` to carry the `i18n` block. **No UI, no Worker.**
- **Acceptance:** a QR with 2 locales round-trips DB → KV; the `i18n` block appears in the KV value; the translation endpoint returns validated fields, meters correctly, and refunds a clean model failure.

**Phase 2 — Edge (staging).**
Chrome dictionaries (6 locales × ~25 keys), `withDocumentLang()`, locale resolution in `src/index.js`, dictionary threading into the vcard + business dispatchers and their 7 templates, conditional Noto font, language switcher, resolved locale on the scan event. Deploy to **staging** (`npm run deploy`).
- **Acceptance:** `?lang=hi` renders Hindi content + Hindi chrome + `lang="hi"`; `Accept-Language: hi-IN` does the same with auto-detect on and is ignored with it off; an unknown/disabled `?lang=` falls back to the default (never errors); a missing key renders English, never blank; a single-locale QR's HTML is byte-for-byte identical to today.

**Phase 3 — Builder + dashboard (closed).**
Languages section, per-locale panels, Translate-with-AI, upgrade chip, out-of-scope-type note, "Languages served" breakdown. Internal + a handful of regional design-partner workspaces (at least one restaurant and one Tamil/Telugu-market retailer — **native-speaker review of the chrome dictionaries is a GA gate**; machine-translated button labels that read wrong are worse than English).

**Phase 4 — GA.**
Flip `multilingual_pages` `inert`→`enforced` (same PR as the seed), remove the FE flag, **`npm run deploy:prod`** the Worker, update the comparison matrix + SEO page + help centre.

**Cross-service gates:**
- **Worker change → `npm run deploy:prod` is required.** Deploy order: migration → backend (KV now carries `i18n`) → Worker. A Worker deployed before the backend writes `i18n` simply sees no locale block and renders exactly as today — safe either way, but apply the migration first.
- **No email** in v1 → the unpublished `_dmarc.qravio.app` record is **not** a gate.
- **No new cron** → no `wrangler.toml` cron change.
- **`ANTHROPIC_API_KEY` must be populated** in staging + prod before Phase 1 ships (Phase-0 checklist item).

## 11. Risks, Edge Cases & Open Questions

**R1 — `Accept-Language` is a weak proxy for language preference in India (the #1 risk, and it targets exactly this market).** Most Indian phones ship with an English UI even when the owner reads Hindi or Tamil, so a large share of vernacular-preferring users will advertise `en-IN`. Auto-detect will therefore **under-serve the very audience the feature is for**, and will occasionally mis-serve a bilingual user who prefers English. **Mitigation:** (a) measure it first from existing `qr_scan_events.language` data (Phase 0 — free); (b) make the **language switcher mandatory and prominent** on every multilingual page, not a hidden affordance; (c) let the owner set the **default locale** to their local language rather than English, so the *fallback* is the right guess for their neighbourhood; (d) make auto-detect a **toggle** so an owner who knows their customers can pin the default. **This risk is why the switcher, not auto-detect, is the load-bearing mechanism.**

**R2 — The permanent i18n maintenance tax (structural, accepted).** Every localized Worker template and its mirrored React preview carries a dictionary + fallback path forever, and the house rule that **every Worker template must be mirrored by a React preview** already makes that pair a known drift point — the two now have to stay in sync on *markup, styling, and translation keys*. Adding a template or a locale is a two-repo change. **Mitigation:** (a) scope to **7 templates, not 50**; (b) freeze the dictionary at ~25 keys and treat additions as a reviewed change; (c) the `<html lang>` half is centralized in one helper so it never becomes per-template work; (d) build `menu` templates i18n-native from day one so the largest future surface never needs a retrofit. **We do not claim this cost goes away — it is the price of the differentiator, and we bought it down as far as scoping can.**

**R3 — Worker↔React dictionary drift across two separate git repos.** `qr_cf_code` and `qr_frontend` are independent repos, so a shared module can't simply be imported and no single CI job sees both copies. A drifted dictionary means the builder preview shows one label and the live page shows another — the exact class of bug that erodes trust in the preview. **Mitigation:** v1 duplicates one small dictionary file per repo with an **identical, checked-in key list** and a key-parity unit test in each; the key set is small and frozen, which is what makes duplication survivable. Extract to a shared git-dependency npm package **when the `menu` type lands** (third consumer, larger key set). Flagged for eng-review — see Open Q3.

**R4 — Machine-translation quality and content liability.** An AI-translated price, allergen note, or service claim that reads wrong is the owner's storefront, hosted by us. The competitive analysis explicitly skipped a general "AI landing-page/copy generator" partly on content-liability grounds (ASCI / health / food claims). **Mitigation:** translation **never auto-publishes** — generated fields land in an editable panel with a "please review" banner and are saved by the owner's action (the AI-OCR confirm-before-save precedent). We translate **only fields the owner already wrote**; we never generate net-new claims. Proper nouns (business name, dish names, person names) are instructed to pass through untranslated, and the prompt is extraction-shaped with server-side validation so card-text-style prompt injection has no effect.

**R5 — Indic fonts.** Templates load **Inter**, which has no Devanagari/Tamil/Telugu/Bengali glyphs, so Indic text silently falls back to the OS font — inconsistent with the design and occasionally ugly. **Mitigation:** conditionally load a Noto script font **only** for non-Latin resolved locales (so the English majority pays zero extra bytes), and add the script font to the `font-family` stack ahead of the generic fallback. Font weight on a slow tier-3 connection is a real cost — subset aggressively and keep `display=swap`.

**R6 — Locale explosion in the KV payload.** Each enabled locale adds a content override object to the QR's KV value. A 6-locale `business` QR with long descriptions grows the entry materially, and KV values have size limits. **Mitigation:** the locale cap (`multilingual_locales_max`) is the bound; store **only overridden fields**, not full copies; store only the **translatable subset** of fields (never phone numbers, URLs, coordinates, prices, or file paths). Fail loudly at write time if the payload exceeds a safe ceiling rather than silently truncating.

The sharp edge here is **nested content**. For flat types (`vcard`/`business`) a per-field override is naturally small. For a tree-shaped type — the future `menu`, with categories containing items — a naive "override the whole array per locale" would duplicate **every price and image URL in every language** (~5× the blob on a 5-language, 300-item menu), destroying the bound. Overrides for nested types must therefore be **keyed by stable row id** and merged during the tree walk, so prices and photos are stored exactly once regardless of locale count. This is settled in the TRD (§4.4) and depends on the `menu` type's stable client-generated UUIDs; **any future nested type must guarantee stable row ids before it can be localized** — positional indices would silently reassign translations to the wrong row whenever the owner reorders a menu.

**R7 — Partial translations render a mixed-language page.** An owner enables Tamil, translates three of eight fields, and saves. **Mitigation:** the merge is per-field over the default locale, so untranslated fields show the default language — a **mixed page, never a blank one**. The builder shows a per-locale completeness indicator so the owner sees what's missing. This is deliberately preferred to hiding the locale: partial Tamil is more useful to a Tamil reader than no Tamil.

**R8 — Scope creep to "translate the whole product".** Once locales exist, "why isn't the dashboard in Hindi?" and "why isn't my event QR localized?" follow immediately. **Mitigation:** state the boundary in-product (the builder note on unsupported types) and in the help centre. The product UI is explicitly a non-goal; the other ~20 types are a labeled limitation with a known unlock path.

**R9 — Cache-key correctness if caching is ever added.** These responses aren't cached today, but the moment any edge cache is introduced, a locale-varying page cached under a bare short code would serve one visitor's language to everyone. **Mitigation:** documented now — the resolved locale must be part of the cache key (or `Vary: Accept-Language` + `?lang=` in the key). Cheap to honour up front; expensive to discover later.

**Open Questions**
1. **Sequence multilingual *after* the `menu` type, or ship `vcard`+`business` first and add `menu` when it lands?** ***Resolved:*** ship `vcard`+`business` first (they exist, they prove the mechanism, they're 7 templates). The cross-spec requirement — "menu templates accept the dictionary parameter from their first commit" — is **agreed and written into `RESTAURANT_MENU_QR_TRD.md` §4.5**, so nothing is owed by either spec until menu localization is scheduled. Product only needs to confirm *when* to enable menu locales, not whether the groundwork exists.
2. **Is auto-detect on or off by default?** *Depends on the Phase-0 data. Recommend on-by-default only if a meaningful share of India-geo scans advertise non-`en`; otherwise default it **off** with the owner's default locale doing the work, and keep the switcher prominent.*
3. **Duplicate the dictionary per repo, or extract a shared package now?** *Recommend duplicate + key-parity test for v1 (~25 keys, 2 repos); extract when `menu` adds a third consumer.* TRD decision, flag for eng-review.
4. **Three plan keys or two?** *Recommend three (feature bool, locale cap, translation meter) — the locale cap bounds payload, the meter bounds AI spend, and they're genuinely different risks. Collapsing to two would leave re-translation spend unbounded. Product to confirm the extra coverage-test surface is acceptable.*
5. **Six locales at launch, or start with three (`en`/`hi` + one southern)?** *Recommend six — the marginal cost of a locale is one small dictionary file, and a short list undercuts the "vernacular" claim in exactly the markets we're targeting. Native-speaker review of each is the real cost and the real gate.*
6. **Should the language switcher show on single-locale QRs?** *Recommend no — zero markup change for the untouched majority, and a switcher with one option is noise.*

## 12. Dependencies

- **`page_design` → KV → template pipeline (shipped):** `PageDesignCreate` (`qr.py:211` — note it declares **only** `themeColor` + `templateId`, so any new key needs an explicit model field), `write_to_kv` payload (`cloudflare_kv.py:93`), `sync_qr_to_kv` (`cloudflare_kv.py:307`), dispatcher `pageDesign` assembly (`qrRouter.js`). The `i18n` block rides this seam.
- **Edge `Accept-Language` parse (shipped):** `qr_cf_code/src/utils/routing.js:40` already extracts the primary subtag exactly as needed — reuse it, don't re-derive it.
- **Scan-event language capture (shipped):** `qr_cf_code/src/utils/scan.js:31` → `internal.py:343` → `qr_scan_events.language`. **This is the Phase-0 validation data and it already exists.** The `extra` parameter on `recordScan` (used today for `variant_key`, `review_route`, `stars`) is the seam for the resolved locale.
- **HTML post-processing seam (shipped):** `withMobileViewport()` in `qr_cf_code/src/utils/html.js` — the pattern `withDocumentLang()` copies, and the reason `<html lang>` is a one-file change rather than 56.
- **Anthropic SDK + `ANTHROPIC_API_KEY` (shipped):** shared with AI_SCAN_ANALYST and card OCR; `src/utilities/card_ocr.py` is the structural model for the translation helper (strict output shape, cached system prefix, capped `max_tokens`, metered, refund-on-failure).
- **Gating engine (shipped):** `FEATURE_ENFORCEMENT` + `check_feature`/`get_limit` (`subscription.py:524`), `canAccessFeature`/`PlanFeatures` on the frontend, and the `test_feature_gate_coverage` guardrail.
- **Builder wizard (shipped):** Page Design step + `TemplatePicker`/`PagePreview` — where the Languages section and per-locale panels slot in.
- **Migration mechanism (shipped):** hand-applied SQL in `qr_backend/migrations/`; highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`, with `0033` claimed by QR Expiry and further slots claimed by other in-flight specs. **Provisional slot `0042` — re-verify with `ls qr_backend/migrations/` immediately before applying.**
- **Blocked-by (sequencing, not code):** the **`menu` QR type** (analysis item #4) for the highest-value multilingual surface — see Open Q1.
- **No new external service, no email, no cron, no new KV namespace.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Locale columns + per-locale content + flag seed | `qr_backend/migrations/0042_multilingual_landing_pages.sql` (NEW — provisional slot; `qr_codes` locale columns + `qr_translations` + 3-flag blob seed) |
| Locale fields on create/update + `qr_translations` CRUD | `qr_backend/src/api/routes/qr.py` (`PageDesignCreate` ~L211; create ~L1667/L2267; update `page_design` pop ~L2845, write ~L3280) |
| Machine-translation endpoint + AI helper | `qr_backend/src/api/routes/translations.py` (NEW) + `qr_backend/src/utilities/translate.py` (NEW — mirrors `utilities/card_ocr.py`) |
| KV snapshot of the `i18n` block | `qr_backend/src/utilities/cloudflare_kv.py` (`write_to_kv` payload ~L93; `sync_qr_to_kv` ~L307; `build_kv_content` ~L387) |
| Gating | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT` ~L524 — 3 new keys, `inert`→`enforced`), `test_feature_gate_coverage.py` (must stay green) |
| Edge locale resolution | `qr_cf_code/src/index.js` (KV parse ~L353; resolution before dispatch ~L420) reusing the `Accept-Language` parse at `src/utils/routing.js:40` |
| Chrome dictionaries | `qr_cf_code/src/i18n/` (NEW — 6 locale files, ~25 keys, English fallback) |
| Central `<html lang>` / `dir` rewrite | `qr_cf_code/src/utils/html.js` (NEW `withDocumentLang()` beside `withMobileViewport()`) |
| In-scope Worker templates (7) | `qr_cf_code/src/pages/vcard/{hero,dense,stack}Template.js` + `src/pages/business/{storefront,premium,minimal,directory}Template.js`; dispatchers `vcard/index.js`, `business/index.js` |
| Language switcher + Noto font | `qr_cf_code/src/pages/` shared partial (NEW), wired into the 7 in-scope templates |
| Resolved locale on scan events | `qr_cf_code/src/utils/scan.js` (`extra` param ~L26/L65) → `qr_backend/src/api/routes/internal.py` (`ScanEventPayload` ~L343) |
| Builder Languages section + per-locale panels | `qr_frontend/src/components/qr-generator/` (NEW, ≤200 lines each) + `PageDesignStep.tsx` |
| Mirrored React previews (7) | `qr_frontend/src/components/qr-generator/templates/` — must carry the same dictionary (R3) |
| Translation hook + FE gating | `qr_frontend/src/hooks/` (NEW `useTranslations`), `qr_frontend/src/lib/plan-features.ts` (`PlanFeatures.multilingual_pages` + 2 limits) |
| "Languages served" analytics | `qr_frontend` QR detail/analytics + `qr_backend/src/api/routes/scan.py` (locale breakdown off `qr_scan_events`) |
| Worker deploy | `qr_cf_code` — **`npm run deploy:prod`** required (edge change); no `wrangler.toml` change |
