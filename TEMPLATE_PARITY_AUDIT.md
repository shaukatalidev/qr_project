# QR Page-Template Parity & Hardcoded-Data Audit

> **Date:** 2026-07-01 · **Scope:** all 44 `templateId`s across 13 QR types, compared on both surfaces — the **React builder preview** (`qr_frontend`, shown on the org page / live preview) vs the **Cloudflare Worker HTML** (`qr_cf_code`, the live scanned page) — plus system pages, legacy fallbacks, orphans and footers.
>
> **Contract:** the React preview and the Worker page must be visually identical, and no user-content field should be hardcoded.
>
> **How to use:** work top-to-bottom (Critical → High → Systemic → per-type cleanup). Tick `[x]` as you go. Every item has file:line refs. This was a read-only audit — nothing has been changed yet.

## Overall state
- ✅ `templateId` → worker-handler mapping is **100% complete and bidirectional** (all 44 ids matched, defaults aligned).
- ✅ The **bottom footer** (`renderFooter`/`renderBrandFooter` in `qr_cf_code/src/utils/design.js`) is centralized and white-label-aware.
- ❌ **No template pair is truly pixel-identical.** 4 preview-breaking bugs + a systemic white-label brand leak + significant hardcoded/fabricated data (some reaching live pages).

---

## 🔴 CRITICAL — preview shows something completely different from the live page

- [x] **C1 · event (all 4 templates) — React reads camelCase field names that don't exist.** ✅ FIXED: all 4 event templates now read snake_case (`start_date/start_time/end_time/event_name/organizer_name`) matching `EventContent`, the form, and the worker.
  React reads `content?.eventName / startDate / startTime / endTime / organizerName`; the `EventContent` type is **snake_case** (`event_name/start_date/start_time/end_time/organizer_name`, `qr_frontend/src/lib/types/qr.ts:300-309`). TS errors (`TS2551`) are silenced by `typescript.ignoreBuildErrors:true` (`qr_frontend/next.config.js:5`). The correct snake→camel mapping is **commented out** at `qr_frontend/src/app/org/[slug]/(builder)/build/page.tsx:414-423`.
  - Files: `EventTicketTemplate.tsx:13,16,18,21`, `EventPosterTemplate.tsx:13,16,18,21`, `EventTimelineTemplate.tsx:13,16,18,21`, `EventInviteTemplate.tsx:20,23,25,28` (all under `qr_frontend/src/components/qr-generator/templates/event/`).
  - Effect: every event **builder preview** shows placeholder title, no date/time, countdown stuck at `00:00:00`, no organizer. The live worker page (reads correct snake_case, `ticketTemplate.js:7-11`) is fine. Only `description` + `location` render in preview (same name both cases).
  - Fix: uncomment/apply the map at `build/page.tsx:414-423`; then keep TS type-checking on in CI so this can't silently ship again.

- [x] **C2 · social_media (all 4) — React iterates `content.urls`, a field that doesn't exist.** ✅ FIXED: added `getSocialLinks()` in social `shared.tsx` mapping the flat `instagram/facebook/twitter/linkedin/youtube/website` fields into `{id,title,url}[]` (order+titles mirror the worker); all 4 templates now render real links, placeholder only when empty.
  `SocialMediaContent` (`qr.ts:288-297`) has flat `profileName/bio/instagram/facebook/twitter/linkedin/youtube/website` — **no `urls` array**. So `content?.urls` is always `undefined` → every template falls back to `PLACEHOLDER_URLS`.
  - Files: `SocialProfileTemplate.tsx:11,23` (same block in `SocialGridTemplate.tsx`, `SocialDarkTemplate.tsx`, `SocialStripTemplate.tsx`).
  - Effect: preview **permanently shows a fixed Instagram/TikTok/YouTube/LinkedIn/Website placeholder list**, ignoring the user's real links. Worker (`socialMedia/helpers.js:3-16`) renders the real flat `*_url` platforms. Can never match.
  - Also: profile-name key differs — React `content.profileName` vs worker `data.display_name` (`profileTemplate.js:8`).
  - Fix: map the flat platform fields into the `{title,url}[]` shape the React templates expect (or rewrite the templates to read the flat fields).

- [x] **C3 · business (all 4) — worker never renders the uploaded logo.** ✅ FIXED: storefront/premium/directory now render `data.logo_url` as `<img>` (fallback to initial); minimal re-adds the 56×56 avatar block it was missing.
  Form uploads `logo_url` (`BusinessContent.tsx:266-327`), backend ships it to KV (`cloudflare_kv.py:377-379`), React renders `logoUrl ? <img> : initial` (`BusinessStorefrontTemplate.tsx:30,88-90`, +premium/minimal/directory). No worker business template references `logo_url` — all hardcode the initial letter. `business_minimal` drops the avatar element entirely (`minimalTemplate.js:92-96`).
  - Worker files: `storefrontTemplate.js:162-168`, `premiumTemplate.js:94-97`, `directoryTemplate.js:113-115`, `minimalTemplate.js` (no avatar).
  - Effect: uploaded logo shows in preview, **vanishes on scan**. (Contradicts the earlier "SVG logo FIXED" note.)

- [x] **C4 · list_links (all 4) — worker never renders the uploaded avatar.** ✅ FIXED: classic/neon/magazine/cards now render `page.profile_url` as `<img>` (avatar boxes given `overflow:hidden`); legacy now reads `profile_url` (was wrong `avatar_path`).
  Avatar column is `profile_url` (`qr.py:1831`). React renders `avatarUrl ? <img> : initial` (`LinksClassicTemplate.tsx:53-55`, +neon/magazine/cards). Every worker template renders only the initial (`classicTemplate.js:28`, `neonTemplate.js:34`, `magazineTemplate.js:32`, `cardsTemplate.js:56`). Legacy reads the wrong `avatar_path` column.
  - Effect: uploaded profile photo shows in preview, **gone on scan**.

---

## 🟠 HIGH — big per-template divergence or fabricated data on the live page

- [x] **H1 · lead_form — preview is a mockup, not the real form.** ✅ FIXED: rewrote the React `LeadFormCardTemplate` to mirror the worker — real `<input>/<textarea>/<select>` fields, normal-case labels, `pageTitle`-driven header (no 📋/subtitle), the worker's exact consent copy with a linked privacy policy (unchecked checkbox), gradient bg, and a "Powered by Qravio" footer. Threaded `pageTitle` through the render bag.
  React = non-interactive `<div>` mockups, UPPERCASE labels, 📋 emoji header + subtitle, boxed **pre-checked** consent with **no** privacy link, no footer, and the title toggles two hardcoded strings off `success_message` (`LeadFormCardTemplate.tsx:70`). Worker = real `<input>/<textarea>/<select>`, `pageTitle`-driven title (`cardTemplate.js:46,172`), **required** consent with a linked different copy (`cardTemplate.js:38,184-187`), gradient bg, Qravio footer.
  - Fix: React title should use `pageTitle`; mirror worker's consent copy/link, header chrome, real-input field styling, and footer.

- [x] **H2 · social_media — per-platform icons diverge (brand colors match).** ✅ FIXED: added per-brand `icon`(path)+`letter` to worker `socialMedia/helpers.js` + `socialIconSvg()`; dark/strip now render distinct brand icons (darkText→black icon for snapchat), grid uses 2-char letter at 38px/800. React: added `darkText` to `SocialBrand`+snapchat → grid uses dark text on the yellow tile (was unreadable white).
  Worker uses a **single globe for every platform** in `social_dark` (`darkTemplate.js:15`) and `social_strip` (`stripTemplate.js:16`), and a 1-char letter in `social_grid` (`gridTemplate.js:15`, e.g. "L" for LinkedIn). React uses distinct brand SVGs / 2-char abbreviations ("IN"). Also `social_grid` letter size 38px/800 (React) vs 20px/700 (worker). Snapchat `darkText` handling exists only worker-side (React forces white text on yellow → unreadable).
  - Note: a 3rd conflicting color source `social-platforms.ts` exists (unused by scan templates) — latent drift trap.

- [x] **H3 · vcard — multiple structural gaps + disagreeing hardcoded data.** ✅ FIXED (structural + fabrication): initials now 1-letter across worker hero/dense/stack (matches React); removed fabricated `vcard_stack` skill tags (both sides); removed the fabricated hero social grid (React `DEMO_SOCIALS` — no social field exists); removed the fully-fabricated dense "Connect" tab (both sides) and added the missing dense About Address card (Directions/Copy) + country/company subtexts to the worker; stack "Elsewhere" now shows only the real Website (both sides). Bonus: fixed the "Powered by QRAVIO"→"Qravio" casing in hero+dense (part of S4). Remaining = pure cosmetic (cover decoration, serif font, share-control geometry).
  - `vcard_hero`: worker **drops the entire social grid** (React `VCardHeroTemplate.tsx:462-495`) and the cover decoration; different share control, serif font (Georgia vs Instrument Serif), contact header.
  - `vcard_dense`: worker About tab missing the country/company subtext + the whole **Address + Directions/Copy card** (React `:495-554`).
  - **All three:** avatar initials differ — React 1 letter (`firstName.charAt(0)`) vs worker 2 letters → "J" vs "JD".
  - `vcard_stack`: skill tags **hardcoded and disagree** — React `['Design','Development','Strategy','Leadership']` vs worker `['Developer','Designer','Creator']` (`stackTemplate.js:110`). Fabricated, shown live, no skills field exists.

- [x] **H4 · coupon — worker drops real data + no expired state.** ✅ FIXED: worker voucher now renders `valid_until` ("Valid until …" w/ clock) + always shows the Redeem Now CTA (links when `website_url`, matches React placement below the card); worker flash now computes `expired` at render → shows "This offer has ended" instead of `00/00/00/00`, and the live countdown script swaps to the ended state at zero.
  - `coupon_voucher`: worker **never renders expiry** (`valid_until` is in KV, ignored) and shows the CTA **only if `website_url`** is set; React always shows both.
  - `coupon_flash`: **no "offer ended" state** — an expired sale renders `00 / 00 / 00 / 00` (`flashTemplate.js:67`), React shows "This offer has ended".

- [x] **H5 · landing_split — contacts lose their icon tiles on the live page.** ✅ FIXED: worker split now renders each contact as a 26×26 icon tile (mail/phone/globe SVG in accent) + text, matching React.
  React renders each contact as an icon tile (`LandingSplitTemplate.tsx:159-173`); worker renders **plain text divs, no icons** (`splitTemplate.js:53`).

---

## 🟡 SYSTEMIC — cross-cutting, affects many templates

- [x] **S1 · White-label brand leak (HIGH, worker) — 15 templates hardcode an ungated "QRAVIO" label.** ✅ FIXED: added `brandTag(whiteLabel, {before/after/sep})` helper in `design.js`; gated the decorative top-bar/badge/pill label in vcard hero/dense/stack, business storefront/minimal/premium/directory, event ticket/poster/invite/timeline, images/editorial, pdf/card. Threaded `whiteLabel`(+`brand`) into the event/editorial/videoCinematic/vcard-stack signatures & dispatchers that were dropping them. (audioPlayer & videoFullscreen were already gated.)
  Bottom footer is gated, but a decorative top-bar/badge/pill "QRAVIO" ignores `whiteLabel`, so Agency white-label scan pages still show "QRAVIO". Dispatchers pass `whiteLabel` through; templates ignore it. `videoFullscreen` is the only one that gates.
  - vcard: `heroTemplate.js:67`, `denseTemplate.js:76`, `stackTemplate.js:70`
  - business: `storefrontTemplate.js:144`, `minimalTemplate.js:84`, `premiumTemplate.js:86`, `directoryTemplate.js:106`
  - event: `ticketTemplate.js:59`, `posterTemplate.js:50`, `inviteTemplate.js:52`, `timelineTemplate.js:57`
  - `images/editorialTemplate.js:53`, `pdf/cardTemplate.js:78` ("QRAVIO PDF" pill), `media/audioPlayerTemplate.js:51`, `media/videoCinematicTemplate.js:74`

- [x] **S2 · apps (all 4) — zero attribution.** ✅ FIXED: `apps/index.js` now reads `whiteLabel`/`brand` from pageDesign and passes them; hero/store/dark/minimal accept the params and render `renderFooter({whiteLabel, brand})` (dark uses `dark:true`) — free-tier gets "Powered by Qravio", Agency white-label gets their brand footer.

- [x] **S3 · Bespoke video footers.** ✅ FIXED: videoFullscreen now uses the unified `renderFooter({whiteLabel, brand, tagline: fileMeta})` (20px icon, WL shows the brand footer instead of blanking); videoCinematic now uses `renderFooter({..., dark:true, tagline:'A SCAN PRESENTATION'})` instead of the bespoke tagline-only line. Both stick to bottom via a `margin-top:auto` wrapper.

- [x] **S4 · React footers not shared / not white-label aware.** ✅ Casing bug FIXED: "Powered by QRAVIO"→"Qravio" at `ImagesMasonryTemplate.tsx:96`, `VCardDenseTemplate.tsx:614`, and `VCardHeroTemplate.tsx`. WL-awareness intentionally NOT added to React previews: they're the builder preview and don't receive `whiteLabel`/`brand` props — the LIVE page (worker) is already WL-aware, so preview always showing "Powered by Qravio" is acceptable.

- [x] **S5 · Custom `page_design.pageTitle` ignored in preview.** ✅ FIXED (PDF): added `pageTitle` to `TemplateContentBag` + `PageDesignData`, populated from `pageDesign.pageTitle`, threaded into all 4 PDF React templates which now use `pageTitle || file_name`. NOTE: mp3/video worker templates use the *file title* (not pageTitle) on both sides — no divergence there; lead_form title is handled in H1. Caveat: no builder UI currently *sets* `pageTitle` (API/worker-only field), so this is forward-looking parity.

- [x] **S6 · Emoji-vs-SVG icon drift.** ✅ FIXED (main cases): worker now uses inline SVGs matching React — landing_hero contacts (📞→phone, 🌐→globe), landing_announcement (📅→calendar chip, 📍→pin button), coupon_flash (⚡→bolt), coupon_stamp (⭐→star header, 📋→copy). giftcard 🎁 left as-is (React also uses the emoji). Residual emoji only remain in dead code (carousel/legacy templates).

---

## 📋 HARDCODED / FABRICATED DATA INVENTORY

### Reaches the LIVE worker page (fix these)
- [x] **coupon codes** default to fake values when empty: `FLASH50` (`flashTemplate.js:9`), `GIFT2024` (`giftCardTemplate.js:8`) render live. `coupon_stamp` shows a static **"4/6 stamps"** for every visitor (`stampTemplate.js:12-14`) — no per-customer field exists. ✅ FIXED (both surfaces): flash/giftcard/stamp default code → empty & the code chip is hidden when empty; stamp card now renders an honest empty 0/6 "start collecting" card (no fabricated progress).
- [x] **apps fake rating** `4.8 · 2.4K Ratings` (`storeTemplate.js:30-31`) / `4.9` + 5 stars (`darkTemplate.js:24`) — no rating field exists in `AppContent`. ✅ FIXED (both surfaces): removed the fabricated rating rows from apps store + dark.
- [x] **pdf_card** avatar initials `SA` (`cardTemplate.js:83`); `QRAVIO PDF` pill both sides (ignores white-label). **pdf_grid** appends static `Updated recently` (`gridTemplate.js:64`). ✅ FIXED: card avatar `SA`→`PDF` (matches React); grid drops `Updated recently` (shows just size, matching React); `QRAVIO PDF` pill gated via S1.
- [x] **landing_startup** 3 fake service blocks incl. "+38% avg conversion lift" (both sides). **landing_hero** default title `The Grand Kitchen` (both sides). ✅ FIXED: removed the fabricated startup service blocks from both surfaces (no services data field); landing_hero title default → "Welcome" (both), React subtitle default "Authentic Cuisine · Est. 1987" → empty (matches worker).
- [x] **vcard_stack** skill tags (both sides, and they disagree — see H3). ✅ FIXED under H3 — removed from both.

### Preview-only fabrication (React) — cosmetic, but misleading in the builder
- [ ] vcard `DEMO_SOCIALS` + fake `@handles` + placeholder contacts (`+1 234 567 8900`, `hello@example.com`, `VCardHeroTemplate.tsx:125-149`).
- [ ] social `PLACEHOLDER_URLS` (always, due to C2); `links_cards` `PLACEHOLDER_LINKS` (`LinksCardsTemplate.tsx:10-15`).
- [ ] media fake durations `218`/`96`s → "3:38"/"1:36" (audioPlayer L48, waveform L40, fullscreen L39, cinematic L38).
- [ ] coupon `SAVE20` default (`CouponVoucherTemplate.tsx:32`); lead_form sample placeholders.

### No leaked sample data found
- business and event templates pull everything from data (only generic empty-state placeholders).

---

## 🗺️ MAPPING, ORPHANS & DEAD CODE

- [x] **`getCarouselPage` is dead code** — imported in `qrRouter.js:2` but never dispatched (no `carousel` type). ✅ FIXED: removed the unused import from `qrRouter.js`. (`generateCarouselHTML` remains as the images legacy fallback for old no-templateId QRs.)
- [x] **`images/index.js` has no `DEFAULT_TEMPLATE`** — a stale/unknown images `templateId` falls back to the legacy **carousel** design instead of `images_slideshow` (the React default). ✅ FIXED: added `DEFAULT_TEMPLATE = "images_slideshow"`; unknown/stale tid → slideshow, only no-tid (legacy) → carousel (matches event/listLinks dispatcher pattern).
- [x] **Image order reversed** preview vs live — React ascending upload order, worker sorts descending by version. ✅ FIXED: worker `images/index.js` now sorts ascending by version to match the React preview (cover/first image now agree).
- [x] **images `size_bytes` dropped** on the worker path (`qrRouter.js:74-78`) → `images_masonry` total-size label is always empty live. ✅ FIXED: `qrRouter.js` + `images/index.js` now carry `size_bytes` through (KV stores it as `size`) → masonry total-size label renders.
- [ ] **`landing_page` type is commented out** in `qr-types.ts:104` — fully built both sides but not user-creatable (latent).
- [ ] **Dead fields** (collected by a form, rendered by nobody): vcard `zip_code`/`state`; business `postal_code`/`country`; event `timezone`/`image`; landing `logo_url`/`background_url`/`theme` (legacy-only); apps `image` (stripped by zod, `AppsContent.tsx:146-164`); list_links per-link `icon` + `click_count`. Also `ListOfLinksContent.tsx` is dead (wrong casing) — safe to delete.
- [ ] **errorPage.js** doesn't handle `whiteLabel` (always shows Qravio on a white-label 404) and is stylistically stale (old purple gradient + Segoe UI vs newer dark-slate status pages).

---

## Per-type verdict (quick reference)

| Type | Parity | Worst issue |
|------|--------|-------------|
| event | ❌ broken | C1 camelCase field bug → preview blank |
| social_media | ❌ broken | C2 `content.urls` doesn't exist; H2 globe-for-all icons |
| business | ❌ HIGH | C3 worker never renders uploaded logo |
| list_links | ❌ HIGH | C4 worker never renders uploaded avatar; cards = globe-for-all |
| lead_form | ❌ HIGH | H1 preview mockup ≠ real form; title bug |
| vcard | ⚠️ poor | H3 dropped social grid, initials 1-vs-2, hardcoded skills |
| coupon | ⚠️ mixed | H4 worker drops expiry; no expired state; fake codes live |
| landing | ⚠️ ok | H5 split contacts lose icons; emoji vs SVG |
| pdf | ⚠️ good | worker adds chrome React lacks; `SA`/`Updated recently`; pageTitle gap |
| mp3 | 🟢 strong | worker missing secondary-icon row (player); waveform pixel-parity |
| video | ⚠️ mixed | dropped action row/orbs; Length↔Quality meta swap |
| apps | 🟢 strong | worker missing Inter font (store/dark/minimal); fake rating; no footer |

---

## PER-TYPE DETAIL (full finding lists)

### vcard  (ids: vcard_hero, vcard_dense, vcard_stack · default vcard_hero)
- [ ] hero: worker missing social grid (`VCardHeroTemplate.tsx:462-495`) + concentric-circle cover decoration (`:196-207`).
- [ ] all: avatar initials — React 1 letter (`:142`) vs worker 2 (`heroTemplate.js:10-11`).
- [ ] hero: share control (pill+text vs 32px circle), contact header (centered vs left dash), cover gradient direction inverted, grain (SVG vs radial), serif font (Georgia vs Instrument Serif), name weight 700 vs 600.
- [ ] hero: empty-state — React always renders rows/bio with placeholders; worker conditional. `street_address` in worker "Address" row vs React "Location" (city+country only).
- [ ] dense: worker About tab missing country/company subtext + Address/Directions/Copy card (`:495-554`); brand bar (no accent square / QR icon); avatar radius+gradient; contact meta labels differ; social sub-labels fabricated & disagree (React `@firstname` vs worker "View profile/repos/tweets").
- [ ] stack: skill tags hardcoded & disagree (H3); icons (mail vs sparkle, link vs share); 4th chip (Map vs 2nd Share); title/company two lines vs one; Elsewhere tile layout vertical vs horizontal; CTA "Save Contact" vs "Save to Contacts".
- [ ] dead fields `zip_code`, `state` (both sides). vcard_stack worker handler drops `brand` (`vcard/index.js:9`).

### business  (ids: business_storefront/premium/minimal/directory · default storefront)
- [ ] C3 logo not rendered by worker (all 4); minimal drops avatar entirely.
- [ ] footer differs (React inline hairline vs worker `renderFooter`).
- [ ] storefront: tagline empty-state — React placeholder "Your tagline here" always; worker renders only if non-empty. Today-badge margin.
- [ ] hours empty-state condition differs (React truthy `{}` vs worker `Object.keys().length>0`).
- [ ] dead fields `postal_code`/`country` (form comment wrongly claims Maps geocoding).

### event  (ids: event_ticket/poster/timeline/invite · default ticket)
- [ ] C1 camelCase field bug (all 4).
- [ ] date timezone: React local vs worker UTC (`shared.tsx:29-38` vs `helpers.js:3-15`).
- [ ] share button React-only (all 4); secondary CTA unconditional React vs `siteUrl`-gated worker; React never reads `website_url`/`rsvp_url` (decorative CTA).
- [ ] modern worker templates ignore white-label (S1); only legacy honors it.
- [ ] poster: "When" row renders broken "---, -- ---" in React, hidden in worker. timeline: "About" gated on `subtitle` (React) vs `subtitle||venue` (worker). ticket/timeline/invite: worker website btn text-only (no link icon).
- [ ] dead fields `timezone`, `image` (form input commented out).

### images  (ids: images_slideshow/masonry/editorial/stack)
- [ ] image order reversed (mapping section); `size_bytes` dropped → masonry size label always empty.
- [ ] no `DEFAULT_TEMPLATE` → unknown tid renders legacy carousel, not slideshow.
- [ ] slideshow: back-chevron points opposite direction; empty state React-only; caption "Photo N" vs "Photo".
- [ ] masonry: right-column tile heights differ (first tile 140 vs 180px); "Slideshow" CTA missing qr icon; footer text vs `renderFooter`.
- [ ] editorial: grid/list view-toggle React-only; dual CTAs lack icons in worker; avatar gradient vs solid; no footer either side.
- [ ] stack: deepest back-card rotation -6° vs -3°; worker renders footer (clipped by `overflow:hidden`), React none; background gradient top color differs.
- [ ] dead `ImagesDesignOptions` fields galleryLayout/showCaptions/imageBehavior (both ignore).

### pdf  (ids: pdf_landing/viewer/grid/card · default landing)
- [ ] all: React never honors `page_design.pageTitle` (S5); worker adds footers React lacks.
- [ ] landing: "Page thumbnails" sub-line worker-only; hero cover/thumb sizes differ slightly.
- [ ] viewer: worker does NOT strip `.pdf` from title → "document.pdf" vs "document"; top-bar share+download (worker) vs download-only (React); bottom strip caps 6 (React) vs all pages (worker).
- [ ] grid: worker "Updated recently" fabricated; "tap to select" no cell pre-selected (worker) vs page-1 pre-highlighted (React).
- [ ] card: avatar "SA" (worker) vs "PDF" (React); "QRAVIO PDF" pill white-label leak both.

### list_links  (ids: links_classic/neon/magazine/cards · default classic)
- [ ] C4 avatar (`profile_url`) not rendered by any worker template.
- [ ] `is_active` filter — worker renders only active links; React previews all (hidden links show in preview).
- [ ] cards: per-link icon shape — React distinct glyphs (camera/at/play) vs worker always globe; sub-label strips `https://` (worker) vs verbatim (React).
- [ ] neon: avatar glow — React 3 shadows vs worker 2 (missing outer bloom).
- [ ] dead: per-link `icon` + `click_count` rendered only by legacy; `ListOfLinksContent.tsx` dead (delete).

### social_media  (ids: social_profile/grid/dark/strip · default profile)
- [ ] C2 `content.urls` doesn't exist → placeholder list; profileName vs display_name key.
- [ ] H2 icons: globe-for-all (dark/strip), 1-char letter 20px (grid) vs React distinct SVG / 2-char 38px.
- [ ] Snapchat `darkText` worker-only (React white-on-yellow unreadable); form omits TikTok/Snapchat though brand tables include them.
- [ ] brand COLORS fully aligned (verified). 3rd color source `social-platforms.ts` unused (latent trap).

### coupon  (ids: coupon_voucher/flash/giftcard/stamp · default voucher)
- [ ] H4 voucher drops expiry + CTA only when website set; flash no expired state.
- [ ] hardcoded codes SAVE20/FLASH50/GIFT2024; stamp static 4/6.
- [ ] giftcard: gift emoji tile vs bare emoji; diagonal stripe React-only. voucher: discount not split (36px+18px superscript vs single blob); CTA placement outside vs inside card.
- [ ] icons emoji vs SVG (bolt/star/copy). giftcard+stamp intentionally ignore accent (fixed palette) — consistent.

### landing_page  (ids: landing_hero/split/startup/announcement · default hero · TYPE COMMENTED OUT)
- [ ] H5 split contacts lose icon tiles.
- [ ] all: React CTA is non-link `<button>` ignoring `button_url`; worker `<a href>`. Emoji vs SVG icons (S6).
- [ ] hero: subtitle default "Authentic Cuisine · Est. 1987" (React) vs "" (worker); "The Grand Kitchen" title default both.
- [ ] startup: 3 hardcoded service blocks both; description default truncated in worker; footer shows contacts+Qravio (worker) vs fallback-only (React).
- [ ] split/startup/announcement: footer render differs (worker always + WL-aware vs React fallback-only text).
- [ ] dead form fields logo_url/background_url/theme (legacy-only).

### mp3 + video (media)  (ids: audio_player/audio_waveform · video_fullscreen/video_cinematic)
- [ ] shared: pageTitle ignored in preview (S5); footer helper drift; fake durations 218/96 (preview only).
- [ ] audio_player: worker missing heart/volume/share/download secondary row (`:120-125`).
- [ ] audio_waveform: strong parity (56-bar deterministic waveform identical). ✅
- [ ] video_fullscreen: worker drops 3 card action buttons + both poster orbs + badge duration; progress bar always in DOM; bespoke `<img>` footer (S3).
- [ ] video_cinematic: 3rd meta column "Length"→duration (React) vs "Quality"→"HD" (worker); missing bottom-left orb; React play button empty path while playing (minor React defect); ignores whiteLabel both sides.

### apps + lead_form  (ids: apps_hero/store/dark/minimal · lead_form_card)
- [ ] apps: store/dark/minimal worker missing Inter font (renders system stack); hero padding/button geometry drift; store icon gradient vs flat, screenshot inner-box; fake rating (both); dead "App Image URL" form field (zod-stripped); App Name help text wrongly says "must be a valid URL".
- [ ] apps: S2 zero footer/attribution (dispatcher never passes whiteLabel/brand).
- [ ] lead_form: H1 (mockup vs real form; title from success_message vs pageTitle; consent copy/link/styling; header chrome; footer). Form action endpoint confirmed correct (`/lead-submit/:shortCode` → `/internal/lead-submit`).

---

## Suggested fix order
1. **C1** event field-name bug (+ turn TS checking on in CI).
2. **C3, C4** worker logo/avatar rendering (business + list_links).
3. **C2** social `content.urls` shape.
4. **S1** white-label brand leak (gate the 15 "QRAVIO" labels).
5. **Hardcoded live data** — coupon codes/stamps, apps rating, pdf `SA`/`Updated recently`.
6. **H1** lead-form preview rewrite, **S5** pageTitle-in-preview, **S6** emoji→SVG, then remaining MED/LOW cosmetic drift per type.
