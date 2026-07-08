# TRD — Campaign Tags + Multi-QR Rollup & Compare

**Status:** Draft · **Author:** Engineering (Staff) · **Date:** 2026-06-24
**Tiers / flags:** Tagging (CRUD + filter) = **all tiers, ungated** (organization is table-stakes, like folders). Campaign **rollup** + head-to-head **compare** analytics = **Pro & Agency** via the existing `advanced_analytics` flag (already `enforced` in `subscription.py`'s `FEATURE_ENFORCEMENT`, line 439). **No new flag is introduced** — no `FEATURE_ENFORCEMENT` edit, no plan-seed JSON edit, no flag-flip, so `test_feature_gate_coverage` stays green untouched.
**Migration:** `0022_campaign_tags_rollup.sql` (reserved slot 0022; current DB highest applied = `0013_retargeting_pixels.sql`; roadmap reserves 0014–0018). Ships **only this phase's schema** — `tags` + `qr_tags` + indexes; **no `UPDATE plans … jsonb_set` block at all**, avoiding the case-sensitive flag-flip footgun entirely.
**Services touched:** `qr_backend` (new `tags.py` router; two new aggregate endpoints in `scan.py`), `qr_frontend` (tag UI on builder + QR detail + QR list; Campaigns rollup section + compare drawer; `useTags`/`useCampaignRollup`/`useQRCompare` hooks). **`qr_cf_code` = ZERO change** — tags never touch KV, `build_kv_content`, `build_entitlements`, `build_pixels`, or the scan hot path.

**Rev (2026-06-24, post eng-review):** P1 fix — the rollup must NOT reuse the bare `_fetch_windowed_events(db, ws, cutoff, cols)`: it's workspace-scoped and caps at `_MAX_WINDOW_EVENTS` (50k) *before* any `qr_id` filter, so a large workspace can truncate the tag's rows out of the window (breaks ±1%) and the `qr_tags(tag_id)` index buys nothing for the events read. Added `_fetch_windowed_events_for_qrs` that pushes `.in_("qr_id", …)` (chunked ~100 for `key:*`) into the DB query so the cap bounds the tag's rows and `idx_qr_scan_events_qr_id_scanned_at` (0007) drives the scan. P2 fix — removed the `CREATE INDEX idx_scan_events_qr_time` from migration 0022: that `(qr_id, scanned_at)` index already exists under a different name (0007), and `IF NOT EXISTS` de-dupes by name only, so the copy would be a redundant duplicate index amplifying writes on the hot scan-insert path. P3 — `list_links` conversion column deferred (no backend-readable per-link counter; `lead_form` retained via `qr_lead_submissions`). Confirmed the `start = max(win, cutoff)` range+retention clamp is sound against the real helper signature. No flag-flip / no `FEATURE_ENFORCEMENT` / seed edit; tenant isolation via explicit `workspace_id` filters.

---

## 1. Overview & Architecture

Folders (`folders` table, `qr_codes.folder_id`, one parent each) impose a single hierarchy. This feature adds an orthogonal, many-to-many **tag** axis (`campaign:summer-2026`, `channel:print`, `client:acme`) that any QR can carry, then builds two read-only analytics surfaces on top of it: a **campaign rollup** (one tag → aggregated KPIs across whatever folders its QRs live in) and a **head-to-head compare** (2–4 QRs, or two tags, side-by-side with one overlaid trend chart). The compare generalizes the existing `get_qr_ab_results` card (scan.py ~line 486), which today compares only the two `variant_key` arms of one `website` QR.

**Services touched:**

| Concern | qr_backend | qr_frontend | qr_cf_code |
|---|---|---|---|
| **Phase 0** — schema + tag CRUD | migration `0022`; new `tags.py` (create/list/rename/delete + attach/detach), `require_can_*`-gated, **ungated** by plan | — | none |
| **Phase 1** — tagging UI (GA-able alone) | — | tag combobox on builder + QR detail; tag filter + manage-modal on QR list; `useTags` | none |
| **Phase 2** — rollup + compare (Pro+) | `GET /analytics/rollup`, `GET /analytics/compare` in `scan.py`, behind `_require_advanced_analytics` + retention clamp + CSV | Campaigns section, compare drawer, CSV export, `useCampaignRollup`/`useQRCompare` | none |

**Phase-2 data flow (no edge data):** FE calls `GET /analytics/rollup?workspace_id=…&tag=campaign:summer-2026&range=30` → backend `_resolve_workspace` → `_require_advanced_analytics` (403 if not Pro+) → resolve the tag to a **distinct `qr_id` set** via the `qr_tags` join (R3: dedupe before aggregating) → fetch windowed events **filtered to `qr_id ∈ set` at the DB layer** (see §3.2 — NOT the bare workspace-wide `_fetch_windowed_events`, which would pull and truncate the whole workspace before the Python filter) clamped to `analytics_retention_days` (R5) → aggregate total/unique scans, device/country/hourly/daily, and a per-QR member breakdown → `RollupResponse`. `?format=csv` returns the same aggregate as `text/csv`. 60 s TanStack `staleTime` + a short backend in-process cache.

**Accuracy posture (R2, identical to the funnel PRD):** rollup and compare are **strictly READ-only and read raw `qr_scan_events` rows**, never the non-atomic `qr_scan_counters` JSONB (its read-modify-write can lose increments). The known counter gap therefore cannot corrupt rollup numbers.

---

## 2. Data Model & Migrations

**File:** `qr_backend/migrations/0022_campaign_tags_rollup.sql` — `BEGIN/COMMIT`-wrapped, idempotent (`IF NOT EXISTS`), applied by hand in the Supabase SQL editor (no automated runner). All backend queries use the **service-role key, which bypasses RLS**, so no policies are added; tenant isolation is enforced in route code via explicit `workspace_id` filters (§9). **No `UPDATE plans` block** — `advanced_analytics` is already seeded `true` for Pro/Agency (0009) and reused as-is.

```sql
-- Migration 0022: Campaign Tags + Multi-QR Rollup & Compare.
-- Ships ONLY this phase's schema (tags + qr_tags + indexes). NO flag-flip:
-- the rollup/compare reuse the existing advanced_analytics flag, so there is
-- deliberately no `UPDATE plans … jsonb_set` block (avoids the case-sensitive
-- flag-flip footgun three prior specs hit) and test_feature_gate_coverage is
-- untouched.
BEGIN;

-- Workspace-scoped tag dictionary. `name` is the full label ("campaign:summer-2026"
-- or a flat "spring-menu"). Case-insensitive uniqueness within a workspace (R4):
-- typos like "Campaign:Summer" vs "campaign:summer" collapse to one tag.
CREATE TABLE IF NOT EXISTS tags (
    id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    workspace_id uuid        NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    name         text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now()
);
-- R4: UNIQUE(workspace_id, lower(name)) — match case-insensitively, store display case.
CREATE UNIQUE INDEX IF NOT EXISTS uq_tags_ws_lower_name
    ON tags (workspace_id, lower(name));
CREATE INDEX IF NOT EXISTS idx_tags_workspace
    ON tags (workspace_id);

-- Many-to-many join: a QR carries many tags, a tag spans many QRs (across folders).
CREATE TABLE IF NOT EXISTS qr_tags (
    qr_id  uuid NOT NULL REFERENCES qr_codes(id) ON DELETE CASCADE,
    tag_id uuid NOT NULL REFERENCES tags(id)     ON DELETE CASCADE,
    PRIMARY KEY (qr_id, tag_id)
);
-- R1: index both directions — tag→QRs (rollup resolve) and QR→tags (chips on detail).
CREATE INDEX IF NOT EXISTS idx_qr_tags_tag_id ON qr_tags (tag_id);
CREATE INDEX IF NOT EXISTS idx_qr_tags_qr_id  ON qr_tags (qr_id);

-- R1 (rollup denominator): the windowed events read filters by qr_id IN (...) +
-- scanned_at >= cutoff. The supporting (qr_id, scanned_at) index ALREADY EXISTS as
-- `idx_qr_scan_events_qr_id_scanned_at` (migration 0007) — do NOT create a second one
-- under a new name (e.g. `idx_scan_events_qr_time`); `IF NOT EXISTS` only de-dupes by
-- exact index NAME, not by column set, so a differently-named copy would be a redundant
-- duplicate index that doubles write amplification on the hot scan-insert path. This
-- migration therefore adds NO scan-events index; it relies on 0007's index.

COMMIT;
-- Sanity: SELECT count(*) FROM tags; SELECT count(*) FROM qr_tags;
```

**Why no flag-flip:** the rollup/compare *are* advanced analytics living on the already-gated `/analytics` page calling the already-gated read pattern. Reusing `advanced_analytics` means no migration flag-flip, no `FEATURE_ENFORCEMENT` registry entry, no plan-seed edit. The PK `(qr_id, tag_id)` makes attach idempotent and prevents duplicate join rows.

---

## 3. Backend Design

### 3.1 Tag CRUD — new `qr_backend/src/api/routes/tags.py` (mirrors `folder.py`)

Workspace-scoped router, registered in `src/api/endpoints.py` (`router.include_router(tags_router)`). Prefix `/workspaces/{workspace_id}/tags`, tag `["Tags"]`. **Ungated by plan** (no `check_feature` call — unlike `folder.py`, which gates on `"folders"`); only `require_can_*` role checks apply.

```python
router = fastapi.APIRouter(prefix="/workspaces/{workspace_id}/tags", tags=["Tags"])

_MAX_TAGS_PER_WS = 200      # R4 hygiene cap
_MAX_TAGS_PER_QR = 20

def _normalize_tag_name(raw: str) -> str:
    # R4: trim, collapse whitespace; lowercase the KEY of a key:value, keep value case.
    s = " ".join(raw.strip().split())
    if ":" in s:
        key, val = s.split(":", 1)
        return f"{key.strip().lower()}:{val.strip()}"
    return s

class TagCreate(pydantic.BaseModel):
    name: str
class TagRename(pydantic.BaseModel):
    name: str
class TagResponse(pydantic.BaseModel):
    id: uuid.UUID; workspace_id: uuid.UUID; name: str
    qr_count: int = 0; created_at: Optional[str] = None
```

Endpoints (all assert the tag/QR belongs to `workspace_id` before mutating — R7):
- `POST /` → `require_can_create`; normalize, enforce `_MAX_TAGS_PER_WS`, insert into `tags`; on the `uq_tags_ws_lower_name` violation return the existing tag (idempotent create) rather than 409.
- `GET /` → `require_can_read`; list workspace tags with `qr_count` (one grouped `qr_tags` read, `tag_id IN (...)`).
- `PATCH /{tag_id}` → `require_can_update`; rename (re-normalize; same uniqueness guard). One row update propagates everywhere (join references `tag_id`).
- `DELETE /{tag_id}` → `require_can_delete`; `ON DELETE CASCADE` clears `qr_tags`.
- `PUT /qr/{qr_id}` → `require_can_update`; **set** a QR's full tag list (`{tag_ids: [...]}` or `{names: [...]}`, auto-creating missing names). Verify each `qr_id`/`tag_id` is in `workspace_id`; enforce `_MAX_TAGS_PER_QR`; diff against current rows, insert added, delete removed. **No `write_to_kv` call** — tags are not edge data; a tag change must NOT trigger a KV resync (explicit scope guarantee).
- `GET /qr/{qr_id}` → `require_can_read`; the QR's current tags.

### 3.2 Rollup + Compare — `qr_backend/src/api/routes/scan.py` (`/analytics` router)

Both reuse `_resolve_workspace`, `_require_advanced_analytics`, `_retention_cutoff_iso`, `_retention_days`/`get_limit`, and the `_fetch_windowed_events` paging convention.

```python
class RollupMember(pydantic.BaseModel):
    qr_id: str; name: str; type: str
    scans: int; unique_scans: int; share_pct: float

class RollupResponse(pydantic.BaseModel):
    tag: str; range_days: int; exclude_bots: bool
    total_scans: int; unique_scans: int
    devices: Dict[str, int]; countries: Dict[str, int]
    hourly: Dict[str, int]; daily: List[Dict[str, object]]
    members: List[RollupMember]

@router.get("/rollup", response_model=RollupResponse)
async def get_campaign_rollup(
    workspace_id: Optional[uuid.UUID] = Query(None),
    tag: str = Query(...),                  # exact name OR "key:*" namespace
    range: int = Query(30, ge=1, le=365),
    exclude_bots: bool = Query(True),       # O.Q.4 default = yes
    format: Optional[str] = Query(None),    # "csv"
    user_id: str = Depends(get_current_user_id),
    db: Client = Depends(get_supabase),
):
    resolved_ws = _resolve_workspace(db, user_id, workspace_id)
    await _require_advanced_analytics(resolved_ws, db)          # 403 if not Pro+
    qr_ids = _resolve_tag_qr_ids(db, resolved_ws, tag)         # DISTINCT set (R3)
    if not qr_ids:
        return RollupResponse(tag=tag, range_days=range, ...empty...)
    cutoff = _retention_cutoff_iso(resolved_ws, db)            # R5 retention clamp
    days = min(range, _retention_days(resolved_ws, db) or range)
    win = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    start = max(win, cutoff) if cutoff else win
    cols = "qr_id, session_id, device_type, country_code, scanned_at"
    # CRITICAL (R1): filter by qr_id IN (qr_ids) AT THE DB LAYER, not in Python after a
    # workspace-wide pull. The existing _fetch_windowed_events(db, ws, cutoff, cols) is
    # workspace-scoped and hard-capped at _MAX_WINDOW_EVENTS (50k) BEFORE any qr_id
    # filter — so on a large workspace the tag's rows can be truncated out of the cap
    # (breaking the ±1% goal) and the qr_tags(tag_id) index buys nothing for the events
    # read. Use a qr_id-scoped variant (new `_fetch_windowed_events_for_qrs`, below) so
    # the 50k cap applies to THIS tag's events and the (qr_id, scanned_at) index drives
    # the scan.
    events = [e for e in _fetch_windowed_events_for_qrs(db, resolved_ws, qr_ids, start, cols)
              if (not exclude_bots or e.get("device_type") != "bot")]
    # aggregate totals, distinct session_id for unique_scans, per-qr_id members, devices/countries/hourly/daily

# New helper alongside _fetch_windowed_events — same paging/cap/log contract, but the
# DB query adds `.in_("qr_id", qr_ids)` (qr_ids already workspace-verified) so the index
# idx_qr_scan_events_qr_id_scanned_at (migration 0007) backs the read. Chunk qr_ids into
# batches of ~100 if a `key:*` namespace resolves to a large set, to bound the IN-list /
# URL length; union the chunk results. workspace_id is still asserted on every chunk.
def _fetch_windowed_events_for_qrs(db, ws, qr_ids, cutoff_iso, columns): ...
```

`_resolve_tag_qr_ids(db, ws, tag)`: when `tag` ends in `:*`, resolve every tag whose `lower(name)` starts with the `key:` prefix and union their `qr_tags.qr_id`; else match the single tag case-insensitively (`ilike` on `name`). **Always scope `tags`/`qr_tags`/`qr_codes` reads by `workspace_id` explicitly** (service role bypasses RLS — R7), and return a **distinct** id set so a QR carrying two selected tags counts once (R3). The events read filters `qr_id ∈ set` **in the DB query** (`.in_("qr_id", qr_ids)` in `_fetch_windowed_events_for_qrs`), so the 50k `_MAX_WINDOW_EVENTS` cap bounds *this tag's* events — not the whole workspace — and the `(qr_id, scanned_at)` index drives the scan.

```python
class CompareEntity(pydantic.BaseModel):
    key: str; label: str; kind: str            # "qr" | "tag"
    scans: int; unique_scans: int
    top_country: Optional[str]; top_device: Optional[str]
    conversion_rate: Optional[float] = None    # None (blank, not 0) when N/A
    series: List[Dict[str, object]]            # [{date, scans}]

class CompareResponse(pydantic.BaseModel):
    range_days: int; exclude_bots: bool
    entities: List[CompareEntity]

@router.get("/compare", response_model=CompareResponse)
async def get_qr_compare(
    workspace_id: Optional[uuid.UUID] = Query(None),
    qr_ids: Optional[str] = Query(None),   # csv of up to 4 (O.Q.2)
    tags: Optional[str] = Query(None),     # csv of up to 2 tag names
    range: int = Query(30, ge=1, le=365),
    exclude_bots: bool = Query(True),
    ...
):
```

`/compare` accepts **either** `qr_ids` (2–4, O.Q.2) **or** `tags` (exactly 2). Each entity resolves to a `qr_id` set (one QR, or a tag's distinct members), shares the same windowed read, and emits aligned per-entity KPIs + a daily `series` (one chart line). **Conversion column:** for an entity that is/contains a `lead_form` QR, `conversion_rate = submissions ÷ scans of that QR`, submissions counted from `qr_lead_submissions` (verified to exist, migration 0012) within the same window. **`list_links` is DEFERRED for the conversion column in v1** — there is no per-link click counter table to source from cleanly (link clicks are tracked via the Worker `/click/:linkId` path, not a backend-queryable counter), so wiring it risks an inaccurate denominator that violates the ±1% posture. `list_links` entities render `None` (blank) for conversion in v1; revisit when a backend-readable link-click aggregate exists. For all other types `conversion_rate = None` (rendered blank, never `0.0`). Validate every passed `qr_id` belongs to `resolved_ws` (404/403 on cross-workspace — R7).

**CSV export:** `format="csv"` on `/rollup` returns `fastapi.responses.PlainTextResponse` (`text/csv`, `Content-Disposition: attachment; filename=rollup_<tag>_<range>d.csv`): a header summary (tag, total/unique scans) + one row per member (`qr_id,name,type,scans,unique_scans,share_pct`). Served from the same cached aggregate (no extra scan).

### 3.3 Gating / KV / entitlements

**No `FEATURE_ENFORCEMENT` edit** (`advanced_analytics` already `enforced`). **No `build_kv_content` / `build_entitlements` / `build_pixels` change** — tags are an org/analytics concept, never edge-enforced, so nothing is threaded into entitlements and `write_to_kv` is never called on tag mutation. No `/internal/*` endpoint added.

---

## 4. Cloudflare Worker / Edge Design

**Zero Worker change. Zero KV write. Zero deploy.** Tags never enter the KV value (`{qr_id,type,destination,destinations,is_password_protected,status,workspace_id,page_design,content,entitlements,pixels}`), never enter `cloudflare_kv.py`, and never touch the scan hot path. The rollup/compare are pure backend aggregates over `qr_scan_events` rows the Worker already writes via `recordScan` → `/internal/scans`.

- **No new QR type** → the 7-step new-type checklist and the React↔Worker template-parity house rule are **not triggered**.
- **No `scheduled()`/cron change** → no `npm run deploy:prod` gate (new crons register only after a prod deploy, but there is no cron here).
- **Scan-data shape unchanged** — the rollup reuses the existing 17-field `qr_scan_events` shape (`qr_id`, `session_id` = daily-rotated `SHA-256(IP+UA+today)` 16-hex for uniques, `device_type` incl. `'bot'` for `exclude_bots`, `country_code`, `scanned_at`).
- **Consent gate (`src/utils/consent.js`) unaffected** — no scan-side marketing tags are added; `hasMarketingTags` is untouched.

A success criterion is **zero Worker deploys / zero KV writes attributable to this feature** (verifies the no-edge-change guarantee).

---

## 5. Frontend Design

### 5.1 Hooks — `qr_frontend/src/hooks/useTags.ts` + extend `useAnalytics.ts`

New `useTags.ts` with a `tagKeys` factory (`tagKeys.list(workspaceId)`, `tagKeys.forQr(qrId)`) over `authApi`: `useTags(workspaceId)`, `useQRTags(qrId)`, and mutations `useCreateTag`/`useRenameTag`/`useDeleteTag`/`useSetQRTags` that `invalidateQueries` on `tagKeys` **and** `qrKeys.lists()` (so chips/counts refresh). Extend the existing `analyticsKeys` factory in `useAnalytics.ts`:

```ts
// add to analyticsKeys:
rollup:  (tag: string, range: number) => [...analyticsKeys.all, 'rollup', tag, range] as const,
compare: (ids: string, range: number) => [...analyticsKeys.all, 'compare', ids, range] as const,

export function useCampaignRollup(tag: string, range = 30, workspaceId?: string) {
  return useQuery({
    queryKey: [...analyticsKeys.rollup(tag, range), workspaceId],
    queryFn: async () => {
      const p = new URLSearchParams({ tag, range: String(range) });
      if (workspaceId) p.set('workspace_id', workspaceId);
      const { data } = await authApi.get<RollupResponse>(`/analytics/rollup?${p}`);
      return data;
    },
    enabled: !!workspaceId && !!tag,
    staleTime: 60_000,   // matches backend 60s cache
  });
}
```

`useQRCompare(idsOrTags, range, workspaceId)` mirrors this against `/analytics/compare`. CSV download is a plain `authApi.get('/analytics/rollup?...&format=csv', { responseType: 'blob' })` → client-side `Blob`/`a.download`.

### 5.2 Tag input — builder final step + QR detail

A `TagInput.tsx` (shadcn `Command`/`Popover` combobox + removable `Badge` chips) rendered in the QR builder's final step (`src/components/qr-generator/`) and on `src/components/org/qrs/details/` (beside the existing folder control in `QRDetails.tsx`). Typing `campaign:` autocompletes existing values in that namespace from `useTags`; a free string creates a flat tag. Chip color is derived **deterministically from the tag key** (hash `key` → one of the palette hues; all `campaign:*` share a hue, `channel:*` another) — no per-tag color picker in v1. Save calls `useSetQRTags` (the `PUT /tags/qr/{qr_id}`). react-hook-form integration on the builder; controlled inputs only.

### 5.3 QR list — `MyQRCodes.tsx` / `QRCodesTable.tsx` / `FolderSection.tsx`

`FolderSection.tsx` gains a **Tags** group below folders: each tag with its `qr_count`, multi-selectable. Selecting tags filters `QRCodesTable.tsx` by tag membership; **folder ∩ tags compose** (folder filter AND'd with the tag filter). Multi-tag semantics: **OR across selected tags** by default (O.Q.1 — "show me everything in any of these campaigns"), AND deferred. A **Manage tags** affordance opens `ManageTagsModal.tsx` (mirrors `CreateFolderModal`/`DeleteFolderModal`) for workspace-wide rename/delete; delete shows a confirm with the **affected-QR count** (O.Q.5). `QRCodesTable.tsx` gains multi-select checkboxes feeding a "Compare" button → the compare drawer.

### 5.4 Campaigns rollup + compare drawer — `analytics/page.tsx` + `src/components/org/analytics/`

A new **Campaigns** section on `/org/[slug]/(dash)/analytics/page.tsx`. The whole page already returns the `advanced_analytics` `UpgradeGate` when `!canAccessFeature(subscription, 'advanced_analytics')` (the `PlanFeatures` interface from `useSubscription.ts`) — so Free/Starter users see the **upsell exactly at the payoff**: "You've grouped 4 QRs into `campaign:summer`. See them rolled up — upgrade to Pro." The Pro view: a tag (or `key:*`) picker → one `CampaignRollupCard.tsx` reusing the existing device-donut / country-bar / hourly / daily-trend components + the top-QR table (scoped to members) + a **Download CSV** button; honors the page's existing `7/30/90/365` selector. `CompareDrawer.tsx` (shadcn `Sheet`) renders a per-entity KPI grid + one overlaid daily-trend chart (line per entity, cap 4 — O.Q.2), generalizing the `ABResultsCard` idiom; non-Pro hitting it sees the same gate.

**Design system:** shadcn primitives only (`Card`, `Badge`, `Command`, `Popover`, `Sheet`, `Select`, `Skeleton`); `PageHeader`/`Card`/`EmptyState` from `src/components/org`; `cn()`; `primary` `#4648d4` indigo + `tertiary` cyan for chart series, `on-surface-variant` for secondary labels; no inline styles, no `any`, ≤200 lines/file (split `TagInput`, chip, drawer chart into sub-components), one export per file, kebab-case filenames. TanStack Query only — no `useEffect+fetch`.

---

## 6. AI / External-Service Integration

**None.** This is a deterministic SQL-aggregate + chart feature; rollup totals must reconcile within ±1% of a manual `qr_scan_events` count, which rules out an LLM. The PRD's "suggest campaign tags from QR names" Haiku helper is explicitly *future* and out of scope. **No email** (CSV is an in-app download, not a sent report) → **no Resend, no `_dmarc.qravio.app` DMARC GA gate**. **No PDF** (CSV only) → no WeasyPrint. *(Future, backend-side only:* `claude-haiku-4-5` fed only the numeric `RollupResponse` (no PII), token-capped, confirm-before-save, empty-string fallback — never on the Worker scan path.)*

---

## 7. API Contracts

**`PUT /api/v1/workspaces/{workspace_id}/tags/qr/{qr_id}`** (Bearer; `require_can_update`; ungated)
```json
// request
{ "names": ["campaign:summer-2026", "channel:print"] }
// 200 — current tags after set
[ { "id": "…", "workspace_id": "…", "name": "campaign:summer-2026" },
  { "id": "…", "workspace_id": "…", "name": "channel:print" } ]
```

**`GET /api/v1/analytics/rollup`** (Bearer; `advanced_analytics`-gated)
Query: `workspace_id?` (uuid), `tag` (required — `"campaign:summer-2026"` or `"campaign:*"`), `range` (1–365, default 30), `exclude_bots` (default true), `format?` (`csv`).
```json
{
  "tag": "campaign:summer-2026",
  "range_days": 30, "exclude_bots": true,
  "total_scans": 8400, "unique_scans": 6120,
  "devices": { "mobile": 7100, "desktop": 1300 },
  "countries": { "US": 5200, "IN": 2100, "GB": 1100 },
  "hourly": { "09": 410, "18": 980 },
  "daily": [ { "date": "2026-05-26", "scans": 240 } ],
  "members": [
    { "qr_id": "…", "name": "Summer Poster", "type": "website",  "scans": 4200, "unique_scans": 3100, "share_pct": 50.0 },
    { "qr_id": "…", "name": "IG Bio Link",   "type": "list_links","scans": 3000, "unique_scans": 2200, "share_pct": 35.7 },
    { "qr_id": "…", "name": "Pack vCard",    "type": "vcard",     "scans": 1200, "unique_scans": 820,  "share_pct": 14.3 }
  ]
}
```
`403` when not Pro+ (`{"detail":"Advanced analytics requires a Pro or higher plan."}`). `format=csv` → `text/csv` attachment.

**`GET /api/v1/analytics/compare`** (Bearer; `advanced_analytics`-gated)
Query: `workspace_id?`, **either** `qr_ids` (csv, 2–4) **or** `tags` (csv, exactly 2), `range`, `exclude_bots`.
```json
{
  "range_days": 30, "exclude_bots": true,
  "entities": [
    { "key": "<qr-a>", "label": "Summer Poster", "kind": "qr", "scans": 4200, "unique_scans": 3100,
      "top_country": "US", "top_device": "mobile", "conversion_rate": null,
      "series": [ { "date": "2026-05-26", "scans": 120 } ] },
    { "key": "<qr-b>", "label": "Summer Flyer", "kind": "qr", "scans": 3000, "unique_scans": 2200,
      "top_country": "US", "top_device": "mobile", "conversion_rate": 18.3,
      "series": [ { "date": "2026-05-26", "scans": 90 } ] }
  ]
}
```

---

## 8. Performance, Scale & Cost

- **Bounded read (R1/R5):** the rollup resolves a tag → `qr_id` set via the indexed `qr_tags(tag_id)` join, then aggregates `qr_scan_events` with `qr_id ∈ set` pushed into the **DB query** (`.in_("qr_id", …)`, chunked ~100/batch for `key:*` namespaces) + `scanned_at >= start`, **clamped to `analytics_retention_days`** by `_retention_cutoff_iso`. The `_MAX_WINDOW_EVENTS` (50 000) cap now bounds *this tag's* rows, not the workspace's — so a large workspace cannot truncate the tag out of the window. The existing `idx_qr_scan_events_qr_id_scanned_at` (migration 0007) backs the read. Target p95 < 700 ms for a 90-day window on a 50-QR workspace.
- **Distinct-set first (R3):** dedupe `qr_id` before aggregating so a QR under two selected tags counts once — totals reconcile within ±1% of a manual `qr_scan_events` count.
- **Caching:** 60 s in-process backend cache keyed `(workspace_id, tag/ids, range, exclude_bots)` + 60 s FE `staleTime`; CSV reuses the same cached aggregate.
- **Cost:** tag mutations are tiny `qr_tags` upserts/deletes; no KV writes; **zero edge cost**. Hygiene caps (200 tags/workspace, 20 tags/QR) bound join cardinality.

---

## 9. Security, Privacy & Abuse

- **Tenant isolation (R7):** the service-role client **bypasses RLS**, so every `tags`/`qr_tags`/`qr_codes`/`qr_scan_events` query filters by the resolved `workspace_id` explicitly. Tag mutations verify the `tag_id`/`qr_id` belongs to `workspace_id` before writing; rollup/compare verify each passed `qr_id` is in `resolved_ws` (404/403 on cross-workspace). No raw `qr_id` is ever aggregated without the workspace check.
- **Permissions:** tag CRUD/attach/detach → `require_can_create`/`require_can_update`/`require_can_delete`; rollup/compare reads → `require_can_read` (implicit via workspace resolution) **and** `_require_advanced_analytics`. Tags inherit the workspace role model — no per-tag ACLs.
- **PII:** rollup/compare expose only **aggregate counts**; `unique_scans` uses the cookieless daily-rotated `session_id` (`SHA-256(IP+UA+today)` 16-hex) — no raw IP, no cross-day linkage. CSV contains aggregates only, no raw scan rows.
- **Input hygiene (R4):** tag names normalized + length-capped server-side; `UNIQUE(workspace_id, lower(name))` blocks case-typo duplicates.
- **No SSRF / webhook surface** — no public/provider webhook is added (no Bearer-middleware `excluded_routes` change). **No consent-gate impact** — no scan-side marketing tags.

---

## 10. Testing Strategy

**Backend (pytest):** tag create normalizes + dedupes on `lower(name)`; rename propagates (one `tag_id` row, join unchanged); delete cascades `qr_tags`; per-QR set diff inserts/deletes correctly + enforces the 20-cap; cross-workspace `tag_id`/`qr_id` rejected. Rollup: resolves `tag` and `key:*` to a **distinct** `qr_id` set (R3 — a QR under two selected tags counts once); totals reconcile **±1%** with hand-counted `qr_scan_events` rows; `exclude_bots` toggles the denominator; retention clamp narrows the window (R5); **gate-deny** — non-Pro `GET /rollup` and `/compare` return **403**; CSV returns `text/csv` with member rows. Compare: 2–4 entities aligned; conversion column is `None` for non-actionable QRs (not `0.0`); >4 / wrong-arity rejected. **`test_feature_gate_coverage` stays green** (no `FEATURE_ENFORCEMENT`/seed edit).

**Frontend (Vitest + Playwright):** `useTags`/`useCampaignRollup`/`useQRCompare` query-key + URL correctness; `TagInput` chips add/remove + namespace color derivation; QR-list tag filter composes with folder filter (folder ∩ OR-of-tags); manage-modal rename/delete with affected-count confirm; rollup card renders members + CSV blob download; compare drawer overlays ≤4 lines; Free user sees the `UpgradeGate` on Campaigns. **Baseline:** the FE suite has ~29 documented pre-existing failures — assert new tests pass and the failure count does **not** increase (these are not regressions).

**Worker (vitest/wrangler):** assert **no KV write fires on a tag change** and the scan path is byte-identical — the no-edge-change guarantee.

---

## 11. Observability & Rollout

- **No DMARC gate** (no email), **no prod-worker-deploy gate** (no cron, no edge code). The only deploy dependency is applying migration `0022` + standard backend + frontend deploys — and a Worker test proving KV is untouched.
- **Phased deploy (order):** (1) apply `0022` to Supabase by hand (BEGIN/COMMIT, idempotent); (2) deploy backend `tags.py` CRUD — smoke-test on a seed workspace, no FE; (3) deploy FE tagging UI behind a FE constant flag → short internal pass → **GA Phase 1** (independently shippable, ungated, low-risk); acceptance: a QR in `/Print` and a QR in `/Social` both carry `campaign:summer`, filtering returns both, rename/delete propagate, **no KV write on tag change**; (4) deploy backend `/analytics/rollup` + `/analytics/compare` (validate rollup against a hand-computed spreadsheet behind the gate); (5) deploy FE Campaigns section + compare drawer + CSV; beta 3–5 agencies ~1 week → **GA Phase 2**; acceptance: a Pro workspace's `campaign:summer` rollup sums all members within retention (±1%), a Free user gets the gate + `403`, compare overlays 3 QRs, CSV downloads, results clamped to `analytics_retention_days`.
- **Metrics:** % workspaces with ≥1 tag; median tags-per-tagged-QR; Campaigns-view rate (Pro/Agency); CSV-export rate; tag-filter session rate; Free/Starter→Pro upgrade lift after hitting the Campaigns gate; rollup p95 latency; the ±1% reconciliation spot-check; **zero KV writes / zero Worker deploys** attributable to this feature.

---

## 12. Open Technical Questions & Risks + Appendix

- **R1 — Aggregation perf:** indexed `qr_tags(tag_id)`/`qr_tags(qr_id)` + the existing `idx_qr_scan_events_qr_id_scanned_at` (0007 — no new copy); push `qr_id ∈ set` into the DB query (`.in_`, chunked) so the 50k cap bounds the tag's rows not the workspace's; window bounded by retention; 60 s cache. Validate p95 on a 50-QR/90-day seed.
- **R2 — Counter irrelevant (neutralized):** rollup/compare read raw `qr_scan_events`, **never** `qr_scan_counters` — the non-atomic counter gap can't corrupt totals.
- **R3 — Double-count:** resolve to a **distinct** `qr_id` set before aggregating; never sum per-tag totals.
- **R4 — Tag hygiene:** normalize (lowercase key, trim, collapse) + `UNIQUE(workspace_id, lower(name))` + 200/20 caps.
- **R5 — Retention bypass:** reuse the exact `get_limit()`/`_retention_cutoff_iso` clamp — a Pro user cannot read past `analytics_retention_days` via a tag.
- **R6 — Bots:** `exclude_bots=true` default (consistent with the funnel PRD) so campaign quality isn't inflated by `device_type='bot'` rows.
- **R7 — RLS bypass:** every query filters `workspace_id` explicitly; mutations verify ownership before write.
- **O.Q.1** multi-tag filter = **OR** default, AND deferred. **O.Q.2** compare cap = **4**. **O.Q.3** `campaign:` = soft UI convention, not a schema distinction. **O.Q.4** exclude bots by default = **yes**. **O.Q.5** delete-tag confirm shows affected-QR count (mirror `DeleteFolderModal`).

| Concern | File |
|---|---|
| Tag CRUD + attach/detach | new `qr_backend/src/api/routes/tags.py`; register in `src/api/endpoints.py` |
| Rollup + compare + gate + retention + CSV | `qr_backend/src/api/routes/scan.py` (`/analytics/rollup`, `/analytics/compare`; reuse `_require_advanced_analytics`, `_fetch_windowed_events`, `_retention_cutoff_iso`, `get_limit`) |
| Permissions | `qr_backend/src/api/dependencies/permissions.py` |
| Gating (no edits) | `qr_backend/src/api/routes/subscription.py` (`advanced_analytics` already `enforced`, line 439) |
| Migration | `qr_backend/migrations/0022_campaign_tags_rollup.sql` (tags + qr_tags + indexes; **no flag-flip**) |
| Tag hooks | `qr_frontend/src/hooks/useTags.ts`; `useCampaignRollup`/`useQRCompare` in `src/hooks/useAnalytics.ts` (extend `analyticsKeys`) |
| Tag input UI | `qr_frontend/src/components/qr-generator/` (builder final step) + `src/components/org/qrs/details/` (`QRDetails.tsx`) |
| Tag filter + manage modal | `qr_frontend/src/components/org/qrs/MyQRCodes.tsx`, `components/QRCodesTable.tsx`, `components/FolderSection.tsx`; new `ManageTagsModal.tsx` (mirror `CreateFolderModal`/`DeleteFolderModal`) |
| Rollup + compare UI | `qr_frontend/src/app/org/[slug]/(dash)/analytics/page.tsx`, `src/components/org/analytics/` (`CampaignRollupCard.tsx`, `CompareDrawer.tsx`; reuse chart + top-QR-table, `ABResultsCard` idiom) |
| FE gating | `qr_frontend/src/lib/plan-features.ts` (`canAccessFeature`), `src/hooks/useSubscription.ts` (`PlanFeatures`) |
| Worker | **no change** (verify no KV write on tag mutation) |
