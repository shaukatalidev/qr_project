# TRD — Restaurant Menu QR Type (menu-only)

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-07-25
**Priority:** Strategic bet — the anchor QR type for the India F&B SMB wedge. Technically this is the **largest new QR type we've built**: it is the first type whose content is a two-level nested collection with per-row images, which stresses three seams that every previous type left untouched — the KV payload size, the multi-child-row write path, and the edge render cost.
**Tiers:** **All plans, ungated.** `menu` is appended to `dynamic_qr_types` on **every** non-custom plan, per the posture set by `0027_open_all_qr_types.sql` ("QR *type* is no longer a paywall lever"). Item photos consume the existing workspace storage quota.
**Plan flags (NEW):** **None.** Gating is `dynamic_qr_types` membership only — `FEATURE_ENFORCEMENT` is untouched and `test_feature_gate_coverage` cannot break (the `review_funnel` precedent, `0022_google_review_funnel.sql`).
**Migration slot:** **`0041`** (`0041_restaurant_menu_qr.sql`) — **provisional.** Verified against disk: highest existing = `0032_lemonsqueezy_variant_backfill.sql`. `0033` is reserved by `QR_EXPIRY_SCHEDULING_TRD.md` and `0034`–`0040` by the sibling specs drafted in this same batch. **Re-run `ls qr_backend/migrations/` immediately before applying and renumber to the lowest free slot** — `0022_google_review_funnel.sql:10-13` documents exactly this slot-drift happening once already (the TRD reserved `0021`; `0019`–`0021` landed first).
**Services touched:** `qr_backend` (3 new tables, type literal, nested Pydantic models, batched create/update write path, `build_kv_content` branch, `SELECT_WITH_RELATIONS` join) · `qr_cf_code` (new `menu` dispatch case + `src/pages/menu/` with a dispatcher, helpers, and 3 templates — **requires `npm run deploy:prod`**) · `qr_frontend` (nested dnd-kit category/item editor, paste-import, 3 mirrored React previews, 4 registry touchpoints). **No AI, no email, no cron, no new external service, no new secret, no `wrangler.toml` change.**
**Implements PRD:** Restaurant Menu QR Type (menu-only). **Mirrors** the new-dynamic-QR-type pipeline of `GOOGLE_REVIEW_FUNNEL_QR_TRD.md`, the multi-template Worker dispatcher of `qr_cf_code/src/pages/vcard/index.js`, and the dnd-kit editor of `qr_frontend/src/components/qr-generator/content-types/ListLinksContent.tsx`.

**Rev (2026-07-25, post eng-review):** Reviewed via `/plan-eng-review` + an outside-voice pass (all claims verified against code). Product decisions in the PRD Rev (per-QR photo cap · heuristic paste parser · auto-linkify **allowed** with a hard scheme allowlist · sold-out toggles in the edit dispatch).
**S1 ship-blockers (required fixes):**
1. **No workspace storage quota exists** — `_QUOTA_SPEC` (`subscription.py:429-455`) has only the per-file `max_file_size_mb`; there is no aggregate storage key anywhere. Replace every "counted against the existing storage quota" claim with the **per-QR photo cap** (≤50/menu), enforced server-side beside the 300-item cap.
2. **Storage is never reclaimed** — `delete_qr_code` (`qr.py:3403-3434`) touches no storage and no reaper exists. Add best-effort `bucket.remove()` on item removal **and** QR delete (pattern at `qr.py:1743/1863/1885`).
3. **Photo round-trip is broken** — model takes `image_path`, table stores `image_url`, response returns `image_url`; the client can't send back what it received. Store **both** (`image_path` + `image_url`), return both, accept either with path winning — the `qr.py:2111-2113` avatar precedent.
4. **The `image_path` ownership check validates the wrong prefix** — §3.7/§8 cite a stale docstring; real uploads land at `{workspace_id}/temp/{uuid}/{name}` (`storage.py:237`), so a `{user_id}/` check 422s **every** genuine upload and breaks agency handover. Validate against the **target QR's `workspace_id`** prefix.
5. **`build_kv_content` swallows all exceptions → `{}`** (`cloudflare_kv.py:476-478`), so a content-build failure **publishes an empty menu behind a 200 save** — and §12-Q2's PostgREST embed ambiguity on `qr_menu_items` (two FKs) makes that a live risk. The `menu` branch must **re-raise** (or assert non-empty categories) so a build failure fails the save. This, not the public-bucket question, is the worst silent-failure mode here.
6. **A PATCH omitting `content` would delete the whole menu** — §3.4 mandates empty-list-deletes-all but never states the outer guard. The menu write path runs **only when `content.menu` is present**; absent ≠ empty (the `qr.py:3158` `is not None` guard the spec told the implementer *not* to copy).
7. **`withDocumentLang` does not exist** — §4.2 imports it from `utils/html.js`, but it's created by the multilingual spec (`0042`) which menu says it doesn't depend on. Menu v1 either uses `withMobileViewport` alone **or** authors the ~6-line helper itself (and multilingual reuses it). Pick one; as written v1 fails to build.
**S2 corrections:** **`position` is broken in the pattern being copied** — `ListLinksContent` assigns it only at `append()` and `move()` never recomputes it, while the backend prefers the client value (`qr.py:3184`); menu's `(position, name)` sort would then render a convincingly *alphabetical* menu. **Strip client `position`; assign from array index server-side on both create and update; tiebreak on `id`, never `name`.** **Nested dnd-kit:** `@dnd-kit/modifiers` isn't installed and no nested precedent exists — use **two separate `DndContext`s** (one for categories, one per category) so cross-level collision is structurally impossible, instead of one context discriminating on `active.data.current?.type`. **Registration surface is ~15 files, not 5** — §5.4 misses `build/page.tsx` (label map **and** the required-content gate at `:288-303`, or a zero-category menu saves), `content-editor-dispatch.tsx`, `pricing.ts` `ALL_DYNAMIC_TYPES` (or the pricing page contradicts "no lock chip"), the **second** `TYPE_ICONS` in `lib/types/qr.ts:844`, `qr-type-icons.ts`, `qr-recommendations.ts`, `useAnalytics.ts`, plus tests. **KV freshness:** reads have no `cacheTtl` (colo-cached ~60 s) and single-key writes rate-limit ~1/s (rapid sold-out toggles can 429 → `write_to_kv` raises → 500) — state a **≤60 s SLO**, drop "within seconds". **Write amplification is the real #1 risk:** `resync_workspace_qrs` (`cloudflare_kv.py:262-281`) serially rebuilds+PUTs every menu blob on branding/pixel/MoR/Razorpay events. **`withMobileViewport` hard-clamps `body` to 390 px** — the "two-column photo grid" is two ~170 px cards *always* (including desktop, which is Farah's Instagram-bio use case); the accordion nav must be `position:sticky` (not `fixed`, which escapes the centred column) and long dish names need `overflow-wrap:anywhere` under `overflow-x:hidden`. **No server-side downscale exists** — `downscale()` is wired only into `vcard_ocr.py`; `POST /storage/upload` resizes nothing and the client-side `resizeImage()` is dead code, so R2's mitigation is **unassigned work** that must be scoped. **`currency` must be a `Literal[...]` enum**, not a free 3-char string (closes both the escaping sink and the undefined `formatPrice` fallback). **Reconcile the two contradictory empty-menu guards** (§1 `categories?.length` vs §4.1 `Array.isArray`). **`updated_at` never reaches KV**, so the "last updated" stamp is unbuildable as specced. **Multi-child create has no rollback** (`qr.py` inserts parent then children with no transaction) — a menu failing mid-insert leaves a phantom QR; state the intended behavior. **Worker test infra doesn't exist** (`qr_cf_code` has `wrangler` only, plus 9 hand-rolled `node *.test.mjs` suites) — the R6 parity gate must follow that convention and be budgeted. §12 skips item 10 (renumber). **Confirmed correct:** batched upsert-then-prune, denormalized `qr_id` on items, public URLs over edge-signed, and the KV sizing math (~215 KB vs 25 MiB).

## 1. Overview & Architecture

`menu` is a new **dynamic** QR type whose content is a two-level ordered tree: **menu → categories →
items**. Items carry `name`, `price_minor`, `description`, `image_url`, `diet`, `is_available`,
`price_note`, and `position`. The whole tree is snapshotted into the KV `content` blob at write time,
so a scan renders **entirely at the edge with zero backend calls** — the same posture `lead_form` and
`review_funnel` take (`qrRouter.js:268-287`), and a hard invariant here because a menu render must not
depend on Render's cold-start latency while a diner is sitting at a table.

Three things make this type architecturally different from every type before it, and each gets an
explicit decision below rather than an inherited pattern:

1. **Payload size.** A menu is the largest `content` blob we've ever put in KV. Every scan reads and
   `JSON.parse`s the entire entry. Bounded by hard, **server-enforced** caps (§2, §9).
2. **Write amplification.** The existing multi-child-row write path — the `qr_link_items` loop at
   `qr.py:3179-3197` — issues **one PostgREST round-trip per row**. That is fine for a 10-link
   Linktree page and catastrophic for a 300-item menu (§3.4). We batch instead.
3. **Per-row images.** The `images`/`pdf`/`mp3` types store storage *paths* and have the Worker mint
   signed URLs at scan time (`qrRouter.js:100-120`, `utils/supabase.js:3`). For a 20-photo menu that
   would add a Supabase round-trip to the hot path and defeat browser caching. We store **durable
   public URLs** instead — the helper already exists (`qr.py:1008-1022`) and the bucket is already
   public (§3.7).

**Services touched**

| Service | Change |
|---|---|
| `qr_backend` | Migration `0041`: `qr_menus`, `qr_menu_categories`, `qr_menu_items` + `dynamic_qr_types` append on all non-custom plans. `"menu"` added to the `QRCodeCreate.type` `Literal` (`qr.py:839-864`); nested `MenuContent`/`MenuCategory`/`MenuItem` Pydantic models with cap validation; batched create/update write path (upsert-then-prune, **not** the per-row loop); `qr_menus(*), qr_menu_categories(*, qr_menu_items(*))` appended to `SELECT_WITH_RELATIONS` (`qr.py:998`); `_build_content_from_db_rows` branch; `build_kv_content` `menu` branch (`cloudflare_kv.py:387`); item-image path validation. **No** new endpoint, gate, flag, RPC, or cron. |
| `qr_cf_code` | New `if (type === "menu")` branch in `handleQRCode` (`qrRouter.js`, before the terminal `return getErrorPage()` at `:289`); new `src/pages/menu/{index.js,helpers.js,classicTemplate.js,photoTemplate.js,accordionTemplate.js}`. **Zero client-side JS** in all three templates (native `<details>` + anchor nav). Templates are **i18n-shaped from the first commit** — trailing optional `i18n` param, no hardcoded chrome (§4.5) — but ship **English-only**, with no dependency on the multilingual spec landing. **Requires `npm run deploy:prod`.** |
| `qr_frontend` | New kebab-case editor components under `content-types/menu/` (nested dnd-kit, ≤200 lines each), `lib/menu.ts` (price/currency + paste parser + zod), 3 React preview templates under `templates/menu/`, plus 4 registry touchpoints (`qr-types.ts`, `page-templates.tsx`, `TemplatePicker.tsx`, `PagePreview.tsx`) and one `QRContent.tsx` case. |

**Data flow — authoring**

```
Builder menu editor (nested RHF field arrays + dnd-kit; client-generated UUIDs)
  → zod: caps (≤30 categories, ≤300 items, ≤300-char description), price as INTEGER minor units
  → authApi POST/PATCH /workspaces/{id}/qrs[/{qr_id}]  { type:"menu", content:{ menu:{...} } }
  → qr.py: dynamic_qr_types gate → cap re-validation (server-side) → image_path ownership check
      create:  1 insert qr_menus  +  1 bulk insert categories  +  1 bulk insert items
      update:  1 upsert qr_menus  +  1 bulk upsert categories  +  1 bulk upsert items
               +  1 prune-delete categories  +  1 prune-delete items      (upsert BEFORE prune)
  → build_kv_content(qr_id, "menu", db) → nested embed + deterministic position sort
  → write_to_kv(..., content=<menu tree>)   [raises RuntimeError on failure → the save 4xx/5xxs loudly]
```

**Data flow — scan (hot path, zero backend calls)**

```
GET /:shortCode → env.QR_KV.get(shortCode) → JSON.parse
  → status / password / custom-domain branches (unchanged)
  → handleQRCode → type === "menu"
      → kvContent.categories?.length ? getMenuPage(kvContent, pageDesign) : getErrorPage()
      → src/pages/menu/index.js: HANDLERS[page_design.templateId] ?? HANDLERS["menu_classic"]
      → template builds one HTML string (escapeHTML on every merchant field,
        formatPrice(price_minor, currency), <img loading="lazy"> with a reserved aspect box)
  → ctx.waitUntil(recordScan(...))    [unchanged — one scan event per menu view]
```

**Explicitly NOT built** (the PRD's hard line, restated as an engineering constraint): no cart state,
no order POST route, no payment intent, no `/internal/order*` endpoint, no table-identifier parameter,
no POS webhook. A PR adding any of these to `src/pages/menu/` or `qr.py`'s menu path is a spec
violation, not a feature request.

---

## 2. Data Model & Migrations

Three new tables. `qr_menus` is the 1:1 header (mirrors `qr_review_funnel`'s `qr_id`-as-PK shape);
`qr_menu_categories` and `qr_menu_items` are the ordered children.

**Why `qr_id` is denormalised onto `qr_menu_items`.** `qr_link_items` deliberately has **no** `qr_id`
column, and `qr.py:3159-3176` pays for it: the update path must first resolve `page_id`, then scope
every delete by it, with an explicit comment (`qr.py:3165`) noting the constraint. Carrying `qr_id` on
items makes the prune a **single** `.eq("qr_id", …).not_.in_("id", …)` statement that is correct even
when an item moved between categories in the same save — which is exactly the operation the "Move
to…" action performs. The cost is one redundant uuid per row; the benefit is a whole class of
cross-category-move bugs that cannot happen.

**RLS.** The older `qr_*` detail tables (`qr_lead_forms` in `0012`, `qr_review_funnel` in `0022`) do
**not** enable RLS. The newer standalone tables (`0014`, `0017`, `0018`, `0026`) enable it with **no
policies** as defence-in-depth. We follow the **newer** convention: the backend uses the service-role
client which bypasses RLS regardless, so enabling it costs nothing and closes the anon/auth role off
entirely. Tenant isolation is enforced in route code via `get_workspace_role` + `require_can_*`, never
by RLS.

**`qr_backend/migrations/0041_restaurant_menu_qr.sql`** — `BEGIN/COMMIT`-wrapped, idempotent
(`IF NOT EXISTS`, `@>` guard), applied by hand in the Supabase SQL editor. Ships **only this phase's**
schema.

```sql
-- Migration 0041: Restaurant Menu QR type (menu-only).
--
-- New dynamic QR type `menu`: a two-level ordered tree (menu → categories → items).
-- MENU-ONLY BY DESIGN. There is deliberately NO order/cart/payment/table schema here
-- and there never will be — see RESTAURANT_MENU_QR_PRD.md §3. Do not "just add" an
-- orders table to this file.
--
-- NO new boolean flag: gating is dynamic_qr_types membership only, so
-- FEATURE_ENFORCEMENT is untouched and test_feature_gate_coverage cannot break
-- (same construction as 0022_google_review_funnel.sql).
--
-- SLOT: provisional. Highest on disk at drafting = 0032. 0033 is reserved by the QR
-- expiry spec and 0034-0040 by sibling specs in the same batch. RE-CHECK
-- `ls qr_backend/migrations/` before applying and renumber to the lowest free slot —
-- 0022 shipped as 0022 precisely because its TRD's reserved 0021 was taken.
--
-- Idempotent; safe to re-run.
BEGIN;

-- ── Menu header (one row per menu QR) ─────────────────────────────────────────
-- currency is set ONCE per menu, never per item: mixed-currency menus are not a
-- real restaurant shape and per-item currency would double the formatting surface
-- in both the Worker template and its React mirror.
CREATE TABLE IF NOT EXISTS qr_menus (
    qr_id       uuid        PRIMARY KEY REFERENCES qr_codes(id) ON DELETE CASCADE,
    currency    char(3)     NOT NULL DEFAULT 'INR',      -- ISO-4217; display only, no FX
    menu_note   text,                                    -- "All prices in ₹, taxes extra"
    show_diet_marks boolean NOT NULL DEFAULT true,       -- India: veg/non-veg glyphs on by default
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ── Categories (ordered) ──────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS qr_menu_categories (
    id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    qr_id       uuid        NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    name        text        NOT NULL,
    description text,
    position    integer     NOT NULL DEFAULT 0,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now()
);

-- ── Items (ordered within a category) ─────────────────────────────────────────
-- price_minor is an INTEGER in the menu currency's minor unit (paise for INR).
-- NEVER numeric/float: float money is how a customer gets shown 249.99999.
-- NULL price_minor = "no price shown" (use price_note for "Market price").
--
-- qr_id is DENORMALISED (qr_link_items deliberately has none — see qr.py:3165 —
-- and the update path pays for it). Carrying it makes the update prune a single
-- statement that stays correct when an item moves between categories in one save.
CREATE TABLE IF NOT EXISTS qr_menu_items (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    category_id  uuid        NOT NULL REFERENCES qr_menu_categories(id) ON DELETE CASCADE,
    qr_id        uuid        NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    name         text        NOT NULL,
    description  text,
    price_minor  integer     CHECK (price_minor IS NULL OR price_minor >= 0),
    price_note   text,                                   -- "half / full", "market price"
    image_url    text,                                   -- durable PUBLIC storage URL (see §3.7)
    diet         text        CHECK (diet IS NULL OR diet IN ('veg','nonveg','egg','vegan')),
    is_available boolean     NOT NULL DEFAULT true,      -- false → renders "Sold out", NOT deleted
    position     integer     NOT NULL DEFAULT 0,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);

-- ── Indexes ───────────────────────────────────────────────────────────────────
-- Every read is "all rows for one QR, in position order" (build_kv_content and the
-- single-QR edit read). Both indexes are covering for that access pattern.
CREATE INDEX IF NOT EXISTS idx_qr_menu_categories_qr
    ON qr_menu_categories (qr_id, position);
CREATE INDEX IF NOT EXISTS idx_qr_menu_items_category
    ON qr_menu_items (category_id, position);
-- Supports the single-statement prune-delete scoped by qr_id (§3.4).
CREATE INDEX IF NOT EXISTS idx_qr_menu_items_qr
    ON qr_menu_items (qr_id);

-- ── RLS: enabled, NO policies (newer house convention — 0014/0017/0018/0026) ──
-- The backend uses the service-role client, which bypasses RLS; enabling it simply
-- ensures the anon/auth roles can never reach these tables. Tenant isolation is
-- enforced in route code (get_workspace_role + require_can_*), never by RLS.
ALTER TABLE qr_menus            ENABLE ROW LEVEL SECURITY;
ALTER TABLE qr_menu_categories  ENABLE ROW LEVEL SECURITY;
ALTER TABLE qr_menu_items       ENABLE ROW LEVEL SECURITY;

-- ── Plan seed: append `menu` to dynamic_qr_types on EVERY non-custom plan ──────
-- HOUSE CONVENTION: parity-safe jsonb append (lower(name) + is_custom guard +
-- coalesce + @> idempotency guard). NO bare "WHERE name IN (...)".
--
-- APPEND, not the wholesale array set 0027 used: 0027 could be wholesale because it
-- was defining the canonical lists; a later migration that re-set them would clobber
-- anything seeded in between. One statement covers all four tiers because the append
-- is per-row against each plan's own current list (free/starter have 13 entries,
-- pro/agency 14 incl. lead_form — both just gain one).
--
-- NEVER set dynamic_qr_types to '[]': the backend gate is fail-open on an empty list
-- (`if _allowed_types and qrType not in _allowed_types`), which would allow ALL types
-- including lead_form. See 0027_open_all_qr_types.sql:18-20.
UPDATE plans
SET features = jsonb_set(
        coalesce(features, '{}'::jsonb),
        '{dynamic_qr_types}',
        CASE
            WHEN coalesce(features->'dynamic_qr_types', '[]'::jsonb) @> '["menu"]'::jsonb
                THEN features->'dynamic_qr_types'
            ELSE coalesce(features->'dynamic_qr_types', '[]'::jsonb) || '["menu"]'::jsonb
        END,
        true)
WHERE coalesce(is_custom, false) = false;

COMMIT;

-- Sanity:
--   SELECT name, features->'dynamic_qr_types' FROM plans
--    WHERE coalesce(is_custom,false)=false ORDER BY price_monthly;
--   → every non-custom plan contains "menu"; none is '[]'.
```

**No `FEATURE_ENFORCEMENT` change, no `_QUOTA_SPEC` entry, no seed blob.** Because gating is
`dynamic_qr_types` membership rather than a boolean flag, `subscription.py` is untouched and
`test_feature_gate_coverage` cannot regress — the same by-construction argument
`GOOGLE_REVIEW_FUNNEL_QR_TRD.md` makes. No change to `qr_codes`, `qr_files`, `qr_scan_events`, or
`qr_scan_counters`.

**Hard caps (enforced server-side in §3.2, mirrored in the client zod schema, and the reason the KV
payload is bounded):** ≤ **30** categories per menu · ≤ **300** items per menu · ≤ **100** items per
category · item `name` ≤ 120 chars · item `description` ≤ 300 chars · category `name` ≤ 80 chars ·
`menu_note` ≤ 300 chars · `price_note` ≤ 40 chars · `price_minor` ≤ 100 000 000 (₹10 lakh). These are
technical bounds, not plan limits — they are not tiered and not in `plans.features` (PRD §8).

---

## 3. Backend Design

### 3.1 Type literal — `qr_backend/src/api/routes/qr.py`
Append `"menu"` to the `QRCodeCreate.type` `Literal` list (`qr.py:839-864`, after `"review_funnel"`).
`QRCodeUpdate.type` is a bare `Optional[str]` (`qr.py:889`) and needs no change.

### 3.2 Content models + cap validation — `qr.py`
Three nested Pydantic models beside the existing per-type content models (the `LinkItem` model at
`qr.py:285` is the shape precedent), wired into `QRContent` (`qr.py:531`) as `menu: Optional[MenuContent]`:

```python
class MenuItemIn(pydantic.BaseModel):
    id: Optional[str] = None              # client-generated UUID (see §3.4)
    name: str = Field(max_length=120)
    description: Optional[str] = Field(default=None, max_length=300)
    price_minor: Optional[int] = Field(default=None, ge=0, le=100_000_000)
    price_note: Optional[str] = Field(default=None, max_length=40)
    image_path: Optional[str] = None      # storage path; validated + converted in §3.7
    diet: Optional[Literal["veg", "nonveg", "egg", "vegan"]] = None
    is_available: bool = True
    position: int = 0

class MenuCategoryIn(pydantic.BaseModel):
    id: Optional[str] = None
    name: str = Field(max_length=80)
    description: Optional[str] = Field(default=None, max_length=200)
    position: int = 0
    items: list[MenuItemIn] = Field(default_factory=list, max_length=100)

class MenuContent(pydantic.BaseModel):
    currency: str = Field(default="INR", min_length=3, max_length=3)
    menu_note: Optional[str] = Field(default=None, max_length=300)
    show_diet_marks: bool = True
    categories: list[MenuCategoryIn] = Field(default_factory=list, max_length=30)
```

Plus a model validator enforcing the **cross-category total** (`sum(len(c.items)) <= 300`), which
`max_length` on a nested list cannot express. All caps are re-validated server-side even though the
client also enforces them — the client is advisory (§8).

`price_minor` is an **integer minor unit**. The API never accepts or returns a decimal price; the
client converts at the input boundary (`lib/menu.ts`) and the Worker/React format at the render
boundary from `(price_minor, currency)`. There is exactly one rounding site in the whole system, in
the client's input parser, and it is unit-tested (§10).

### 3.3 Create path — `qr.py`
The `list_links` create at `qr.py:2035-2072` (insert `qr_link_pages`, then a **single bulk**
`qr_link_items` insert at `:2072`) is the right precedent and we follow it, one level deeper:

1. `db.table("qr_menus").insert({...})` — header.
2. `db.table("qr_menu_categories").insert([...])` — **one** bulk insert, all categories, `position`
   from array index (ignore any client-sent `position`, so the array order is authoritative).
3. `db.table("qr_menu_items").insert([...])` — **one** bulk insert of every item across every
   category, each row carrying its `category_id` and the denormalised `qr_id`.

Category ids are **client-generated UUIDs** (§3.4), so step 3 does not need step 2's returned ids and
the two inserts are independent. Total: **3** PostgREST round-trips regardless of menu size.

All three writes precede the `write_to_kv()` call so KV carries fresh content, matching every other
type.

### 3.4 Update path — the one place NOT to copy the existing pattern
**Do not reuse the `qr_link_items` loop at `qr.py:3179-3197.`** That code issues **one `UPDATE` or
`INSERT` per item, sequentially** — `for i, item in enumerate(link_items_update): db.table(...).update(...)`.
At ~40-60 ms per PostgREST round-trip that is fine for a 10-link page and **~15-18 s for a 300-item
menu**, which exceeds the frontend Axios client's 10 s timeout (`qr_frontend/src/lib/api-client.ts`)
— the user would see a timeout on a save that is still running, and retry into a duplicate write.

Instead, per table:

```python
# 1. UPSERT first (never delete first — there is no transaction; supabase-py is a
#    REST client, so a failure between statements is observable. Upsert-then-prune
#    can only ever leave EXTRA rows, which the next save cleans up. Delete-then-
#    insert can leave the merchant's menu EMPTY on a mid-save failure.)
db.table("qr_menu_categories").upsert(category_rows, on_conflict="id").execute()
db.table("qr_menu_items").upsert(item_rows, on_conflict="id").execute()

# 2. PRUNE anything the payload no longer contains, scoped by qr_id.
#    Items first, then categories — categories cascade to items anyway, but pruning
#    items first keeps the delete sets disjoint and the intent explicit.
db.table("qr_menu_items").delete().eq("qr_id", qr_id).not_.in_("id", incoming_item_ids).execute()
db.table("qr_menu_categories").delete().eq("qr_id", qr_id).not_.in_("id", incoming_category_ids).execute()
```

**Total: 5 round-trips for any menu size**, versus 300+.

> **Stable row ids are now a cross-spec invariant, not just a batching optimisation.**
> `MULTILINGUAL_LANDING_PAGES_TRD.md` §4.4 keys its per-locale menu overrides by row id, and its §12
> Q2 states the constraint plainly: **positional indices are never acceptable override keys**, because
> reordering a menu would silently reassign every translation to the wrong dish. So the UUIDs below
> have two consumers — batched writes and future localization. Anyone tempted to "simplify" back to
> DB-generated ids or array positions breaks menu localization silently, in a way no menu-only test
> would catch.

**Client-generated UUIDs are what makes the single `upsert` possible.** The existing builder assigns
client temp ids like `"new-1783101300882"` and `_is_valid_uuid` (`qr.py:1025-1037`) exists purely to
tell those apart from real row ids before they reach a `uuid` column (a temp id would raise 22P02).
The menu editor instead mints real UUIDs with `crypto.randomUUID()` at row-creation time, so insert
and update unify into one `upsert(on_conflict="id")`, and item ids are **stable across saves** — which
is a prerequisite for the deferred per-item analytics (PRD §7). This is a deliberate, documented
divergence from the `"new-…"` convention; server-side, still validate every incoming id with
`_is_valid_uuid` and reject the payload (422) rather than silently inserting, so a client that regresses
to temp ids fails loudly instead of duplicating the menu on every save.

**Empty-list semantics:** an incoming empty `incoming_*_ids` list must delete *all* rows for the QR —
mirror the explicit branch at `qr.py:3174-3176`, since `not_.in_("id", [])` is not a safe way to express
"delete everything".

### 3.5 Read path — `SELECT_WITH_RELATIONS` (`qr.py:998`)
Append `, qr_menus(*), qr_menu_categories(*, qr_menu_items(*))`. This is safe for the QR **list**
endpoint because the list uses the lightweight `SELECT_LIST_LIGHT` projection (`qr.py:1005`, and the
comment at `:1000-1004` explicitly says the heavy relation string is "only needed for single-QR
responses"). `SELECT_WITH_RELATIONS` is used at `qr.py:2741`, `:2801`, and `:3285` — all single-QR
reads, which genuinely need the full tree for the edit view.

**Verify the embed at build time.** `qr_menu_items` has two FKs (`category_id` → `qr_menu_categories`,
`qr_id` → `qr_codes`), so PostgREST has two paths to it. Nested under `qr_menu_categories(...)` there
is exactly one relationship and it should resolve unambiguously, but PostgREST's ambiguity detection is
a classic footgun — if it errors, disambiguate explicitly:
`qr_menu_categories(*, qr_menu_items!qr_menu_items_category_id_fkey(*))`.

`_build_content_from_db_rows` (`qr.py:1401-1432` handles `qr_link_pages` — `row.pop(...)`, normalise
dict→`[dict]`, read the nested `qr_link_items`) gains the analogous `menu` branch, returning
`{currency, menu_note, show_diet_marks, categories:[{..., items:[...]}]}` **sorted by `position`**
(PostgREST does not guarantee embedded row order; sort in Python — §3.6).

### 3.6 KV content — `qr_backend/src/utilities/cloudflare_kv.py`
New branch in `build_kv_content` (`cloudflare_kv.py:387-478`), inserted before the terminal `else`
(`:474`), modelled on the `list_links` nested embed at `:407-416`:

```python
elif qr_type == "menu":
    hdr = (supabase.table("qr_menus")
           .select("currency, menu_note, show_diet_marks")
           .eq("qr_id", qr_id).maybe_single().execute())
    cats = (supabase.table("qr_menu_categories")
            .select("id, name, description, position, "
                    "qr_menu_items(id, name, description, price_minor, price_note, "
                    "image_url, diet, is_available, position)")
            .eq("qr_id", qr_id).execute())
    out = dict(hdr.data) if hdr and hdr.data else {"currency": "INR", "show_diet_marks": True}
    # Explicit column lists (not `*`): keeps created_at/updated_at/qr_id/category_id
    # OUT of the KV blob. On a 300-item menu those four fields alone are ~25 KB of
    # payload the edge never reads.
    #
    # Sort in PYTHON, not via PostgREST: embedded-resource ordering is not guaranteed,
    # and the Worker must not re-sort on the hot path.
    categories = sorted(cats.data or [], key=lambda c: (c.get("position") or 0, c.get("name") or ""))
    for c in categories:
        c["items"] = sorted(c.pop("qr_menu_items", None) or [],
                            key=lambda i: (i.get("position") or 0, i.get("name") or ""))
    out["categories"] = categories
    return out
```

Two queries, size-bounded by §2's caps, and the resulting tree is **already in render order** so the
Worker does zero sorting.

**No `write_to_kv` signature change.** The menu tree rides the existing `content` parameter
(`cloudflare_kv.py:60`, payload key at `:102`). `sync_qr_to_kv` (`:307`) picks it up for free, so
every KV rewrite path (create-refresh, scan-limit disable/re-enable, billing lock) carries the menu.
`write_to_kv` raises `RuntimeError` on a non-2xx from Cloudflare (`:129-132`) — so a failed KV write
surfaces as a failed save rather than a silently stale menu, which is the behaviour we want here.

### 3.7 Item images — durable public URLs, **not** edge-signed
`images`/`pdf`/`mp3`/`video` store storage **paths** in KV and have the Worker mint 1-hour signed URLs
at scan time (`qrRouter.js:100-120` → `utils/supabase.js:3-38`). **We do not do that for menu photos**,
for three reasons: it adds a Supabase round-trip to a hot path we've promised makes zero backend calls;
a URL that rotates hourly defeats browser and CDN caching for the most repeat-scanned page we ship; and
a Supabase blip would blank every photo on every menu simultaneously.

Instead the backend converts `image_path` → a **durable public URL** at write time using the helper
that already exists for exactly this purpose — `_public_url_from_path(path, db)` (`qr.py:1008-1022`),
whose docstring states *"The storage bucket is public (same bucket used by workspace branding logos and
user avatars), so `get_public_url` yields a permanent URL — unlike the 1-hour signed URLs returned by
the upload endpoint. Used to persist a scan-time-safe `avatar_url` for social media QRs."* Menu photos
are the same case: content printed on a table tent for any passer-by to scan is not secret.

`qr_menu_items.image_url` therefore stores the resolved public URL; the client uploads via the existing
`POST /storage/upload` (`storage.py:159`, wrapped by `useUploadFile` in
`qr_frontend/src/hooks/useStorage.ts:86`) and sends back the returned `image_path`.

**Path-ownership validation is mandatory** (§8): the client supplies an arbitrary string. Storage paths
are `{bucket}/{user_id}/{uuid}_{filename}` (`storage.py:9`), so reject any `image_path` that does not
start with the authenticated caller's `{user_id}/` prefix with a 422, before it is ever resolved to a
public URL. Without this, a caller could mint a public URL for another user's object.

**Build-time verification:** `upload_avatar` calls `get_public_url` on `SUPABASE_STORAGE_BUCKET`
(`storage.py:148`) while the `images` type signs against the same bucket. Confirm on the actual
Supabase project that the bucket's public flag is set (a public URL on a private bucket returns a
403/404 body, not an error at generation time — `get_public_url` is a pure string builder and will
"succeed" either way). This is the single riskiest silent-failure mode in the whole feature: broken
photos on every menu with no server-side error. Assert it in the Phase-0 canary (§11).

### 3.8 Gating
**No code change.** The `dynamic_qr_types` gate already runs on create and, with the `0041` seed,
admits `menu` on every plan. No `check_feature` call, no `FEATURE_ENFORCEMENT` entry, no
`_QUOTA_SPEC`. Routes keep the existing `require_can_create` / `require_can_update` dependencies.

### 3.9 Internal endpoints / cron
**None.** Deliberately **no `/internal/menu/{qr_id}` GET fallback**: a fallback fetch of a 300-item
menu on the scan path is precisely the latency we are engineering away, and it would make the
"zero backend calls" invariant untestable. KV is the source of truth, exactly as for `lead_form`
(`qrRouter.js:270`, "no `/internal/lead-form` GET endpoint; content must be in KV") and `review_funnel`
(`:283`, "KV is source of truth; no /internal GET fallback"). A menu whose KV entry is missing renders
the standard error page; re-saving the QR (or any `sync_qr_to_kv` trigger) repairs it. No cron, no
`scheduled()` change.

---

## 4. Cloudflare Worker / Edge Design

### 4.1 Dispatch — `qr_cf_code/src/handlers/qrRouter.js`
Add the import beside the others (`:1-18`) and a branch before the terminal `return getErrorPage()`
(`:289`), following the `review_funnel` shape at `:281-287`:

```js
// ── Menu ──────────────────────────────────────────────────────────────────
// KV is the source of truth (no /internal fallback, by design — a 300-item
// backend fetch on the scan path is exactly the latency this type avoids).
if (type === "menu") {
  const menu = kvContent && Array.isArray(kvContent.categories) ? kvContent : null;
  if (!menu) return getErrorPage();
  return getMenuPage(menu, pageDesign);
}
```

`pageDesign` already carries `whiteLabel` and `brand`, injected from `parsedData.entitlements` at
`qrRouter.js:43-50` — no extra plumbing. `recordScan` is unchanged: one scan event per menu view, no
new fields, no `scan.js` whitelist change (contrast `review_funnel`, which needed a 3-point change to
thread `stars`).

### 4.2 Dispatcher — `qr_cf_code/src/pages/menu/index.js`
Byte-for-byte the `src/pages/vcard/index.js` shape (a `HANDLERS` map, a `DEFAULT_TEMPLATE`, an unknown
`templateId` falling back to the default, `withMobileViewport`, a `text/html; charset=utf-8` 200):

```js
import { generateMenuClassicHTML }   from "./classicTemplate.js";
import { generateMenuPhotoHTML }     from "./photoTemplate.js";
import { generateMenuAccordionHTML } from "./accordionTemplate.js";
import { withMobileViewport, withDocumentLang } from "../../utils/html.js";

const HANDLERS = {
  menu_classic:   generateMenuClassicHTML,
  menu_photo:     generateMenuPhotoHTML,
  menu_accordion: generateMenuAccordionHTML,
};
const DEFAULT_TEMPLATE = "menu_classic";

// i18nCtx is a TRAILING OPTIONAL param (§4.6). Undefined on the monolingual fast
// path, in which case every template falls back to its English dictionary and the
// output is byte-for-byte what it would have been without i18n.
export function getMenuPage(menu, pageDesign, i18nCtx) {
  const tid        = pageDesign?.templateId || DEFAULT_TEMPLATE;
  const accent     = pageDesign?.themeColor || "#4648d4";
  const whiteLabel = !!pageDesign?.whiteLabel;
  const brand      = pageDesign?.brand || null;
  const handler    = HANDLERS[tid] ?? HANDLERS[DEFAULT_TEMPLATE];
  const html = withDocumentLang(
    withMobileViewport(handler(menu, accent, whiteLabel, brand, pageDesign, i18nCtx)),
    i18nCtx?.locale || "en",
  );
  return new Response(html, { headers: { "Content-Type": "text/html; charset=utf-8" }, status: 200 });
}
```

`menu_classic` must be the default **and the first entry** in the frontend's `MENU_TEMPLATES` array,
because `getDefaultTemplateId` returns `getTemplatesForType(qrType)[0]?.id`
(`page-templates.tsx:552-554`) — the two defaults must agree or a QR saved without an explicit
`templateId` renders differently in the preview and at the edge.

### 4.3 Shared helpers — `qr_cf_code/src/pages/menu/helpers.js`
Following the per-type `helpers.js` convention (`pages/vcard/helpers.js`, `pages/pdf/helpers.js`):

- `formatPrice(priceMinor, currency)` — integer minor units → `"₹250"` / `"₹249.50"`. A small
  symbol/decimals table (`INR/USD/EUR/GBP/AED/SGD` → symbol + 2 decimals; trailing `.00` dropped).
  **No `Intl.NumberFormat`** — locale data availability is a Workers-runtime variable we don't need to
  bet a price display on, and the output must match the React preview character-for-character (§10).
- `dietGlyph(diet)` — the inline SVG/box glyph for `veg`/`nonveg`/`egg`/`vegan` (green square with a
  green dot, brown/red square with a dot). Static markup, no external assets.
- `renderItemImage(url, alt)` — `<img src loading="lazy" decoding="async" width height alt>` inside a
  fixed-aspect wrapper so lazy images cause **no layout shift**.

### 4.4 Templates — zero client-side JavaScript, all three
- **`classicTemplate.js`** (default) — category headings, dotted price leaders, no images unless
  present. This is the fast path and the right default for a typical Indian 60-dish menu with no
  photography.
- **`photoTemplate.js`** — two-column dish cards with images; text-only items degrade to a card
  without a photo.
- **`accordionTemplate.js`** — collapsible categories via **native `<details>`/`<summary>`** and a
  sticky category jump-nav built from plain `#anchor` links.

**No template ships client JS.** `<details>` gives collapse/expand natively and anchors give jump-nav
natively, so the pages work with JS disabled, add no parse/execute cost on a low-end Android phone, and
introduce no inline-script surface. This is a deliberate divergence from `review_funnel`'s templates
(which need JS for the star interaction) and it is worth protecting in review.

Every merchant-authored string — category names/descriptions, item names/descriptions, `price_note`,
`menu_note` — goes through `escapeHTML()` (`utils/html.js:1`). Theme colour and page chrome come from
`buildDesignCSS(pageDesign)` (`utils/design.js:7`); the footer from
`renderFooter({ whiteLabel, brand })` (`utils/design.js:125`) / `renderBrandFooter(brand)` (`:102`),
so white-label entitlements behave exactly as on every other landing page with no menu-specific work.

**Sold-out items render, they don't disappear**: `is_available === false` → the row is dimmed with a
"Sold out" chip. A paper menu doesn't delete a dish when the kitchen runs out, and neither do we.

### 4.5 i18n-native from the first commit (cross-spec requirement)
`menu` is the **highest-value multilingual surface in the product** — a vernacular menu is the single
most useful thing an Indian restaurant can hand a diner — and the gap analysis sequences item #4 with
item #3 as the restaurant bundle. `MULTILINGUAL_LANDING_PAGES_TRD.md` scopes its v1 to `vcard` +
`business` **only because `menu` doesn't exist yet**, and makes it a hard requirement that the menu
templates are built i18n-ready. Retrofitting three Worker templates plus their three React mirrors
later is a full pass over six files; doing it now costs a `const t = …` line each.

**This is a shape requirement, not a feature.** v1 ships **English only** — no locale columns, no
`qr_translations` rows, no language switcher, no translation UI, and no dependency on `0042` landing.
The menu simply must not *hardcode* its chrome.

Three obligations, matching the multilingual TRD's contract exactly (§4.1–§4.3 there):

1. **Trailing optional `i18n` parameter.** `handleQRCode(parsedData, request, env, i18nCtx)` →
   `getMenuPage(menu, pageDesign, i18nCtx)` → `handler(menu, accent, whiteLabel, brand, pageDesign, i18nCtx)`.
   Appending is safe and incremental: JavaScript ignores extra arguments, so this is inert until the
   multilingual feature starts passing a context.
2. **No hardcoded chrome string.** Each template opens with
   `const t = i18n?.t || ((k) => EN[k]);` and routes every non-merchant string through `t('key')`.
   The `makeT(locale)` factory and the per-locale dictionaries live in `qr_cf_code/src/i18n/`
   (created by `0042`'s spec); until then the menu keys live in a local `EN` map in
   `src/pages/menu/helpers.js` and **move to `src/i18n/en.js` when that directory lands** — a
   mechanical move, not a rewrite. The multilingual spec **reserves these nine keys in `en.js` from
   the start** (`MULTILINGUAL_LANDING_PAGES_TRD.md` §4.1) precisely so that move has a target, and
   folds them into its Phase-3 native-speaker review — so do not rename them unilaterally.
3. **`withDocumentLang(html, locale)`** wraps `withMobileViewport(...)` in the dispatcher (§4.2). It is a
   no-op for `en`, so this is free today.

**Menu chrome keys** (~9, extending the multilingual spec's ~25-key set — none of these exist in its
current audit because they audited only `vcard`/`business`):
`sold_out` · `menu` · `categories` · `last_updated` · `diet_veg` · `diet_nonveg` · `diet_egg` ·
`diet_vegan` · `prices_incl_taxes`. Everything else on a menu page is **merchant-authored content**
(dish names, descriptions, category names, the menu note), which is per-locale override data, not
chrome.

**The data model already satisfies their allowlist constraint.** The multilingual spec stores only
translatable fields per locale — never prices, URLs, phone numbers, or image paths — to bound the KV
payload. §2's schema separates these cleanly: **translatable** = `qr_menus.menu_note`,
`qr_menu_categories.name`/`description`, `qr_menu_items.name`/`description`/`price_note`;
**never translated** = `price_minor`, `currency`, `image_url`, `diet`, `is_available`, `position`, `id`.
Prices and photos are stored exactly once regardless of locale count, which is the property that keeps
a 5-language 300-item menu from being 5× the KV payload. **Do not** later "simplify" by inlining a
formatted price string into a translatable field — it would silently break that bound.

**One interop gap to resolve before menu localization ships** (flagged to the multilingual author, and
tracked as §12 Q11): their edge merge is a **shallow per-field spread** —
`content = { ...content, ...(i18n.content[locale] || {}) }` — which works for `vcard`/`business`
because those contents are flat objects. A menu's translatable fields are nested two levels inside an
array, so a shallow merge cannot express "translate item 47's description". The override must be
**keyed by row id** (e.g. `{ "categories": {"<uuid>": {"name": …}}, "items": {"<uuid>": {"name": …, "description": …}} }`)
and merged by id during the tree walk. This is workable **because §3.4 already mandates stable
client-generated UUIDs** that survive every save — a convergence worth noting, since the alternative
(whole-array replacement per locale) would duplicate every price and image URL per language, the exact
payload blow-up their allowlist exists to prevent.

### 4.6 What the Worker does *not* gain
No new route in `src/index.js` (contrast `review_funnel`'s `/review-go/`), no `recordScan`/`scan.js`
change, no `ScanEventPayload` change, no consent-gate change (a menu sets no marketing tags of its
own; workspace pixels behave exactly as on any other landing page), no `scheduled()` change, and **no
`wrangler.toml` change** — no new cron, route, KV namespace, var, or secret.

**Deploy gate:** the Worker changes, so **`npm run deploy:prod` is required** (staging via
`npm run deploy:dev` first).

---

## 5. Frontend Design

All new files are **kebab-case, one export, ≤200 lines**, shadcn primitives only, no inline styles, no
`any`, react-hook-form + zod, TanStack Query for any server state. (Note `ListLinksContent.tsx` is 551
lines — it predates the rule and is not a licence to repeat it; the menu editor is split from the start.)

### 5.1 `qr_frontend/src/lib/menu.ts` — the pure logic, unit-tested
- `toMinor(input: string, currency: string): number | null` / `fromMinor(minor, currency): string` —
  the **only** rounding site in the system.
- `formatPrice(priceMinor, currency)` — **must produce byte-identical output to the Worker's
  `helpers.js` `formatPrice`** (§10 parity test). Same symbol/decimals table, same trailing-zero rule.
- `parsePastedMenu(text): MenuDraft` — the paste-import parser: `## Category` starts a category,
  `Name | 250 | description` is an item (price and description optional, `|` or tab separated), blank
  lines ignored, everything clamped to the §2 caps. Pure, deterministic, no network, no AI.
- `menuSchema` — the zod schema mirroring §3.2's caps exactly.

### 5.2 Editor — `content-types/menu/`
| File | Role |
|---|---|
| `menu-content.tsx` | Builder-step orchestrator: header fields (name, currency, note), the category field array, the single `DndContext`, paste-import entry, item counter (`62 / 300`). Wired into the step chrome the same way `ListLinksContent` is (`useStandaloneFormSync`, `NavButton`, `currentStep`/`steps`/`handleBack`/`handleNext`/`handleComplete`). |
| `menu-category-row.tsx` | One sortable category: `useSortable`, drag handle, name/description, collapse, delete-with-confirm, and its own nested `useFieldArray` + `SortableContext` for items. |
| `menu-item-row.tsx` | One sortable item: name, price, description, diet select, availability `Switch`, image field, "Move to…" `DropdownMenu`. |
| `menu-item-image-field.tsx` | Upload control over `useUploadFile` (`hooks/useStorage.ts:86` → `POST /storage/upload`), client-side type/size guard, thumbnail + remove. |
| `menu-paste-import.tsx` | `Textarea` + preview of parsed rows + "Add these items" — calls `parsePastedMenu`, never saves directly (review-before-commit). |

**Nested dnd-kit.** The existing pattern in `ListLinksContent.tsx` is a single flat list —
imports at `:31-44`, `SortableLinkItem` with `useSortable({id})` at `:70-84`, sensors
(`PointerSensor` + `KeyboardSensor` with `sortableKeyboardCoordinates`) at `:233-238`, `handleDragEnd`
using `useFieldArray`'s `move(oldIndex, newIndex)` at `:240-248`, and
`<DndContext sensors collisionDetection={closestCenter} onDragEnd>` wrapping
`<SortableContext items={fields.map(f => f.id)} strategy={verticalListSortingStrategy}>` at `:488-509`.

The menu editor uses **one `DndContext`** in `menu-content.tsx` with **two levels of `SortableContext`**
— one for categories, one per category for its items — and discriminates in `onDragEnd` via
`active.data.current?.type === 'category' | 'item'`, routing to the outer `move()` or that category's
nested `move()`. Note `useFieldArray`'s `keyName: 'rhfId'` (`ListLinksContent.tsx:229`): RHF's
auto-injected `id` would otherwise clash with our own row `id`, which is now a real UUID we depend on.

**Cross-category moves are a "Move to…" dropdown, not a drag** (PRD Open Q2). Multi-container dnd-kit
dragging needs `onDragOver` container transfer and `closestCorners`, and it is fragile on touch — which
is where this editor is actually used. Within-list drag at both levels + an explicit move action is
more reliable and materially cheaper. The move is a `remove()` from the source item array plus an
`append()` to the target's.

### 5.3 React preview templates — `templates/menu/`
Three components mirroring the three Worker templates 1:1 — `MenuClassicTemplate.tsx`,
`MenuPhotoTemplate.tsx`, `MenuAccordionTemplate.tsx`, plus a `shared.tsx` for the price formatter and
diet glyph (the `templates/business/shared.tsx`, `templates/event/shared.tsx` convention). House rule:
**every Worker template ⇄ exactly one React preview, shipped in the same PR.**

**The previews are i18n-shaped too** (§4.5). Each takes an optional trailing `i18n` prop and opens with
the same `const t = i18n?.t ?? ((k) => EN[k])` fallback, reading the identical key set from a shared
`EN` map in `templates/menu/shared.tsx`. The whole point of §4.5 is that the Worker template and its
React mirror never diverge on chrome — localizing one and not the other would reintroduce exactly the
drift the mirroring rule exists to prevent, and the parity fixture (§10) asserts both render the same
strings for the same keys.

### 5.4 Registry touchpoints
| File | Change |
|---|---|
| `lib/constants/qr-types.ts` | Four edits: `HAS_LANDING_PAGE_TYPES` (`~:70-90`), `ALL_TYPES` (`:91-121` — `{ id:'menu', name:'Menu', description:'A live restaurant menu customers read on their phone', icon: FiBookOpen, category:'dynamic' }`), `QR_TYPES` (`~:180-210`, `MENU: 'menu'`), `TYPE_ICONS` (`~:215-243`, `menu: 'restaurant_menu'`). |
| `lib/constants/page-templates.tsx` | `menuContent?: MenuContent` on `TemplateContentBag` (`:~40-72`); `MENU_TEMPLATES: PageTemplate[]` with `menu_classic` **first** (so `getDefaultTemplateId` at `:552-554` agrees with the Worker's `DEFAULT_TEMPLATE`); spread into `ALL_PAGE_TEMPLATES` (`:524-540`). `getTemplatesForType` (`:542-545`) then works with no change. |
| `qr-generator/TemplatePicker.tsx` | Add `menuContent` to the props (`:35-79`) and to the `bag` (`:111-128`). No switch case — the picker is registry-driven (`:94`, `:176`). |
| `qr-generator/PagePreview/PagePreview.tsx` | Add `menuContent: content?.menuContent` to the `bag` (`:192-210`). Resolution at `:215` is generic. |
| `qr-generator/QRContent.tsx` | New `case 'menu':` in the type→content-component switch, beside `case 'list_links':` (`:417`) and `case 'review_funnel':` (`:521`). |

No new hook and no new query key: the menu rides the **existing** QR create/update mutations in
`src/hooks/` (the `useQRs` family); only their payload types widen. `workspaceId` comes from
`useWorkspaceStore`, per house rule.

---

## 6. External-Service Integration

**None new.** No AI / Anthropic call, no Resend email, no payment provider, no third-party API, no new
environment variable, no new secret. The only external dependency is **Supabase Storage**, already
provisioned and already used by `images`/`social_media`/branding — menu photos go through the same
`POST /storage/upload` route and the same bucket.

Two consequences worth stating explicitly because they clear the usual gates:
- **`_dmarc.qravio.app` is NOT a gate** — this feature sends no email.
- **No cron** → no `wrangler.toml` trigger change; the prod-worker deploy is required for the *edge
  templates*, not for a scheduler.

The one **provisioning check** (§3.7): confirm `SUPABASE_STORAGE_BUCKET` is genuinely marked public on
each environment's Supabase project. `get_public_url` is a client-side string builder — it "succeeds"
against a private bucket and yields URLs that 400 at fetch time. Verify with a real HTTP GET in the
Phase-0 canary, not by reading code.

---

## 7. API Contracts

No new route. The menu rides the existing QR create/update endpoints (Bearer, `require_can_create` /
`require_can_update`, `dynamic_qr_types` gate).

**POST** `/api/v1/workspaces/{workspace_id}/qrs` · **PATCH** `/api/v1/workspaces/{workspace_id}/qrs/{qr_id}`

```jsonc
{
  "type": "menu",
  "category": "dynamic",
  "name": "Cafe Aroma — table tent",
  "content": {
    "menu": {
      "currency": "INR",
      "menu_note": "All prices in ₹. Taxes extra.",
      "show_diet_marks": true,
      "categories": [
        {
          "id": "0f6b2b3a-...",              // client-generated UUID (crypto.randomUUID)
          "name": "Starters",
          "description": "Served 12pm–4pm",
          "position": 0,
          "items": [
            {
              "id": "a2c9d1e4-...",
              "name": "Paneer Tikka",
              "description": "Charred cottage cheese, mint chutney",
              "price_minor": 28000,           // ₹280.00 — INTEGER minor units, never a float
              "price_note": "half / full",
              "image_path": "9f3c…/2b7e…_paneer.jpg",   // storage path; server resolves to a public URL
              "diet": "veg",
              "is_available": true,
              "position": 0
            }
          ]
        }
      ]
    }
  },
  "page_design": { "templateId": "menu_classic", "themeColor": "#4648d4", "pageTitle": "Cafe Aroma" }
}
```

Errors:
```jsonc
// 403 — plan's dynamic_qr_types lacks "menu" (should not occur post-0041; custom plans can)
{ "detail": "This QR type is not available on your plan." }
// 422 — caps
{ "detail": "A menu can have at most 30 categories." }
{ "detail": "A menu can have at most 300 items." }
{ "detail": "Item description must be 300 characters or fewer." }
// 422 — image path not owned by the caller (§8)
{ "detail": "image_path is not a file you own." }
// 422 — non-UUID row id (client regressed to a \"new-…\" temp id)
{ "detail": "Menu row ids must be UUIDs." }
```

The QR **read** response returns the same nested shape (assembled by `_build_content_from_db_rows`),
with `image_url` (resolved public URL) in place of `image_path`.

**KV value** — the `content` key for a menu QR:
```jsonc
{
  "qr_id": "…", "type": "menu", "status": "active", "workspace_id": "…",
  "page_design": { "templateId": "menu_classic", "themeColor": "#4648d4", "whiteLabel": false },
  "content": {
    "currency": "INR",
    "menu_note": "All prices in ₹. Taxes extra.",
    "show_diet_marks": true,
    "categories": [                                  // pre-sorted by position (§3.6)
      { "id": "…", "name": "Starters", "description": "…", "position": 0,
        "items": [ { "id": "…", "name": "Paneer Tikka", "description": "…",
                     "price_minor": 28000, "price_note": "half / full",
                     "image_url": "https://<project>.supabase.co/storage/v1/object/public/<bucket>/…",
                     "diet": "veg", "is_available": true, "position": 0 } ] }
    ]
  }
}
```

---

## 8. Security, Privacy & Abuse

- **XSS is the primary risk and it is entirely merchant-authored text rendered at the edge.** A menu
  has more free-text fields than any other type (category name + description, item name + description +
  price note, menu note — up to ~1 200 strings on a max-size menu). **Every** one goes through
  `escapeHTML()` (`utils/html.js:1`). The zero-client-JS decision (§4.4) removes the inline-script sink
  entirely, so there is no `<script>` context for a merchant string to land in.
- **Storage-path injection (the real new attack surface).** The client sends `image_path` as a free
  string, and the backend turns it into a public URL. Without validation, an authenticated user could
  submit another user's path and publish a durable public URL to their file. **Mitigation:** paths are
  `{bucket}/{user_id}/{uuid}_{filename}` (`storage.py:9`), so reject with 422 any `image_path` that
  does not start with the authenticated caller's `{user_id}/` prefix, and reject `..`, absolute paths,
  and URL schemes outright. Validate **before** `_public_url_from_path` is called.
- **Public-URL trade-off, taken deliberately.** Menu photos are served from a public bucket with
  guessable-only-if-you-know-the-UUID paths. They are, by definition, printed on a table tent for any
  stranger to scan — there is nothing to protect. This is the same posture already taken for user
  avatars and workspace branding logos (`qr.py:1011-1014`). Private-by-default types (`pdf`, `images`)
  keep their edge-signed URLs; no existing behaviour changes.
- **Tenant isolation unchanged.** Create/update go through `get_workspace_role` + `require_can_*`; every
  menu write carries an explicit `qr_id` (and `workspace_id` on the parent QR) because the service-role
  client bypasses RLS. The prune-deletes are scoped `.eq("qr_id", …)` — never a bare `not_.in_`.
- **No PII.** A menu contains dish names and prices. No scanner data is captured beyond the existing
  scan event, no form, no submission table, no consent surface change.
- **Denial-of-payload.** The caps (§2) are enforced **server-side**, so a hand-rolled API client cannot
  push a 50 MB menu into KV and blow the Worker's memory/CPU on every subsequent scan. This is the main
  reason the caps are not merely a client-side nicety.
- **No new unauthenticated surface.** No new `/internal/*` endpoint, no new Worker route, no new
  excluded route in `auth_bearer.py`. Scan traffic reads KV exactly as it does today.
- **Nothing transactional exists to abuse.** No cart, no price submitted by the scanner, no order, no
  payment — the entire class of "customer manipulates the price / places a fake order" vulnerabilities
  that an ordering feature would introduce is structurally absent. This is a security argument for the
  PRD's hard line, not just a product one.

---

## 9. Performance, Scale & Cost

**KV payload.** Worst case (300 items, all fields near cap, all with photos):
~300 × (120 name + 300 desc + ~130 URL + ~60 other) ≈ **~190 KB** of JSON, plus ~30 categories × ~300 B.
Cloudflare KV's per-value limit is 25 MiB, so we are ~2 orders of magnitude inside it. The realistic
median menu (60 items, short descriptions, 10 photos) is **~20-25 KB**. Selecting explicit columns
rather than `*` in `build_kv_content` (§3.6) keeps `created_at`/`updated_at`/`qr_id`/`category_id` out
of the blob — worth ~25 KB on a max menu.

**Edge CPU.** One `JSON.parse` of ≤190 KB plus one template-literal build over ≤300 items — low
single-digit milliseconds, comfortably inside the Workers CPU budget, with **zero** additional network
calls (no signed-URL round-trip, no `/internal` fetch). The menu render is CPU-only.

**HTML weight.** Budget **< 150 KB** for a 300-item `classic` page (photos excluded — lazy). Photos are
`loading="lazy"` inside reserved aspect boxes, so above-the-fold weight is roughly the first screen's
worth regardless of menu length, and there is no layout shift.

**Backend writes.** The whole reason for §3.4: **3 round-trips on create, 5 on update, for any menu
size**, versus 300+ with the `qr_link_items` per-row loop — the difference between a ~250 ms save and a
timeout past the frontend's 10 s Axios ceiling.

**Backend reads.** `build_kv_content` is 2 queries; the single-QR edit read is one `SELECT_WITH_RELATIONS`
with a nested embed. Both are covered by `idx_qr_menu_categories_qr` / `idx_qr_menu_items_category`.
The paginated QR list is untouched (`SELECT_LIST_LIGHT`, `qr.py:1005`).

**Storage.** Item photos are the only new byte cost, server-downscaled on upload and counted against
the workspace's existing storage quota. No new quota key, no new limit to enforce.

**Cost.** No per-use COGS: no AI call, no email, no third-party API, no cron. The only marginal costs
are KV reads (already paid per scan) and Supabase Storage bytes (already metered).

---

## 10. Testing Strategy

**Backend (pytest, `qr_backend/tests/`)**
- `test_menu_caps`: 31 categories → 422; 301 items across categories → 422; 101 items in one category →
  422; over-length name/description/price_note → 422; `price_minor` negative or > cap → 422.
- `test_menu_create_batched`: a 300-item create issues exactly **3** table writes (assert call counts on
  a mocked client) — this is the regression guard against someone "helpfully" refactoring back to the
  per-row loop.
- `test_menu_update_upsert_then_prune`: upserts precede deletes; removing a category prunes its items;
  **moving an item between categories in one save** keeps exactly one row (the `qr_id`-scoped prune);
  an empty payload deletes all rows for the QR and no others.
- `test_menu_image_path_ownership`: an `image_path` under another user's prefix → 422; `..`/absolute/
  `http://` → 422; a valid own-prefix path resolves via `_public_url_from_path`.
- `test_menu_kv_shape`: `build_kv_content("menu")` returns `{currency, menu_note, show_diet_marks,
  categories:[{…, items:[…]}]}`, **sorted by `position`** with a deterministic tiebreak, containing
  `image_url` (never `image_path`), and **not** containing `created_at`/`updated_at`/`qr_id`/`category_id`.
- `test_menu_kv_size_bound`: a max-size fixture serialises under the documented byte budget.
- `test_menu_ids_must_be_uuid`: a `"new-…"` temp id → 422 (loud), never a silent duplicate insert.
- `test_menu_gate`: a custom plan without `menu` in `dynamic_qr_types` → 403; a seeded plan → 201.
- **`test_feature_gate_coverage` stays green by construction** — no new boolean flag, so
  `FEATURE_ENFORCEMENT` is untouched.

**Frontend (Vitest)**
- `parsePastedMenu`: `## Category` headers, `|`- and tab-separated rows, missing price, missing
  description, blank lines, over-cap truncation, and a pasted block that is just prose (→ no items, no
  crash).
- **Price round-trip is a release gate**: `toMinor("249.50","INR") === 24950`, `fromMinor(24950,"INR") === "₹249.50"`,
  `fromMinor(28000,"INR") === "₹280"` (trailing `.00` dropped), and no float artefacts across a table of
  ~50 values.
- Nested dnd reorder: dragging a category reorders categories only; dragging an item reorders within its
  category only; "Move to…" relocates an item and preserves its `id`.
- zod caps match the server's exactly (a shared constants table, asserted in both suites).

**Worker ⇄ React parity (the house pain point, R6)**
There is **no test framework in `qr_cf_code` today** (`package.json` has `wrangler` only). Two options,
in preference order: (a) add `vitest` + `@cloudflare/vitest-pool-workers` and unit-test the three
template functions directly — the right long-term fix and cheap now, since the templates are pure
`(menu, accent, whiteLabel, brand) → string` functions with no bindings; or (b) at minimum, drive the
existing `preview/templates-preview.mjs` harness from a checked-in fixture.

Either way, the parity gate is: **one shared fixture menu JSON**, rendered by both the Worker template
and its React preview, asserting the same visible text sequence (category order, item order, formatted
prices, sold-out labels, diet marks) and the same `formatPrice` output byte-for-byte. This is the test
that catches the drift the house rule keeps warning about.

**Worker behaviour tests**: unknown `templateId` → `menu_classic`; missing/empty `content.categories`
→ error page (no crash); an item with `is_available:false` renders a "Sold out" chip and is **not**
omitted; a category name containing `<script>` is escaped; **zero `fetch` calls** during a menu render
(the KV-only invariant, asserted by a fetch spy).

**Manual / canary**: a staging menu QR with 3 categories / 25 items / 5 photos — verify the photos load
over plain HTTP from the public URL (the §3.7 silent-failure mode), the `classic` page hits the LCP
budget on a throttled 4G profile, and a price edit is live at the edge within seconds.

---

## 11. Observability & Rollout

**Phase 0 — Backend + edge (internal/staging).** Apply `0041` (after re-checking the slot). Add the
type literal, nested models + caps, batched create/update, `SELECT_WITH_RELATIONS` join,
`_build_content_from_db_rows` branch, `build_kv_content` branch, `image_path` validation. Add the Worker
dispatch case + `src/pages/menu/{index,helpers,classicTemplate}.js`; `npm run deploy:dev`. Verify with a
hand-seeded menu: renders from KV, **zero backend fetches**, caps enforced, sold-out renders,
`formatPrice` correct, **and photos actually load from the public URL**.

**Phase 1 — Builder + all three templates (closed).** Nested editor, paste-import, image upload, the
`photo`/`accordion` templates and all three React previews, registry touchpoints. Behind a FE constant
flag (`NEXT_PUBLIC_MENU_BETA`) for internal + design partners — deliberately including **one 60+ item
text-only menu and one photo-led café menu**, the two failure shapes.
- **Acceptance:** a partner builds a real 40+ item menu unaided in one sitting; reorder, "Move to…",
  sold-out, and photo upload all work on a phone; a price edit is live at the edge within seconds;
  `classic` meets the LCP budget on 4G; each Worker template matches its React preview on the shared
  fixture; a 300-item save completes well inside the 10 s client timeout.

**Phase 2 — GA.** Remove the FE flag; **`npm run deploy:prod`**; add `menu` to the marketing type list
and ship the `/restaurant-menu-qr-code` SEO page; help-centre entries for paste-import and sold-out.

**Deploy order:** apply `0041` → deploy backend (KV now carries `menu` content) → **`npm run deploy:prod`**
the Worker → release the frontend. A Worker deployed before the backend simply has a dispatch case
nothing produces yet (safe); a frontend released before the Worker would let a user create a menu that
renders an error page at scan time (**not** safe) — so the Worker must lead the frontend. **No DMARC
gate** (no email). **No cron gate** (no `wrangler.toml` change).

**Metrics / logs.** Menu QRs created per week and share of all new dynamic QRs (top-5 target);
started-vs-published ratio and time-to-first-save (the entry-friction KPIs); paste-import usage rate;
30-day edit rate (the dynamic-value proof); p75 LCP and HTML transfer size sampled from the scan pages;
KV blob size distribution (alarm if any menu approaches the cap); backend save latency p95 for menu
updates (guards the batching); and **the bundle signal** — share of menu-creating workspaces that also
create a `review_funnel` QR within 60 days. Structured Worker log per menu render: `shortCode`,
`templateId`, category/item counts, render duration. No PII, no new dashboard infrastructure.

---

## 12. Open Technical Questions & Risks

1. **Public bucket vs edge-signed URLs — resolved: public.** `_public_url_from_path` (`qr.py:1008-1022`)
   already exists for exactly this case and documents the bucket as public. Signing 20 URLs per scan
   would add a Supabase round-trip to a hot path we've promised makes zero backend calls and would kill
   image caching. **Residual risk:** `get_public_url` is a pure string builder and cannot tell a private
   bucket from a public one — so the Phase-0 canary must fetch a photo over real HTTP, per env. This is
   the single most likely silent failure in the feature.
2. **PostgREST embed ambiguity on `qr_menu_items`.** It has two FKs (`category_id`, `qr_id`), so
   `qr_menu_categories(*, qr_menu_items(*))` *should* resolve unambiguously (one relationship at that
   level) but must be verified at build; if PostgREST complains, pin the FK:
   `qr_menu_items!qr_menu_items_category_id_fkey(*)`. Same check applies to the `build_kv_content` embed.
3. **Batched upsert vs the existing per-row loop — resolved: batched.** The `qr_link_items` loop
   (`qr.py:3179-3197`) is 1 round-trip per row; at 300 items that exceeds the frontend's 10 s Axios
   timeout. Client-generated UUIDs make a single `upsert(on_conflict="id")` possible. **Confirm
   `supabase-py`'s `.upsert()` accepts a list with `on_conflict` on the pinned version**, and confirm
   PostgREST's payload-size ceiling accommodates a 300-row body (chunk at ~200 rows if not).
4. **Upsert-then-prune ordering — resolved, and load-bearing.** There is no transaction (REST client), so
   ordering is the only safety mechanism: upsert-then-prune can leave extra rows (self-healing on the
   next save); delete-then-insert can leave a merchant's menu **empty** mid-failure. Never reorder these.
5. **Per-item variants (half/full) — deferred to v1.1** (PRD Open Q1). v1 ships one price plus a
   free-text `price_note`. Note the schema cost of adding them later is a new `qr_menu_item_variants`
   table plus a third nesting level in the editor, KV blob, and both template families — real, but
   additive, and no v1 data has to change.
6. **Cross-category drag — deferred; "Move to…" in v1** (PRD Open Q2). Multi-container dnd-kit is
   fragile on touch, and this editor lives on a phone.
7. **No Worker test framework exists.** `qr_cf_code/package.json` has only `wrangler`. Adding
   `vitest` + `@cloudflare/vitest-pool-workers` is cheap here because the menu templates are pure
   functions, and it's the only way to make the Worker⇄React parity gate real rather than aspirational.
   Decide at Phase 0 — this spec assumes it lands.
8. **Cap values are a judgement call.** 30/300 are set high enough that no honest restaurant menu hits
   them and low enough that the KV blob stays ~2 orders of magnitude inside Cloudflare's limit. If a real
   partner legitimately exceeds them (a large hotel with several outlets behind one code), the correct
   answer is **more QRs**, not a bigger cap — which is also better analytics and more scans.
9. **`updated_at` maintenance.** The tables carry `updated_at` defaults but no trigger; the batched
   upsert must set it explicitly, or the PRD's "menu last updated" trust stamp (Open Q5) reads stale.
   Decide whether to set it in the payload (simple, consistent with `qr_review_funnel`) or add a trigger.
11. **Nested per-locale override merge (cross-spec, blocks menu localization — not menu v1).**
    `MULTILINGUAL_LANDING_PAGES_TRD.md` merges locale overrides with a shallow spread,
    `content = { ...content, ...(i18n.content[locale] || {}) }`, which is sufficient for the flat
    `vcard`/`business` contents it scopes to but **cannot address a field two levels inside an array**.
    Menu overrides must be **keyed by row id** and merged during the tree walk. Viable precisely because
    §3.4 mandates stable client-generated UUIDs. Owned by the multilingual spec (its `build_i18n` and
    edge merge), not by menu v1 — raised with that author. The **menu-side** obligation is only §4.5's
    template shape, which ships in menu v1 and has no dependency on `0042`.
12. **Ordering-scope creep is a standing risk, not a one-time decision.** Treat any PR that adds a
    cart, order route, price-submitting form, table identifier, or POS webhook under `src/pages/menu/`
    or the menu backend path as a spec violation (PRD §3). Worth a line in the review checklist.

### Appendix — Key Files

| Concern | File |
|---|---|
| Migration (3 tables + `dynamic_qr_types` append) | `qr_backend/migrations/0041_restaurant_menu_qr.sql` (NEW — slot provisional, re-check before applying) |
| Type literal | `qr_backend/src/api/routes/qr.py` (`QRCodeCreate.type` `Literal` `:839-864`) |
| Nested content models + caps | `qr_backend/src/api/routes/qr.py` (`MenuContent`/`MenuCategoryIn`/`MenuItemIn` beside `LinkItem` `:285`; wired into `QRContent` `:531`) |
| Create write path (3 round-trips) | `qr_backend/src/api/routes/qr.py` (precedent: `qr_link_pages` + bulk `qr_link_items` insert `:2035-2072`) |
| Update write path (upsert-then-prune, 5 round-trips) | `qr_backend/src/api/routes/qr.py` (**do NOT copy** the per-row loop `:3179-3197`; empty-list branch precedent `:3174-3176`) |
| Single-QR read join | `qr_backend/src/api/routes/qr.py` (`SELECT_WITH_RELATIONS` `:998`; list stays on `SELECT_LIST_LIGHT` `:1005`) |
| DB rows → content | `qr_backend/src/api/routes/qr.py` (`_build_content_from_db_rows`, `qr_link_pages` precedent `:1401-1432`) |
| Item image → durable public URL | `qr_backend/src/api/routes/qr.py` (`_public_url_from_path` `:1008-1022`); upload via `src/api/routes/storage.py` (`POST /storage/upload` `:159`, path convention `:9`) |
| Row-id validation | `qr_backend/src/api/routes/qr.py` (`_is_valid_uuid` `:1025-1037`) |
| KV snapshot | `qr_backend/src/utilities/cloudflare_kv.py` (`build_kv_content` `menu` branch before the `else` at `:474`; `list_links` nested-embed precedent `:407-416`; `write_to_kv` unchanged `:52-115`; `sync_qr_to_kv` `:307`) |
| Type gating seed reference | `qr_backend/migrations/0027_open_all_qr_types.sql` (canonical arrays; never `'[]'` — `:18-20`) |
| New-type precedent | `qr_backend/migrations/0022_google_review_funnel.sql` (detail table + `@>`-guarded `dynamic_qr_types` append; slot-drift note `:10-13`) |
| Worker dispatch | `qr_cf_code/src/handlers/qrRouter.js` (new `menu` branch before `:289`; `review_funnel` shape `:281-287`; `pageDesign` injection `:43-50`) |
| Worker dispatcher + templates | `qr_cf_code/src/pages/menu/` (NEW — `index.js`, `helpers.js`, `classicTemplate.js`, `photoTemplate.js`, `accordionTemplate.js`; shape from `src/pages/vcard/index.js`) |
| Worker shared utils | `qr_cf_code/src/utils/html.js` (`escapeHTML` `:1`, `withMobileViewport` `:31`), `src/utils/design.js` (`buildDesignCSS` `:7`, `renderBrandFooter` `:102`, `renderFooter` `:125`) |
| i18n shape (cross-spec, §4.5) | Menu `EN` key map in `qr_cf_code/src/pages/menu/helpers.js`, moving to `qr_cf_code/src/i18n/en.js` when `MULTILINGUAL_LANDING_PAGES_TRD.md` creates that directory; `withDocumentLang` (added to `utils/html.js` by that spec). **Menu v1 is English-only — no dependency on `0042`.** |
| Deliberately NOT used | `qr_cf_code/src/utils/supabase.js` (`getSupabaseSignedUrls` `:3` — menu photos are public URLs, §3.7) |
| Builder editor | `qr_frontend/src/components/qr-generator/content-types/menu/` (NEW — `menu-content.tsx`, `menu-category-row.tsx`, `menu-item-row.tsx`, `menu-item-image-field.tsx`, `menu-paste-import.tsx`; each ≤200 lines) |
| dnd-kit precedent | `qr_frontend/src/components/qr-generator/content-types/ListLinksContent.tsx` (imports `:31-44`, `useSortable` `:70-84`, `useFieldArray` `keyName:'rhfId'` `:226-230`, sensors `:233-238`, `handleDragEnd`/`move` `:240-248`, `DndContext`+`SortableContext` `:488-509`) |
| Price / parser / schema | `qr_frontend/src/lib/menu.ts` (NEW — `toMinor`/`fromMinor`/`formatPrice`/`parsePastedMenu`/`menuSchema`) |
| React previews (mirroring rule) | `qr_frontend/src/components/qr-generator/templates/menu/` (NEW — `MenuClassicTemplate.tsx`, `MenuPhotoTemplate.tsx`, `MenuAccordionTemplate.tsx`, `shared.tsx`) |
| Template registry | `qr_frontend/src/lib/constants/page-templates.tsx` (`TemplateContentBag`, `MENU_TEMPLATES` with `menu_classic` first, `ALL_PAGE_TEMPLATES` `:524-540`, `getDefaultTemplateId` `:552-554`) |
| Picker / preview | `qr_frontend/src/components/qr-generator/TemplatePicker.tsx` (props `:35-79`, bag `:111-128`), `PagePreview/PagePreview.tsx` (bag `:192-210`) |
| Type→form switch | `qr_frontend/src/components/qr-generator/QRContent.tsx` (`case 'menu':` beside `:417` / `:521`) |
| Type registry | `qr_frontend/src/lib/constants/qr-types.ts` (`HAS_LANDING_PAGE_TYPES`, `ALL_TYPES` `:91-121`, `QR_TYPES`, `TYPE_ICONS`) |
| Upload hook | `qr_frontend/src/hooks/useStorage.ts` (`useUploadFile` `:86`) |
| Worker deploy | `qr_cf_code` — **`npm run deploy:prod`** required; **no `wrangler.toml` change** |
