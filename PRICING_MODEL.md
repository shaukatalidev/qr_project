# Qravio Pricing Model — INR + USD

> Repriced structure derived from competitive analysis (QR Tiger, Uniqode, Bitly, Flowcode, Scanova, QRCodeChimp, ME-QR, TQRCG — mid-2026) and the strategy decisions below. Collapses the current 6 tiers (`free/lite/starter/pro/business/agency`) into **Free + 3 paid**.

## Strategy in one screen

Three wedges, each aimed at a specific competitor weakness:

1. **Far more seats per dollar than anyone** — generous caps (2 / 5 / 10 / unlimited) vs QR Tiger's flat "1 user even at $37/mo" or Bitly's $35/user. Free includes 2 seats (try-before-you-pay), and **Pro gives 10 seats at $19** — the seat comparison still crushes QR Tiger in the paid tiers, where it matters.
2. **India-native pricing in ₹ via Razorpay/UPI** — every competitor is USD-card-first and effectively 3–5× too expensive in India. We localize aggressively in ₹ and capture a market they can't even bill.
3. **Cheap, bundled white-label + custom domains** — Uniqode charges **$2,000/domain/year**; we bundle custom domains at Pro and full white-label at Agency for a flat fee.

**What we do NOT do:** race below QRCodeChimp on global USD price (they're optimized to be the cheapest; "cheaper than cheap" signals fly-by-night for infrastructure). We sit at **parity-to-slight-premium in USD** and win on value; we go **well below everyone in ₹** because that's localization, not a price war.

Spend generosity on the **free tier's usage** (5 codes, 2,000 scans/mo — near-zero marginal cost, maximal funnel value) and on **paid seat counts**, not on slashing paid prices.

---

## Tier structure (Free + 3 paid)

| Old tier(s) | → New tier | Persona |
|---|---|---|
| `free` | **Free** | Trial / personal / one-off events |
| `lite` + `starter` | **Starter** | Solo creators, small business |
| `pro` + `business` | **Pro** ⭐ most popular | Marketing teams, growing business |
| `agency` | **Agency** | Agencies, resellers, white-label |

`lite` (5 dyn) and `starter` (15 dyn) were the redundant rungs — no competitor bothers pricing 5 or 15 dynamic codes. Existing subscribers on those plans get **grandfathered** (keep their current price/limits until they change plans).

---

## Pricing

### USD — Rest of World (billed via Merchant-of-Record, e.g. Paddle/LemonSqueezy)

| Tier | Monthly | Annual (effective /mo) | Annual total |
|---|---|---|---|
| Free | $0 | $0 | $0 |
| Starter | **$9** | $7.50 | $90 |
| Pro ⭐ | **$19** | $15.83 | $190 |
| Agency | **$39** | $32.50 | $390 |

Annual = **10× monthly (2 months free, ~17% off)**. MoR absorbs global VAT/sales-tax and ~5% + $0.50 fee — already comfortable at these prices.

### INR — India (billed via Razorpay / UPI), prices ex-GST

| Tier | Monthly | Annual (effective /mo) | Annual total |
|---|---|---|---|
| Free | ₹0 | ₹0 | ₹0 |
| Starter | **₹399** | ₹333 | ₹3,990 |
| Pro ⭐ | **₹999** | ₹833 | ₹9,990 |
| Agency | **₹2,499** | ₹2,083 | ₹24,990 |

18% GST added at checkout (or show inclusive — decision pending). Annual = 10× monthly.

**Localization depth:** ~40% / 35% / 29% below QR Tiger's INR (₹667 / ₹1,525 / ₹3,527) at Starter / Pro / Agency — clearly the affordable, UPI-native Indian option at every tier, but no longer so cheap it signals "hobby tool." Discount vs a naive USD×84 conversion narrows from ~47% (Starter) to ~24% (Agency), since agencies are less price-sensitive. Earlier ₹199/₹499/₹1,499 was discounting well past what the wedge needs.

---

## Full feature matrix

| Feature / Quota | Free | Starter | Pro ⭐ | Agency |
|---|---|---|---|---|
| **Price USD/mo** | $0 | $9 | $19 | $39 |
| **Price INR/mo** | ₹0 | ₹399 | ₹999 | ₹2,499 |
| Dynamic QR codes | 5 | 50 | 300 | Unlimited |
| Static QR codes | Unlimited | Unlimited | Unlimited | Unlimited |
| Scans | **2,000 / month (pooled, resets)** | Unlimited | Unlimited | Unlimited |
| **Team members (incl. owner)** | **2** | **5** | **10** | **Unlimited** |
| Workspaces | 1 | 1 | 3 | Unlimited |
| Dynamic QR types | 2 (website, vCard) | 5 | All 13 | All 13 |
| File upload size | 2 MB | 10 MB | 25 MB | 50 MB |
| Scan analytics | Basic | Basic | Advanced | Advanced |
| Analytics retention | 7 days | 30 days | 90 days | 365 days |
| Folders | ❌ | ✅ | ✅ | ✅ |
| Password protection | ❌ | ✅ | ✅ | ✅ |
| A/B testing | ❌ | ❌ | ✅ | ✅ |
| Bulk generation | ❌ | ❌ | ✅ | ✅ |
| Custom domain | ❌ | ❌ | 1 | Unlimited |
| White-label (remove "Powered by Qravio") | ❌ | ❌ | ❌ | ✅ |
| API access | ❌ | ❌ | ✅ 3k/mo | ✅ 25k/mo |
| Ads / intrusive upsell | shown | none | none | none |
| Landing-page badge | "Powered by Qravio" | subtle | subtle | removed |
| Support | Community | Email | Priority | Priority |

Counts are **concurrent active** codes (the industry norm — Chimp/Scanova/Uniqode all do this), not per-month creation caps. Generous counts are intentional: a dynamic QR is one KV entry + DB row at ~zero marginal cost. Monetize on tier capability and features, not stingy counts.

---

## Free tier — the fix (critical before launch)

**Live-code update:** the "500 all-time, never resets" behavior described in `BILLING_ENFORCEMENT_PLAN.md` is **already gone** — `_enforce_scan_limit` (`internal.py:478-530`) counts scans per *period* via `period_start_iso()`, which for free (no subscription) uses the UTC calendar-month start. So free scans already window monthly. The v3 change is just the number, plus one missing piece:

- **5 dynamic QR codes** (concurrent active) + unlimited static
- **2,000 scans / month, pooled across all QRs, auto-windowed** — more generous than Chimp (1,000/mo) and QR Tiger (500/QR ≈ 1,500). One workspace counter; one viral QR can consume the pool and pause the rest until the month rolls — acceptable on free.
- On exceed: active dynamic QRs are set `status='disabled'` + KV-synced.
- ⚠️ **Required new work — free monthly re-enable:** re-enable today only fires on a subscription renewal webhook (`razorpay_routes.py:1115-1193`), which free tier never gets. Without a scheduled monthly re-enable job, tripped free QRs stay dead — *worse* than the bug we're fixing. **Must ship with the reprice.** See `PRICING_RESTRICTIONS.md` gap #2.
- **2 members (owner + 1)** — enough to *try* collaboration on free; the real seat upgrade triggers at Starter (5) → Pro (10). Pro's 10 seats at $19 still beats QR Tiger's 1 at $37.
- "Powered by Qravio" badge on landing pages (virality + upgrade pressure)
- 7-day analytics, 2 core types

---

## Competitive positioning check

| Our tier | vs closest competitor | Verdict |
|---|---|---|
| Starter $9 / 50 codes | Chimp $6.99 / 50 codes (1 user) | +$2, but **unlimited team** + better UX. Count-neutral so Chimp's count isn't a reason to defect. |
| Pro $19 / 300 codes | Chimp $13.99 / 300 (2 users); QR Tiger $16 / 200 (1 user); Uniqode $49 / 250 | **Best value in the band** — custom domain + A/B + bulk + unlimited team, under Uniqode by 60%. |
| Agency $39 / unlimited | Chimp $34.99 / 900 + WL; Uniqode $49 / 250; Scanova $75 / 500 | +$4 over Chimp but **unlimited codes + unlimited custom domains + unlimited team**; Uniqode charges $2k/domain alone. |
| Free (5 codes, 2k scans/mo reset, 2 seats) | Chimp 10 codes/1k scans; QR Tiger 3 codes/500-per-QR/1 seat | More scans than anyone + resets + recovers, and 2 seats vs QR Tiger free's 1. |

---

## Migration / implementation notes (reconciled with live code, 2026-06-09)

A live-code audit found the system is **much more built than `BILLING_ENFORCEMENT_PLAN.md` says** — dual currency (geo + Razorpay INR / Lemon Squeezy USD), the migration framework (now at **0008**, next = **0009**), and nearly all enforcement gates already exist. This is a **reprice + 6→4 collapse**, not a greenfield build. Full restriction map + gaps in **`PRICING_RESTRICTIONS.md`**.

1. **`plans` table (migration 0009)** — UPDATE the 4 kept tiers (`free/starter/pro/agency`) by name; add `is_public boolean DEFAULT true`; set **`lite` + `business` → `is_public=false`** (retire from UI, rows kept for grandfathering — `subscriptions.plan_id` FK stays valid). Filter the plans-listing endpoint to `is_public=true`.
2. **`max_members` = `2 / 5 / 10 / -1`** — already enforced at `workspace.py:327-337` (invite). Verify the `accept_invitation` path also re-checks (gap #4).
3. **`max_scans`** — Free `500 → 2000`; already period-windowed in live code (no all-time bug). Paid = unlimited. **Add the free monthly re-enable job** (gap #2) — the one genuinely missing piece.
4. **Dual currency** — already complete; no schema work. INR lives in `plans.price_monthly/yearly`; USD in `pricing.ts` + Lemon Squeezy variants. **Payment follow-up (release gate):** all paid INR prices changed + Pro/Agency USD changed ⇒ create new Razorpay plans + LS variants and backfill the `*_plan_id_*` / `*_variant_id_*` columns. 0009 nulls the stale pointers so checkout fails loudly meanwhile.
5. **Frontend** — edit `constants/pricing.ts` `PLANS[]` (drop lite/business, reprice 4); rewrite the hardcoded `PricingComparisonTable.tsx` (4 columns); drop lite/business from `PLAN_META` in `PricingCards.tsx` + `BillingPlans.tsx`. Currency toggle / geo / "Save 17%" copy all stay.
6. **White-label** — gate at Agency only; verify the worker actually suppresses the badge (gap #6).

---

## Decisions to confirm

1. **Free seats = 2** (locked) — owner + 1, lets small teams try collaboration before paying (land-and-expand) while keeping a slight edge over QR Tiger free's 1 seat.
2. **Agency price** — $39 / ₹2,499 assumed. Could go $49 / ₹2,999 for more margin (still far under Uniqode's $2k/domain).
3. **Annual discount** — 2 months free (17%) assumed; could push to 25–30% to drive annual lock-in like Flowcode/Uniqode.
4. **GST** — show ₹ prices ex-GST + "18% GST" line, or GST-inclusive round numbers (₹199 → ₹235 inclusive)? Doc assumes **ex-GST display**.
5. **QR-type split** — Free = 2 (website, vCard), Starter = 5 (+pdf, list_links, business), Pro/Agency = all 13. Confirm the Starter-5 selection.
