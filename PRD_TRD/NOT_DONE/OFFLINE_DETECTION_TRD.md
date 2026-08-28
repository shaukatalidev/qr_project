# TRD — Offline detection

**Spec:** `OFFLINE_DETECTION_PRD.md` · **Status:** Draft (detailed) · **Date:** 2026-08-28
**Migration:** none. **Repos:** `qr_frontend` only.
**Backend:** no change (uses the existing public `GET /api/health`). **Worker:** no change. **KV:** untouched.
**New dependencies:** none. **Service worker:** none. **New plan flags:** none.

---

## 1. Architecture

```
window online/offline events ──┐
navigator.onLine (on mount) ───┤
                               ▼
api-client response interceptor ──▶ connectivityStore (Zustand)
        │  reportRequestFailure()          │  status: online | offline | unreachable
        │  reportSuccess()                 │
        │                                  ├──▶ <ConnectionBanner/>      (shell + builder)
        └── error.isNetworkError = true    ├──▶ useConnectivity()        (disable-with-reason)
            (attached to the rejection)    └──▶ providers.tsx            (refetch on recovery,
                                                                          Sentry suppression)
```

The interceptor **already** computes the classification this feature needs:

```ts
const isTransportFailure = error.code === 'ECONNABORTED' || !error.response;
```

That expression is the single source of truth for "network failure" and **must not be duplicated**.
This feature exposes it; it does not re-derive it.

## 2. Migration

None.

## 3. The store — `src/store/connectivityStore.ts`

Zustand, matching the existing convention (`workspaceStore.ts` is the only store today; this is the
second and it stays this small). Zustand rather than React state because **the interceptor is not
inside React** and must write from a plain module.

```ts
export type ConnectionState = 'online' | 'offline' | 'unreachable';

interface ConnectivityStore {
  status: ConnectionState;
  consecutiveFailures: number;
  lastRecoveredAt: number | null;
  probing: boolean;

  reportRequestFailure(): void;   // interceptor, AFTER its retries are exhausted
  reportSuccess(): void;          // interceptor success path
  setBrowserOffline(offline: boolean): void;   // window events + mount
  probe(): Promise<boolean>;      // GET /api/health
}

export const FAILURE_THRESHOLD = 2;
```

### 3.1 Transitions

| From | Trigger | To | Note |
|---|---|---|---|
| any | `offline` event, or `navigator.onLine === false` on mount | `offline` | Signal 1 is trusted only in this direction |
| `online` | `reportRequestFailure()` reaching `FAILURE_THRESHOLD` | `unreachable` | consecutive, exhausted requests |
| `online`/`unreachable` | `reportSuccess()` | `online`, counter → 0 | any success clears |
| `offline` | `online` event → `probe()` resolves true | `online` | probe is mandatory |
| `offline` | `online` event → `probe()` resolves false | stays `unreachable` | captive portal |
| `unreachable` | manual Retry → `probe()` true | `online` | |
| `unreachable` | manual Retry → `probe()` false | stays `unreachable` | no error toast (PRD E10) |

`reportSuccess()` resetting the counter is what makes the threshold mean *consecutive* (PRD E4).

### 3.2 `probe()`

```ts
async probe() {
  set({ probing: true });
  try {
    await axios.get(`${process.env.NEXT_PUBLIC_API_URL}/health`, {
      timeout: PROBE_TIMEOUT_MS,          // ~5s, explicit
      headers: { 'x-connectivity-probe': '1' },
    });
    set({ status: 'online', consecutiveFailures: 0, lastRecoveredAt: Date.now() });
    return true;
  } catch { return false; }
  finally { set({ probing: false }); }
}
```

Three deliberate choices:

1. **A bare `axios.get`, not `authApi`.** Going through `apiClient` would run the response
   interceptor, which would call `reportRequestFailure()` on a failed probe — incrementing the
   counter that triggered the probe. **That recursion is the single easiest bug to ship here.** A
   bare call avoids it structurally. (Belt and braces: the interceptor also ignores any request
   carrying `x-connectivity-probe`.)
2. **An explicit short timeout.** Inheriting `DEFAULT_TIMEOUT_MS` (30s) would make recovery
   detection slower than the failure it is recovering from.
3. **`/api/health` needs no token** — it is on `main.py`'s middleware exclusion list, so the probe
   cannot fail for auth reasons and cannot itself trigger the 401 hard-redirect to `/login`.

## 4. Interceptor wiring — `src/lib/api-client.ts`

Three edits, all inside the existing response interceptor.

### 4.1 Report **after** retries are exhausted, not per attempt

The existing block is:

```ts
if (isTransportFailure && isSafeMethod && config) {
  const retryCount = config._retry || 0;
  if (retryCount < MAX_TRANSPORT_RETRIES) {
    config._retry = retryCount + 1;
    await new Promise((r) => setTimeout(r, 1000 * 2 ** retryCount));
    return apiClient(config);
  }
}
```

Report **after** it, on the path where the request is genuinely being rejected:

```ts
if (isTransportFailure && !isProbe(config)) {
  connectivityStore.getState().reportRequestFailure();
}
```

A safe-method GET that exhausts three retries reports **once**, not four times. An unsafe method
(never retried) reports once immediately. This is what makes `FAILURE_THRESHOLD = 2` mean two
*requests* rather than half a request (PRD §6, Signal 2).

### 4.2 Report success

In the success handler, currently a bare pass-through:

```ts
(response) => { connectivityStore.getState().reportSuccess(); return response; },
```

### 4.3 Attach the classification to the rejection

```ts
(error as AxiosError & { isNetworkError?: boolean }).isNetworkError = isTransportFailure;
```

This is what makes PRD §5.4's copy rule enforceable rather than aspirational: call sites branch on
one flag instead of each re-testing `error.response`. Export a helper beside the existing
`getErrorStatus`:

```ts
export function isNetworkError(error: unknown): boolean;
```

### 4.4 What must NOT change

- **The retry policy.** Safe methods keep their three transport retries with `1000 * 2 ** n`
  backoff; unsafe methods still never auto-retry, because *"retrying a POST can create a second QR
  code or submit a second charge"*. That comment stays and so does the behaviour.
- **The FormData timeout bump** (`config.timeout === DEFAULT_TIMEOUT_MS → UPLOAD_TIMEOUT_MS`).
- **The 401 hard-redirect**, which sits outside the `skipErrorToast` silencing because it is an
  action rather than a notification.
- **`skipErrorToast`** semantics.

> **Pin all four in tests before editing this file.** The `ECONNABORTED`-only bug (PRD §2.3) made
> this block unreachable for months without anyone noticing, and the same class of regression is
> the main risk of touching it.

## 5. Hook — `src/hooks/useConnectivity.ts`

```ts
export function useConnectivity(): {
  status: ConnectionState;
  isDegraded: boolean;       // status !== 'online'
  canMutate: boolean;        // !isDegraded
  reason: string | null;     // the single tooltip sentence
  retry: () => Promise<boolean>;
};
```

`reason` lives here and nowhere else, so the sentence in PRD §5.2 exists once and cannot drift
across twenty disabled controls.

## 6. Components

### `src/components/ui/connection-banner.tsx`

Renders per PRD §5.1. Requirements:

- **Height reservation.** The shell reserves the bar's height rather than injecting it into flow.
  Verify explicitly against the builder's sticky action footer and `MobilePreview`'s phone frame —
  both are fixed-position and are exactly where a naive banner breaks the layout.
- `role="status"` with `aria-live="polite"` — announced, never interrupting.
- The recovered state auto-dismisses on a timer; clear the timer on unmount.
- Themed with design tokens (`surface-container`, `on-surface`), never raw palette classes.

### Mount points

- `app/[slug]/(dash)/layout.tsx` — the dashboard shell.
- `app/[slug]/(builder)/layout.tsx` — **separately**, because the builder is outside `(dash)` and
  is the surface where the feature matters most.
- **Not** in `(marketing)` or `(auth)` (PRD E9).

### Window events

One client component in the shell registers `online`/`offline` listeners and removes them on
unmount, and **reads `navigator.onLine` on mount** — a tab restored offline fires no event
(PRD E1). Guard for SSR: `typeof navigator !== 'undefined'`.

## 7. `providers.tsx`

Two additions, neither changing existing behaviour:

**Refetch on recovery** — subscribe to the store; on a transition into `online`:

```ts
queryClient.refetchQueries({ type: 'active' });
```

`type: 'active'` only. Refetching everything on a dashboard with many mounted queries is the storm
in PRD §10; the analytics page is the worst case and is where to measure.

**Sentry suppression** (PRD G8) — in the existing `QueryCache.onError`, which today filters 4xx:

```ts
if (status !== undefined && status >= 400 && status < 500) return;
if (isNetworkError(error) && connectivityStore.getState().isDegraded) return;   // NEW
```

The reasoning matches the comment already there: a transport failure during a known outage is the
network being broken, not the frontend. Reporting them buries real 5xx under train-tunnel noise.
**Keep reporting transport failures while `online`** — those are the interesting ones.

## 8. Builder integration

`app/[slug]/(builder)/build/page.tsx` and the step-4 submit path.

### 8.1 Branch on the classification

```ts
onError: (error) => {
  if (isNetworkError(error)) {
    setNetworkError(true);      // inline banner + Retry; state untouched
    return;                     // do NOT navigate, reset, or clear the file selection
  }
  // existing behaviour: field errors / status-coded toast
}
```

The file selection is the one to be explicit about: a cleared file input forces the user back
through the OS file picker, and that is the loss people write in to complain about (PRD §5.3).

### 8.2 Fast-fail before submitting (PRD G4)

```ts
const { canMutate, reason } = useConnectivity();
...
if (!canMutate) { setNetworkError(true); return; }   // never start the request
```

This is the whole point of §2.2's arithmetic: on a **confirmed** degraded state, do not begin a
request that will take up to 127s (GET) or 120s (upload) to fail. Gate on the *store's* state, not
on `navigator.onLine` alone — a false positive here blocks a save that would have succeeded.

The primary action is disabled while `!canMutate`, with `reason` as its tooltip.

### 8.3 Retry

Re-fire the **same** mutation with the **same** payload. Do not rebuild the payload from form state
— if the user edited a field while offline, the retry should send what they now have, so read from
the form at fire time rather than from a captured snapshot. Pick one and comment it; the ambiguity
is real and silent.

## 9. Tests

### 9.1 Regression pins — write these FIRST, before touching `api-client.ts`

- a transport failure on a GET retries exactly `MAX_TRANSPORT_RETRIES` times with `1000 * 2 ** n`
  backoff;
- a transport failure on a POST retries **zero** times;
- a 500 response retries zero times;
- FormData gets `UPLOAD_TIMEOUT_MS`; JSON keeps `DEFAULT_TIMEOUT_MS`;
- 401 still hard-redirects to `/login` even with `skipErrorToast`;
- `skipErrorToast` still silences the status-code toasts.

### 9.2 Store — `src/store/__tests__/connectivityStore.test.ts`

- one failure does **not** degrade; two consecutive do;
- a success between two failures resets the counter (PRD E4);
- `offline` event degrades immediately regardless of the counter;
- `navigator.onLine` flipping to `true` alone does **not** clear `unreachable` — the probe must
  resolve (PRD E2, the captive-portal case);
- a failing probe does **not** increment the counter (§3.2 recursion);
- recovery sets `lastRecoveredAt` and zeroes the counter.

### 9.3 Interceptor — `src/lib/__tests__/api-client-connectivity.test.ts`

- an exhausted GET reports **once**, not four times (§4.1 — the arithmetic that makes the threshold
  meaningful);
- a POST transport failure reports once;
- a 404 reports **zero** times (PRD E7 — a settled answer is not an outage);
- a success calls `reportSuccess`;
- `error.isNetworkError` is `true` on transport failure and `false` on an HTTP error;
- a request carrying `x-connectivity-probe` reports nothing.

### 9.4 Builder — Vitest

- a network-classified failure preserves every field, the step index, **and the selected file**;
- a 422 takes the existing path, not the network path;
- `!canMutate` disables the primary action and shows `reason`;
- fast-fail starts **no** request when degraded (assert the mutation function was not called).

### 9.5 Banner — Vitest

- renders per state; renders nothing when `online`;
- reserves height;
- `role="status"`, `aria-live="polite"`;
- the recovered state auto-dismisses and clears its timer on unmount.

### 9.6 Playwright — `npm run test:e2e`

The only test that proves the user-visible promise end to end:

1. drive the builder to step 4 with content entered and a file selected;
2. `context.setOffline(true)`;
3. attempt save → assert the banner, assert **fields and file survive**, assert the failure is
   fast (well under the §2.2 numbers);
4. `context.setOffline(false)`;
5. assert "Back online", then save successfully.

Run once at a **mobile viewport** — banner positioning against the sticky footer is not observable
in jsdom and mobile is the primary environment.

## 10. Observability

- Mixpanel (via the existing `src/lib/analytics/mixpanel.ts` wrapper, through `sanitize`):
  `connectivity_degraded` (with `status`), `connectivity_recovered` (with duration),
  `connectivity_false_positive` — emitted when a degraded state ends with **no** intervening failed
  request, which is PRD §8's threshold-tuning metric.
- No PII, no URLs, no workspace content.

## 11. Rollout

**One frontend PR**, in this internal order so each piece is independently reviewable:

1. Regression pins (§9.1) — no behaviour change.
2. Store + interceptor wiring.
3. Banner + shell mounts.
4. Builder integration + fast-fail.
5. `providers.tsx` refetch + Sentry suppression.

Ship 2 and 3 together at minimum: a banner without the interceptor detects only
`navigator.onLine`, which is the half that lies (PRD E2).

No migration, no backend deploy, no Worker deploy, no KV change. Fully revertable.

## 12. Risks

| Risk | Mitigation |
|---|---|
| The interceptor edit breaks the retry logic it lives inside | §9.1 pins, written first. This block was unreachable for months once already. |
| Probe recursion inflates the failure counter | Bare `axios` + the `x-connectivity-probe` header guard — two independent defences. |
| False positives disable a working app | Two consecutive *exhausted* requests; probe never counts; fast-fail gates on the store, not on `navigator.onLine`. |
| Fast-fail blocks a save that would have worked | Only on a confirmed degraded state, and Retry is always available. |
| Banner breaks fixed-position layouts | Height reserved in the shell; explicit checks against the builder footer and `MobilePreview`; mobile-viewport Playwright run. |
| Refetch storm on reconnect | `type: 'active'` only; measured on the analytics page. |
| A second Zustand store starts a trend of scattered client state | It stays at four fields and one purpose. Server state remains TanStack Query, no exceptions. |
| Sentry suppression hides a real backend outage | Suppress **only** while already degraded, and only for transport failures. A 5xx with a response is always reported. |
