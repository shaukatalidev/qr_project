# Qravio Brand Kit — Off-Site Profile Fields

**Purpose:** one source of truth for every off-site profile (G2, Capterra, Wikidata, Crunchbase, directories). Entity SEO is a **consistency** game — paste these values **verbatim**, never paraphrase per-site. Retyping = drift = competing entities = diluted signal.

**Always sign up with `support@qravio.app`** (brand email — never a personal one, so you don't lose access). **Always use the handle `qravioapp`** wherever a handle/slug applies.

---

## 0. Canonical brand block (the master copy)

```
Name:            Qravio
Handle / slug:   qravioapp
URL:             https://qravio.app
Category:        Dynamic QR Code Generator / QR Code Management Software
Logo (square):   https://qravio.app/Icons/qravio_icon.png
Support email:   support@qravio.app
HQ / location:   Bangalore, India
Founded:         February 2026
X:               https://x.com/qravioapp
LinkedIn:        https://www.linkedin.com/company/qravioapp

One-liner (≤120 chars):
Free dynamic QR code generator with real-time scan analytics — edit your QR
codes anytime, no reprinting, no watermark.

Boilerplate (≈50 words):
Qravio is a dynamic QR code generator with real-time scan analytics, a
genuinely free no-watermark dynamic tier, and custom domains. Create editable,
trackable QR codes for websites, PDFs, vCards, business profiles, events, WiFi,
and more — and update where they point without reprinting.
```

**Feature list** (for review-platform descriptions — verify against the live product before publishing):
- 20+ QR code types (website, PDF, vCard, business profile, event, WiFi, images, social, coupon, and more)
- Dynamic QR codes — edit the destination after printing, no reprint
- Real-time scan analytics (scans over time, location, device)
- Genuinely free, **no-watermark** dynamic tier
- Custom branded domains
- Password-protected QR codes
- A/B split testing for destinations
- Team workspaces with member roles
- Branded landing-page templates

**Pricing** (verify against the live pricing page — these change):
Free ₹0 / $0 · Starter ₹399 / $9 · Pro ₹999 / $19 · Agency ₹2499 / $39 (per month).

**Review-platform description** (paste into G2 / Capterra "About" / long description — built to lead with the differentiator):
> Qravio is a dynamic QR code generator with real-time scan analytics. Unlike most "free" QR tools that watermark your codes or only make static ones, Qravio's free tier creates genuinely no-watermark dynamic QR codes you can edit after printing — change where a code points without reprinting it. Create trackable QR codes for websites, PDFs, vCards, business profiles, events, WiFi, social links, coupons and more (20+ types), each with a branded landing page, and track scans in real time by time, location and device. Pro features include custom branded domains, password-protected codes and A/B split testing. Plans start free; paid tiers from $9/month.

---

## 1. Wikidata  (strongest free entity signal — AI reads it directly)

**Model it as ONE item** = the Qravio software/product. Do **not** split into separate "company" + "product" items yet — a 4-month-old startup barely clears notability for one item, let alone two. `instance of: web application` carries both the product and the brand.

> ⚠️ **Notability — read before you start.** Wikidata deletes items for brand-new companies with no *independent* references. A page that cites only your own site + socials will likely get a deletion nomination. **Sequence: create Crunchbase first** (and ideally launch on Product Hunt / land one listicle), then cite those URLs as references on the statements below. ≥1 credible third-party reference is what keeps the item alive.

**Label / description / aliases**
- **Label (en):** `Qravio`
- **Description (en):** `dynamic QR code generator and management software` — short, lowercase, factual. **No marketing words** ("free", "best", "real-time") — promotional descriptions get reverted.
- **Alias (en):** `qravio.app`

**Statements.** Add each value by *typing its label* and picking the match from Wikidata's autocomplete — don't paste a Q-number blind (the labels below are what to search for):

| Property | Value (search this label) | Notes |
|---|---|---|
| instance of (P31) | `web application` | primary type; optionally also add `software` |
| official website (P856) | `https://qravio.app` | |
| inception (P571) | `February 2026` | set date **precision = month** |
| country of origin (P495) | `India` | use P495 for products — *not* P17 (that's for the org/place) |
| license (P275) | `proprietary software` | optional |

**External-ID statements — the highest-value part.** These hard-link the item to your other profiles, which is exactly the entity consolidation you're after:

| Property | Value |
|---|---|
| X/Twitter username (P2002) | `qravioapp` |
| LinkedIn company ID (P4264) | `qravioapp` |
| Crunchbase organisation ID (P2088) | *(add once Crunchbase is live)* |

**References:** on the **inception** and **official-website** statements, add `reference URL (P854)` → your Crunchbase page (or a Product Hunt / press link). This is the single thing that stops the item being deleted.

**Logo (P154):** optional, and only works if the logo is on Wikimedia Commons. The Qravio mark is simple geometric shapes, so it probably qualifies as `{{PD-textlogo}}` (below the threshold of originality) — but skip it if Commons upload is a hassle; it's not essential.

---

## 2. Crunchbase  (feeds Google Knowledge Graph + a backlink — **do this FIRST**)

This is the reference that keeps your Wikidata item from being deleted, so create it before Wikidata.

**How it works:** sign up for a free Crunchbase account with `support@qravio.app`, then **"Add a Company."** Edits go through a **moderation queue** (often a few days) before they're public and indexed — start it early. A domain-matching email speeds verification. Your profile URL will be `crunchbase.com/organization/qravio` (note it for `sameAs` later).

| Field | Value |
|---|---|
| Organization name | `Qravio` |
| Also known as | `qravio.app` |
| Legal name | `Qravio` *(use your registered entity name if different)* |
| Website | `https://qravio.app` |
| Short description | the **one-liner** above |
| Full / About description | **boilerplate** + the **feature list** above |
| Founded date | `February 2026` |
| Operating status | Active |
| Company type | For Profit |
| Number of employees | 1–10 |
| Headquarters location | **Bangalore, India** |
| Industries (pick from Crunchbase's list) | QR Codes · SaaS · Software · Information Technology · Marketing |
| Contact email | `support@qravio.app` |
| Social links | X `https://x.com/qravioapp` · LinkedIn `https://www.linkedin.com/company/qravioapp` |
| Founders | *optional — left non-public; add a founder person-profile later if you want it public* |

**After it's live:**
1. Copy the `crunchbase.com/organization/...` URL.
2. Cite it as `reference URL (P854)` on your Wikidata statements + add `Crunchbase organisation ID (P2088)` to the Wikidata item.
3. Append the URL to `COMPANY` + `sameAs` (ping Claude).

---

## 3. G2  (highest review-platform weight; heavily cited by LLMs for "best X software")

**How it works:** search G2 for "Qravio" — if it's not there, add it via G2's **"Add a Product"** flow, then **claim** the profile with `support@qravio.app` (a domain-matching email speeds verification). G2's research team moderates new products before they go live.

| Field | Value |
|---|---|
| Product name | `Qravio` |
| Seller / vendor | `Qravio` |
| Website | `https://qravio.app` |
| Primary category | **QR Code Generator Software** |
| Logo | `https://qravio.app/Icons/qravio_icon.png` (square, ≥200×200) |
| Tagline / short description | the **one-liner** above |
| Long description | the **review-platform description** above |
| Has free version | **Yes** ← your key differentiator; make sure this flag is set |
| Free trial | Yes (Pro features) — set per reality |
| Entry-level price | Free; paid from **$9/month** (Starter) |
| Full pricing | the **pricing** block above |
| Markets served | Small-Business, Mid-Market |
| Languages | English |
| Media | 3–5 product screenshots + (optional) a short demo video |
| Vendor details | founded Feb 2026 · Bangalore, India · 1–10 employees |

> Empty profiles do nothing — the value is **reviews**. After it's live, run the **review drive** (checklist §1): export happy/high-scan users, send a personal founder ask deep-linking the "write a review" page, target **15–20+ genuine reviews**. Then wire the real `aggregateRating` into `structured-data.ts` (§8b). **Never fabricate ratings — you may incentivize an *honest* review (a small gift card is allowed), never a *positive* one. G2 suppresses profiles that pay for stars.**

---

## 4. Capterra  (one form → also feeds GetApp + Software Advice)

**How it works:** go to Capterra's **"List Your Software"** vendor portal (Gartner Digital Markets), create a vendor account with `support@qravio.app`, and submit the product. Filling it **once propagates to GetApp + Software Advice** — after it's live, verify both picked it up (checklist §3). Moderated before publishing.

| Field | Value |
|---|---|
| Product name | `Qravio` |
| Website | `https://qravio.app` |
| Category | **QR Code Software** |
| Logo | `https://qravio.app/Icons/qravio_icon.png` |
| Short description | the **one-liner** above |
| Long / About description | the **review-platform description** above |
| Deployment | Cloud, SaaS, Web-Based |
| Supported devices | Web-based (mobile-responsive) — **no native iOS/Android app; don't claim one** |
| Free version | **Yes** |
| Free trial | Yes (Pro features) — set per reality |
| Starting price | **$9/month** (Starter); Free tier available |
| Pricing model | Per month (subscription) |
| Support | Email/Help Desk, Knowledge Base, FAQs |
| Languages | English |
| Vendor details | Qravio · founded Feb 2026 · Bangalore, India · 1–10 employees |
| Media | screenshots + (optional) demo video |

> Capterra reviews feed the whole Gartner network (Capterra + GetApp + Software Advice), so the §1 review drive counts triple here. Same ethics rule: honest reviews only, never paid-for-positive.

---

## 5. Alternatives directories (AlternativeTo · SaaSHub · Slant · SaaSworthy)

Position Qravio as an **alternative to**: Flowcode, QR Tiger, Uniqode, QR-Code-Generator.com, QRCode Monkey. Lead with the differentiator: **genuinely free, no-watermark, editable dynamic tier**. Tag *Free* + *Freemium*. This compounds your on-site `/[x]-alternative` pages.

| Field | Value |
|---|---|
| Name | `Qravio` |
| URL | `https://qravio.app` |
| Tagline | the **one-liner** above |
| Description | the **boilerplate** above |
| Tags | QR code generator, Free, Freemium, Analytics, Dynamic QR |

---

## When each profile goes live

Append its canonical URL to `COMPANY` in `qr_frontend/src/lib/constants/company.ts` (new fields like `g2`, `capterra`, `crunchbase`, `wikidata`, `alternativeTo`) and spread them into `sameAs` (`structured-data.ts:41`). **Rule: only add URLs that resolve 200 and are branded — never a 404 or empty stub.** Ping Claude to make that edit.
