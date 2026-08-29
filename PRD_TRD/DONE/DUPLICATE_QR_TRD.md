# TRD — Duplicate QR

**Spec:** `DUPLICATE_QR_PRD.md` · **Status:** SHIPPED 2026-08-29 (see §0) · **Date:** 2026-08-28
**Migration:** **none.**
**Repos:** `qr_backend`, `qr_frontend`. **Worker:** no change, no redeploy. **KV contract:** unchanged, no regeneration.
**New plan flags:** none. **New `FEATURE_ENFORCEMENT` entries:** none. **Plan seed:** untouched.

---

## 0. AS BUILT — 2026-08-29

Shipped as `feat/duplicate-qr` in `qr_backend` and `qr_frontend`. **Read this section before
anything below it**: the design below was written from the specs rather than from a trace of
the code, and seven of its claims are wrong. Where they conflict, this section wins.

The load-bearing decision — go through `create_qr` rather than copying tables — survived
contact with the code and turned out to be *more* right than the argument for it, because
`create_qr` already owns more than the TRD credited it with.

| # | Section | What it says | What is actually true |
|---|---|---|---|
| 1 | §1.1 steps 5–7, §5 steps 5–7, §7 row 2 | Pre-generate `new_qr_id`, copy storage objects by hand, build a `path_map`, rewrite paths in `content`, compensate on a partial copy | **`create_qr` already does it.** `service.py:337-369` and `:432-488` hold a *"File belongs to another QR — copy it for this one"* branch that copies the object **and** its PDF thumbnails and carries `page_count`/`metadata`, keyed off `file_id`. `_build_content_from_db_rows` emits `file_id` (`rows.py:597,611`), so passing the content straight through triggers it. **The whole manual storage step, the `path_map` and its compensation logic were deleted.** |
| 2 | §5 step 11 | Finish with `run_in_threadpool(publish_qr, …)` | `create_qr` publishes **inline** (`service.py:917-993`) via `write_to_kv` + `kv_sync.mark_synced`/`mark_failed`, never `publish_qr`. A second publish is redundant — except for #3. |
| 3 | — | not considered | ⚠️ **`build_kv_content` reads `qr_translations`** (`cloudflare_kv.py:738`), and `create_qr` publishes *before* the translation rows are copied. A multilingual QR would therefore duplicate into a copy that **advertises its locales and serves only the default**, silently, until an unrelated edit resynced it. Copying translations is now followed by exactly one `publish_qr`. |
| 4 | §5 step 10, PRD carry-over matrix | Copy "routing rules" from a routing table | **No such table.** `0015_routing_rules.sql:25` put them in `qr_destinations.rules` (jsonb), and `QRDestinationCreate.rules` exists, so routing rides along with the destination and needs no copy step. |
| 5 | §6, §13.1 | Assert no `qr_passwords` insert | **`qr_passwords` is dead** — present in the base schema, referenced nowhere in `src/`. Password protection is `is_password_protected` + `password_hash` **columns on `qr_codes`** (`0004`). Neither is a `QRCodeCreate` field, so the copy is unprotected by construction; the test asserts the columns, not a phantom insert. |
| 6 | §5 step 5 | `sum(f["size_bytes"])` | The column is **`size`**. `size_bytes` is the *response model* name (`rows.py:600`). |
| 7 | §4 | `payload: … = None` declared before `request: Request` | **`SyntaxError`** — a non-default parameter cannot follow a default one. `request` comes first. |

### Two hazards the spec did not know about, both silent, both reachable only through duplication

**Menu row ids.** `_build_menu_rows` honours a client-supplied `id` (`category.id or uuid4()`)
and the create path **INSERTs**. Passing the original's menu through unchanged would insert
the original's primary keys and die on a duplicate-key violation *after* the `qr_codes` row
existed, leaving an orphan. Ids are stripped before the create.

**Menu photos.** They are **not** `qr_files` — they are bare storage paths on
`qr_menu_items`, and `_validate_menu_image_path` checks only the WORKSPACE prefix, so the
original's paths validate happily on a copy. But deleting a QR removes exactly the paths its
own rows name (`_collect_storage_paths_by_qr`), so a shared path means **deleting either QR
destroys the other's photos** — including the user who duplicates, dislikes the copy, deletes
it, and silently loses the photos on an original they never touched. Each photo is copied to
an object the copy owns; a failed copy drops `image_path` and keeps `image_url`, so the photo
still renders and the copy registers no delete-path for a file it does not own.

### Smaller corrections

* `ab_enabled` is recomputed server-side (`service.py:209`) and the client value ignored, so
  passing it is inert.
* `content` is **required** on `QRCodeCreate` while `_build_content_from_db_rows` returns
  `Optional`, so it needs an `or QRContent()` fallback.
* `destinations` must be passed to `_build_content_from_db_rows` as **model objects**, not
  raw rows — it reads `destinations[0].target_url` to rebuild `content.url` and the whole
  `phone` payload.
* The name probe must use the **stem** (`"Menu (copy"`), not the base: `LIKE 'Menu (copy)%'`
  can never match `"Menu (copy 2)"`, so every duplicate past the second kept proposing
  `(copy 2)`.
* §13.1's "one test per type family" was replaced by testing the **payload handed to
  `create_qr`**. `create_qr` is stubbed: re-driving it per family would re-test `create_qr`,
  and the contract `duplicate_qr` actually owns is what it refuses, what it sends, and what it
  copies afterwards. 39 backend tests, 13 frontend.

### PRD correction

PRD §2.4 argues "landing pages have had a duplicate endpoint since they shipped". **They have
not.** `useDuplicateLandingPage` exists (`useLandingPages.ts:253`) and POSTs
`/landing-pages/{id}/duplicate`, but no such backend route exists and nothing imports the
hook. It is dead code, not a precedent. The argument for the feature stands on its own; this
particular support for it does not.

### Product decision taken at build time

Duplicating **stays on the list** and the confirmation toast carries an "Open copy" action,
rather than navigating to the copy as PRD §5.3/G5 specified. G5's own reasoning — "the next
action is always change the one thing that differs" — argues for landing on the edit surface,
but the PRD's own personas (an agency doing twelve clients, a restaurant doing eleven outlets)
duplicate repeatedly, and bouncing them off the list each time is the workflow the feature
exists to remove. The toast action keeps the single-edit case to one click.


---

## 1. Architecture

### 1.1 The chosen shape

```
POST /api/workspaces/{ws}/qr-codes/{qr_id}/duplicate
        │
        ├─ 1. load original      SELECT_WITH_RELATIONS, .eq("workspace_id", ws)
        ├─ 2. refuse holds       is_staff_hold(status) / unclaimed_expired  → 403
        ├─ 3. check_limit        max_qr  → 402 / 503
        ├─ 4. entitlement        dynamic_qr_types + lead_forms  → 403
        ├─ 5. storage pre-flight max_file_size_mb vs original's qr_files  → 402
        ├─ 6. copy storage       {ws}/{orig_id}/… → {ws}/{new_id}/…   (new_id pre-generated)
        ├─ 7. rebuild content    _build_content_from_db_rows(...) + path rewrite
        ├─ 8. resolve name       "(copy)" / "(copy N)"
        ├─ 9. create_qr(...)     ← every validator, every insert, short-code mint, KV publish
        ├─ 10. side tables       tags, routing rules, translations (only what create does not own)
        └─ 11. publish_qr        via run_in_threadpool  (idempotent; create may already have)
```

### 1.2 The rejected alternative, and why

The obvious implementation is a table-by-table row copy across the ~20 `qr_*` child tables
(`qr_vcard_details`, `qr_menus` + `qr_menu_categories` + `qr_menu_items`, `qr_link_pages` +
`qr_link_items`, `qr_lead_forms`, `qr_review_funnel`, `qr_files`, `qr_designs`,
`qr_destinations`, …). **Reject it.**

`create_qr` is ~950 lines and owns: schedule-window validation, daily-window validation, locale
validation, the `max_qr` check with its fail-closed-but-retryable 503 semantics, custom-domain
verification, short-code minting and reservation (`_generate_short_code`, `_is_reserved`,
`_reserve_short_code`), menu row construction (`_write_menu`), variant-key assignment
(`_ensure_variant_keys`), storage-path validation (`_validate_menu_image_path`), and the KV
publish. A parallel copy path re-implements none of that correctly and drifts from it on the
first schema change.

By going through `create_qr`, **anything the API would refuse, Duplicate refuses, for free** — and
a new `qr_*` child table wired into create is copied automatically without anyone updating this
document.

### 1.3 The consequence to accept deliberately

Duplicate can only copy what a `GET` can express. `_build_content_from_db_rows` is the function
that turns relation rows back into the `QRContent` model, and it is what `GET /qr-codes/{id}` uses.
If some field does not survive that round trip, Duplicate loses it too.

That is a **feature** — it concentrates the gap in one function instead of two — but it is not
free. **Before writing code, audit `_build_content_from_db_rows` against `SELECT_WITH_RELATIONS`
and record every field that does not round-trip.** See §16. The per-type-family tests in §13 are
the ongoing guard.

## 2. Migration

**None.** No new column, no new table, no index, no plan-seed change, no `FEATURE_ENFORCEMENT`
entry. This is the only feature in the 2026-08-28 batch with zero schema footprint.

## 3. Backend — schemas

`src/api/schemas/qr.py`:

```python
class QRCodeDuplicate(pydantic.BaseModel):
    """Optional overrides for POST /qr-codes/{qr_id}/duplicate. An empty body is the common case."""
    name: Optional[str] = None          # default: "{original} (copy)" with collision suffix
    folder_id: Optional[uuid.UUID] = None   # default: the original's folder
```

Response model: the existing **`QRCodeResponse`**. The copy is an ordinary QR and there is no
reason for a distinct shape; reusing it means the frontend's `QRCode` type needs no change and the
detail page renders the response directly.

Deliberately **not** in v1: `include_tags`, `clear_schedule`, `target_workspace_id`. Each is a
product decision held open in PRD §14 / NG3, and each would harden into API surface if added now.

## 4. Backend — endpoint contract

```
POST /api/workspaces/{workspace_id}/qr-codes/{qr_id}/duplicate
```

Declared in `src/api/routes/qr.py` beside the create routes, matching their dependency set exactly:

```python
@router.post(
    "/{qr_id}/duplicate",
    name="qr:duplicate",
    status_code=fastapi.status.HTTP_201_CREATED,
    response_model=QRCodeResponse,
    summary="Duplicate a QR code, including content, design and destinations",
)
async def duplicate_qr_code(
    workspace_id: uuid.UUID,
    qr_id: uuid.UUID,
    payload: QRCodeDuplicate | None = None,
    request: Request,
    db: Client = Depends(get_supabase),
    user_id: str = Depends(get_current_user_id),
    member: dict = Depends(require_can_create),
) -> QRCodeResponse:
    return await service.duplicate_qr(workspace_id, qr_id, payload, request, db, user_id, member)
```

`require_can_create`, not `require_can_update` — the operation creates a QR. A `viewer` and an
`editor` differ here in exactly the way they differ for create, which is the correct and already
understood behaviour.

`request: Request` is threaded through because `create_qr` takes it.

Orchestration lives in `src/core/qr/service.py::duplicate_qr`, matching the note already in the
create and update routes ("Orchestration lives in src/core/qr/service.py").

### 4.1 Status codes

| Code | Condition | Body |
|---|---|---|
| 201 | Success | `QRCodeResponse` for the copy |
| 402 | `max_qr` reached | The existing `check_limit` message, including the lapsed-grace variant |
| 402 | File size exceeds `max_file_size_mb` | "This QR's files are larger than your plan allows…" |
| 403 | Type no longer entitled | The same message the create path emits |
| 403 | `suspended` | "A suspended QR cannot be duplicated. Contact support." |
| 403 | `unclaimed_expired` | "This QR has no owner yet. Claim it before duplicating." |
| 404 | QR not found in this workspace | |
| 503 | Plan lookup failed transiently | Inherited verbatim from `check_limit` |

## 5. Backend — handler algorithm

`src/core/qr/service.py::duplicate_qr`. Each step aborts cleanly before any durable write, except
where §7 says otherwise.

### Step 1 — Load

```python
res = (
    db.table("qr_codes")
      .select(SELECT_WITH_RELATIONS)
      .eq("id", str(qr_id))
      .eq("workspace_id", str(workspace_id))   # explicit: the service role bypasses RLS
      .maybe_single()
      .execute()
)
```

`maybe_single()` returns a **dict or `None`**, matching PostgREST — not a one-element list. `None`
→ 404.

The `.eq("workspace_id", …)` filter is the tenancy boundary and must be asserted in tests against
`FakeDB`'s operation journal, not against a mock (a `MagicMock` returns a truthy row whether or not
the filter is present, so the assertion passes with or without the thing that makes it true).

### Step 2 — Refuse holds

```python
from src.core.qr.status import is_staff_hold, UNCLAIMED_EXPIRED
if is_staff_hold(original["status"]):        # ('suspended',) today
    raise HTTPException(403, "A suspended QR cannot be duplicated.")
if original["status"] == UNCLAIMED_EXPIRED:
    raise HTTPException(403, "This QR has no owner yet.")
```

Using the constants rather than literals means a future hold status is covered without editing
this file. PRD §7.3 explains why the bypass matters.

### Step 3 — `max_qr`

`await check_limit(str(workspace_id), "max_qr", db)` when the original's `category == "dynamic"`,
with the identical `except HTTPException: raise` / `except Exception: → 503` structure the create
path uses. **Do not re-implement**; extract the create path's block into a small shared helper if
duplicating the try/except is unappealing, but keep the semantics byte-identical — the
fail-closed-but-retryable behaviour was a deliberate revenue-leak fix.

Static QRs skip this, exactly as create does.

### Step 4 — Entitlement re-check

Resolve the plan and apply the same `dynamic_qr_types` membership test the create path applies —
including its **fail-open on an empty list** (`if _allowed_types and qrType not in _allowed_types`).
That fail-open is deliberate and documented in `0027`'s header; do not "fix" it here.

`lead_form` is double-gated: membership **and** the `lead_forms` boolean. Apply both.

### Step 5 — Storage pre-flight

```python
files = original.get("qr_files") or []
total_bytes = sum(f.get("size_bytes") or 0 for f in files)
```

Compare the **largest single file** against `get_limit(workspace_id, "max_file_size_mb")` — the
limit is per-file, matching how `storage.py` enforces it on upload. Exceeded → 402 before any byte
is copied.

If `qr_files` carries no size column, fall back to a storage `list()` on the prefix; do **not**
skip the check silently.

### Step 6 — Copy storage objects

Pre-generate the new QR id so the destination prefix is known before `create_qr` runs:

```python
new_qr_id = uuid.uuid4()
```

For each source path `{workspace_id}/{original_id}/{rest}`, the destination is
`{workspace_id}/{new_qr_id}/{rest}` — preserving `rest` verbatim keeps PDF page-thumbnail naming
and menu image paths intact, which matters because `_validate_menu_image_path` checks the prefix.

**Use a server-side copy** (`db.storage.from_(bucket).copy(src, dst)`) rather than
download-then-upload. It avoids pulling a 50MB PDF through the API process and is the difference
between this endpoint fitting inside the client's 30s timeout and not (§8).

Hold `path_map: dict[str, str]` for step 7.

### Step 7 — Rebuild content

```python
content = _build_content_from_db_rows(
    files=original.get("qr_files"),
    qr_type=original.get("type"),
    vcard=_one(original.get("qr_vcard_details")),
    whatsapp=_one(original.get("qr_whatsapp_details")),
    wifi=..., email=..., sms=..., bitcoin=..., paypal=..., upi=...,
    link_page=_one(original.get("qr_link_pages")),
    business=..., location=..., social_media=..., event=..., coupon=...,
    apps=..., landing_page=...,
    destinations=original.get("qr_destinations"),
    lead_form=_one(original.get("qr_lead_forms")),
    review_funnel=_one(original.get("qr_review_funnel")),
    menu=_one(original.get("qr_menus")),
    menu_categories=original.get("qr_menu_categories"),
    db=db,
    include_thumbnails=False,
)
```

`include_thumbnails=False` deliberately: signing thumbnail URLs is a per-path Supabase round trip
and the copy's thumbnails are regenerated by the create path anyway. Signing them here would add
up to 12 network calls for output nobody reads.

Then **rewrite every storage path in `content` through `path_map`**. Paths appear in `files`, in
`business.logoPath`, and in menu item images; walk the model rather than string-replacing the
serialised JSON, so a path that happens to appear inside user text is not mangled.

`_build_content_from_db_rows` returns `None` when every relation is empty. For a QR with no
content that is legitimate — pass it through and let `create_qr`'s own validation decide.

### Step 8 — Name resolution

```python
base = (payload.name if payload else None) or f"{original['name']} (copy)"
```

Collision probe in **one** query:

```python
existing = (db.table("qr_codes").select("name")
              .eq("workspace_id", str(workspace_id))
              .like("name", f"{base}%").execute())
```

Then pick the first free of `base`, `f"{base[:-1]} 2)"`, … up to a ceiling of 50, falling back to
`base` unchanged. Never raise on collision — `qr_codes.name` has no unique constraint, so this is
readability, not correctness. One query, never N round trips.

### Step 9 — Create

Assemble `QRCodeCreate` and delegate:

```python
payload_create = QRCodeCreate(
    name=resolved_name,
    type=original["type"],
    category=original["category"],
    status="active",                       # PRD §5.4 — never inherited
    folder_id=(payload.folder_id if payload and payload.folder_id else original.get("folder_id")),
    custom_domain_id=verified_domain_id_or_none,   # PRD carry-over matrix, E4
    ab_enabled=original.get("ab_enabled"),
    destinations=[...],                    # target_url, weight, is_active, variant_key, label
    design=design_row.get("design"),
    content=content,
    page_design=design_row.get("page_design"),
    retargeting_mode=original.get("retargeting_mode"),
    pixel_ids=original.get("pixel_ids"),
    start_at=original.get("start_at"),
    end_at=original.get("end_at"),
    schedule_tz=original.get("schedule_tz"),
    daily_start=original.get("daily_start_time"),
    daily_end=original.get("daily_end_time"),
    daily_days=original.get("daily_days"),
    default_locale=original.get("default_locale"),
    locales=original.get("locales"),
    locale_autodetect=original.get("locale_autodetect"),
)
return await create_qr(workspace_id, payload_create, request, db, user_id, member)
```

**Note the column↔field name mismatches** — `daily_start_time` (column) → `daily_start` (field),
`daily_end_time` → `daily_end`. These are silent data-loss bugs if transcribed carelessly, and
they will not fail any type check. §16 holds the full mapping.

`is_password_protected` is absent from `QRCodeCreate` entirely, so the copy is unprotected by
construction rather than by remembering to omit it. Good — but assert it in a test anyway (§13).

### Step 10 — Side tables `create_qr` does not own

- **Tags** — insert `qr_tags` join rows for each of the original's tags.
- **Routing rules** — copy the rule set, repointed at `new_qr_id`.
- **Translations** — `qr_translations` rows per locale. **Verify first**: if `create_qr` already
  accepts translations in its payload, fold them into step 9 and delete this bullet. Two write
  paths for the same data is how translations drift.

Keep this list **short and commented**, one line per entry explaining why it is not covered by
`create_qr`. It is the only part of the feature that needs maintenance when a table is added.

### Step 11 — KV publish

```python
await run_in_threadpool(publish_qr, str(new_id), db)
```

`publish_qr`, never `sync_qr_to_kv`: it records `kv_sync_status` / `kv_attempt_count` /
`kv_next_attempt_at` / `kv_last_error` on the row and **never raises**, so a Cloudflare hiccup
leaves a flagged row the `/internal/kv-sweep` cron repairs rather than a 500 on a QR that was
otherwise created successfully.

`create_qr` may already publish. If so this step is a redundant second publish — verify and drop
it rather than shipping both; a double publish is harmless but confusing to trace.

**The `run_in_threadpool` wrapper is not optional.** These helpers are synchronous and blocking,
and `test_no_blocking_kv_call_survives_in_an_async_handler` walks the AST of every route module.
An unwrapped call fails CI, which is the intended outcome.

## 6. What is never copied — assert, do not assume

| Table | Reason |
|---|---|
| `qr_scan_events` | History |
| `qr_scan_counters` | History; and a copy inheriting counts corrupts billing |
| `qr_blocked_scans` | History |
| `qr_lead_submissions` | Other people's data, belonging to a different QR |
| `qr_link_click_events` | History |
| `qr_webhook_milestones` | Per-QR thresholds; a new QR has fired none |
| `qr_passwords` | Secret (PRD §7.2) |

Because Duplicate goes through `create_qr` and never writes these tables directly, the property
holds by construction. **Test it anyway** — the failure mode is silent and the blast radius
(billing, analytics, another customer's submitted data) is large enough that "it can't happen"
is not an adequate control.

## 7. Failure and compensation semantics

There are no transactions: the app talks to Supabase's PostgREST client, not an ORM. The create
route's own docstring already acknowledges this ("If a child insert fails the QR code row will
already exist"). Duplicate inherits that reality and must not pretend otherwise.

| Failure point | State left behind | Action |
|---|---|---|
| Steps 1–5 | None | Return the error. Clean. |
| Step 6 (storage copy) fails midway | Some copied objects under `{ws}/{new_id}/` | Delete them via `_remove_storage_objects(list(path_map.values()), db)` — best-effort, never raises — then return 500. |
| Step 9 (`create_qr`) fails | Copied objects, possibly a partial QR from `create_qr`'s own path | Delete the copied objects. Do **not** attempt to unwind `create_qr`'s partial writes: it owns its own failure behaviour and second-guessing it from outside is how a half-created QR becomes a deleted-wrong-QR incident. |
| Step 10 (side tables) fails | A **valid** QR missing tags/routing/translations | Return **201** with the QR. Log loudly. The user can see and fix it; deleting a QR they can already see because a tag insert failed is strictly worse. |
| Step 11 (publish) fails | A valid QR flagged `kv_sync_status != 'synced'` | Return 201. The sweep repairs it. This is exactly what `publish_qr` exists for. |

## 8. Performance

The expensive step is 6. Budget:

- Frontend `DEFAULT_TIMEOUT_MS` is **30s**, and this request is **not** FormData, so it does not
  get the request interceptor's `UPLOAD_TIMEOUT_MS` (120s) bump.
- A server-side storage `copy()` is a control-plane operation and should be sub-second per object
  regardless of size. **Measure it with a 50MB PDF** (the Agency `max_file_size_mb`) and a
  40-image `images` QR before shipping.
- If measurement shows headroom problems, the escape hatch is the one `usePrintExport` already
  uses: pass an explicit longer timeout on this one call. Do **not** raise `DEFAULT_TIMEOUT_MS`.

The rest — one relation read, one name query, `create_qr`'s inserts, one KV write — is the same
cost as an ordinary create, which is already an accepted latency.

## 9. Worker

**No change. No redeploy. No KV contract regeneration.** The copy is an ordinary KV entry under a
new short code, written by the same `sync_qr_to_kv` path as every other QR.

## 10. Frontend — hook

`src/hooks/useQRs.ts`, beside `useCreateQR`:

```ts
export function useDuplicateQR(workspaceId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { data } = await authApi.post<QRCode>(
        `/workspaces/${workspaceId}/qr-codes/${id}/duplicate`,
      );
      return data;
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: qrKeys.lists() });
      queryClient.invalidateQueries({ queryKey: qrKeys.counts(workspaceId) });
    },
  });
}
```

Invalidating **counts** as well as the list is not optional — the QR-count badge and the `max_qr`
usage meter both read it, and a stale count after a duplicate is the first thing a user near their
limit will notice.

Mutations never retry (the `providers.tsx` default), which is correct and load-bearing here: a
retried duplicate is a second QR and a second `max_qr` slot consumed.

## 11. Frontend — surfaces

**`MyQRCodes.tsx`** — add a `handleDuplicate` beside the existing `handleEdit` / `handleDeleteQR`,
and pass `onDuplicate` into `QRCodesTable` alongside the props it already receives (`onEdit`,
`onPreview`, `onViewDetails`, `onDelete`, `onMoveToFolder`).

```ts
const duplicateQR = useDuplicateQR(currentWorkspaceId || '');
const handleDuplicate = (id: string) =>
  duplicateQR.mutate(id, {
    onSuccess: (copy) => router.push(`/${slug}/qrs/${copy.id}`),
  });
```

**`components/org/qrs/components/QRCodesTable.tsx`** — the menu item, between Edit and
Move to folder, disabled with a spinner while `duplicateQR.isPending` and the pending id matches
the row (track the in-flight id, or the whole table greys out).

**`components/org/qrs/details/details-header.tsx`** — the same action in the header cluster,
using the `Copy` icon already imported in that file.

**Error handling** — the response interceptor already toasts by status code. Add only what it
cannot know: on 402, render the QR list's existing upgrade CTA rather than leaving the user with a
message and no next step.

**Types** — none. The response is `QRCodeResponse`, which the frontend already models as `QRCode`.

**House rules** — no new component exceeds 200 lines; the menu item is markup inside the existing
table component, not a new file. No inline styles, no `any`.

## 12. Observability

- Log one structured line at duplicate: `original_qr_id`, `new_qr_id`, `type`, `file_count`,
  `duration_ms`, and the outcome. The app emits one structured line per request via
  `RequestMiddleware`; this rides on that `request_id`.
- Count 402/403/503 by reason so PRD §11's "limit surfaces are unclear" metric is answerable
  without a database query.
- The storage-copy duration is the number worth graphing — it is the only part with an unbounded
  input size.

## 13. Tests

### 13.1 Backend unit — `tests/unit_tests/test_qr_duplicate.py`

Use `FakeDB` from `tests/fakes/`. It applies `.eq()` filters and **journals operation order**,
which a `MagicMock` cannot: a mock returns a truthy row whatever you ask it for, so a tenancy
assertion passes with or without the filter that makes it true.

**Happy path, one per type family** — the families differ structurally and a bug in one is invisible
in the others:

| Test | Family | Asserts |
|---|---|---|
| `test_duplicate_website_qr` | simple + destinations | content, destinations with weights and `variant_key` |
| `test_duplicate_pdf_qr` | file-backed | `qr_files` copied, storage paths rewritten to the new prefix |
| `test_duplicate_menu_qr` | nested | `qr_menus` + categories + items all present, item order preserved |
| `test_duplicate_review_funnel_qr` | detail-table + config | `qr_review_funnel` config copied, `qr_lead_submissions` **not** |
| `test_duplicate_vcard_plus_qr` | detail-table + page design | `page_design.templateId` identical |

**Guardrails:**
- `test_duplicate_at_max_qr_returns_402_and_writes_nothing` — assert **zero** inserts against the
  FakeDB journal, not against a mock call count.
- `test_duplicate_suspended_qr_returns_403` — zero inserts.
- `test_duplicate_unclaimed_expired_returns_403`.
- `test_duplicate_unentitled_type_returns_403` — a downgraded workspace with a `lead_form` QR.
- `test_duplicate_oversized_file_returns_402_before_copy` — no storage call is made.
- `test_duplicate_plan_lookup_error_returns_503` — not 402. The distinction is the revenue-leak fix.

**Carry-over and exclusion:**
- `test_copy_has_new_short_code` — different from the original, and non-empty.
- `test_copy_is_active_when_original_paused`.
- `test_copy_has_no_password` — `is_password_protected is False` **and** no `qr_passwords` insert
  appears in the journal.
- `test_copy_has_no_scan_history` — no insert touches `qr_scan_events`, `qr_scan_counters`,
  `qr_blocked_scans`, `qr_link_click_events`, `qr_webhook_milestones`, `qr_lead_submissions`.
- `test_copy_preserves_schedule_and_daily_window` — including the
  `daily_start_time` → `daily_start` mapping, which is the field most likely to be mis-transcribed.
- `test_copy_preserves_locales_and_translations`.
- `test_copy_drops_unverified_custom_domain` — copy created on the default domain, no 4xx.

**Tenancy:**
- `test_duplicate_cross_workspace_returns_404` — and the `.eq("workspace_id", …)` filter is
  present in the journal.

**Naming:**
- `test_duplicate_name_collision_increments` — `(copy)`, `(copy 2)`, `(copy 3)`.
- `test_duplicate_name_probe_is_one_query` — assert one `select` against `qr_codes.name`, not N.

**Compensation:**
- `test_storage_copy_failure_removes_partial_objects`.
- `test_side_table_failure_still_returns_201`.

### 13.2 Backend integration — `tests/integration_tests/test_qr_duplicate_api.py`

One end-to-end duplicate through the **real ASGI stack** via `async_client`, so the Bearer
middleware, dependency resolution and the response model are actually exercised.
`make_access_token()` mints the HS256 token the middleware verifies offline; inject state with
`use_fake_db(FakeDB({...}))`.

Plus `anonymous_client` → 401, proving the route was not accidentally added to `main.py`'s public
exclusion list.

**This must not need Postgres.** CI runs bare `pytest` with no database service, so a DB-backed
test *skips* there — and a skip is indistinguishable from a pass in a green run.

### 13.3 KV safety

Assert `publish_qr` is called for the **new** id and **not** for the original. `conftest.py`
installs a guard that fails any test reaching the real Cloudflare API, because the consequence is
CI issuing live DELETEs against the production KV namespace.

### 13.4 Frontend — Vitest

- The menu item renders in the row menu and calls the hook with the row's id.
- It is disabled and shows a spinner while pending, and only that row is affected.
- On success the router is pushed to `/{slug}/qrs/{newId}`.
- On 402 the upgrade CTA renders, not a bare toast.
- Query invalidation covers both the list key and the counts key.

## 14. Rollout

1. **Backend PR** — schema, route, `service.duplicate_qr`, tests. Inert: nothing calls it.
2. **Frontend PR** — hook, two surfaces, tests.

No migration, no Worker deploy, no KV contract regeneration, no plan-seed change, no
`FEATURE_ENFORCEMENT` edit. Independently revertable in either order.

**Pre-merge checklist**
- [ ] `_build_content_from_db_rows` audited against `SELECT_WITH_RELATIONS`; non-round-tripping
      fields recorded in §16.
- [ ] Storage copy measured at 50MB and at 40 images.
- [ ] `black`/`isort` run with **line-length 119** (bare `black` uses its 88-col default and
      reformats the world).
- [ ] `mypy src/` clean.

## 15. Risks

| Risk | Mitigation |
|---|---|
| `_build_content_from_db_rows` drops a field for some type | Pre-build audit (§16) + five per-family tests (§13.1). |
| Column↔field name mismatch loses the daily window silently | §16 mapping table + an explicit test. Type checking does not catch this. |
| Storage copy exceeds the 30s client timeout | Server-side `copy()`, measured; explicit per-call timeout as the escape hatch. |
| Duplicate becomes a downgrade-evasion hatch | Step 4 re-checks entitlement on every duplicate; tested. |
| A future `qr_*` table is added and Duplicate does not know about it | It is copied automatically if wired into `create_qr`. Only step 10's short list needs maintenance — keep it short and commented. |
| Partial failure deletes a QR the user can already see | §7: after `create_qr` succeeds, never unwind. Return 201 and log. |

## 16. Appendix — field mapping to audit before building

`qr_codes` column → `QRCodeCreate` field. **The mismatched rows are the dangerous ones**: they
produce silent data loss and no type error.

| `qr_codes` column | `QRCodeCreate` field | Note |
|---|---|---|
| `name` | `name` | Derived, §5 step 8 |
| `type`, `category` | `type`, `category` | |
| `status` | `status` | **Forced `"active"`, never copied** |
| `folder_id` | `folder_id` | |
| `custom_domain_id` | `custom_domain_id` | Conditional on `status='verified'` |
| `ab_enabled` | `ab_enabled` | Recomputed from destinations by create |
| `retargeting_mode` | `retargeting_mode` | |
| `pixel_ids` | `pixel_ids` | |
| `start_at` | `start_at` | |
| `end_at` | `end_at` | |
| `schedule_tz` | `schedule_tz` | |
| **`daily_start_time`** | **`daily_start`** | ⚠ **name differs** |
| **`daily_end_time`** | **`daily_end`** | ⚠ **name differs** |
| **`daily_days`** | **`daily_days`** | 0=Sun..6=Sat, matches the Worker's `DAY_INDEX` |
| `default_locale` | `default_locale` | |
| `locales` | `locales` | Includes the default; ≤6 by CHECK constraint |
| `locale_autodetect` | `locale_autodetect` | |
| `is_password_protected` | *(absent)* | Not a create field — the copy is unprotected by construction |
| `short_code` | *(absent)* | Minted by create |
| `kv_sync_status` + 4 siblings | *(absent)* | Owned by `publish_qr` |

Relations → `QRCodeCreate`:

| Relation (from `SELECT_WITH_RELATIONS`) | Destination |
|---|---|
| `qr_destinations(*)` | `destinations[]` — `target_url`, `weight`, `is_active`, `variant_key`, `label` |
| `qr_designs(*)` | `design` **and** `page_design` — one row, two fields |
| `qr_files(*)` | `content` (paths rewritten) |
| the 15 `*_details` relations | `content`, via `_build_content_from_db_rows` |
| `qr_link_pages(*, qr_link_items(*))` | `content.linkPage` |
| `qr_menus(*)`, `qr_menu_categories(*, qr_menu_items(*))` | `content.menu` |
| `qr_lead_forms(*)`, `qr_review_funnel(*)` | `content` |
| `qr_translations` | **Not in `SELECT_WITH_RELATIONS`** — separate read, step 10 |
| `qr_tags` | **Not in `SELECT_WITH_RELATIONS`** — separate read, step 10 |
| routing rules | **Not in `SELECT_WITH_RELATIONS`** — separate read, step 10 |
