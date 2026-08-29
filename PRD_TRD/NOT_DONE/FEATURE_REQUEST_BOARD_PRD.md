# PRD — Feature request board

**Status:** Draft (detailed) · **Author:** Product · **Date:** 2026-08-28
**Priority:** **Lowest of the 2026-08-28 batch. Read §2.4 before scheduling this.** The spec is complete and buildable; the *timing* is the open question, and launching it at the wrong moment is worse than not building it.
**Tiers:** **All plans, ungated** for reading and voting. Submission requires an authenticated, non-guest user (§8).
**Plan flags:** none new.
**Split from:** `support_tickets` (shipped, `0046`, with an admin surface at `admin/tickets.py`). A ticket is *"something is wrong for me"*; a request is *"something should exist for everyone"*. They look similar and behave completely differently — §10.
**Repos:** `qr_backend`, `qr_frontend`, `qr_admin`.

---

## 1. TL;DR / Summary

A board inside the dashboard where customers submit feature requests, vote on each other's, and see
status (`Open` → `Planned` → `In progress` → `Shipped` / `Declined`). Staff triage it from the
existing admin panel, beside tickets.

Requests are visible **across workspaces**. That is the entire point — seeing that fourteen other
people want the same thing is the value — and it is also the main design risk, because every other
table in this product is workspace-scoped (§7).

## 2. Problem & Motivation

### 2.1 Today, an idea has one route, into a queue built for problems

`support_tickets` has a `category` CHECK that includes `'feature'`, so feature requests already
arrive — as tickets, into a queue whose statuses are `open` / `pending` / `closed` and whose SLA
expectation is "something is broken". The mismatch is structural.

### 2.2 Four consequences

**Signal is invisible.** Ten workspaces asking for the same thing produce ten unrelated tickets.
Nobody — including us — can see they are the same request. There is no aggregation, because tickets
are not designed to aggregate.

**The customer gets nothing back.** No acknowledgement that the idea landed, no visibility when it
ships. The people who care most about the product get the least for telling us.

**We prioritise from our own inference.** `FUTURE_FEATURES.md` and
`docs-internal/competitive-feature-gap-analysis.md` are both *our* reading of the market — a
codebase audit and a competitor matrix. Neither is a customer saying what they want in their words.

**We cannot close the loop.** There is a `/changelog` page, but nothing connects a shipped feature
back to the person who asked for it. That message — "the thing you asked for is live" — is the
highest-value email a small SaaS can send, and we currently cannot send it.

### 2.3 What a board actually buys us

Not a feature list. **A ranked, attributable demand signal in customers' own words**, plus a
mechanism for telling them we listened. The second half is worth more than the first at our size.

### 2.4 ⚠ The honest objection: we may not have enough users yet

**Twelve real users, six of whom have never created a QR.**

A board with four requests and two votes reads as abandonware. An empty public board is **actively
worse than no board** — it advertises that nobody is asking for anything, to every prospect who
clicks it.

Two mitigations, either sufficient:

- **Seed it.** Launch with 15–20 real requests drawn from existing `support_tickets` rows with
  `category = 'feature'`, the dormant-user outreach replies, and the competitive gap analysis —
  each attributed to staff and **honestly labelled as staff-submitted**. Substance invites
  participation; emptiness repels it.
- **Gate the launch on a threshold.** Build it, hold it behind a flag, launch at ~50 active
  workspaces.

**Build the spec now; make the launch call from the number, not the calendar. Do not launch an
empty board.**

### 2.5 The prior question: buy or build

At our size, a hosted board (Canny, Featurebase, or even GitHub Discussions) is a link in the
sidebar and zero maintenance. The reasons to build are: branding, no separate login, and not
sending customer identities to a third party.

**That is a real trade and it must be made deliberately, before the TRD is executed** (§12 Q1).
This PRD assumes "build" because that is what was asked for; it does not assume that is right.

## 3. Goals & Non-Goals

### Goals

- **G1.** Authenticated users submit a request: title, description, optional category.
- **G2.** Anyone signed in can **upvote** — one vote per user per request, revocable.
- **G3.** Sort by votes / newest / recently updated; filter by status and category.
- **G4.** Staff set status and post an **official response**, visible on the request.
- **G5.** **Notify the requester and all voters on status change**, especially `Shipped`. This is
  the loop from §2.2; without it the board is a suggestion box.
- **G6.** Staff **merge duplicates**, carrying votes across without double-counting.
- **G7.** Triage from the **existing admin panel**, beside `admin/tickets.py` — not a second admin
  surface with its own auth story.
- **G8.** Duplicate suppression **at submit time** (§6), which is cheaper than merging afterwards.

### Non-Goals

- **NG1 — no public (unauthenticated) board in v1.** Cross-tenant visibility among paying customers
  is already the hard part (§7); a world-readable roadmap adds a competitive-intelligence decision
  on top of it.
- **NG2 — no comment threads in v1.** Votes plus an official response carry most of the signal, and
  threads bring a moderation load a team our size cannot service. Add later if asked for.
- **NG3 — no commitments and no dates, ever.** `Planned` is an intent, not a delivery date.
- **NG4 — no anonymous submissions.** Un-attributable requests cannot be followed up and are a spam
  vector.
- **NG5 — no replacement for support tickets.** Bugs stay in tickets. §10.
- **NG6 — no vote weighting by plan.** An Agency vote counting for five is commercially defensible
  and corrosive to the thing the board is for.

## 4. Personas & user stories

**Meera — agency, Agency plan**
> *I ask for Apple Wallet passes, see 14 other people want it, and get an email when it ships.*

**A prospect evaluating us**
> *An active board tells me the product is alive and that whoever builds it listens. That is worth
> more to me than the feature list.*

**Staff (us)**
> *I open the board sorted by votes and see demand ranked, in customers' own words, instead of
> inferring it from a competitor matrix.*

**Staff, again**
> *I merge six variants of "dark mode" into one request that holds all their votes.*

## 5. UX

### 5.1 Route and placement

`/[slug]/feedback`, inside `(dash)`, sidebar entry under Help.

### 5.2 List

One row per request: title · vote count with a vote control · status badge · category · requester's
display name · a response indicator. Sort and filter controls. A prominent **Submit a request**
action.

### 5.3 Detail

Full description, requester display name, date, vote control, the official staff response when
present, and a status timeline.

### 5.4 Submit

Title (≤120 chars), description (≤2,000), category from a fixed list.

**As the user types a title, show similar existing requests inline and let them vote on one
instead** (G8). This is the single most effective duplicate control there is, and it is far cheaper
than merging afterwards.

The **first** element in the form is the branch to support: *"Is something broken?"* → routes to
the existing contact/ticket flow (§10).

### 5.5 Status badges

| Status | Treatment | Note |
|---|---|---|
| `Open` | Neutral | |
| `Planned` | Primary (indigo) | Intent, **never a date** (NG3) |
| `In progress` | Tertiary (cyan) | |
| `Shipped` | Success, links to the changelog entry | Closes the loop |
| `Declined` | Muted, **always with a reason** | A silent decline is worse than no board |

### 5.6 Voting

One press, optimistic, revocable. Counts only — the vote roster is never public (§7).

## 6. Duplicate handling

Two layers:

1. **At submit time** — similar-request suggestions from a title search, with a vote control inline.
   Most duplicates never get created.
2. **Staff merge** — sets `merged_into_id`, transfers votes with `ON CONFLICT DO NOTHING` so a user
   who voted for both counts once, and recomputes both counts.

Duplicates are the default state of any board. Unmerged, it becomes unreadable within weeks.

## 7. Cross-tenant visibility — the load-bearing design decision

**Every other read path in this product is scoped by `workspace_id` because the service role
bypasses RLS. This one is deliberately not.** That inverts the project's usual discipline, so the
consequences must be decided explicitly rather than discovered:

| Decision | Choice | Reason |
|---|---|---|
| Requester identity shown | **Display name** (or email local-part) | Never the full email. **Never the workspace name** — a workspace name can identify a business to a competitor. |
| Requester's workspace | **Never returned to customers** | Staff-only column. |
| Vote roster | **Counts only** | "Who else wants this" is a customer-relationship question, not a board feature. |
| Request bodies | **User-authored, readable by every customer** | Customers will paste URLs, business names and occasionally customer data. One-line warning at the submit box; staff redact action. |
| Declined requests | **Stay visible, with the reason** | Hiding them makes the board look like a wishlist that only grows. |

**Correctness here comes from what is written into the row and what the serialiser returns — not
from a `WHERE` clause.** Say that in the code (TRD §1).

## 8. Anti-abuse

- Authenticated users only; **5 requests per user per day**, keyed on user rather than IP (the
  identity is authenticated, so IP adds nothing). Same shape as the existing lead-submission
  limiter (10/IP/hour).
- Votes de-duplicated by a **composite primary key** `(request_id, user_id)` — enforced in the
  schema, not in application code, because it is a race the database wins for free.
- Staff can hide/remove a request; hidden requests **keep their votes** so a merge is still
  possible afterwards.
- **Guest / anonymous accounts (`0051`) cannot submit or vote.** Their identity is a cookie and does
  not survive — the anon cookie is the only key, and that path has already produced one class of
  unrecoverable-identity bug. Votes keyed on a vanishing session are noise, not signal.

## 9. Success metrics

| Metric | Why | Healthy |
|---|---|---|
| Requests per week, **and share from distinct workspaces** | A board carried by two enthusiasts is not a signal | Distinct-workspace share high |
| Votes per request; distribution | A long tail of 1-vote requests means §6 is failing | Concentrated |
| **Time from `Open` to a staff status change** | The board's credibility *is* a response-time metric | Days, not months |
| Share of shipped features that originated on the board | The point of the exercise | Rising |
| Requests per user before vs after | Does it displace tickets, and is that good? | — |
| Board page views by prospects (pre-signup, if ever public) | §2.3's second-order value | — |

## 10. Board vs support ticket — they must not merge

| | Support ticket | Feature request |
|---|---|---|
| Question | "Something is wrong for me" | "Something should exist for everyone" |
| SLA | Urgent | Not urgent |
| Visibility | **Private** | **Cross-tenant** |
| Lifecycle | Opens → closes | Opens → ships |
| Content | **May contain data a request must never** | Public to all customers |
| Table | `support_tickets` + `support_ticket_messages` | `feature_requests` |

The submit form asks "Is something broken?" first and routes to support if so (§5.4). Separate
tables, separate endpoints, separate admin views. The privacy row is the one that makes merging
them unsafe, not merely untidy.

## 11. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **An empty board signals a dead product** | **High** | §2.4 — seed it, or gate the launch on a user-count threshold. This is a release gate, not a nice-to-have. |
| A customer pastes sensitive data into a world-readable description | High | One-line warning at the submit box; staff redact action; plain text with no rich embeds. |
| **Requests go unanswered and the board becomes evidence that we don't listen** | **High** | A board is a **commitment to triage**. Do not ship it without a named owner and a cadence. This is a process risk, and it is the most common way these fail. |
| The board becomes a roadmap customers hold us to | Medium | NG3 — no dates, ever. Say it in the status legend. |
| Duplicates make it unreadable | Medium | §6's two layers. |
| Competitors read our demand signal | Low | Accepted: customer-visible, not world-visible, in v1. Revisit before any public board. |
| Build cost exceeds the value at our scale | Medium | §2.5 / §12 Q1 — answer buy-vs-build first. |
| A cross-tenant leak of `author_workspace_id` | **High** | TRD §3.2 — explicit response models, and the leak test written first. |

## 12. Open questions

1. **Buy or build?** §2.5. **Answer this before the TRD is executed, not after.** The TRD assumes
   build.
2. **Notify on every status change, or only `Shipped` / `Declined`?** Over-notifying a board with
   slow-moving items trains people to ignore us. **Proposal:** `Shipped` and `Declined` always,
   `Planned` opt-in.
3. **Show the requester's name at all?** Anonymising raises submission rates and removes the
   follow-up loop. **Proposal:** show a display name, with a per-request opt-out.
4. **Does erasure remove a user's requests?** A 40-vote request cannot simply vanish because one
   person left. **Proposal:** null the author, keep the row, replace the display name — and check
   it against `ACCOUNT_DELETION_ERASURE`, which governs.
