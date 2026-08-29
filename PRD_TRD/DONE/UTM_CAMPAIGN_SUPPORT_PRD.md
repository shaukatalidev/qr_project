# PRD — UTM campaign support

> ✅ **SHIPPED 2026-08-29** — migration `0057`, across all three repos.
> **Scope delivered:** the `website` 302 (all three branches: plain, A/B, routing rules),
> per-variant `utm_content`, the builder section with a live preview, and the detail-page card.
> **Deferred to v1.1:** G7's landing-page CTAs and `list_links` items — 36 template files and
> ~66 hrefs, most of which are `tel:`/`mailto:`/`data:`/map links that must never be stamped.
> `applyUtm` fails open on all of them, so adopting them later is purely additive.
> **Open question 4** ("should `/click` carry UTMs?") was answered by finding that route was an
> **open redirect**; it is fixed separately and the answer is now "it can, safely, in v1.1".
> See `../DONE/UTM_CAMPAIGN_SUPPORT_TRD.md` §0 for the seven spec claims the code contradicted.

**Status:** Draft (detailed) · **Author:** Product · **Date:** 2026-08-28
**Priority:** Parity checkbox with real pull. Every serious competitor ships a UTM builder, but the stronger argument is that this is the only way a customer sees QR traffic **inside their own GA4** — which is where their marketing decisions actually get made.
**Tiers:** **All plans, ungated.** Zero COGS. Gating it pushes customers back to hand-typing UTM strings into the destination field, which is what they do today and what goes wrong (§2.2).
**Plan flags:** none new.
**Split from:** `CAMPAIGN_TAGS_ROLLUP` (shipped, `0025`). That gave QRs cross-folder tags and **our** rollup analytics; it never touches the destination URL. This is the other half — stamping `utm_*` on the outbound redirect so **their** analytics can attribute it. The two are complementary and must not be conflated in the UI.
**Repos:** `qr_backend`, `qr_cf_code`, `qr_frontend`.

---

## 1. TL;DR / Summary

A dynamic QR carries the five standard UTM parameters (`utm_source`, `utm_medium`, `utm_campaign`,
`utm_term`, `utm_content`) as **structured fields stored separately from the destination URL**. The
Worker merges them into the destination at redirect time.

The builder offers a UTM section with sensible defaults (`utm_source=qr`, `utm_medium=qr_code`,
`utm_campaign` from the QR's `campaign:` tag), channel presets, per-variant `utm_content` for A/B
destinations, and a **live preview of the exact final URL**.

The entire behavioural surface is one pure function, `applyUtm`, which never throws and fails open
to the unmodified destination.

## 2. Problem & Motivation

### 2.1 We give customers analytics; we do not give them attribution

Our dashboard says 5,000 scans happened. Their GA4 says 5,000 sessions arrived from
`(direct) / (none)` — because a QR scan is a direct hit with no referrer. The customer's manager
asks "did the poster work?", and answering it requires reconciling two systems by hand, by date,
with no join key.

This is not a reporting nicety. It is the difference between a QR being a line in a marketing plan
and a QR being an unmeasurable cost.

### 2.2 Customers already do this, and it fails in three specific ways

They paste UTMs into the destination field. Then:

1. **Editing the destination loses them.** Dynamic QRs exist so the destination can change after
   printing. Every edit means re-typing the UTM string (error-prone) or losing it (silent). The
   whole value proposition of a dynamic QR works against the manual approach.
2. **The encoding goes wrong.** `utm_campaign=Summer Sale 2026` unencoded; a `?` appended to a URL
   that already has one; a parameter placed after a `#fragment` where analytics never sees it. Each
   produces a link that either 404s or silently tracks nothing.
3. **They cannot vary it per A/B variant.** `ab_testing` is a paid feature, and the two variants of
   a split test are indistinguishable in the customer's own analytics — which defeats the point of
   running the split test in a tool that charges for it.

Storing UTMs as structured fields separate from the destination fixes all three, and it is only
possible **because we control the redirect**. This is a capability a static QR generator
structurally cannot offer, so it is a real differentiator rather than a checkbox.

### 2.3 We already have the campaign vocabulary

`CAMPAIGN_TAGS_ROLLUP` shipped `tags` / `qr_tags` with namespaced labels like
`campaign:summer-2026`, `channel:print`, `client:acme`. Defaulting `utm_campaign` from the QR's
`campaign:` tag makes the two features one coherent story — organise with tags, attribute with
UTMs — instead of two overlapping ones the user has to reconcile.

## 3. Goals & Non-Goals

### Goals

- **G1.** Store the five standard UTM parameters as structured, separately-editable fields on a
  dynamic QR, surviving destination edits untouched.
- **G2.** Merge them into the outbound URL at the edge, **correctly**: existing query string,
  existing `utm_*` keys, fragments, and encoding.
- **G3.** **Never break a destination.** Malformed, hostile or oversized input produces, at worst,
  the destination unmodified — never a broken redirect.
- **G4.** **Per-variant `utm_content`** for A/B destinations.
- **G5.** A **live preview of the exact final URL** in the builder, computed by the *same logic the
  Worker runs*.
- **G6.** Sensible defaults from what we already know (§2.3), always editable, never silently
  rewritten later.
- **G7.** Apply to landing-page outbound links too — the CTA on a `business` page, each item in
  `list_links` — not only the `website` redirect. That is where a large share of outbound clicks
  happen.

### Non-Goals

- **NG1 — no UTMs on non-HTTP destinations.** `tel:`, `mailto:`, `sms:`, `upi:`, `bitcoin:`,
  `whatsapp:`. Appending query parameters to these ranges from meaningless to **actively harmful**:
  a `upi:` URI with unexpected parameters can fail a payment. Enforced at the edge, not just hidden
  in the UI (§9).
- **NG2 — no custom parameter names** in v1 (`gclid`, `fbclid`, arbitrary keys). Five standard
  fields keep the UI honest and the validation tight.
- **NG3 — no reading the customer's GA4.** We write the parameters; their analytics reads them. No
  integration, no OAuth, no reporting on their property.
- **NG4 — no retroactive application.** Existing scans are not re-attributed and nothing rewrites
  history.
- **NG5 — no UTMs on static QRs.** The URL is in the pixels; there is no redirect to modify.
- **NG6 — no workspace-level UTM defaults** in v1. Attractive for agencies, but it adds a settings
  surface and an inheritance rule. §12 Q2.

## 4. Personas & user stories

**Meera — marketer at an SMB, Pro plan**
> *The poster QR shows up in my GA4 as `qr / qr_code / spring-launch`. I can finally compare it
> against email and paid in one report, using the tool my boss already reads.*

**Priya — agency, Agency plan**
> *My client's own analytics attributes the traffic I generated, so my invoice has evidence behind
> it instead of a screenshot of someone else's dashboard.*

**Arun — running an A/B test**
> *My two variants carry different `utm_content`, so their conversion difference shows in my funnel,
> not just in Qravio's scan counts.*

**Ravi — changing a destination**
> *I edit the URL and my tracking survives, because it was never part of the URL.*

## 5. UX

### 5.1 The section

**"Campaign tracking (UTM)"** on the builder's content step and on the QR detail page. Collapsed by
default with a one-line summary when set (`qr / qr_code / spring-launch`).

- Five inputs, labelled with both the human name and the parameter (`Source (utm_source)`).
- `utm_source` and `utm_medium` pre-filled `qr` / `qr_code`, editable.
- `utm_campaign` pre-filled from the QR's `campaign:` tag if it has one, else a slug of the QR name.
- **Presets row** for the common channels — Print, Poster, Flyer, Table tent, Packaging, Business
  card — each filling `utm_medium` / `utm_content` in one press.

### 5.2 The live preview (the highest-value element)

Directly beneath the inputs, the **exact final URL**, updating as they type, with a copy control.

This is what prevents §2.2's encoding failures — the customer sees `Summer+Sale+2026` and
recognises it, or sees a mangled URL and fixes it, *before* printing 5,000 flyers.

**It must be truthful.** A preview computed by different logic than the Worker is worse than no
preview, because it converts an invisible failure into a confidently-wrong promise. TRD §7 makes
this a mirrored-pair guarantee with a test, following the precedent already set for maps URLs.

### 5.3 Per-variant

In the A/B card, each variant gets its own `utm_content`, defaulting to the variant key. The
preview shows both final URLs.

### 5.4 Where it is hidden

- `category === 'static'` — with a one-line reason and the "convert to dynamic" path.
- Non-HTTP types (`phone`, `upi`, `whatsapp`, `sms`, `email`, `wifi`, `bitcoin`, `paypal`) — with a
  one-line reason, not a disabled control with no explanation.

### 5.5 Detail page

The effective UTM set and the final URL, copyable. Copyability is not decoration: people paste that
URL into their own campaign spreadsheets and briefs.

## 6. Merge rules — the whole feature lives or dies here

| # | Situation | Behaviour | Why |
|---|---|---|---|
| M1 | Destination has no query string | Append `?utm_source=…&…` | |
| M2 | Destination already has a query string | Append with `&` | Two `?` breaks the URL |
| M3 | Destination already has a `utm_*` key | **The QR's value replaces it** | The QR is the more recent, more deliberate configuration. Duplicate keys are resolved inconsistently by different analytics tools. |
| M4 | Destination has a fragment (`#section`) | Parameters go **before** the fragment | After it, analytics never sees them, and the URL still looks right |
| M5 | A UTM value is empty or whitespace | **Omit the key entirely** | `utm_term=` is noise in every report |
| M6 | Any value | Encoded **exactly once** | Double-encoding yields `%2520`, invisible until someone reads their GA4 |
| M7 | Non-HTTP(S) scheme | **No modification at all** | NG1 |
| M8 | Result would exceed ~2,000 chars | Serve the destination **unmodified** | A truncated URL is a broken URL |
| M9 | Anything unexpected throws | Return the destination unmodified | G3 |

## 7. Where UTMs are applied

| Surface | Applies? | Note |
|---|---|---|
| `website` 302 redirect | **Yes** | The primary case. Must run *after* the existing `ensureScheme` coercion, or a legacy scheme-less destination fails the URL parse and silently gets no UTMs. |
| A/B variant destination | **Yes**, with per-variant `utm_content` | G4 |
| Routing-rule-selected destination | **Yes** | Applied after variant selection, so the served URL is the one stamped |
| Landing-page CTAs (`business`, `event`, `coupon`) | **Yes** | G7 |
| `list_links` items | **Yes** | G7 |
| `/click/:linkId?target=` tracking redirect | **Careful — see TRD §6.2** | Its target arrives in a query parameter; applying UTMs there must not weaken whatever validation guards it |
| vCard `.vcf` download | No | A file, not a link |
| Password-gate proxy | No | Not an outbound destination |

## 8. Gating

Ungated. It is a text field that improves the customer's own reporting, costs us nothing, and
paywalling it guarantees the messy manual workaround that generates the support load in §2.2.

## 9. Security & validation

Two independent layers, so one mistake cannot produce a bad URL:

1. **On write** — length ceiling (200 chars per value), strip control characters and newlines,
   reject unknown keys. Deliberately permissive otherwise: campaign names legitimately contain
   spaces, `+`, `&`, and non-Latin scripts, and rejecting those pushes users back to hand-typing
   into the destination.
2. **On read (at the edge)** — scheme allowlist (`http`, `https` only) and single-pass encoding via
   `URLSearchParams`.

**The scheme allowlist must live at the edge, not only in the UI.** The public API can set the field
on any QR type, so the UI is not the security boundary. NG1's `upi:` case is the one with real
consequences.

## 10. Success metrics

| Metric | Why |
|---|---|
| Share of dynamic QRs with UTMs set | Adoption |
| Share using the defaults unedited | Validates G6's defaults |
| Preset usage vs manual entry | Validates §5.1's channel list |
| **Destination edits on QRs with UTMs** | The workflow this feature exists to make safe (§2.2 #1) |
| Preview copy-to-clipboard events | Confirms §5.2 is the value we think it is |
| **"My link is broken" tickets, week one** | This feature modifies the most load-bearing string in the product. Watch it closely. |

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **A merge bug breaks live, printed QRs** | **Critical** | One pure function, table-driven tests per rule, outermost try/catch returning the original, and Worker-first deploy so a bad KV field is simply ignored. |
| Double-encoding | High | Build with `URLSearchParams` and `url.toString()`; **never** concatenate strings. Tested with spaces, `&`, `=`, `+`, `#` and Devanagari. |
| UTMs appended to `upi:` break a payment | High | Scheme allowlist enforced at the edge (§9). |
| **The builder preview and the Worker disagree** | High | Mirrored-pair test importing the real Worker module, following the `maps.js` precedent exactly (TRD §7). |
| A hostile value injects into the URL | Medium | Validate on write, encode on read — two independent mistakes required. |
| `sync_qr_to_kv`'s explicit select is not updated → UTMs vanish on an unrelated save | Medium | TRD §3.2; the same failure that caused permanent `page_design` drift. |
| Users expect **our** dashboard to report on UTMs | Medium | Section copy points at campaign tags for our rollups. Do not blur the two features. |

## 12. Open questions

1. **Should `utm_campaign` auto-follow the `campaign:` tag when the tag later changes?** v1: **no**
   — it is a default at set time. Auto-following changes a printed QR's attribution under the
   customer mid-campaign, which is worse than a stale value.
2. **Workspace-level UTM defaults?** Attractive for agencies (NG6). Adds a settings surface and an
   inheritance rule; v2.
3. **Custom parameters (`gclid`, `fbclid`)?** Excluded (NG2); revisit if asked more than twice.
4. **Should the `/click` tracking redirect carry UTMs?** §7 and TRD §6.2 — decide during
   implementation, on evidence about how that path validates its target.
