# PRD — Email-Signature Embed for vCard Plus

**Status:** Draft · **Author:** Product · **Date:** 2026-07-25
**Priority:** Quick win / distribution multiplier. Uniqode and QRCodeChimp both distribute the digital business card as an **email-signature snippet** (QR image + link); we ship `vcard_plus` but give the user no way to put it in the one place a professional's contact card actually belongs. Small effort, small-but-real B2B distribution lift. Do not gold-plate it.
**Tiers:** **All plans, ungated.** `vcard_plus` is in `dynamic_qr_types` for **every** non-custom plan including Free (`0009` seed, re-affirmed wholesale by `0027_open_all_qr_types.sql`). Gating the *distribution surface* for a type we hand out free would be incoherent. The only entitlement read is the **existing** `white_labeling` flag, which suppresses the "Powered by Qravio" attribution line for Agency.
**Plan flags:** **None.** No new flag, therefore no `FEATURE_ENFORCEMENT` entry, no plan seed, and **no migration** (§12).
**Split from:** the shipped `vcard_plus` type (`VCardPlusContent.tsx`, `qr_vcard_details`, `qr_cf_code/src/pages/vcard/`) and the shipped client-side QR renderer (`useQRPreview` → `qr-generator.ts`). **Explicitly unbundled from NFC** — the competitive analysis's Skips section rejects in-house NFC, and this feature must carry **zero** hardware, tag-encoding, or NDEF dependency. It is a text-and-an-image feature.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`; ships **as-drafted** — ungated, no migration, no Worker change; the hosted-PNG design (client renders with the user's own saved design → publish to the existing public bucket → absolute `https://` URL) is the correct answer to email clients stripping `data:` URIs. Decision: **fold a best-effort delete of the published signature PNG into the QR-delete path in this PR** (Open Q4 / R6) — do not add a second uncascaded public artifact while the account-deletion cascade is a known liability. (The broader storage-orphan cleanup — QR file uploads, avatars, branding logos — still belongs in that cascade work; this fixes only the artifact this feature introduces.) Two build notes: the publish endpoint must keep `upload_avatar`'s validation (PNG magic-bytes + size cap + workspace-scoped path — it writes to a **public** bucket); Outlook-desktop (Word engine) rendering — table layout, HTML-attribute sizing, hex colors, system fonts — is the **named release gate**. Other open questions accepted per the PRD (ship Card + Compact; no phone/email text lines; vCard-only in v1; publish on panel open). Field escaping + the sandboxed `srcdoc` preview (R5) are non-negotiable.

---

## 1. TL;DR / Summary

A user who owns a saved **vCard Plus** (or `vcard`) QR gets a **"Email signature"** panel on the QR detail
page. One click produces a **portable, inline-styled HTML block** — a `<table>` holding the QR image plus
their name, title, company and a link to the card — that they paste into Gmail / Outlook / Apple Mail
signature settings. Their card now rides on every email they send.

The whole feature is: **one pure string builder** (build inline-styled HTML from data we already have), **one
copy panel**, and **one small backend endpoint** that publishes the rendered QR PNG to the existing public
Supabase Storage bucket so the snippet has an **absolute image URL** an email client can actually fetch.

**No new data model. No migration. No Worker change. No new plan flag. No NFC.** The snippet points at the
short URL the Worker already serves; the image is served by Supabase Storage's CDN.

The one genuinely non-obvious engineering fact drives the whole design: **email clients cannot render our QR
codes as they exist today.** Every QR image in the product is generated client-side into a canvas `dataUrl`
(`useQRPreview` → `generateQRCode`). Gmail, Outlook.com and Outlook desktop all strip or block `data:` URIs,
external CSS, `<script>`, `<svg>` and web fonts. So the feature is not "print a string" — it is "get a
**hosted PNG at a stable https URL** and wrap it in HTML that survives Outlook's Word rendering engine."
That publish step is the only new backend surface, and it mirrors `upload_avatar` almost line for line.

## 2. Problem & Motivation

**We ship the card and then abandon the distribution.** `vcard_plus` is one of our most-built types and it is
free on every plan. Once a user saves one, the product's answer to "now what?" is: download a PNG, or copy a
short link. Both put the burden of distribution on them. Competitors close the loop — Uniqode and
QRCodeChimp both generate an **email-signature block** as a first-class output of the digital card, because
that is where a professional's contact details already live and where the card gets seen dozens of times a
day without any further effort.

**The email signature is the highest-frequency, lowest-effort surface a B2B user owns.** A sales rep sends
40 emails a day. A signature QR is seen by every recipient, forwarded with every thread, and costs the user
a single paste. Nothing else in our product has that ratio of one-time effort to recurring impressions —
and for a *dynamic* QR, the destination stays editable forever after the signature is pasted, which a
static contact block in a signature can never do. That is the honest differentiator: **not the snippet, the
fact that the thing it points at is editable and tracked.**

**Today the user cannot do this themselves, even manually.** They could download the PNG — but a signature
needs an image at a **URL**, not a file, and a pasted local image either becomes an inline attachment (which
many clients strip on reply/forward) or breaks entirely. They would have to host the PNG somewhere
themselves. That hosting step is exactly what we are supplying.

**It is near-zero cost.** One storage object per published card (a ~10–20 KB PNG), no per-use COGS, no AI,
no email sending, no cron, no edge change. The effort is concentrated in getting the HTML right across five
mail clients — which is craft, not scale.

## 3. Goals & Non-Goals

**Goals**
- Give any saved `vcard_plus` / `vcard` QR a **one-click copyable email-signature block**.
- Produce HTML that **actually renders** in Gmail (web + mobile), Outlook 365 web, **Outlook desktop
  (Windows/Word engine)**, and Apple Mail (macOS + iOS) — the five clients that cover our buyers.
- Publish the QR image, **rendered with the user's own saved design** (colors, logo, eye shapes, frame), to a
  **permanent absolute `https://` URL** so the snippet is self-contained.
- **Degrade gracefully** when remote images are blocked (the corporate default): the block always carries a
  plain text hyperlink beside the QR, so a blocked image never leaves a dead signature.
- Offer a **live, faithful preview** of the block before copying, isolated from our dashboard CSS.
- Ship **ungated on every plan**, with the existing `white_labeling` flag suppressing our attribution line.

**Non-Goals**
- **No NFC, no hardware, no tag writing, no NDEF.** (Deliberate unbundling — the competitive analysis rejects
  in-house NFC outright. This feature must never become the on-ramp to it.)
- **No email sending.** We generate a snippet the user pastes; we never send mail on their behalf, and the
  unpublished `_dmarc.qravio.app` record is therefore **not** a gate.
- **No signature *management*** — no "push this signature to my team's Google Workspace", no signature
  templates library, no org-wide enforcement. That is a different product (Exclaimer, WiseStamp) and a
  different buyer.
- **No per-source scan attribution in v1.** `qr_scan_events` has no `utm_*` column and `recordScan` captures
  only `referer`/`referer_domain` — a phone-camera scan of a signature QR carries no referrer at all. We
  will **not** pretend to report "scans from your email signature." (Future: §7.)
- **No open-tracking.** The hosted image will be fetched by every recipient's mail client. We will **not**
  mine those fetches as a read/engagement signal — turning a user's signature into an unconsented tracking
  pixel is a DPDP/GDPR liability we are not taking on for a quick win.
- **No server-side QR rendering.** We will not add a Python QR library and re-implement the renderer; it
  would drift from the canvas renderer and silently lose logo/gradient/frame fidelity (§11 R2).
- **No snippet for non-vCard types in v1** — the block's text column is name/title/company from
  `qr_vcard_details`; a `website` QR has nothing to put there. (Open Q3.)

## 4. Target Users & Personas

| Persona | Who | Job-to-be-done | Today's pain |
|---|---|---|---|
| **Field Sales Rep ("Sana")** | Emails 40 prospects/day, carries a digital card | Put the card in front of every recipient with one paste | Downloads a PNG, has nowhere to host it; signature stays text-only |
| **Consultant / Solo Founder ("Amit")** | One-person brand, no IT | A professional signature with a scannable card | Hand-builds a signature in Gmail; a pasted image breaks on reply |
| **Agency Account Manager ("Meera")** | Manages client-facing staff | Roll the same card block out to a small team | Copies a screenshot around; no consistent block, no white-label |
| **Recruiter / BD ("Leo")** | High-volume outbound | Recipients save the contact without a back-and-forth | Attaches a .vcf that spam filters flag |

Primary buyer is the **B2B individual/SMB** already using `vcard_plus`. This is a **retention/activation**
feature, not an acquisition one — its job is to make the card they already built visibly useful.

## 5. User Stories

- As a **sales rep**, I want to copy a ready-made email-signature block for my card, so that every email I
  send carries a scannable contact card without me building HTML.
- As a **consultant**, I want the block to look right in Gmail *and* in Outlook, so that I don't discover
  three weeks later that half my recipients saw a broken box.
- As **anyone whose recipient blocks images**, I want a working text link beside the QR, so that a blocked
  image never leaves my signature dead.
- As a user who **later restyles my QR**, I want the image in my already-pasted signature to pick up the new
  design, so that I don't have to re-paste the block into every device.
- As an **Agency (white-label) user**, I want no "Powered by Qravio" line in the block, so that my client-
  facing signature stays my brand.
- As a **privacy-minded user**, I want to know exactly what the hosted image is and what it isn't, so that I
  can be sure I'm not attaching a tracking pixel to my correspondence.
- As a user pasting into **Gmail's signature box**, I want the copy to land as a *rendered block*, not as
  visible HTML source, so that it just works.

## 6. UX / Product Flow

**6.1 Entry point — QR detail page**
1. On a saved `vcard_plus` / `vcard` QR, the overview tab gains an **"Email signature"** card, sitting under
   the existing QR preview / short-URL card (`qr-preview-card.tsx`). It is only offered for a **saved**
   dynamic card QR — the block needs a `short_code` and a `qr_id`, so there is no pre-save state to handle.
2. The card shows a **live preview** of the block, a **layout** toggle (**Card** / **Compact**), a **QR size**
   toggle (**S 96px / M 120px**), and two copy buttons.
3. First render triggers a one-time **publish**: the client renders the QR PNG from the QR's *saved* design
   (the exact `useQRPreview` pipeline) and uploads it to the public storage bucket at a deterministic path.
   The returned public URL is what the snippet's `<img src>` uses.

**6.2 The two copy modes (this is the part that decides whether the feature works)**
- **"Copy signature"** — writes **both** `text/html` and `text/plain` to the clipboard. This is the mode that
  matters: pasting into Gmail's / Outlook web's WYSIWYG signature editor lands the **rendered block**. A
  plain-text copy of HTML source would paste as visible markup and read as broken.
- **"Copy HTML source"** — plain text, for Outlook desktop's "edit signature source", for signature-manager
  tools, and for anyone templating it.
- If `navigator.clipboard.write` with an HTML flavor is unavailable (Firefox), the first button is hidden and
  the panel falls back to source-copy plus a **selectable `<pre>`** — the exact degradation
  `EmbedSnippet.tsx` already uses when the clipboard is blocked.

**6.3 The block itself**
- **Card layout:** a two-column `<table>` — QR image left (96/120 px), text right: **Name** (bold), job title
  · company, then a link line ("View my contact card" → the short URL). Optional attribution line below.
- **Compact layout:** QR + a single link line. For users who already have a long signature.
- Every style is **inline on the element**. Table-based layout, `border="0" cellpadding="0" cellspacing="0"`,
  `role="presentation"`. `width`/`height` as **HTML attributes** (Outlook ignores CSS sizing on images).
  System font stack only. Hex colors only. **No** `<style>`, `class=`, `<script>`, `<svg>`, `data:` URI, web
  font, flexbox, or grid. Alt text on the image names the card.
- **Attribution:** a small "Contact card by Qravio" line, **suppressed** when the workspace has
  `white_labeling` — mirroring `build_entitlements` and the report `white-label-footer.tsx` precedent.

**6.4 Preview fidelity**
The preview renders the *same* HTML string in a **sandboxed `<iframe srcdoc>`**, so our Tailwind/global CSS
cannot leak in and flatter the result. What the user sees is what the mail client gets — and the sandbox also
neutralizes anything unexpected in user-authored text (§11 R5).

**6.5 Instructions**
Three short client-specific hints under the panel (Gmail: Settings → See all settings → Signature; Outlook:
Settings → Mail → Compose and reply; Apple Mail: Settings → Signatures), because "where do I paste this" is
the single most likely support question. Copy only, no screenshots, no per-client wizard.

**6.6 Re-publish on design change**
The image path is deterministic (`{workspace_id}/{qr_id}`) and uploaded with upsert, so re-opening the panel
after a design edit **overwrites the same URL** — already-pasted signatures pick up the new design once the
CDN TTL rolls. The panel says so plainly rather than implying instant propagation (§11 R3).

## 7. Scope

**In scope (v1)**
- Pure snippet builder: data + options → inline-styled HTML string, with HTML escaping of every user field.
- "Email signature" panel on the QR detail page for `vcard_plus` / `vcard`: sandboxed live preview, layout
  toggle (Card/Compact), size toggle (S/M), dual-mode copy + `<pre>` fallback, paste instructions.
- One backend endpoint publishing the client-rendered PNG to the existing public bucket at a deterministic,
  workspace-scoped path; returns the permanent public URL.
- `white_labeling`-conditional attribution line (existing flag; no new flag).
- Client-compatibility test matrix (Gmail web/mobile, Outlook 365 web, **Outlook desktop**, Apple Mail
  macOS/iOS) as a release gate.

**Out of scope / Future**
- **NFC / physical tags of any kind** *(permanently out — see Skips in the competitive analysis)*.
- Source attribution for signature scans — needs a `utm_source`-style column on `qr_scan_events` **and** a
  Worker query-param capture; `ScanEventPayload` has no such field today *(future)*.
- Team/org signature rollout, Google Workspace push, signature enforcement *(different product)*.
- Snippet for non-vCard dynamic types *(future, trivial once we decide what the text column says — Open Q3)*.
- A hosted "signature page" or per-signature short link *(unnecessary; reuse the card's short URL)*.
- Downloadable `.htm` signature file for Outlook desktop's signature folder *(future polish)*.
- Photo/avatar in the block *(future; the vCard avatar isn't universally set and doubles the image surface)*.
- Deleting the published PNG when the QR is deleted — **flagged as a real gap, see §11 R6 / Open Q4.**

## 8. Pricing & Packaging

| Surface | Tier | Flag / Limit |
|---|---|---|
| Email-signature snippet for vCard Plus / vCard | **All plans (Free, Starter, Pro, Agency)** | **None** (ungated) |
| "Contact card by Qravio" attribution suppressed | **Agency** | `white_labeling` (**existing** flag) |

**Why ungated — and this one isn't a close call.** `vcard_plus` is creatable on **Free** (`0009` seed) and
`0027_open_all_qr_types.sql` deliberately removed QR *type* as a paywall lever across the board. Putting a
paywall on the act of *distributing* a QR type we give away would be an incoherent fence, and it would blunt
the only real payoff: our brand riding along in the attribution line of every Free user's outbound email.
The Free tier's attribution line is, in effect, this feature's business case.

**No new plan flag ⇒ no migration, no `FEATURE_ENFORCEMENT` entry, no `test_feature_gate_coverage` surface.**
This is a deliberate simplification, not an oversight: the house guardrail exists so a flag can't ship
ungated, and the correct way to satisfy it is to **not add a flag**.

**The existing white-label hook does the tier work for free.** Agency already pays for
`white_labeling`; extending it to the signature attribution is a one-line `canAccessFeature` read and adds
a tangible, visible benefit to a tier that mostly buys invisible ones.

## 9. Success Metrics & KPIs

**Adoption**
- ≥ **20%** of workspaces with at least one `vcard_plus` QR publish a signature within 60 days of GA.
- ≥ **60%** copy-completion rate among users who open the panel (opened → clipboard write succeeded). A low
  rate means the panel isn't self-explanatory, not that the feature isn't wanted.

**Distribution effect (measured honestly, given no UTM)**
- **Median scans per card, published-signature cohort vs non-published cohort**, over the 30 days after
  publish. This is a cohort comparison, not attribution — we say so in the readout. It is the only signal we
  can produce without adding a scan-events column, and it is enough to answer "did this move anything."

**Correctness (the bar that actually matters)**
- **Renders correctly in 5/5 clients** in the manual matrix — Gmail web, Gmail iOS/Android, Outlook 365 web,
  **Outlook desktop (Windows)**, Apple Mail macOS/iOS. **Outlook desktop is the release gate**; the other
  four rarely break table-based inline HTML.
- **Zero broken-image reports** on published signatures (the image URL must be permanent and public).
- **Zero "my signature shows HTML code"** tickets — i.e. the `text/html` clipboard path works where it is
  offered, and the fallback is clearly labeled where it isn't.

**Non-metric (deliberate):** we do **not** track image-fetch counts. See §3 Non-Goals.

## 10. Rollout Plan

**Phase 0 — Builder + publish endpoint (internal).**
Ship the pure snippet builder with its unit tests and the publish endpoint. No UI. Verify: the endpoint
upserts at a workspace-scoped deterministic path, rejects a `qr_id` that doesn't belong to the caller's
workspace, and returns a URL that is publicly fetchable with no auth from a clean session.

**Phase 1 — Panel behind a FE flag (closed).**
Add the detail-page panel (preview, toggles, dual copy, instructions) for internal + a few design-partner
workspaces. **Run the 5-client matrix.**
- **Acceptance:** publish → copy → paste into Gmail *and* Outlook desktop → block renders, QR scans from a
  phone at the S size on a normal laptop screen → link click lands on the card → images-off still shows a
  working text link → an Agency workspace sees no attribution line → editing the QR design and re-copying
  updates the same URL.

**Phase 2 — GA.**
Remove the FE flag, add a help-center entry ("Add your contact card to your email signature"), flip the
comparison matrix cell, and mention it on the vCard landing/SEO page. Consider a one-time in-app nudge on
existing `vcard_plus` QRs.

**Cross-service gates — all clear, stated explicitly:**
- **No Worker change ⇒ `npm run deploy:prod` is NOT required.** The snippet targets the existing short URL.
- **No email sent ⇒ the unpublished `_dmarc.qravio.app` record is NOT a gate.**
- **No migration ⇒ no Supabase SQL-editor step, no slot to reserve** (§12).
- **No cron, no KV write, no new external service, no new env var.**

## 11. Risks, Edge Cases & Open Questions

**R1 — Outlook desktop (the Word rendering engine) is the whole risk.** It has no flexbox/grid, ignores CSS
sizing on images, mangles margins, and drops modern color syntax. A block that looks perfect in Gmail can be
a stack of misaligned junk there. **Mitigation:** table layout with `border`/`cellpadding`/`cellspacing`
attributes, sizing as HTML attributes, hex colors only, system fonts only — and **Outlook desktop is a named
release gate**, not a nice-to-have check.

**R2 — Design fidelity vs a server-side renderer.** Every visual affordance in our QR (logo, gradients, eye
shapes, frames) lives in the client-side `qr-code-styling` canvas pipeline. A backend re-render would ship a
signature QR that looks nothing like the one the user designed and downloaded. **Mitigation:** the client
renders (reusing the *exact* `useQRPreview` path) and we only *host* the bytes. The trade is one upload
round-trip, which is invisible.

**R3 — Stale image after a design edit.** A pasted signature references a URL; if the user restyles the QR,
already-sent signatures keep the CDN-cached old image. **Mitigation:** deterministic path + upsert means the
URL never changes and re-publishing overwrites in place; the CDN TTL is the only lag. **We say this in the
panel** rather than implying instant propagation. Not a correctness bug — the QR *encodes the same short
URL either way*, so a stale image still scans to the right place.

**R4 — Remote images blocked (the corporate default).** Many clients block remote images until the recipient
clicks "show images", so the QR may simply not appear. **Mitigation:** the block **always** contains a text
hyperlink to the card; alt text names it. A blocked image degrades to a normal, working signature line.

**R5 — User text in generated markup.** Name/company/title come from user input and are interpolated into an
HTML string that we also render in-app. Unescaped, that is an XSS shape in our own dashboard and a broken
snippet in the recipient's client. **Mitigation:** escape `& < > " '` on every interpolated field (the
frontend counterpart of the Worker's `escapeHTML`), **and** render the preview inside a sandboxed
`<iframe srcdoc>` so nothing executes in our origin even if escaping regresses. Belt and braces, both cheap.

**R6 — Orphaned public objects.** Deleting a QR does not today delete its published signature PNG, leaving a
public object behind. Given the flagged "Delete Account is a stub / no backend cascade" liability in the
competitive analysis, we should not add a *second* uncascaded artifact silently. **Mitigation:** best-effort
delete of the signature object in the QR-delete path (small addition), or an explicit documented decision to
defer. **Open Q4.**

**R7 — The image is a fetchable pixel.** By necessity the PNG is publicly readable and fetched by every
recipient's client. **Mitigation:** it encodes nothing but the already-public short URL, its path is two
UUIDs (not enumerable), and we make an explicit product commitment **not** to derive engagement signals from
its fetch logs. Stated in the help-center copy so a privacy-minded buyer can verify the claim.

**R8 — Clipboard `text/html` support variance.** `navigator.clipboard.write` with an HTML flavor is solid in
Chromium and Safari, weaker in Firefox. **Mitigation:** feature-detect; hide the rich-copy button and lead
with "Copy HTML source" + the selectable `<pre>` where it's unavailable. Never show a button that silently
does the wrong thing.

**R9 — QR too small to scan.** A signature QR is read off a screen at arm's length. Below ~96 px it starts
failing on older phone cameras. **Mitigation:** minimum offered size is 96 px, the hosted PNG is rendered at
**2×** the display size for HiDPI crispness, and "scans from a phone at S size" is an explicit acceptance
criterion.

**Open Questions**
1. **Card + Compact, or Card only in v1?** *Recommend both — Compact is ~15 lines of the same builder and
   covers the "my signature is already long" objection that otherwise blocks adoption.*
2. **Include phone/email as text lines in the block?** *Recommend no by default. The point is the card, and
   duplicating contact details makes the block tall enough that people won't paste it. Leave it as future
   polish if asked for.*
3. **Open the panel to all dynamic QR types later?** *Recommend v1 stays `vcard`/`vcard_plus` — the text
   column is vCard data. Extending it means deciding what a `website` QR's block says (QR name? destination?);
   that's a product call, not a technical one, and it can wait for demand.*
4. **Delete the published PNG on QR delete?** *Recommend yes, best-effort, in this PR — it is a few lines and
   we should not add a second uncascaded public artifact while the account-deletion cascade is already a
   known liability.* (R6.)
5. **Publish eagerly on panel open, or only on first copy?** *Recommend on panel open — the preview is only
   honest if it shows the real hosted image, and a user who opens the panel is almost certainly going to copy.*

## 12. Dependencies

- **`vcard_plus` type + vCard data (shipped):** `qr_vcard_details`, `VCardPlusContent.tsx`, the Worker vCard
  templates — the snippet's text fields and the link target.
- **Client QR renderer (shipped):** `useQRPreview` → `designToGeneratorOptions` → `generateQRCode` →
  `generateWithFrame` — reused verbatim to produce the PNG bytes with the user's own design.
- **Short-URL builder (shipped):** `generateDynamicQRContent(short_code, customHostname)` — the snippet's
  link and QR payload, including custom-domain resolution via `useVerifiedDomainMap`.
- **Public Supabase Storage bucket (shipped):** the same bucket used for avatars and workspace branding logos;
  `get_public_url` yields a permanent URL (documented in `_public_url_from_path`). The `upload_avatar` route
  is the template for the publish endpoint.
- **Copy-panel precedent (shipped):** `EmbedSnippet.tsx` — tabs, `<pre>`, copy button, clipboard-blocked
  fallback. Reuse the interaction shape.
- **White-label entitlement (shipped):** `canAccessFeature(subscription, 'white_labeling')` — attribution
  suppression. No new flag.
- **No migration. No Worker change. No cron. No email. No AI. No new external service or env var.**

### Appendix — Key Files

| Concern | File |
|---|---|
| Snippet builder (pure) | `qr_frontend/src/lib/email-signature.ts` (NEW — inline-styled HTML string + field escaping) |
| Signature panel | `qr_frontend/src/components/org/qrs/details/email-signature-card.tsx` (NEW, ≤200 lines) + a sandboxed preview child |
| Panel mount point | `qr_frontend/src/components/org/qrs/details/overview-tab.tsx`, beside `qr-preview-card.tsx` |
| Copy-panel precedent | `qr_frontend/src/components/marketing/EmbedSnippet.tsx` (tabs + `<pre>` + clipboard fallback, L50–58 / L112–125) |
| QR render pipeline (reused) | `qr_frontend/src/hooks/useQRPreview.ts` (L27–57), `qr_frontend/src/lib/qr-generator.ts` (`generateQRCode` L64, `generateDynamicQRContent` L243) |
| Publish hook | `qr_frontend/src/hooks/useSignatureImage.ts` (NEW — TanStack mutation via `authApi`) |
| Publish endpoint | `qr_backend/src/api/routes/qr_signature.py` (NEW — mirrors `storage.py` `upload_avatar` L132–149), mounted in `src/api/endpoints.py` |
| Public-URL semantics | `qr_backend/src/api/routes/qr.py` `_public_url_from_path` (L1008–1021 — bucket is public, URL permanent) |
| White-label read | `qr_frontend/src/lib/plan-features.ts` `canAccessFeature` (L14–21); precedent `qr_frontend/src/components/org/reports/white-label-footer.tsx` |
| Ungated rationale | `qr_backend/migrations/0009_pricing_v3_4tier_collapse.sql` (L98 — Free has `vcard_plus`), `0027_open_all_qr_types.sql` |
| Attribution/no-flag guardrail | `qr_backend/src/api/routes/subscription.py` `FEATURE_ENFORCEMENT` (L525–560 — **no entry added**) |
| Why no attribution metric | `qr_backend/src/api/routes/internal.py` `ScanEventPayload` (L326–347 — no `utm_*`), `qr_cf_code/src/utils/scan.js` `recordScan` |
| Worker | **No change** (no KV key, no template, no dispatch case, no cron) |
