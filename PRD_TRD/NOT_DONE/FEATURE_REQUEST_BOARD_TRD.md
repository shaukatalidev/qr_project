# TRD — Feature request board

**Spec:** `FEATURE_REQUEST_BOARD_PRD.md` · **Status:** Draft (detailed) · **Date:** 2026-08-28
**Migration slot (RESERVATION):** `0058_feature_request_board.sql`. Highest on disk when written: `0054`. **`ls qr_backend/migrations/` and take the next free integer; re-confirm the highest APPLIED number in the DB.**
**Repos:** `qr_backend`, `qr_frontend`, `qr_admin`. **Worker:** no change. **KV:** untouched.
**New plan flags:** none.
**⚠ Precondition:** PRD §12 Q1 (**buy vs build**) answered "build". Do not execute this otherwise.

---

## 1. Architecture

Three tables, one customer router, one admin router, one dashboard surface. The only structurally
novel thing is **deliberate cross-tenancy**, and it needs a comment at the top of the router:

```python
"""
Feature request board — the ONE router in this codebase that is deliberately cross-tenant.

Every other read path filters `.eq("workspace_id", ...)` because the backend uses the Supabase
service role and bypasses RLS. This one does not, ON PURPOSE: the product value is seeing that
other workspaces want the same thing.

Correctness therefore depends on WHAT IS WRITTEN INTO THE ROW and WHAT THE SERIALISER RETURNS,
not on a filter at read time. `author_workspace_id` is staff-only and must never appear in a
customer response. Do not "fix" the missing tenant filter, and do not copy this router as a
template for anything that needs one.
"""
```

That paragraph is load-bearing. Without it, the first reviewer who notices the missing
`workspace_id` filter will either add one (breaking the feature) or copy this file as a pattern
(breaking something else).

## 2. Migration `0058`

```sql
-- Migration 0058: feature request board.
--
-- Sibling to support_tickets (0046), NOT a replacement — see the PRD's §10 table. Different
-- SLA, different visibility, different lifecycle, and crucially a different privacy posture:
-- a ticket may contain data a request must never.
--
-- Idempotent; safe to re-run. Re-confirm the highest APPLIED migration first.

BEGIN;

CREATE TABLE IF NOT EXISTS feature_requests (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),

    title         text        NOT NULL,
    description   text        NOT NULL,
    category      text,
    status        text        NOT NULL DEFAULT 'open',

    -- Nullable, NO FK — matching support_tickets.user_id and admin_audit_log.actor_user_id.
    -- account_purge enumerates the tables it clears; an unknown FK is how it fails (the
    -- guest-transfer work hit exactly this with created_by).
    author_user_id      uuid,
    -- Denormalised so a 40-vote request survives its author's account deletion, and so
    -- rendering never requires enumerating users the reader may not be entitled to see.
    author_display      text,
    -- STAFF ONLY. Never returned to a customer. See the router docstring and §3.2.
    author_workspace_id uuid,

    staff_response      text,
    staff_response_at   timestamptz,

    merged_into_id uuid REFERENCES feature_requests(id) ON DELETE SET NULL,
    is_hidden      boolean NOT NULL DEFAULT false,

    -- Denormalised for the votes-sorted index. Kept in step with the rows by §3.3.
    vote_count     integer NOT NULL DEFAULT 0,

    created_at     timestamptz NOT NULL DEFAULT now(),
    updated_at     timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT feature_requests_status_chk CHECK (
        status = ANY (ARRAY['open','planned','in_progress','shipped','declined'])
    ),
    CONSTRAINT feature_requests_title_len_chk       CHECK (char_length(title) BETWEEN 1 AND 120),
    CONSTRAINT feature_requests_description_len_chk CHECK (char_length(description) BETWEEN 1 AND 2000),
    CONSTRAINT feature_requests_vote_count_nonneg   CHECK (vote_count >= 0),
    -- A decline without a reason is worse than no board (PRD §5.5).
    CONSTRAINT feature_requests_declined_has_reason_chk CHECK (
        status <> 'declined' OR (staff_response IS NOT NULL AND char_length(staff_response) > 0)
    ),
    CONSTRAINT feature_requests_no_self_merge_chk CHECK (merged_into_id IS DISTINCT FROM id)
);

-- One vote per user per request, enforced in the SCHEMA. Doing it in application code is a
-- race the database wins for free.
CREATE TABLE IF NOT EXISTS feature_request_votes (
    request_id uuid        NOT NULL REFERENCES feature_requests(id) ON DELETE CASCADE,
    user_id    uuid        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (request_id, user_id)
);

CREATE TABLE IF NOT EXISTS feature_request_status_events (
    id            uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    request_id    uuid        NOT NULL REFERENCES feature_requests(id) ON DELETE CASCADE,
    from_status   text,
    to_status     text        NOT NULL,
    note          text,
    actor_user_id uuid,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_feature_requests_votes
    ON feature_requests (vote_count DESC)
    WHERE NOT is_hidden AND merged_into_id IS NULL;
CREATE INDEX IF NOT EXISTS idx_feature_requests_status
    ON feature_requests (status, created_at DESC) WHERE NOT is_hidden;
CREATE INDEX IF NOT EXISTS idx_feature_requests_author
    ON feature_requests (author_user_id);
CREATE INDEX IF NOT EXISTS idx_feature_request_votes_user
    ON feature_request_votes (user_id);

ALTER TABLE feature_requests              ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_request_votes         ENABLE ROW LEVEL SECURITY;
ALTER TABLE feature_request_status_events ENABLE ROW LEVEL SECURITY;

COMMIT;
```

**Deliberately not append-only**, unlike `admin_audit_log` and the change-history table. Staff must
be able to edit a response, hide spam and merge duplicates, and PRD §12 Q4 requires erasure to be
able to null an author. An append-only trigger here would make all four impossible.

### 2.1 `account_purge` must learn about these tables — in the same PR

`account_purge.py` maintains explicit lists (`_QR_CHILD_TABLES`, `_WORKSPACE_SCOPED_TABLES`,
`_USER_SCOPED_TABLES`, `_NEVER_DELETE`). Decide and implement:

- **`feature_request_votes`** → delete by `user_id`. A vote is personal data with no retention basis.
- **`feature_requests`** → **do not delete.** Null `author_user_id`, and set `author_display` to a
  neutral string (PRD §12 Q4). A 40-vote request must not vanish because one person left; the
  identity goes, the request stays. This mirrors how `subscriptions` are *pseudonymised* rather
  than deleted, and it needs the same explicit comment stating the basis.
- **`feature_request_status_events.actor_user_id`** → null where it is the erased user.

Because these are pseudonymisation rather than deletion, they need their **own step** in the purge,
not a line in `_USER_SCOPED_TABLES`. Check the choice against `ACCOUNT_DELETION_ERASURE` before
implementing — that spec governs.

## 3. Backend

### 3.1 Customer router — `src/api/routes/feedback.py`

Mounted under `API_PREFIX` (`/api`, **not** `/api/v1`). **Authenticated** — it must **not** be added
to `main.py`'s middleware exclusion list, and a test asserts that (§7.2).

| Method | Path | Notes |
|---|---|---|
| `GET` | `/api/feedback/requests` | `sort=votes\|new\|updated`, `status=`, `category=`, `limit`/`offset`. Excludes `is_hidden` and rows with `merged_into_id`. |
| `GET` | `/api/feedback/requests/{id}` | Detail + status events |
| `GET` | `/api/feedback/requests/similar?q=` | Title search for the submit-time duplicate check (PRD G8) |
| `POST` | `/api/feedback/requests` | Rate-limited (§3.4) |
| `POST` | `/api/feedback/requests/{id}/vote` | **Idempotent** |
| `DELETE` | `/api/feedback/requests/{id}/vote` | **Idempotent** |

Idempotent votes matter: the frontend votes optimistically, and a double-fire must not 500.

### 3.2 ⚠ What must never reach a customer response

**`author_workspace_id`, the author's email, and the vote roster.**

Serialise through an **explicit Pydantic response model that names its fields**. Never
`select("*")` into a response. This table holds exactly one staff-only column, and a `select("*")`
leak is the whole cross-tenant risk realised in a single line — a competitor learning which
business asked for what.

```python
class FeatureRequestPublic(BaseModel):
    id: uuid.UUID
    title: str
    description: str
    category: str | None
    status: str
    author_display: str | None      # never author_workspace_id, never an email
    vote_count: int
    has_voted: bool                 # for THIS user only, computed per request
    staff_response: str | None
    created_at: datetime
```

`author_display` is derived at **create** time (display name, else email local-part — never the
full address, never the workspace name) and stored. Deriving at read time would require reading
user records the requester should not be able to enumerate.

### 3.3 Vote counting — do it in the database

`vote_count` is denormalised for `idx_feature_requests_votes`. **On a board, a wrong number is the
whole product**, so it must not be able to drift from the rows.

The cautionary precedent is in this codebase already: `qr_scan_counters` has a known non-atomic
write path. Do not repeat it.

Use a Postgres function (or triggers on `feature_request_votes`) so the insert/delete and the
counter move together:

```sql
CREATE OR REPLACE FUNCTION feature_request_vote(p_request_id uuid, p_user_id uuid)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE v_count integer;
BEGIN
    INSERT INTO feature_request_votes (request_id, user_id)
    VALUES (p_request_id, p_user_id)
    ON CONFLICT DO NOTHING;                       -- idempotent
    UPDATE feature_requests
       SET vote_count = (SELECT count(*) FROM feature_request_votes WHERE request_id = p_request_id),
           updated_at = now()
     WHERE id = p_request_id
    RETURNING vote_count INTO v_count;
    RETURN v_count;
END; $$;
```

Recomputing with `count(*)` rather than `vote_count + 1` makes the function **self-healing**: any
historical drift corrects on the next vote. Add a staff-runnable reconciliation query too.

**Merge** transfers votes:

```sql
INSERT INTO feature_request_votes (request_id, user_id)
SELECT p_target_id, user_id FROM feature_request_votes WHERE request_id = p_source_id
ON CONFLICT DO NOTHING;                            -- a user who voted for both counts once
UPDATE feature_requests SET merged_into_id = p_target_id WHERE id = p_source_id;
-- then recompute both counts
```

### 3.4 Rate limiting and guest refusal

5 requests per user per 24h:

```python
res = (db.table("feature_requests").select("id", count="exact")
         .eq("author_user_id", user_id)
         .gte("created_at", one_day_ago).execute())
if (res.count or 0) >= 5:
    raise HTTPException(429, "You've reached today's limit of 5 feature requests.")
```

Same shape as the existing lead-submission limiter (10/IP/hour), but keyed on **user** — the
identity is authenticated, so IP adds nothing and would only punish shared offices.

**Guest accounts (`0051`) → 403** on submit *and* vote (PRD §8). Their identity is a cookie that
does not survive; the guest path has already produced one class of unrecoverable-identity bug, and
votes keyed on a vanishing session are noise.

### 3.5 Admin router — `src/api/routes/admin/feedback.py`

Beside `admin/tickets.py`, under the existing `/admin` prefix and its `require_platform_admin`
guard. Endpoints: list (including hidden and merged), set status (+ note), post/edit response,
hide/unhide, merge.

Every action writes `admin_audit_log` via `record_admin_action(db, actor=..., action="feature_request.update", ...)`,
matching the dotted-verb convention (`plan.update`, `qr.suspend`).

`author_workspace_id` is visible **here and only here**.

### 3.6 Notifications

Reuse `src/utilities/email.py` (Resend). On a transition to `shipped` or `declined`, email the
author and all voters — **as a FastAPI background task**, never in the request path, and batched.

> ⚠ **A 200-voter `shipped` email is 200 sends.** Check it against the Resend plan and the existing
> DMARC posture before enabling. If either is unresolved, **ship the board with notifications off
> behind a flag** and turn them on deliberately. A half-delivered "we shipped it" is worse than
> silence, because the half who did not receive it are the ones who will notice.

## 4. Frontend — `qr_frontend`

| File | Responsibility |
|---|---|
| `app/[slug]/(dash)/feedback/page.tsx` | Composition only |
| `components/org/feedback/request-list.tsx` | List + sort/filter |
| `components/org/feedback/request-row.tsx` | One row |
| `components/org/feedback/request-detail.tsx` | Detail + status timeline |
| `components/org/feedback/submit-request-modal.tsx` | RHF + zod; the "Is something broken?" branch first |
| `components/org/feedback/similar-requests.tsx` | Debounced `similar?q=` results, votable inline |
| `components/org/feedback/vote-button.tsx` | Optimistic, revocable |
| `components/org/feedback/status-badge.tsx` | PRD §5.5 treatments |
| `hooks/useFeatureRequests.ts` | Queries + mutations, own key factory following `qrKeys` |

**Optimistic voting** with rollback on error. Mutations never retry (the `providers.tsx` default),
which is correct: the vote endpoints are idempotent, but a retried **create** is a duplicate request.

Validation: `title` ≤120, `description` ≤2,000, category from a fixed list — matching the DB CHECKs
so the two cannot disagree.

Sidebar entry under Help. All components under 200 lines, one export per file, kebab-case,
no `any`, no inline styles.

## 5. Admin — `qr_admin` (separate repo)

A Feedback view beside Tickets: all requests including hidden and merged; `author_workspace_id`
shown here only; status control with a **required note on `declined`** (mirroring the DB CHECK);
response editor; hide/unhide; merge with a target picker showing vote counts for both sides.

## 6. Seeding (PRD §2.4) — a release gate, not a chore

Before any customer sees the route:

1. Query `support_tickets WHERE category = 'feature'` and convert the real ones.
2. Add entries from the dormant-user outreach replies and
   `docs-internal/competitive-feature-gap-analysis.md`.
3. Target **15–20** requests, each with `author_display` set to a staff label and **honestly
   presented as staff-submitted** — do not fabricate customer attribution.
4. Set realistic statuses: some `planned`, some `shipped` linking to real changelog entries. A board
   where nothing has ever shipped is only marginally better than an empty one.

## 7. Tests

### 7.1 The leak test — write this first

```python
def test_customer_response_never_contains_author_workspace_id():
```

Assert on the **serialised payload** of both the list and the detail endpoints — not on the model,
not on a field list — that `author_workspace_id`, any email, and any vote roster are absent. This
is the one failure in this feature that is a privacy incident rather than a bug.

### 7.2 Backend unit (`FakeDB` — applies `.eq()` filters and journals operation order)

- Double vote → one row, `vote_count == 1`.
- Unvote is idempotent; unvoting something never voted is a no-op, not a 500.
- Hidden and merged requests absent from the list.
- Merge transfers votes without double-counting a user who voted for both.
- `vote_count` equals `COUNT(votes)` after a **randomised** vote/unvote/merge sequence — the
  self-healing property in §3.3.
- 6th request in 24h → 429.
- A guest account → 403 on submit **and** on vote.
- Status change writes a `feature_request_status_events` row.
- `declined` with no note → rejected (application **and** DB CHECK).
- Title of 121 chars → 422.

### 7.3 Integration

- One authenticated end-to-end submit + vote through the real ASGI stack (`async_client`,
  `make_access_token()`, `use_fake_db`).
- **`anonymous_client` → 401**, proving the router was not added to the public exclusion list.

**Must need no Postgres.** CI runs bare `pytest` with no database service, so a DB-backed test
*skips* there — and a skip is indistinguishable from a pass in a green run.

### 7.4 Migration / purge

- The purge nulls `author_user_id` and `author_display` and **keeps the request row and its votes
  from other users** (§2.1).
- The purge deletes the erased user's own votes and the counts recompute.
- **A full `account_purge` run completes** with feature-request rows present. This is the check that
  catches the class of failure `_NEVER_DELETE`'s `admin_audit_log` comment describes — a table the
  purge cannot touch stalls the whole run.

### 7.5 Vitest

- Optimistic vote rolls back on error.
- Similar requests appear while typing and are votable inline.
- The "Is something broken?" branch is the first element of the form.
- `declined` renders its reason.

## 8. Rollout

1. **Answer buy vs build** (PRD §12 Q1).
2. Apply `0058`; **add the purge handling in the same PR** (§2.1).
3. Backend + admin, **notifications off**.
4. **Seed 15–20 real requests** (§6) — release gate.
5. Frontend.
6. Enable notifications once the Resend volume and DMARC questions are settled (§3.6).

**Do not launch an empty board.**

## 9. Risks

| Risk | Mitigation |
|---|---|
| **`select("*")` leaks `author_workspace_id` cross-tenant** | Explicit response models + §7.1 written first. A privacy incident, not a bug. |
| A reviewer "fixes" the missing tenant filter | The §1 docstring, verbatim, at the top of the router. |
| `vote_count` drifts from the rows | DB-side counting that recomputes with `count(*)` (self-healing) + the randomised-sequence test. |
| `account_purge` breaks or stalls on the new tables | §2.1 in the same PR + the §7.4 full-run test. The guest-transfer work produced this exact failure once. |
| A `shipped` fan-out trips Resend limits or DMARC | Notifications behind a flag, batched, background, enabled deliberately. |
| The board launches empty | §6 is a release gate. |
| Nobody triages it | PRD §11 — a named owner and a cadence, or do not ship. This is the most common way these fail and no amount of engineering fixes it. |
