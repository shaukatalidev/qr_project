# TRD — Location / Google Maps QR Type

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Quick win (gap-analysis **#6**, `S · Fit 4 · Impact 2`). A textbook "add a QR type" job — four known touchpoints, no new external service, no COGS. The only non-mechanical decisions are the maps-URL contract and the `dynamic_qr_types` migration shape.
**Tiers:** **All plans, ungated.** `location` joins `features.dynamic_qr_types` on every non-custom plan, per the policy set by `0027_open_all_qr_types.sql`.
**Plan flags (NEW):** **None.** No boolean, no limit, no `FEATURE_ENFORCEMENT` entry, no `_QUOTA_SPEC` entry — `dynamic_qr_types` is already registered `enforced` (`qr_backend/src/api/routes/subscription.py:534`), so `test_feature_gate_coverage` needs nothing.
**Migration slot:** **`0035`** (`0035_location_qr_type.sql`) — **provisional; re-verify against `qr_backend/migrations/` at build time.** Highest on disk today is `0032_lemonsqueezy_variant_backfill.sql`; `0033` is claimed by QR Expiry + Scheduling and `0034` by the UPI type, both drafted but unapplied. The repo already carries a commit fixing stale slot numbers — do not trust this header.
**Services touched:** `qr_backend` (detail table, Pydantic model, persistence, KV branch, internal fallback endpoint) · `qr_cf_code` (dispatch case, shared maps helper, page + 2 templates, storefront refactor — **requires `npm run deploy:prod`**) · `qr_frontend` (content form, 2 React template previews, type registration, SEO pages). **No AI, no email, no cron, no new env var, no API key.**
**Implements PRD:** Location / Google Maps QR Type. **Mirrors** the `business`/`event` type recipe end-to-end: `build_kv_content` branch → `qrRouter.js` case → `src/pages/<type>/index.js` `HANDLERS` dispatcher → per-template modules.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review`. Ships as-drafted on the type recipe, the append-if-absent `dynamic_qr_types` migration guard, coordinate range-validation, and the shared maps-URL helper (extract-don't-fork + storefront link-equality regression test). Two decisions: (1) **keep the "open Maps directly" 302 toggle, landing page default** (as drafted). (2) **`maps_url_override` SHIPS in v1** (this **supersedes** any "drop the override / Open Q3 = no" statement in the body) — with a **mandatory map-host allowlist** as a hard requirement: allow only `google.com/maps`, `maps.google.*`, `goo.gl/maps`, `maps.app.goo.gl`, `maps.apple.com`, `waze.com`, `openstreetmap.org`; validate at **both** write time (a backend Pydantic validator on `LocationContent`, mirroring the `_validate_google_review_url` write-time-guard precedent — parse the URL, check the host against the allowlist, reject with 422) **and** render time (the Worker re-checks the host before honoring the override in direct mode, falling back to the composed `search?query=`/`lat,lng` URL if it fails — **never** 302 to an unvalidated host, **never** fail open on a parse error). Add tests: allowlisted hosts pass; `evil.com`, a look-alike (`google.com.evil.com`), a scheme-relative `//evil.com`, and a `javascript:` URL all reject on both sides. Open Q5 caveat: `location` in `HAS_LANDING_PAGE_TYPES` means "has a page unless direct-mode is on" — verify no consumer of that constant assumes "always renders a page."

---

## 1. Overview & Architecture

A new `location` dynamic QR type. Content lives in a 1:1 `qr_location_details` row, is snapshotted into the
KV `content` object by `build_kv_content` at every write, and is rendered at the edge by a new page module
— or short-circuited to a `302` when the owner picked direct mode. There is **no runtime call to any maps
provider**: we only *construct URLs*. That is what keeps this feature free of keys, billing, quotas, and
latency.

**The one piece of real logic** is `buildMapsUrl(data)`, promoted out of
`qr_cf_code/src/pages/business/storefrontTemplate.js:32-34`:

```
lat/lng present  →  https://www.google.com/maps/search/?api=1&query=<lat>,<lng>     (exact pin)
otherwise        →  https://www.google.com/maps/search/?api=1&query=<encoded address>  (today's behavior)
```

Everything else is the standard type recipe. The storefront template is refactored to import the shared
helper in the same PR so the two implementations never coexist.

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0035` (`qr_location_details` + `dynamic_qr_types` append). `LocationContent` Pydantic model; `"location"` in the `QRCodeCreate.type` Literal; `locationContent` on `QRContent`; create-insert + update-upsert branches; `qr_location_details(*)` in `SELECT_WITH_RELATIONS`; response mapping; `build_kv_content` branch; `GET /internal/location/{qr_id}`. **No gating code, no RPC, no cron.** |
| `qr_cf_code` | `src/utils/maps.js` (NEW, shared); `location` case in `handlers/qrRouter.js` incl. the direct-mode `302`; `src/pages/locationPage.js` + `src/pages/location/{index,shared,cardTemplate,pinTemplate}.js` (NEW); `storefrontTemplate.js` refactored onto the shared helper. **Requires `npm run deploy:prod`.** |
| `qr_frontend` | `LocationContent.tsx` form + registration in `content-types/index.ts` and `QRContent.tsx`; `src/lib/maps.ts` (mirror of the Worker helper); 2 React templates + `LOCATION_TEMPLATES` in `page-templates.tsx`; type registration in `qr-types.ts` / `qr-type-icons.ts`; `TYPE_PAGES` entry for `/location-qr-code` + the free `/location-qr-code-generator`. |

**Data flow — create/edit**

```
Builder LocationContent form (react-hook-form + zod)
  → POST/PATCH /api/v1/workspaces/{id}/qrs[/{qr_id}]  { content: { locationContent: {...} } }
  → qr.py: dynamic_qr_types gate (L1546-1560) → insert/upsert qr_location_details
  → build_kv_content(qr_id, "location", db) → SELECT * FROM qr_location_details WHERE qr_id = …
  → write_to_kv(... content=<that row>, page_design={templateId:"location_card", …})
  → KV entry: { type:"location", content:{ place_name, street_address, …, latitude, longitude,
                open_directly }, page_design:{ templateId } }
```

**Data flow — scan**

```
GET /:shortCode → KV lookup → status/schedule/password branches (unchanged)
  → recordScan(...)                                   [index.js:415 — fires for BOTH modes]
  → handleQRCode(parsedData, …)                       [index.js:426]
      → case "location":
          content = kvContent  ||  fetchInternal(`/internal/location/${qr_id}`)   [stale-KV fallback]
          if (!content) → getErrorPage()
          if (content.open_directly) → Response.redirect(buildMapsUrl(content), 302)
          else → getLocationPage(content, pageDesign)   → HANDLERS[templateId] ?? location_card
```

Direct mode redirects **after** `recordScan`, so it keeps full scan analytics — the single functional
advantage over the plain `website`-QR-pointing-at-a-Maps-link it imitates (PRD §2).

---

## 2. Data Model & Migrations

One 1:1 detail table plus a plan-array append. Shape follows `qr_event_details` /
`qr_business_details`: surrogate `id`, `qr_id`, `workspace_id`, timestamps.

**Embed shape matters.** `SELECT_WITH_RELATIONS` (`qr.py:998`) embeds detail tables via PostgREST, which
returns a **list** for a table whose `qr_id` is a unique index but not the primary key
(`raw_event: list = row.pop("qr_event_details", None) or []`, `qr.py:1405`) and a **dict** when `qr_id`
*is* the PK (`qr_review_funnel`, normalized at `qr.py:1416-1418`). We deliberately use **surrogate PK +
`UNIQUE(qr_id)`** so `location` follows the simpler, more common **list** shape — copy the `event`
normalization, not the `review_funnel` one.

**RLS note:** the backend uses the Supabase **service-role** REST client, which bypasses RLS. Match
whatever `qr_event_details` / `qr_business_details` carry today (**verify at build time**); the guidance
below enables RLS with no policies so anon/auth roles can never read the table. Tenant isolation is
enforced in code via the explicit `workspace_id` column and the `require_can_*` dependencies, never RLS.

**`qr_backend/migrations/0035_location_qr_type.sql`** — BEGIN/COMMIT-wrapped, idempotent
(`IF NOT EXISTS`), applied by hand in the Supabase SQL editor.

```sql
BEGIN;

-- ── Location detail table (1:1 with a `location` QR) ─────────────────────────
-- Shape mirrors qr_event_details: surrogate PK + UNIQUE(qr_id) so PostgREST embeds
-- it as a LIST (like qr_event_details), not a dict (like qr_review_funnel, whose
-- qr_id is the PK). qr.py's to-one normalization must follow the event pattern.
CREATE TABLE IF NOT EXISTS qr_location_details (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id             uuid NOT NULL REFERENCES qr_codes(id)   ON DELETE CASCADE,
    workspace_id      uuid NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,

    place_name        text NOT NULL,
    street_address    text,
    city              text,
    state             text,
    postal_code       text,
    country           text,
    landmark          text,          -- one free line: "opposite Reliance Fresh, 2nd gate"

    -- Exact pin. When BOTH are non-null the maps query becomes "lat,lng" and no
    -- geocoding/search happens at all — this is the v1 answer to messy addresses
    -- (PRD R1). NULL/NULL falls back to search?query=<address>, i.e. today's
    -- storefrontTemplate.js behavior verbatim.
    latitude          double precision CHECK (latitude  BETWEEN  -90 AND  90),
    longitude         double precision CHECK (longitude BETWEEN -180 AND 180),

    phone             text,          -- optional Call button; nothing else from the storefront profile
    open_directly     boolean NOT NULL DEFAULT false,  -- true → Worker 302s, skips the landing page

    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

-- 1:1 with the QR. UNIQUE (not PK) on purpose — see the embed-shape note above.
CREATE UNIQUE INDEX IF NOT EXISTS uq_qr_location_details_qr_id
  ON qr_location_details (qr_id);
CREATE INDEX IF NOT EXISTS idx_qr_location_details_workspace
  ON qr_location_details (workspace_id);

ALTER TABLE qr_location_details ENABLE ROW LEVEL SECURITY;
-- No policies → only the service role (bypasses RLS) can read/write.
-- VERIFY this matches qr_event_details/qr_business_details before applying.

-- ── Unlock the type on every non-custom plan (UNGATED — policy set by 0027) ──
-- APPEND-IF-ABSENT, deliberately NOT a wholesale array rewrite like 0027 used.
-- Why: sibling quick-win type migrations (UPI, Phone) each want to add one entry
-- to the SAME array. Wholesale rewrites make it last-writer-wins and silently drop
-- the others' type. Append-if-absent is idempotent and order-independent.
--
-- The jsonb_array_length(...) > 0 guard is LOAD-BEARING, not defensive noise:
-- 0027's own header warns "NEVER set the list to '[]' — the backend gate is
-- fail-open on an empty list" (qr.py:1560 `if _allowed_types and qrType not in
-- _allowed_types`). Appending onto an empty array would convert a plan that
-- currently allows EVERY type into one that allows ONLY 'location'.
UPDATE plans
SET features = jsonb_set(
        coalesce(features, '{}'::jsonb),
        '{dynamic_qr_types}',
        coalesce(features -> 'dynamic_qr_types', '[]'::jsonb) || '["location"]'::jsonb,
        true)
WHERE coalesce(is_custom, false) = false
  AND jsonb_array_length(coalesce(features -> 'dynamic_qr_types', '[]'::jsonb)) > 0
  AND NOT (coalesce(features -> 'dynamic_qr_types', '[]'::jsonb) @> '["location"]'::jsonb);

COMMIT;

-- Sanity (after COMMIT) — every non-custom plan's array must be exactly ONE longer
-- than before, must contain "location", and must never be empty:
--   SELECT name,
--          jsonb_array_length(features->'dynamic_qr_types')            AS n_types,
--          features->'dynamic_qr_types' @> '["location"]'::jsonb        AS has_location
--     FROM plans WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
--   Expect: free/starter 14 (13+1), pro/agency 15 (14+1), has_location = true for all.
```

**No plan-flag seed.** No `card_ocr`-style `'{...}'::jsonb` blob is needed because no new feature key is
introduced — `dynamic_qr_types` already exists on every plan and is already in `FEATURE_ENFORCEMENT`.
`test_feature_gate_coverage` is unaffected.

No change to `qr_codes`, `qr_destinations`, `qr_designs`, `qr_scan_events`, or any other detail table.

---

## 3. Backend Design

### 3.1 Content model — `qr_backend/src/api/routes/qr.py`
Add `LocationContent` beside `BusinessContent` (~L323-339), reusing its address field names verbatim so the
two forms and the shared maps helper agree:

```python
class LocationContent(pydantic.BaseModel):
    place_name: str
    street_address: Optional[str] = None
    city: Optional[str] = None
    state: Optional[str] = None
    postal_code: Optional[str] = None
    country: Optional[str] = None
    landmark: Optional[str] = None
    latitude: Optional[float] = None      # -90..90;  both-or-neither with longitude
    longitude: Optional[float] = None     # -180..180
    phone: Optional[str] = None
    open_directly: bool = False
```

**Server-side validation** (defense-in-depth; zod validates client-side too):
- Range-check lat/lng and require **both or neither** → `422` otherwise. A lone latitude is a half-filled
  form, and silently ignoring it would mis-pin without telling anyone.
- Reject `latitude == 0 and longitude == 0` (Null Island — always a paste error) → `422`.
- Require **at least one of** `{street_address, city, latitude}` — a `place_name`-only location QR produces
  a `search?query=<name>` that lands anywhere in the world (PRD R1/R10).
- Length-cap every string; trim whitespace.

Register the type in three places:
- `QRCodeCreate.type` Literal (~L836-863) — add `"location"`.
- `QRContent` (~L531-556) — add `locationContent: Optional[LocationContent] = None`.
- `SELECT_WITH_RELATIONS` (L998) — append `, qr_location_details(*)`.

### 3.2 Persistence — `qr_backend/src/api/routes/qr.py`
- **Create** (~L2121-2126, beside the `eventContent` insert): if `payload.content.locationContent`, dump
  with `exclude_none=True`, stamp `qr_id` + `workspace_id`, `db.table("qr_location_details").insert(...)`.
- **Update** (~L2932 collect / ~L3227-3234 apply, beside the event branch): the existing
  select-then-update-else-insert upsert. `open_directly` is a **boolean** — it must be collected with an
  explicit key-presence check, not truthiness, or the user can never turn it back **off**. (This is the
  classic bug in that block; the event branch only handles strings and doesn't exercise it.)
- **Response mapping** (~L1264-1304 kwargs, ~L1405 row pop): `raw_location: list = row.pop(
  "qr_location_details", None) or []` then `kwargs["locationContent"] = LocationContent(**raw_location[0])`
  — the **list** shape (`qr_event_details` pattern), not the dict shape (`qr_review_funnel`, `qr.py:1416`).

**No gating code.** The `dynamic_qr_types` check at `qr.py:1546-1560` (and the bulk twin at `:2459-2477`)
already covers `location` once the migration lands. There is no per-type `check_feature` call to add — the
`lead_form` / `review_funnel` double-gate pattern (`qr.py:1579-1591`) explicitly does **not** apply.

### 3.3 KV snapshot — `qr_backend/src/utilities/cloudflare_kv.py`
Add one branch to `build_kv_content` (`:387`), beside the `business` branch (`:404-406`):

```python
elif qr_type == "location":
    resp = supabase.table("qr_location_details").select("*").eq("qr_id", qr_id).maybe_single().execute()
    return dict(resp.data) if resp and resp.data else {}
```

Also extend the default-`templateId` shim at `:90` (`if qr_type == "business" and not (page_design or
{}).get("templateId")`) to cover `location` → `"location_card"`, so a QR created before the frontend ships
(or via the public API without a `page_design`) still renders the intended template instead of falling into
the dispatcher's legacy branch.

**No `write_to_kv` signature change** — `location` content rides the existing `content` field. No
`build_entitlements` change: nothing about this type is entitlement-gated at the edge.

### 3.4 Internal fallback endpoint — `qr_backend/src/api/routes/internal.py`
Add `GET /internal/location/{qr_id}`, a verbatim copy of `get_internal_event` (`:274-285`) against
`qr_location_details`. It is the stale-KV escape hatch every content type has, and it makes the
Worker-before-backend deploy ordering non-fatal rather than merely unlikely. Protected by
`x-internal-secret` like its siblings; no Bearer auth.

---

## 4. Cloudflare Worker / Edge Design

### 4.1 Shared maps helper — `qr_cf_code/src/utils/maps.js` (NEW)
The extraction the gap analysis asks for. Single source of truth for every maps URL in the Worker:

```js
// Promoted from src/pages/business/storefrontTemplate.js L22-34. The address-only
// path MUST stay byte-identical to that expression — the storefront's Map button
// is live and a URL change is a silent regression (see §10).
export function buildMapsUrl(d) {
  const q = hasPin(d)
    ? `${d.latitude},${d.longitude}`
    : [d.street_address, d.city, d.state, d.postal_code, d.country]
        .filter(Boolean).join(', ');
  if (!q) return '';
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(q)}`;
}
export function buildDirectionsUrl(d) { /* .../maps/dir/?api=1&destination=<q> */ }
export function buildAppleMapsUrl(d)  { /* https://maps.apple.com/?q= | ?ll=lat,lng */ }
export function buildWazeUrl(d)       { /* https://waze.com/ul?q= | ?ll=lat,lng&navigate=yes */ }
export function hasPin(d) { /* both lat & lng are finite numbers */ }
```

`hasPin` must test **finite numbers**, not truthiness — a legitimate `longitude: 0` (Greenwich) is falsy
and would silently drop the pin. Note the address join here uses the full five-part address, a deliberate
superset of storefront's three-part `[street, city, state]` join (`storefrontTemplate.js:25`); when called
with a storefront record whose `postal_code`/`country` are absent, `filter(Boolean)` collapses it to the
identical three-part string. **That equivalence is the release gate in §10, not an assumption.**

Then refactor `storefrontTemplate.js:32-34` to `const mapsUrl = buildMapsUrl(data);`, deleting the inline
expression. Ship the refactor in the same PR — two implementations must never coexist.

### 4.2 Dispatch — `qr_cf_code/src/handlers/qrRouter.js`
Import `getLocationPage` alongside the other page imports (L1-14) and add a case beside `business`
(L165-182):

```js
// ── Location ──────────────────────────────────────────────────────────────
if (type === "location") {
  const loc =
    kvContent && Object.keys(kvContent).length > 0
      ? kvContent
      : await fetchInternal(`/internal/location/${qr_id}`, env);
  if (!loc) return getErrorPage();
  // Direct mode: skip the landing page entirely. recordScan already fired in
  // index.js:415 (before this dispatch at :426), so analytics are unaffected —
  // that's the whole advantage over a plain website-QR pointing at Maps.
  if (loc.open_directly) {
    const url = buildMapsUrl(loc);
    if (url) return Response.redirect(url, 302);
    // No usable URL → fall through to the page rather than 302-ing to "".
  }
  return getLocationPage(loc, pageDesign);
}
```

**Never redirect to a user-supplied URL.** v1 ships no `maps_url_override` field (PRD Open Q3); the 302
target is always something `buildMapsUrl` constructed from an allowlisted `google.com/maps` prefix. If a
future revision adds an override, it must be host-allowlisted at **both** write time and here — otherwise
the short-code domain becomes an open redirector (PRD R8).

### 4.3 Page module — `qr_cf_code/src/pages/location/` (NEW)
Follow the `event` dispatcher pattern verbatim (`src/pages/event/index.js`):

```js
// src/pages/location/index.js
const HANDLERS = { location_card: generateLocationCardHTML,
                   location_pin:  generateLocationPinHTML };
const DEFAULT_TEMPLATE = "location_card";
export function getLocationPage(data, pageDesign) { /* …withMobileViewport(handler(...)) */ }
```

Plus `src/pages/locationPage.js` as the one-line re-export (`export { getLocationPage } from
'./location/index.js';`) matching `businessPage.js` / `eventPage.js`, and `src/pages/location/shared.js`
for the escape/shade/icon helpers (mirroring `src/pages/business/shared.js`).

Both templates take `(data, pageDesign, whiteLabel, brand)`, run **every** user string through
`escapeHTML()` from `src/utils/html.js`, and render `renderFooter`/`brandTag` from `src/utils/design.js` in
the white-label branch — identical to the storefront template. `location_card`: address block + landmark +
primary "Open in Google Maps" + secondary Apple Maps / Waze + optional `tel:` Call. `location_pin`: hero
pin, large place name, one primary directions button.

**Deploy gate:** the Worker changes, so **`npm run deploy:prod` is required** (staging via `npm run deploy`
first). No `wrangler.toml` change — no new route, KV namespace, cron, or secret.

---

## 5. Frontend Design

### 5.1 Types + shared maps util
Add `LocationContent` to `qr_frontend/src/lib/types/qr.ts` (mirroring §3.1) and `locationContent?:
LocationContent` to the `QRContent` interface (`:433-459`). Add `qr_frontend/src/lib/maps.ts` — a pure
mirror of `qr_cf_code/src/utils/maps.js`, used by the React previews and the builder's
"preview the exact link" control. **These two files are a mirrored pair like the templates; changing one
without the other is the bug.** Keep both tiny and covered by the same fixture table (§10).

### 5.2 Builder form — `content-types/LocationContent.tsx` (NEW)
One kebab-cased concern per house rules: one export, ≤200 lines, shadcn primitives only, no raw `<input>`,
no inline styles, react-hook-form + zod. Fields per PRD §6.2. Two details carry the feature's quality:
- **Exact-pin group** (collapsed `Accordion`): a single paste of `"12.9716, 77.5946"` splits into the two
  numeric fields on blur. zod: both-or-neither, range-checked, `0,0` rejected — mirroring §3.1 exactly.
- **"Preview the exact link scanners get →"**: an anchor built by `src/lib/maps.ts` from the current form
  values, `target="_blank" rel="noopener noreferrer"`, live-updating. This is the mis-pin mitigation (PRD
  R1); it is not optional polish.

Register in `content-types/index.ts` (the barrel) and in `QRContent.tsx` — a `dynamicImport` beside
`BusinessContent`/`EventContent` (~L149/189) and a render case in the type switch (~L445/458).

### 5.3 Type registration
- `qr_frontend/src/lib/constants/qr-types.ts`: `ALL_TYPES` entry `{ id:'location', name:'Location',
  description:'Open directions to a place', icon: FiMapPin, category:'dynamic' }` (~L92-120);
  `QR_TYPES.LOCATION = 'location'` (~L185-210); `TYPE_ICONS.location = 'location_on'` (~L218-243);
  add `'location'` to `HAS_LANDING_PAGE_TYPES` (~L75-90). `QR_LOGO_ICONS.location` (`:31`) and
  `QR_LOGO_COLORS.location` (`:127`) already exist — reuse, don't re-add.
- `qr-type-icons.ts`: a `location` entry in `TYPE_ICON_INNER` (inline stroke-SVG map pin, matching the
  existing Feather-style 24×24 convention).

### 5.4 Templates
`components/qr-generator/templates/location/LocationCardTemplate.tsx` and `LocationPinTemplate.tsx`, then
`LOCATION_TEMPLATES` in `src/lib/constants/page-templates.tsx` spread into `ALL_PAGE_TEMPLATES` (~L527-539)
with `qrType: 'location'`. `getTemplatesForType` (`:542`) and `getDefaultTemplateId` (`:552`) then work
unchanged — first entry (`location_card`) becomes the default, which must match the Worker's
`DEFAULT_TEMPLATE` and the `cloudflare_kv.py:90` shim. Thread `locationContent` into the template bag in
`TemplatePicker.tsx` (~L41-46) and `PagePreview/PagePreview.tsx` (bag ~L196-201, cases ~L32 and ~L76).

### 5.5 Hooks / API
**No new endpoint and no new hook.** `locationContent` rides the existing QR create/update mutations
(the `useQRs` family in `qr_frontend/src/hooks/`); only the payload type widens. No new query key.

### 5.6 SEO pages
A `TYPE_PAGES` entry in `qr-type-pages.ts`: `slug: 'location'`, `category: 'dynamic'`, `isStaticTool:
**true**`. The static-tool flag is the point — a location QR is a URL QR encoding a maps link, so the
existing client-side generator produces `/location-qr-code-generator` with **zero backend work**, and
`/location-qr-code` gets the informational page. Unique copy per the anti-thin-content rule in that file's
header. Both slugs are served by the existing `(marketing)/[slug]` dispatcher; add them to `sitemap.ts` if
it isn't already derived from `TYPE_PAGES`.

---

## 6. External-Service Integration

**None — and that is the design.** We construct URLs to third-party map apps; we never call them. No
Google Cloud project, no API key, no `.env` entry, no per-request cost, no quota, no rate limit, no
latency, no ToS/caching obligation, no vendor to be down.

Explicitly **not** integrated in v1 (PRD §7, R3/R4): Places API (autocomplete/place IDs), Geocoding API,
Maps Static API, Maps Embed API, Maps JavaScript API. Each needs a billed key. The unofficial
`maps.google.com/maps?q=…&output=embed` iframe is **not** used — undocumented, unsupported, breaks silently.

No email → `_dmarc.qravio.app` is **not** a gate. No AI → `ANTHROPIC_API_KEY` is irrelevant. No payment
provider. No cron.

---

## 7. API Contracts

The type rides the existing QR create/update/read endpoints — no new public route.

```jsonc
// POST /api/v1/workspaces/{workspace_id}/qrs
{
  "name": "Indiranagar outlet",
  "type": "location",
  "category": "dynamic",
  "content": {
    "locationContent": {
      "place_name": "Anand Sweets — Indiranagar",
      "street_address": "1102, 12th Main Rd, HAL 2nd Stage",
      "city": "Bengaluru", "state": "Karnataka",
      "postal_code": "560038", "country": "India",
      "landmark": "Opposite Reliance Fresh, 2nd gate",
      "latitude": 12.9716, "longitude": 77.5946,   // optional; both or neither
      "phone": "+919876543210",
      "open_directly": false
    }
  },
  "page_design": { "templateId": "location_card", "themeColor": "#4648d4" }
}

// 422 — one coordinate supplied without the other
{ "detail": "latitude and longitude must be provided together." }
// 422 — out of range / Null Island
{ "detail": "latitude must be between -90 and 90." }
// 422 — nothing locatable
{ "detail": "Provide a street address, a city, or coordinates." }
// 403 — plan's dynamic_qr_types lacks "location" (i.e. migration 0035 not applied)
{ "detail": "This QR type is not available on your plan." }
```

The QR **read** response returns `content.locationContent` (the mapped `qr_location_details` row).

**KV value** for a `location` QR:
```jsonc
{ "qr_id": "…", "type": "location", "destination": null, "status": "active",
  "workspace_id": "…",
  "page_design": { "templateId": "location_card", "themeColor": "#4648d4" },
  "content": { "place_name": "…", "street_address": "…", "city": "…", "state": "…",
               "postal_code": "…", "country": "…", "landmark": "…",
               "latitude": 12.9716, "longitude": 77.5946,
               "phone": "…", "open_directly": false } }
```

**Internal:** `GET /internal/location/{qr_id}` (header `x-internal-secret`) → the raw
`qr_location_details` row, or `404`. Mirrors `GET /internal/event/{qr_id}`.

---

## 8. Security, Privacy & Abuse

- **Open redirect is the one real risk.** In direct mode the Worker returns a `302` to a URL *we*
  constructed with a hard-coded `https://www.google.com/maps/search/?api=1&query=` prefix and an
  `encodeURIComponent`'d payload — a user cannot steer the host. v1 ships **no** `maps_url_override` field
  precisely to keep it that way (PRD Open Q3). If one is ever added, host-allowlist it at write time *and*
  at render time; an unvalidated override turns every short code into a phishing redirector on our own
  domain, which also poisons the domain's reputation for every other tenant.
- **XSS:** every field is owner-authored free text rendered into a template literal. `escapeHTML()` on
  **every** interpolation, including `place_name`, `landmark`, and `phone` (a `tel:` href is still an
  attribute-injection surface). Same discipline as `storefrontTemplate.js`.
- **Auth / tenant isolation:** create/update ride the Bearer-authed, `require_can_*`-gated QR endpoints;
  `qr_location_details` carries an explicit `workspace_id` and every query filters on `qr_id` — the
  service-role client bypasses RLS, so code-side filtering is the boundary. The custom-domain workspace
  isolation check in `src/index.js` applies to `location` short codes like any other.
- **Privacy:** the address is deliberately published by the owner (identical posture to the `business`
  type's address today). No new PII class, no scanner-side collection, no geolocation prompt, no consent-
  gate change. Worth one line of builder copy for the sole-proprietor-home-address case (PRD R9).
- **No SSRF:** the backend makes no outbound request from any user-supplied value; the maps URL is data we
  return, never something we fetch.
- **Abuse / cost:** no per-use cost, no unauthenticated write surface, no metering needed. The free tool
  page is fully client-side — no backend to abuse.

---

## 9. Performance, Scale & Cost

- **Edge:** one extra `if` in the dispatch chain and, in direct mode, a `302` that skips HTML generation
  entirely (**cheaper** than every other dynamic type). Landing-page mode is one template-literal build —
  the same cost profile as `business`, with less data. No extra KV read, no subrequest, no external call.
- **Backend:** one small `SELECT` in `build_kv_content` per QR write; one more embedded table in
  `SELECT_WITH_RELATIONS`. The KV payload grows by a handful of short strings and two floats.
- **DB:** one narrow 1:1 table; two indexes. Row count tracks `location` QR count, which we forecast at
  2–5% of new dynamic QRs (PRD §9). Negligible.
- **Cost: zero marginal.** No API key, no metered provider, no AI, no storage, no email, no cron. This is
  the cheapest type in the catalogue to run.

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`):**
- `test_location_create`: a `location` QR persists `qr_location_details` and the row reaches KV via
  `build_kv_content` (assert the `content` payload carries `latitude`/`longitude`/`open_directly`).
- `test_location_validation`: lone `latitude` → 422; out-of-range → 422; `0,0` → 422; `place_name`-only
  (no address, no coords) → 422; over-length strings capped.
- `test_location_update`: **`open_directly: false` on a PATCH actually turns it off** (the boolean-vs-
  truthiness bug called out in §3.2) — the single most likely defect in this feature.
- `test_location_response_shape`: the `qr_location_details` embed normalizes from the **list** form
  (`qr_event_details` pattern), not the dict form (`qr_review_funnel`).
- `test_location_type_gate`: with `"location"` absent from `dynamic_qr_types` → 403; present → 201. Assert
  on a **Free** plan fixture (ungating is the product claim).

**Migration (applied by hand, verified by query):** re-run `0035` twice — the array must gain exactly one
entry and no plan's array may be empty or shrink. Explicitly assert the empty-array guard by seeding a
scratch plan with `'[]'` and confirming it is **skipped**, not appended to.

**Worker (`qr_cf_code`):**
- **`buildMapsUrl` equivalence gate (release-blocking):** for a corpus of existing `qr_business_details`
  address fixtures, `buildMapsUrl(record)` must equal the *pre-refactor* `storefrontTemplate.js:32-34`
  expression byte-for-byte. This is the regression that would be invisible in review.
- `hasPin` treats `longitude: 0` as a valid pin (falsy-zero trap); `latitude: null` → no pin.
- Dispatch: `open_directly: true` → `302` to a `google.com/maps` URL; `open_directly: true` with no usable
  address/coords → renders the page instead of `302`-ing to `""`.
- KV-first vs `/internal/location/{qr_id}` fallback; missing both → `getErrorPage()`.
- `templateId` routing: `location_pin` → pin template; unknown/absent → `location_card`.
- Escaping: a `place_name` of `"</div><script>alert(1)</script>"` and a `phone` containing `"` are escaped
  in the rendered HTML and in the `tel:` attribute.

**Frontend (Vitest):**
- `src/lib/maps.ts` and `qr_cf_code/src/utils/maps.js` produce **identical** URLs for a shared fixture
  table (the mirrored-pair guarantee, §5.1).
- zod: both-or-neither coordinates, ranges, `0,0`, the `"lat, lng"` paste-split.
- The "preview the exact link" anchor's `href` matches what the Worker would build for the same values.
- **Note the ~29 pre-existing FE test failures baseline** — only net-new failures in `location`/`maps`
  files are regressions.

**Manual / staging:** create a `location` QR on a Free workspace; scan on Android and iOS; confirm the
Google/Apple/Waze buttons open the right apps; confirm a lat/lng QR pins exactly where the builder preview
showed; confirm the **existing** business storefront's Map button is unchanged post-refactor.

---

## 11. Observability & Rollout

**Phase 0 — Backend + edge (internal/staging).** Apply `0035` (re-verify the slot first). Add the model,
persistence, `SELECT_WITH_RELATIONS` embed, `build_kv_content` branch + default-template shim, and
`/internal/location`. Add `utils/maps.js`, the dispatch case, the page + 2 templates, and the storefront
refactor. `npm run deploy` to staging. Verify via the `buildMapsUrl` equivalence gate and a canary QR in
each mode.

**Phase 1 — Builder + previews (closed).** `LocationContent.tsx`, the two React templates, type
registration, the preview-the-exact-link control. Internal + design partners. **Acceptance:** create on a
Free workspace → scan renders the card with working Google/Apple/Waze links → editing the address updates
the live QR → direct mode `302`s and still records a scan → lat/lng beats free text → the React preview
and the Worker page agree for the same `templateId`.

**Phase 2 — GA + SEO.** `npm run deploy:prod`. Ship the `TYPE_PAGES` entry (`/location-qr-code` + free
`/location-qr-code-generator`), sitemap, comparison matrix, `/beaconstac-alternative`, help-center entry.

**Deploy order (matters here):** migration → backend → Worker → frontend. The Worker must not ship before
`build_kv_content` writes `location` content; the `/internal/location` fallback makes an inversion
survivable rather than fatal, but order it correctly. **No DMARC gate. No cron gate. No key provisioning.**

**Metrics / logs:** `location` share of newly created dynamic QRs (expect 2–5%); % of `location` QRs with
coordinates (target ≥25% — the quality lever); direct-mode vs landing-page split (informs Open Q1);
organic sessions + free-tool→signup on the two SEO pages (the actual success criterion); support-tag watch
for "wrong location". Structured Worker log on the `location` branch: `shortCode`, `mode`
(`direct`/`page`), `hasPin` — no address, no PII. No new dashboard infra.

---

## 12. Open Technical Questions & Risks

1. **Migration slot `0035` is provisional.** `0033` (QR expiry) and `0034` (UPI) are drafted-but-unapplied;
   whichever lands first shifts the rest. **Re-verify against `qr_backend/migrations/` at build time** — the
   repo has a prior commit fixing exactly this class of staleness.
2. **`dynamic_qr_types` append vs wholesale rewrite — resolved: append-if-absent.** `0027` rewrote the
   array wholesale, which is safe for one migration and lethal for three concurrent ones. The
   `jsonb_array_length(...) > 0` guard is load-bearing: appending onto `[]` flips a fail-open plan
   (`qr.py:1560`) into "only `location` allowed". Coordinate with the UPI/Phone type specs so all three use
   the same append shape.
3. **PostgREST embed shape — resolved: surrogate PK + `UNIQUE(qr_id)`** so the embed returns a **list**
   (`qr_event_details` pattern, `qr.py:1405`) rather than a dict (`qr_review_funnel`, `qr.py:1416-1418`).
   Copy the event normalization. Getting this backwards produces a confusing `TypeError` at response time.
4. **`open_directly` boolean on PATCH.** The update-collection block builds partial dicts; a truthiness
   check makes `false` unsettable. Must use explicit key-presence. Called out in §3.2 and §10 because it is
   the most likely defect in the whole feature.
5. **Storefront refactor equivalence.** The shared helper joins five address parts vs storefront's three
   (`storefrontTemplate.js:25`). `filter(Boolean)` makes them identical **only** when
   `postal_code`/`country` are absent on business records. **Verify against real `qr_business_details`
   rows** — if any carry those fields, the storefront's Map URL changes and either (a) that is an accepted
   improvement, stated explicitly, or (b) the helper needs a field-list parameter. Do not hand-wave this.
6. **`maps_url_override` — recommend NOT shipping in v1** (PRD Open Q3). It is the entire open-redirect
   surface (§8), and the `website` type already serves "I have a Maps link". If product insists, the host
   allowlist is mandatory at both write and render time.
7. **Two templates or one** (PRD Open Q2) — recommend two; each React template obligates a mirrored Worker
   template (house rule), so the count is a 2× cost multiplier on an Impact-2 feature.
8. **Apple Maps / Waze URL schemes are third-party contracts we don't control.** They are stable and
   documented, but unversioned. Keep them in the one shared helper so a scheme change is a one-line fix in
   each service, and don't UA-sniff — render all buttons and let the user choose.
9. **`HAS_LANDING_PAGE_TYPES` semantics** (PRD Open Q5) — adding `location` makes the constant mean "has a
   page *unless* the owner enabled direct mode". Audit its consumers before adding; if any assume "always
   renders a page," either fix them or derive the flag per-QR.

### Appendix — Key Files

| Concern | File |
|---|---|
| Logic being promoted | `qr_cf_code/src/pages/business/storefrontTemplate.js` (address join L22-25, `mapsUrl` L32-34, Map button L52) |
| Migration | `qr_backend/migrations/0035_location_qr_type.sql` (NEW — `qr_location_details` + append-if-absent `dynamic_qr_types`) |
| Content model + type registration | `qr_backend/src/api/routes/qr.py` (`LocationContent` ~L323-339; `QRCodeCreate.type` Literal ~L836-863; `QRContent` ~L531-556; `SELECT_WITH_RELATIONS` L998) |
| Persistence | `qr_backend/src/api/routes/qr.py` (create insert ~L2121-2126; update collect ~L2932 / apply ~L3227-3234; response map ~L1264-1304, row pop ~L1405) |
| KV snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` branch ~L404-427; default-`templateId` shim ~L90) |
| Internal fallback | `qr_backend/src/api/routes/internal.py` (`GET /internal/location/{qr_id}`, mirrors `get_internal_event` L274-285) |
| Type gate (unchanged) | `qr_backend/src/api/routes/qr.py` (create L1546-1560, bulk L2459-2477); `subscription.py:534`; policy in `migrations/0027_open_all_qr_types.sql` |
| Shared maps helper | `qr_cf_code/src/utils/maps.js` (NEW) ↔ `qr_frontend/src/lib/maps.ts` (NEW mirror) |
| Edge dispatch | `qr_cf_code/src/handlers/qrRouter.js` (imports L1-14; `location` case beside `business` L165-182) |
| Worker page + templates | `qr_cf_code/src/pages/locationPage.js` (re-export) + `src/pages/location/{index,shared,cardTemplate,pinTemplate}.js` (NEW; `HANDLERS` map per `src/pages/event/index.js`) |
| Builder form | `qr_frontend/src/components/qr-generator/content-types/LocationContent.tsx` (NEW, ≤200 lines) + `content-types/index.ts` + `QRContent.tsx` (~L149/189, ~L445/458) |
| FE types | `qr_frontend/src/lib/types/qr.ts` (`LocationContent` + `QRContent.locationContent`, L433-459) |
| Type registration (FE) | `qr_frontend/src/lib/constants/qr-types.ts` (L75-90, L92-120, L185-210, L218-243); `qr-type-icons.ts` (`TYPE_ICON_INNER.location`) |
| React templates | `qr_frontend/src/lib/constants/page-templates.tsx` (`LOCATION_TEMPLATES`, spread ~L527-539, `getTemplatesForType` L542) + `components/qr-generator/templates/location/` (NEW) |
| Preview wiring | `qr_frontend/src/components/qr-generator/TemplatePicker.tsx` (~L41-46) + `PagePreview/PagePreview.tsx` (~L32, ~L76, bag ~L196-201) |
| SEO | `qr_frontend/src/lib/constants/qr-type-pages.ts` (`TYPE_PAGES` entry, `isStaticTool: true`) + `src/app/sitemap.ts` |
| Worker deploy | `qr_cf_code` — **`npm run deploy:prod`** required; no `wrangler.toml` change |
