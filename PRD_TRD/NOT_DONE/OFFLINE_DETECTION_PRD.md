# PRD — Offline detection

**Status:** Draft (detailed) · **Author:** Product · **Date:** 2026-08-28
**Priority:** Data-loss prevention and latency honesty, not a nicety. The QR builder is a four-step wizard holding unsaved state, and today a dropped connection at step 4 is indistinguishable from a server rejection.
**Tiers:** **All plans, ungated.** No COGS and no comparison-table value — it is table stakes for an app used on Indian mobile networks.
**Plan flags:** none.
**Split from:** the Axios layer (`src/lib/api-client.ts`) and the builder (`app/[slug]/(builder)/build/page.tsx`). **Not** a PWA or offline-first rewrite — see NG1.
**Repos:** `qr_frontend` only. No backend change, no Worker change, no migration, no service worker, no third-party script.

---

## 1. TL;DR / Summary

The app learns three things it currently does not know:

1. **the browser is offline** (`navigator.onLine === false`);
2. **the backend is unreachable** even though the browser believes it is online — a captive
   portal, a DNS failure, or an actual outage;
3. **the connection just came back**.

It responds with a persistent status bar, mutating actions disabled **with a stated reason**,
preserved builder state on a network-classified failure, a fast client-side failure instead of a
multi-minute wait, and an automatic refetch of active queries on recovery.

**`navigator.onLine` appears nowhere in the codebase today.** There is no offline handling to
improve; there is none.

## 2. Problem & Motivation

### 2.1 A network failure and a rejected payload look identical

`api-client.ts`'s response interceptor classifies transport failures precisely and correctly:

```ts
const isTransportFailure = error.code === 'ECONNABORTED' || !error.response;
const isSafeMethod = method === 'get' || method === 'head' || method === 'options';
```

and it retries **only safe methods**, deliberately: *"Retrying a POST can create a second QR code
or, on the billing routes, submit a second charge — the request may well have reached the server
and only the response been lost."* That reasoning is right and this PRD does not touch it.

The consequence is that an offline **save** fails once and surfaces as a generic toast. The
classification exists in the interceptor and is then **thrown away** — nothing downstream can tell
the two cases apart:

- **"The server rejected your data"** → the user should fix the form.
- **"Your network died"** → the user should wait and press save again, and the app should still be
  holding their work.

The user's rational response to the first — start over — destroys their work in the second.

### 2.2 The wait before the failure is the bigger surprise

The retry layers compose, and nobody has multiplied them out. For a **GET** on a *hung* connection
(`ECONNABORTED`, the timeout path — not a fast connection-refused):

| Layer | Behaviour | Elapsed |
|---|---|---|
| Interceptor attempt 1 | 30s timeout (`DEFAULT_TIMEOUT_MS`) | 30s |
| backoff `1000 * 2**0` | 1s | 31s |
| attempt 2 | 30s | 61s |
| backoff `1000 * 2**1` | 2s | 63s |
| attempt 3 | 30s | 93s |
| backoff `1000 * 2**2` | 4s | 97s |
| attempt 4 | 30s | **127s** — interceptor gives up (`MAX_TRANSPORT_RETRIES = 3`) |

TanStack then retries the query up to twice more (`retry: failureCount < 2` in `providers.tsx`,
which correctly excludes 4xx but not transport failures), each retry re-entering the full
interceptor cycle:

> **Worst case ≈ 3 × 127s ≈ 6 minutes 20 seconds of spinner before a user sees an error.**

Each layer is individually well-reasoned. The product of the two has never been stated. On a
connection we already know is dead, every second of that is waste.

For **uploads** it is worse in a different way: FormData requests are bumped to
`UPLOAD_TIMEOUT_MS` (120s) by the request interceptor, and uploads are POSTs so they are not
retried — but a user who hits Save on a file QR while offline waits **two minutes** for a failure
that was knowable immediately.

### 2.3 The history behind this

`DEFAULT_TIMEOUT_MS` was `0` — no timeout at all — until 2026-08-16. A hung connection never
rejected, so the response interceptor never ran, so there was no toast and no error state: just a
spinner forever. That explains a whole class of historic bug reports. Fixing the timeout converted
"forever" into "up to six minutes, then an unexplained failure". This feature is the other half of
that fix.

### 2.4 The audience makes it routine, not exceptional

The primary market is Indian SMBs on mobile networks. A 30-second tunnel, a lift, or a patchy
café connection is a normal Tuesday, not an edge case.

### 2.5 A secondary cost: Sentry noise

`providers.tsx` reports query failures to Sentry, filtering out 4xx (correctly — *"a 403 or 404 is
the backend enforcing a rule, not the frontend breaking"*). Transport failures are **not** filtered,
so one user on a train generates a burst of Sentry exceptions that are not bugs. Knowing the
session is offline lets us stop reporting them, which is worth doing while we are here.

## 3. Goals & Non-Goals

### Goals

- **G1.** Detect and expose three states: `online`, `offline` (browser-reported), `unreachable`
  (backend not answering despite the browser claiming connectivity).
- **G2.** A persistent, non-blocking status bar while degraded — **not** a toast, which scrolls
  away and is the wrong shape for a condition that persists.
- **G3.** **Preserve in-flight builder work.** A save that fails for network reasons leaves the
  wizard exactly as it was, on the same step, with every field and file selection intact, and a
  Retry affordance.
- **G4.** **Fail fast when we already know.** If the connection is known-dead at submit time, fail
  client-side immediately rather than starting a request that will take up to two minutes to
  disappoint (§2.2).
- **G5.** **Disable-with-explanation**, never disable-silently. Every disabled mutating control
  states why and re-enables on reconnect.
- **G6.** Refetch **active** queries on recovery, so a returning user sees truth rather than a
  cache from before the outage.
- **G7.** Distinguish network failure from server rejection **in copy**, everywhere both can occur.
- **G8.** Suppress Sentry reporting of transport failures while degraded (§2.5).

### Non-Goals

- **NG1 — no offline-first, PWA, or service worker.** No caching QR assets for offline use, no
  background sync, no installability. That is a different product with a cache-invalidation
  problem attached, and it would need its own spec and its own QA surface.
- **NG2 — no offline mutation queue.** Replaying a queued QR create on reconnect is precisely the
  duplicate-POST hazard the interceptor is designed around (§2.1). Preserve the state; let the
  human press Retry. Revisit only with idempotency keys, which do not exist.
- **NG3 — no change to the scan landing pages.** A scanner with no network never reaches the
  Worker; there is nothing to detect and no page to show.
- **NG4 — no optimistic offline editing.** Nothing pretends to have saved.
- **NG5 — no change to the retry policy itself.** This feature *observes and communicates* what the
  interceptor already decides. G4's fast-fail is a pre-flight gate, not a change to retry rules.
- **NG6 — no draft autosave to `localStorage`.** It solves a superset (tab crash, accidental close)
  and carries its own staleness and PII questions. §11 Q3.

## 4. Personas & user stories

**Ravi — SMB owner, building a menu QR on a train, Starter plan**
> *My connection drops at step 4. A bar tells me I'm offline; Save is disabled and says why. When
> signal returns the bar says "Back online", my six menu categories are still there, and I save.*

**Meera — marketer, office WiFi up, backend having an outage**
> *The app says "Can't reach Qravio", not "check your internet". I don't spend ten minutes
> rebooting a router that is working fine.*

**Arun — returning after his laptop slept**
> *The dashboard refetches instead of showing me numbers from before lunch.*

**Priya — uploading a 20MB PDF on a bad connection**
> *I get told immediately that I'm offline, instead of watching a progress bar for two minutes.*

## 5. UX

### 5.1 Status bar

Fixed, directly below the header, full width, `surface-container` background with the warning
accent. **Never a modal. Never blocking.**

| State | Copy | Actions |
|---|---|---|
| `offline` | **"You're offline. Changes won't save until you reconnect."** | none |
| `unreachable` | **"Can't reach Qravio. Retrying…"** | **Retry** |
| recovered | **"Back online."** | auto-dismisses after ~4s |

The recovered state is not decoration: the user needs an affirmative signal that it is safe to
press Save. A bar that silently vanishes leaves them guessing.

### 5.2 Controls while degraded

- **Disabled:** Save, Create, Publish, Delete, Duplicate, and every billing action.
- **Enabled:** all navigation and reads. Cached pages remain useful, and blocking navigation turns
  an inconvenience into a perceived crash.
- Every disabled control carries a tooltip with the same sentence, sourced from one place so the
  wording cannot drift between twenty call sites.

### 5.3 Builder behaviour (the core of the feature)

On a **network-classified** save failure:

- stay on the current step;
- keep every field, including the selected file — a cleared file input is the single most
  infuriating loss, because re-selecting requires the file picker again;
- render an inline banner above the primary action: *"Couldn't save — you appear to be offline.
  Your work is still here."* with **Retry**;
- **never** navigate, never reset, never toast-and-forget.

On a **server rejection** (4xx/5xx with a response): existing behaviour — field errors or the
status-coded toast. Unchanged.

### 5.4 Copy discipline

One rule, applied everywhere both outcomes are possible:

> **If we did not reach the server, never blame the user's input. If we reached it and it said no,
> never blame the network.**

## 6. Behaviour & detection

Three signals, combined:

**Signal 1 — `navigator.onLine` plus the `online`/`offline` window events.** Instant and free, but
trustworthy in exactly one direction: `false` reliably means offline; `true` only means an
interface is up, which a captive portal also satisfies. Use it as a shortcut, never as the definition.

**Signal 2 — request outcomes (authoritative).** The interceptor already computes
`isTransportFailure` exactly. **Two consecutive failed requests** — counted *after* the
interceptor's own retries are exhausted, not per attempt — means `unreachable`, whatever
`navigator.onLine` claims. Any successful response resets the counter to zero.

Counting exhausted requests rather than attempts matters: a single offline GET already produces
four attempts internally, so per-attempt counting would trip on one request and make the "two
consecutive" threshold meaningless.

**Signal 3 — a liveness probe on recovery.** One `GET /api/health` before declaring `online`.
`/api/health` is on the middleware's public-path exclusion list, so it needs no Bearer token and
cannot fail for authentication reasons. Short, explicit timeout — the probe must not inherit the
30s default it exists to short-circuit.

**Recovery** clears the degraded state and refetches active queries.

## 7. Gating

None. An app that loses your work on a bad connection is not a premium tier.

## 8. Metrics

| Metric | Why | Healthy |
|---|---|---|
| Sessions entering a degraded state; median duration | Baseline frequency | — |
| Recovery rate (degraded → online in-session) | Does the probe actually clear? | High |
| **False-positive rate** — degraded states with no subsequent failed request | A bar that cries wolf is its own failure | Near zero; this decides the two-failure threshold |
| Builder saves failing with a network classification, and the share retried successfully | The core promise | Retry success high |
| Time-to-error on a failed save, before vs after | §2.2 is the motivating number | Seconds, not minutes |
| "Lost my work" / "didn't save" tickets | | Falling |
| Sentry transport-failure volume | §2.5 | Falling |

## 9. Edge cases

| # | Case | Behaviour |
|---|---|---|
| E1 | Tab restored already offline (no event fires) | Read `navigator.onLine` on mount. Events alone are not enough. |
| E2 | Captive portal — `onLine === true`, all requests fail | Signal 2 wins → `unreachable`. This is the case Signal 1 cannot see. |
| E3 | Backend down, user's network fine | `unreachable`, with the "Can't reach Qravio" copy. Never "check your internet". |
| E4 | One blip, next request succeeds | No degraded state — the counter resets on success. |
| E5 | The probe itself fails | Stay degraded; do **not** increment the failure counter from the probe (§10 recursion risk). |
| E6 | Reconnect with 12 active queries mounted (analytics) | Refetch **active** only; TanStack dedupes. |
| E7 | A 500 while online | **Not** a transport failure — `error.response` exists. No degraded state. A broken server is not a broken network. |
| E8 | Upload in flight when the connection drops | The 120s upload timeout still applies to the in-flight request; the *next* submit fails fast (G4). |
| E9 | Offline on a marketing or auth page | The bar is not mounted there — no api-client, nothing to say. |
| E10 | User is offline and presses Retry | The probe fails; the bar stays and the Retry control re-enables. No error toast — they already know. |

## 10. Risks

| Risk | Severity | Mitigation |
|---|---|---|
| **False positives** — a scary bar on one blip | High | Two *consecutive exhausted* requests; never trip from a single request or from the probe. |
| `navigator.onLine === true` behind a captive portal | Medium | Signal 2 is authoritative; Signal 1 is only a shortcut. |
| The bar shifts layout and breaks fixed positioning | Medium | Reserve its height in the shell rather than injecting into flow. Check the builder's sticky footer and `MobilePreview`'s phone frame explicitly — both are fixed-position. |
| Disabling actions strands a user mid-flow | Medium | Mutations only; navigation and reads stay live; every disabled control states why. |
| A refetch storm on reconnect | Medium | Active queries only. Measure on the analytics page, which mounts the most. |
| The interceptor edit breaks the retry logic it lives in | High | **Pin current retry behaviour in a test before editing.** This code path was unreachable for months once already (§2.3). |
| Fast-fail (G4) blocks a save that would have succeeded | Medium | Gate only on a *confirmed* degraded state, never on `navigator.onLine === false` alone, and always leave Retry available. |

## 11. Open questions

1. **Two consecutive failures, or two within a window?** Start with two consecutive; tune from the
   false-positive metric in §8.
2. **Does `qr_admin` (separate repo) get the same treatment?** Same problem, same shape; it can
   copy the store and hook once this ships.
3. **Draft autosave to `localStorage` as a follow-up?** It solves a superset of G3 (tab crash,
   accidental close) and carries staleness and PII questions of its own. Separate spec; do not
   quietly grow this one into it.
4. **Should TanStack's `retry` exclude transport failures once degraded?** It would cut §2.2's
   worst case by two thirds. Attractive, but it changes settled behaviour — propose separately with
   its own measurement rather than smuggling it in here.
