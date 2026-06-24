# Off-Site GEO Checklist — Qravio

**Goal:** Build the off-site authority + consensus that on-page SEO can't. Per the SEO/GEO roadmap, ~80% of GEO weight is off-site, and it's currently at near-zero. This is the highest-leverage SEO work remaining. Almost all of it is **user action (off-codebase)** — the only in-repo work is the two code touchpoints in §8.

**Strategic hook to lead with everywhere:** *genuinely free, no-watermark dynamic QR tier* + *real-time scan analytics* + *editable after printing*. That's the differentiator that wins the competitor-alternative cluster and the AI "which is best / which is free" consensus.

**Status legend:** `[ ]` todo · `[~]` in progress · `[x]` done · 🔒 = blocks later steps

---

## §0 — Lock the brand entity FIRST 🔒

Entity SEO is a **consistency** game: Google/LLMs gain confidence when the *same* name, URL, logo, description, and category appear identically across many sources. Inconsistent profiles create *competing* entities and dilute the signal. So define the canonical block ONCE and paste it **verbatim** everywhere below.

### Canonical brand block (copy-paste verbatim — do not paraphrase per-site)
```
Name:            Qravio
URL:             https://qravio.app
Category:        Dynamic QR Code Generator / QR Code Management Software
Logo:            https://qravio.app/Icons/qravio_icon.png
Support email:   support@qravio.app
HQ / location:   Bangalore, India
Founded:         February 2026

One-liner (≤120 chars):
Free dynamic QR code generator with real-time scan analytics — edit your QR
codes anytime, no reprinting, no watermark.

Boilerplate (≈50 words — matches the site's schema.org description):
Qravio is a dynamic QR code generator with real-time scan analytics, a
genuinely free no-watermark dynamic tier, and custom domains. Create editable,
trackable QR codes for websites, PDFs, vCards, business profiles, events, WiFi,
and more — and update where they point without reprinting.
```

### Tasks
- [x] **Founding year filled: February 2026** (locked — never change). Founder name left non-public for now (optional; add to Crunchbase/Wikidata later if desired).
- [x] **Social handles created, branded, and verified live (2026-06-20):** handle = **`qravioapp`** (bare `qravio` is taken on X by a dead 2012 squatter). X `https://x.com/qravioapp` + LinkedIn `https://www.linkedin.com/company/qravioapp`. `company.ts:15-16` updated → flows to `sameAs` (§8a partly done) + footer links. NEEDS FE DEPLOY to go live.
- [x] Brand kit saved → `BRAND_KIT.md` (repo root): canonical block + ready-to-paste per-platform fields. Use it for every signup (copy-paste, no retyping).

---

## §1 — Review platforms (HIGHEST weight) 🔒 for §8 aggregateRating

These are the single strongest SaaS GEO signal — LLMs and Google both lean on G2/Capterra consensus for "best / top / which should I use" queries. Order = priority.

- [ ] **G2** — create/claim the Qravio listing (g2.com). Category: QR Code Generator Software.
- [ ] **Capterra** (capterra.com) — vendor listing. *Single submission also feeds GetApp + Software Advice* (all Gartner Digital Markets) — fill the vendor portal once.
- [ ] **Product Hunt** — plan a launch (not just a profile). Pick a Tue–Thu, line up hunters/upvoters in advance, lead with the free-no-watermark angle. PH pages get cited and rank fast.
- [ ] **TrustRadius** (trustradius.com) — claim profile.
- [ ] **SourceForge / Slashdot** (optional, easy domain) — software listing.

### Review drive — target 15–20+ genuine reviews 🔒
The profiles are worthless empty. You need real reviews to (a) trigger rich-result stars, (b) feed the `aggregateRating` in §8, (c) become the consensus LLMs quote.
- [ ] Export your active/paying users; segment the happiest (high scan volume, repeat logins, support praise).
- [ ] Send a personal ask (founder email > automated blast). Make it 2 clicks: direct deep-link to the G2/Capterra "write a review" page.
- [ ] Add an in-app prompt for power users (e.g., after they create their 3rd QR or hit an analytics milestone). Gate it so you ask *engaged* users, not first-session bounces.
- [ ] **Ethics / ToS line:** you may incentivize *leaving an honest review* (a small gift card is allowed by G2/Capterra programs); you may **NOT** incentivize *positive* reviews or buy fake ones — that gets the profile suppressed. Ask for honesty, not 5 stars.
- [ ] Once ~10+ real reviews land → record the true average rating + count → wire into §8.

---

## §2 — Knowledge-graph entity (Wikidata, Crunchbase, LinkedIn)

These are the structured sources Google's Knowledge Graph and LLMs ingest directly. High GEO value, low ongoing cost.

- [ ] **Wikidata** — create a Qravio item (instance of: *software* / *business*). Add: official website, logo, inception date, country (India), and statements that match the canonical block. This is the strongest free entity signal and is the one most directly read by AI models.
- [ ] **Crunchbase** — create the company profile (free tier). Even a basic profile feeds the knowledge graph + earns a backlink.
- [ ] **LinkedIn company page** — must exist + be branded (it's already in `sameAs`). Post occasionally so it's not a ghost.
- [ ] **Google Business Profile** — only if you want a local/India entity; optional for a pure SaaS, but it strengthens NAP consistency.
- [ ] After the above are live, you become eligible for a **Google Knowledge Panel** (don't "apply" — it appears once entity confidence is high; Wikidata + Crunchbase + consistent NAP are the inputs).

---

## §3 — "Alternatives" directories (feeds the competitor-cluster wedge)

Your on-site wedge is the `/[x]-alternative` + `/vs/[competitor]` cluster. These directories are where users *and* LLMs go for "alternatives to Flowcode/QR Tiger/Uniqode" — getting Qravio listed there with the free-tier hook compounds that wedge.

- [ ] **AlternativeTo** (alternativeto.net) — add Qravio as an alternative to: flowcode, qr-tiger, uniqode, qr-code-generator.com, qrcode-monkey. Tag *Free* + *Freemium*.
- [ ] **SaaSHub** (saashub.com) — listing + position as alternative to the same five.
- [ ] **Slant** (slant.co) — add Qravio to "best QR code generator" question(s).
- [ ] **SaaSworthy** (saasworthy.com) — listing.
- [ ] **GetApp** — covered by the Capterra submission (§1), verify it propagated.
- [ ] After each goes live, note the profile URL for §8 `sameAs`.

---

## §4 — Community consensus (Reddit / Quora) — DISCLOSED & honest

This is where AI models harvest "real people say…" consensus. Rules: **always disclose** you're affiliated with Qravio, only post where genuinely relevant, lead with a real answer (don't drop a link into an empty comment). Astroturfing gets the brand poisoned in exactly the corpus you're trying to win.

- [ ] Build a watch-list of threads/questions. Target subs: r/QRcode, r/smallbusiness, r/marketing, r/restaurateur, r/Entrepreneur, r/web_design, r/nonprofit.
- [ ] Quora: answer "best free QR code generator", "how to edit a QR code after printing", "static vs dynamic QR code", "do QR codes expire".
- [ ] For each: give the genuinely useful answer first; mention Qravio only where it's the honest best fit (free editable dynamic tier); disclose ("I work on Qravio, but…").
- [ ] Track which answers get traction; those are the ones LLMs are most likely to quote.

---

## §5 — Listicle / editorial inclusion ("best QR code generator 2026")

Ranking listicles dominate the head-term SERP you're *not* chasing directly — but getting *included* borrows their authority and gets you into the AI training/citation corpus.

- [ ] Identify the top 15–20 "best QR code generator" / "best free QR code generator 2026" articles.
- [ ] Outreach to each author/editor with the differentiator pitch (free, no-watermark, *editable* dynamic tier — most "free" tools watermark or are static-only). Offer a free Pro account to test.
- [ ] Prioritize publications that already rank for your wedge terms (they pass the most relevant equity).

---

## §6 — Digital PR / backlinks / unlinked mentions

Earns referring domains (DR growth KPI) — the thing that actually closes the authority gap vs incumbents.

- [ ] **Stats hub as linkbait** — the roadmap's "State of QR Scans 2026" original-data page. *Only with REAL data from your own scan dataset* (do not fabricate). Original stats are the most link-earning asset you can ship; journalists/bloggers cite numbers.
- [ ] **HARO / Connectively / Featured** — respond as a QR/SaaS source to relevant journalist queries → earns high-DR editorial links.
- [ ] **Partnerships / integrations** — any tool you integrate with (or template partners) → mutual listing pages.
- [ ] **Unlinked-mention reclamation** — set a Google Alert / search for "Qravio" mentions without a link; ask for the link.

---

## §7 — On-site schema reinforcement (light, supports the above)

- [ ] Once §1 reviews exist → stars show in SERP via the `aggregateRating` (see §8). No new pages needed.
- [ ] Keep `Organization.sameAs` (§8) in lockstep with every profile that goes live — it's the on-site half of the entity-consistency signal.

---

## §8 — CODE TOUCHPOINTS (the only in-repo work) ⚙️

Two edits, both in the frontend, both already scaffolded:

### 8a — Add every live profile URL to `Organization.sameAs`
- File: `qr_frontend/src/lib/seo/structured-data.ts:41`
- Currently: `sameAs: [COMPANY.twitter, COMPANY.linkedin]`
- Action: as each profile in §1–§4 goes live, append its canonical URL. Cleanest: add fields to `COMPANY` in `qr_frontend/src/lib/constants/company.ts` (e.g. `g2`, `capterra`, `productHunt`, `crunchbase`, `wikidata`, `alternativeTo`) and spread them into `sameAs`.
- Rule: **only add URLs that resolve 200 and are branded** — never a 404 or an empty stub.

### 8b — Pass real `aggregateRating` to SoftwareApplication
- The option is already wired: `buildSoftwareApplicationLd({ aggregateRating })` (`structured-data.ts:68/127`).
- Action: once §1 has ~10+ genuine reviews, pass the **true** average + count where the homepage (or flagship) builds the SoftwareApplication LD.
- Rule (already in the code comment): **never fabricate** — wrong/invented ratings are a manual-action risk and a GEO credibility hit. Numbers must match the public review platforms.

---

## §9 — Measurement (know if it's working)

Track monthly (KPIs from the roadmap):
- [ ] **Referring domains / DR** (Ahrefs/Semrush free tiers or Search Console links report) — primary off-site KPI.
- [ ] **Off-site citation count** — how many of §1–§5 list/mention Qravio.
- [ ] **AI share-of-voice** — ask ChatGPT/Gemini/Perplexity "best free dynamic QR code generator" / "alternative to QR Tiger" monthly; record whether Qravio appears and how it's described. This is the GEO north star.
- [ ] **GA4 AI-referral** (medium = ai-assistant) and the wedge keyword ranks (not the head term).

---

## Suggested cadence

| Week | Focus |
|------|-------|
| 1 | §0 lock entity + brand kit · create G2/Capterra/Product Hunt/TrustRadius profiles (§1) · Wikidata + Crunchbase (§2) |
| 2 | Launch the review drive (§1) · all alternatives directories (§3) |
| 3 | Product Hunt launch (§1) · start disclosed Reddit/Quora cadence (§4) |
| 4 | Listicle outreach (§5) · wire §8a as profiles land |
| 5+ | Stats hub + digital PR (§6) · §8b once reviews ≥10 · monthly measurement (§9) |

> Sequence rule: **§0 before everything** (consistency), **§1 reviews before §8b** (need real numbers), **profiles live before §8a** (no 404s in `sameAs`).
</content>
</invoke>
