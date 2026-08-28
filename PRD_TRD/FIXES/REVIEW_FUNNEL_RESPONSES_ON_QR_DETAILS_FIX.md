# FIX — Review-funnel responses are unreadable on the QR that collected them

**Status:** Draft · **Author:** Product/Eng · **Date:** 2026-08-28
**Type:** Defect + gap in a **shipped** feature (`GOOGLE_REVIEW_FUNNEL_QR_PRD.md`, DONE).
**Repos:** `qr_backend` (one gate), `qr_frontend` (one card). **Migration:** none. **Worker:** none.
**Plan flags:** no new flag. **One existing flag's blast radius is narrowed** — see §2.

---

## 1. What is wrong

### D1 — The QR detail page shows counts, never words

`ReviewFunnelCard` (`components/org/qrs/details/review-funnel-card.tsx`) renders on the
overview tab for `type === 'review_funnel'` and shows, from `useReviewFunnelStats`:

- the 1–5 star distribution,
- the Google-vs-feedback routing split,
- the feedback-form completion rate.

All aggregates. The **written feedback itself** — the reason the below-threshold arm exists —
is written to `qr_lead_submissions` by `internal.py`, and the only surface that reads that
table is `/[slug]/leads`. So the card tells an owner "7 people were routed to the feedback
form and 71% completed it" on the same screen where it refuses to show what any of the 7 said.
Reading them means leaving the QR, opening Leads, and re-selecting the QR from a dropdown.

### D2 — On Free and Starter, those responses are unreadable *anywhere* (the load-bearing bug)

The read path is gated on the wrong flag:

```python
# qr_backend/src/api/routes/lead_forms.py:95
if not await check_feature(str(workspace_id), "lead_forms", db):
    _require_lead_forms(str(workspace_id), db)   # 403 "Lead capture forms require a Pro or higher plan."
```

But `review_funnel` is not gated by `lead_forms`. It is a **type**, and:

- `0022_google_review_funnel.sql` appended `review_funnel` to Starter/Pro/Agency `dynamic_qr_types`;
- `0027_open_all_qr_types.sql` then gave free + starter all 13 creatable types, and states in
  its own header that `lead_form` — **not** `review_funnel` — is the one type that stays paid;
- `0039_replay_plan_flag_flips.sql` sets `lead_forms: false` on free/starter and `true` on Pro+.

Net effect: **a Free or Starter workspace can build a review funnel, publish it, collect
written customer complaints through it, and receive a 403 every time it tries to read them.**
The data accrues in `qr_lead_submissions` under their `workspace_id` and is invisible to them.
The frontend hides the failure well — `useLeads` has `retry: 1` and the Leads page renders an
error state — so this reads to the customer as "the feedback form is broken", not as a paywall.

This is worse than a missing feature. Service-recovery feedback is time-sensitive; a complaint
nobody can read for a month is a customer already lost. It is also the exact class of bug
recorded in `plan-flags-clobbered-by-0009` — a capability and its gate drifting apart across
migrations.

---

## 2. The fix

### 2.1 Backend — narrow the `lead_forms` gate to lead-form data (P0)

`lead_forms` should gate what it names: the **Lead Capture** product. Funnel feedback is output
of an ungated QR type and must be readable by whoever owns the QR.

In `list_leads` (and the same check in `/leads/export.csv`):

- When the request carries `qr_id` **and** that QR's `type == 'review_funnel'`, skip the
  `lead_forms` check. The `require_can_read` workspace-role dependency still applies, and the
  `workspace_id` filter is untouched, so this widens a *plan* gate, never a *tenancy* one.
- When no `qr_id` is given (the workspace-wide Leads list), keep the existing gate but return
  funnel-sourced rows to unentitled workspaces too, filtered to `qr_id IN (funnel QRs)`. If
  that read is judged too broad for v1, the acceptable minimum is: unentitled workspaces get a
  403 on the unfiltered list and a 200 on `?qr_id=<their funnel>`. State whichever is chosen in
  the docstring — this must not be re-derived from the code later.
- **`_require_lead_forms` currently ignores both its arguments and unconditionally raises.** It
  is a 403-message helper with a name that reads like a check. Rename it
  `_raise_lead_forms_403()` in the same commit; a future caller *will* misread it as a gate.

Register nothing new in `FEATURE_ENFORCEMENT` — `lead_forms` stays `enforced`, its scope just
becomes accurate. Update its comment to say what it now covers.

### 2.2 Frontend — responses on the QR detail page (D1)

New `components/org/qrs/details/review-funnel-responses-card.tsx`, mounted in
`overview-tab.tsx` immediately below the existing `ReviewFunnelCard`, guarded the same way
(`qr.type === 'review_funnel'`, mirroring `ABResultsCard`'s guard for `'website'`).

**No new endpoint and no new hook.** It calls the existing
`useLeads(workspaceId, { qrId: qr.id, limit: 5 })` → `GET /workspaces/{id}/leads?qr_id=…`,
which already accepts the filter.

Renders:

- the 5 most recent responses: submitted-at (relative), and each configured field's value from
  the `data` JSONB, longest text field given the most room;
- an empty state that distinguishes **"no one has left written feedback yet"** from
  **"nobody has been routed to the feedback form yet"** — the second is good news and the card
  should say so, using `routed_to_feedback` from the stats the sibling card already fetched;
- **"View all N responses"** → `/[slug]/leads?qr={id}`, and a CSV link reusing
  `downloadLeadsCsv(workspaceId, qr.id)`;
- on 403 (a workspace that somehow still fails the gate), an explicit upgrade message — never a
  bare error toast, which is what makes D2 read as breakage today.

### 2.3 Verify before building — the star rating may not be on the row

`qr_lead_submissions.data` holds only the funnel's configured feedback fields. The star rating
drives routing and the distribution chart, and there is no `stars` column on the table. **Check
whether the rating is persisted onto the submission row at all** before designing the card
around "3★ — 'the wait was long'".

Three outcomes, decide from evidence:

1. The rating is already in `data` under a known key → render it, no backend change.
2. The rating is only on the scan event / `reminder_contacts.stars` → either join on
   `session_id` (present on both `qr_lead_submissions` and the reminder contact) or ship the
   card without a star and file the join as a follow-up. **Do not invent a rating.**
3. Neither → the card shows text + timestamp only in v1, and adding a `stars` column becomes a
   separate one-line migration.

Whichever holds, write it into the card's docblock.

---

## 3. Tests

- **Backend, the P0:** a Free-plan workspace (`lead_forms: false`) owning a `review_funnel` QR
  gets **200** from `GET /leads?qr_id=<that QR>` and still gets **403** from
  `GET /leads?qr_id=<a lead_form QR>`. Use `FakeDB` — it applies `.eq()` filters, so the
  tenancy assertion is real; a `MagicMock` would pass with or without the `workspace_id` filter.
- **Backend, tenancy:** workspace B's funnel `qr_id` against workspace A's token → 404/403,
  never rows. This must not regress while the plan gate is widened.
- **Vitest:** the card renders only for `review_funnel`; renders response text; renders the
  "nobody routed here yet" state when `routed_to_feedback === 0`; renders the upgrade message
  on a 403 rather than a generic failure.

## 4. Rollout

Backend first, frontend second. Shipping the card against the un-widened gate would hand every
Free/Starter owner a permanent 403 box on their QR page — strictly worse than today's silence.
No migration, no Worker deploy, no KV rewrite; both changes are independently revertable.

## 5. Risk

| Risk | Mitigation |
|---|---|
| Widening the gate leaks lead-form rows to unentitled workspaces | The widening is keyed on the QR's `type`, resolved server-side from `qr_codes`, never from the request. A `lead_form` `qr_id` takes the unchanged path. |
| Owners on Free now see feedback they could not see before and read it as a new feature | It is one. Say so in the changelog; do not describe it as a fix, and do not quietly backfill-notify — a month of unread complaints arriving as one email digest is its own incident. |
| The responses card double-fetches what Leads already caches | Same query key factory (`leadKeys.list`), so TanStack dedupes the QR-filtered read across both surfaces. |
