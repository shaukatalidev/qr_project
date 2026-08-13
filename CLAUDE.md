# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

QR Code SaaS monorepo with three independent services:

- **`qr_backend/`** — FastAPI (Python 3.11+) REST API backed by Supabase/PostgreSQL
- **`qr_frontend/`** — Next.js 14 App Router (TypeScript/React) frontend
- **`qr_cf_code/`** — Cloudflare Worker (JavaScript) edge router handling QR scan redirects

## Backend (`qr_backend`)

### Commands
```bash
python -m uvicorn src.main:backend_app --reload --host 0.0.0.0 --port 8000
pytest
pytest --cov=src --cov-report=html
black src/ tests/ && isort src/ tests/    # line-length 119 — running bare `black` uses
                                          # its 88-col default and reformats the world
mypy src/
docker-compose up -d
```

### Tests

Two tiers, and the distinction is load-bearing:

- **`tests/unit_tests/`** (~1,120) — import a route coroutine and `await` it directly,
  passing `user_id="u1"`, `member={"role": "owner"}` as plain kwargs. Auth, routing and
  serialisation never run. Fast, and the right place for logic.
- **`tests/integration_tests/`** (~33) — drive the **real ASGI stack** via the
  `async_client` / `anonymous_client` fixtures in `tests/conftest.py`, so the Bearer
  middleware, dependency resolution and response models are actually exercised. Auth is
  real: `make_access_token()` mints an HS256 token the middleware verifies offline against
  `SUPABASE_JWT_SECRET` from the committed `.env.test`. Inject a database with
  `use_fake_db(FakeDB({...}))`.

**New tests must not need Postgres.** CI (`.github/workflows/ci.yml`) runs bare `pytest`
with no database service, so a DB-backed test *skips* there — and a skip is
indistinguishable from a pass in a green run. `tests/integration_tests/conftest.py`'s
`requires_db` marks the few that genuinely need the local stack.

Use the shared double in **`tests/fakes/`** (`FakeDB`) rather than writing a new one. It
applies `.eq()` filters and journals operation order, which a `MagicMock` cannot: a mock
returns a truthy row whatever you ask it for, so a tenancy assertion passes with or without
the filter that makes it true. Note `maybe_single()` returns a **dict or `None`**, matching
PostgREST — not a one-element list.

### Architecture

**Entry point**: `src/main.py` — FastAPI app factory with lifespan, CORS middleware, and `BearerTokenAuthMiddleware`.

**Request lifecycle**: `RequestMiddleware` (mints `request.state.request_id`, logs the one structured line the app emits) → CORSMiddleware → `BearerTokenAuthMiddleware` → router → dependency injection → handler.

`BearerTokenAuthMiddleware` verifies the JWT **locally** against `SUPABASE_JWT_SECRET` (HS256) and only falls back to `supabase.auth.get_user(token)` when that is impossible — secret unset, a non-HS256 token, or a bad signature. So the common path makes **no network call**. It attaches `user_id`, `user_email`, `user_role` and `supabase_user` to `request.state`. An expired-but-well-formed token is rejected immediately without the fallback.

**Auth dependencies** (`src/api/dependencies/`):
- `get_current_user_id()` — reads from `request.state`
- `get_workspace_role(workspace_id, user_id)` — DB lookup on `workspace_members`
- `require_can_read/create/update/delete` — raise 403 if role insufficient (viewer=1, editor=2, owner=3)

**The API prefix is `/api`, NOT `/api/v1`.** Hardcoded at `src/config/settings/base.py:26`
(`API_PREFIX`), not env-driven. Every app route is `/api/<router-prefix>/…` — e.g.
`/api/workspaces/`, `/api/health/`, `/api/internal/kv-sweep`. The **only** paths carrying a
`v1` are the public developer API and the public report reader, which mount their own
absolute prefix `/api/public/v1/…` and do not sit under `API_PREFIX`.

**Public routes** — the exclusion list is passed to the middleware in `main.py`
(prefix-matched), not defined inside `auth_bearer.py`. Adding a route here is the only way
to make it reachable without a Bearer token, so the full list is worth knowing:

| Path prefix | What guards it instead |
|---|---|
| `/api/razorpay/webhooks` | Razorpay HMAC signature |
| `/api/mor/webhooks` | Merchant-of-Record signature |
| `/api/bsp/webhook/` | per-workspace BSP HMAC |
| `/api/security/deletion/cancel` | HMAC-signed token from the deletion email (the account has no live session by design) |
| `/api/health`, `/health/live`, `/health/ready` | nothing — liveness probes |
| `/api/internal/` | `x-internal-secret` header (`verify_internal_secret`) |
| `/api/public/plans` | nothing — anonymous pricing page |
| `/api/public/v1` | API key, not JWT (`api_key_auth`) |
| `/docs`, `/redoc`, `/openapi.json` | nothing |

There are **no** `register` / `login` / `forgot-password` / `verify-otp` endpoints — signup
and login happen against Supabase directly from the frontend. The backend's only auth route
is `POST /api/auth/verify-user`, which resolves an already-authenticated user (and creates
their first workspace on first login). It is **not** public; it requires a Bearer token.

**Database**: Supabase REST client (not SQLAlchemy despite it being in requirements). All queries use the `supabase-py` fluent API: `db.table("x").select("*").eq("id", id).execute()`. The service role key is used (bypasses RLS). Client is a lazy-initialized singleton in `src/database/supabase.py`.

**Config**: `ENVIRONMENT` env var (not `APP_ENV`) selects the settings class via `src/config/manager.py` — `DEV`/`STAGE`/`PROD` plus the long forms (`development`, `staging`, `production`), case-insensitive; anything unrecognized resolves to production. Settings singleton imported as `from src.config.manager import settings`. On startup `settings.validate_public_urls()` refuses to boot outside development if `QR_DYNAMIC_URL`/`PUBLIC_API_URL`/`FRONTEND_URL`/`SITE_URL` still hold localhost defaults — these get published (into QR pixels and emails), so set them per environment before deploying.

**Cloudflare KV sync** — two modules, and the split matters:

- `src/utilities/cloudflare_kv.py` — the transport and the payload builders.
  `build_kv_content(qr_id, qr_type, db)` assembles the type-specific content block;
  `sync_qr_to_kv(qr_id, db)` is the canonical DB→KV publish. All four HTTP helpers go
  through `_kv_request`, which applies `timeout=30`, retries **3 times** (0.5s then 2.0s)
  on transport errors / 429 / 5xx, and never retries other 4xx. Failures raise **`KVError`**,
  and `build_kv_content` raises **`KVContentError`** — both subclass `RuntimeError` so
  existing `except RuntimeError` handlers keep working *and* now also catch what used to be
  an uncaught `httpx.ConnectError`. `build_kv_content` raises for **every** type rather than
  degrading to `{}`: `write_to_kv` is a full PUT, so an empty write destroys a working KV
  value, while skipping the write preserves the last-good one.
- `src/utilities/kv_sync.py` — durability. **Call `publish_qr(qr_id, db)`, not
  `sync_qr_to_kv`, from any write path**: it records the outcome on the `qr_codes` row
  (`kv_sync_status` / `kv_attempt_count` / `kv_next_attempt_at` / `kv_last_error`, migration
  0049) and **never raises**. `POST /internal/kv-sweep` re-publishes flagged rows on a cron
  tick, with backoff, a dead-letter cap and a circuit breaker; `GET /admin/abuse/kv-unsynced`
  lists what is currently broken.

These helpers are **synchronous and blocking**. Called from an `async def` handler they must
be wrapped: `await run_in_threadpool(publish_qr, str(qr_id), db)`. A test enforces this —
`test_no_blocking_kv_call_survives_in_an_async_handler` walks the AST of every route module.

**Key files by size** (they drift; re-measure before trusting):
- `src/api/routes/internal.py` (~2,100) — Worker-only endpoints, `x-internal-secret` guarded.
- `src/api/routes/scan.py` (~2,050) — scan recording and analytics reads.
- `src/api/schemas/qr.py` (~1,860) — the 74 QR request/response models + pure validators.
- `src/core/qr/service.py` (~1,760) — `create_qr` / `update_qr` orchestration. Still two very
  long functions (950 / 711 lines); they were relocated out of the route layer, not split.
- `src/api/routes/razorpay_routes.py` (~1,400) — billing lifecycle and webhook handler.
- `src/api/routes/qr.py` (~1,320) — the QR endpoints, now thin. Re-exports names from
  `src/api/schemas/qr.py` and `src/core/qr/rows.py` so existing imports keep resolving.
- `src/core/qr/rows.py` (~930) — row↔response translation, `SELECT_WITH_RELATIONS`, menu row
  building, short-code minting.

**When moving a handler between modules**, repoint its tests' `patch.object` targets in the
same commit. Patching the module a handler *used* to live in is a silent no-op, not an error
— `conftest.py` installs a guard that fails any test reaching the real Cloudflare API,
because the consequence is CI issuing live DELETEs against the production KV namespace.

## Frontend (`qr_frontend`)

### Commands
```bash
npm run dev
npm run build
npm run lint
npm test                # Vitest unit tests
npm run test:e2e        # Playwright E2E
```

### Architecture

**Route structure** (Next.js 14 App Router):
```
src/app/
  (auth)/           # login, signup, invite, callback — no sidebar
  org/
    layout.tsx      # workspace layout with sidebar
    page.tsx        # redirects to first workspace slug
    [slug]/
      (dash)/       # dashboard, qrs, analytics, billing, members, settings, ...
      (builder)/
        build/      # QR builder wizard (create + edit)
```

**QR Builder wizard** (`src/components/qr-generator/`): 4 steps rendered in `build/page.tsx`. Step 3 (Page Design) uses `TemplatePicker` + `PageDesignStep` + `PagePreview`. Step 4 uses `QRPreview` + `DownloadOptions`. `MobilePreview` wraps the live preview in a phone frame.

**Template system** (`src/lib/constants/page-templates.ts`): `VCARD_TEMPLATES` and `PDF_TEMPLATES` define which `templateId` values exist per QR type. `getTemplatesForType(qrType)` drives the picker. Template React preview components live in `src/components/qr-generator/templates/{vcard,pdf}/`. The same `templateId` is stored in `page_design.templateId` in KV and consumed by the Worker to pick the HTML generator.

**State management**:
- Server state: TanStack Query v5 — all hooks in `src/hooks/`. Key: `useQRs`, `useWorkspaces`, `useSubscription`, `useAnalytics`, `useStorage`, `useUser`.
- Client state: Zustand — only one store: `src/store/workspaceStore.ts` (workspace list + current workspace).
- Query key factories follow the pattern in `useQRs.ts` (`qrKeys.list(filters)`, etc.).

**API client**: `src/lib/api-client.ts` (`authApi`) — Axios with Supabase JWT injected via request interceptor, 10s timeout, auto-retry on network errors. The older `src/lib/api.ts` is a bare Axios instance; prefer `authApi` from `api-client.ts` in hooks.

**Auth**: Middleware (`src/middleware.ts`) uses `@supabase/ssr` to validate the Supabase session on every request. Protects all `org/*` routes; redirects to `/login` if no session.

**Design system** (`DESIGN_SYSTEM.md` — read it before building UI):
- Primary: Indigo `#4648d4` (`primary` token)
- Accent: Cyan `#06b6d4` (`tertiary` token)
- Font: Inter 300–900
- Surface hierarchy: tonal shifts instead of borders ("No-Line Rule")
- All tokens in `tailwind.config.ts`; use `cn()` from `src/lib/utils.ts` for conditional classes.

### Frontend Code Rules (from `.agents/rules/code-style-guider.md`)

- **Stitch MCP first**: Before any UI component, fetch the design reference via the Stitch MCP tool.
- **shadcn/ui always**: Use shadcn primitives before writing raw HTML. Never `<button>` when `<Button>` exists.
- **No inline styles** in components — Tailwind classes only. No `style={{}}`.
- **No `any` types** — TypeScript interfaces for all props.
- **200-line limit** per component file — split if exceeded.
- **One export per file**. File names: kebab-case. Component names: PascalCase.
- Pages (`src/app/`) compose components — no business logic or raw JSX blocks in page files.
- Forms: react-hook-form + zod only. No uncontrolled inputs.
- Server state: TanStack Query. Never `useEffect + fetch`.
- Check `src/hooks/` before writing a new hook.

## Cloudflare Worker (`qr_cf_code`)

### Commands
```bash
npm run dev           # wrangler dev (local preview, uses preview_id KV namespace)
npm run deploy:dev    # deploy to staging/dev  (there is NO plain `npm run deploy`)
npm run deploy:prod   # deploy to production
node src/<name>.test.mjs   # tests are standalone scripts — no runner, no `npm test`
wrangler secret put INTERNAL_SECRET
```

### Architecture

**Modular `src/` structure** — the entry point is `src/index.js` (set as `main` in `wrangler.toml`). The root-level `worker.legacy.js` is the old ~3300-line monolith and is **NOT deployed** — ignore it, along with the `link_of_links.js`, `link.js`, `bussines_index.js` prototypes. Layout:
- `src/index.js` — the `fetch` handler: routing, custom-domain tenant isolation, password gate, then dispatch.
- `src/handlers/` — `qrRouter.js` (`handleQRCode` dispatches by QR `type`), `vcardDownload.js`, `linkClick.js`.
- `src/pages/<type>Page.js` — per-type entry that selects a template by `page_design.templateId`; individual templates live in `src/pages/<type>/<variant>Template.js` (e.g. `src/pages/vcard/heroTemplate.js`). `vcard`/`pdf` use `src/pages/<type>/index.js` as their dispatcher.
- `src/pages/{errorPage,scanLimitPage,disabledPage,passwordGatePage}.js` — system/status pages.
- `src/utils/` — `html.js` (`escapeHTML`), `scan.js` (`recordScan`), `design.js`, `supabase.js`, `vcard.js`.

**Request routing** (in `src/index.js`, patterns in order):
1. `GET /vcard-download/:qrId` — builds `.vcf` in memory, returns as attachment (`handlers/vcardDownload.js`)
2. `GET /click/:linkId?target=<url>` — background link-click tracking, then 302 to `target` (`handlers/linkClick.js`)
3. `POST /pw-verify/:shortCode` — password-gate verification (proxies to the backend)
4. `GET /:shortCode` — main scan flow: KV lookup → custom-domain isolation check → `handleQRCode` dispatch (`handlers/qrRouter.js`)

**KV data model**: Each key is a `shortCode`. Value is JSON:
```json
{
  "qr_id": "uuid",
  "type": "website|pdf|vcard|...",
  "destination": "url or null",
  "status": "active|inactive",
  "workspace_id": "uuid",
  "page_design": { "templateId": "...", "themeColor": "#...", "pageTitle": "...", "locked": false },
  "content": { /* type-specific content object */ }
}
```
The `content` field is pre-fetched by the backend at create/update time via `build_kv_content()` so the Worker doesn't need to call the backend at scan time for most types.

**Type handlers and fallback pattern**: For types with content in KV (`vcard`, `pdf`, `images`, `business`, etc.), the Worker first tries to render from `kvContent`. If KV data is stale (no `content` key), it falls back to a backend fetch via `/internal/{type}/{qr_id}`. Example:
```javascript
if (kvContent && kvContent.files?.length > 0) {
  // use KV data
} else {
  // fallback fetch to backend
}
```

**HTML generation**: Landing pages are template-literal strings produced by per-template modules in `src/pages/<type>/<variant>Template.js`. Each type's dispatcher (`src/pages/<type>Page.js`, or `src/pages/<type>/index.js` for `vcard`/`pdf`) picks the right template based on `page_design.templateId`. Always use `escapeHTML()` (from `src/utils/html.js`) on user data.

**Scan tracking**: `ctx.waitUntil(recordScan(...))` (`recordScan` in `src/utils/scan.js`) — fires after the response is sent. Never blocks the user. Errors are swallowed silently.

**Custom-domain isolation**: `src/index.js` compares `url.hostname` to `env.PRIMARY_HOSTNAME`; on a custom hostname it looks up `domain:<hostname>` in KV → `{workspace_id}` and rejects any short code whose QR belongs to a different workspace. Custom-hostname TLS/routing is handled by Cloudflare for SaaS (backend `cloudflare_saas.py`), not the Worker.

**Adding a new QR type**: (1) add a `case` to the `handleQRCode` dispatch in `src/handlers/qrRouter.js` pointing to a new `src/pages/<type>Page.js`, (2) add a `build_kv_content` branch in `qr_backend/src/utilities/cloudflare_kv.py`, (3) write the page/template module(s) under `src/pages/<type>/`, (4) add the content type form in `qr_frontend/src/components/qr-generator/content-types/`.

**Adding a new scan page template**: (1) add a `*Template.js` in `src/pages/<type>/`, (2) wire it into that type's dispatcher (`src/pages/<type>Page.js` or `src/pages/<type>/index.js`) via `templateId`, (3) add the template entry to `qr_frontend/src/lib/constants/page-templates.ts`, (4) create a React preview component in `qr_frontend/src/components/qr-generator/templates/`, (5) add a case to `TemplatePicker.tsx` and `PagePreview.tsx`. Every React template **must** be mirrored by a matching Worker template — keep the two in sync.

**Multilingual chrome (`vcard` / `vcard_plus` / `business` / `menu`)**: those templates take a
trailing optional `i18n` context and route every hardcoded label through `t('key')`. Dictionaries
live in `qr_cf_code/src/i18n/` and are **duplicated** in `qr_frontend/src/lib/i18n/` — separate git
repos, so no shared import is possible. Both check in the same canonical `keys.json` (key → English
**value**) and each has a test pinning its own `en` dictionary to it. Nothing inside either repo can
see the other's copy, so after changing any chrome string **or the locale set** run:

```bash
./scripts/check-i18n-parity.sh    # manual pre-merge step; not CI — no CI job sees both repos
```

It diffs three things, one per blind spot: the two `keys.json` files (a drifted string means the
builder preview lies about the live page), the two `SUPPORTED_LOCALES` arrays **including order**
(a locale in one repo only means the builder offers a language the Worker refuses, and the visitor
silently gets the default), and the dictionary files on disk (a locale listed in both barrels but
written in only one still passes that repo's own tests).

**11 locales, LTR only** — `en`, the five Indic (`hi ta te bn mr`), the five world (`zh es fr pt ru`).
`MAX_LOCALES = 6` is a **per-QR cap below the supported set**, not a tautology: the switcher renders
a chip per enabled locale and eleven wrap past the fold on a 390px phone. `NOTO_FAMILY` /
`NOTO_STACK_NAME` membership means *"needs a webfont"*, **not** *"is not English"* — Inter already
covers Latin **and Cyrillic**, so `es`/`fr`/`pt`/`ru` deliberately have no entry and tests assert
that absence. Only `zh` and the four Indic scripts load a face. RTL (`ar`/`ur`/`he`/`fa`) is excluded
by assertion in all three repos: it needs `dir="rtl"` out of `withDocumentLang` plus ~40 directional
CSS declarations across 20 files.

`<html lang>` is stamped **once**, centrally, by `finalizeLocalizedResponse` in `src/index.js`'s
response tail (beside the pixel/consent injectors) — never per template. Locale is resolved per scan
by `src/utils/locale.js` after the status/schedule/password branches, so system pages stay English.
A monolingual QR (`i18n` absent, or one locale) must stay **byte-for-byte identical** to pre-feature
output; `src/i18n/templates.test.mjs` asserts that and is the regression to protect.

### Integration tests (`qr_cf_code/src/integration/`)

Every other Worker test imports one module and checks its output. `src/integration/` drives the
**real `src/index.js` fetch handler** over a fake KV binding and a `fetch` recorder — no miniflare,
no wrangler, since the default export is a plain `fetch(request, env, ctx)` and Node supplies
Request/Response. `harness.mjs` is the whole runtime; `scanFlow.test.mjs` covers routing, the
status/schedule gates, custom-domain tenant isolation, locale resolution and the deferred scan POST.

Two things it pins are invariants, not cosmetics: a page that served **no content must never POST
`/internal/scans`** (the backend counts that table per workspace with no type filter, so a blocked
scan burns the billable cap and, once tripped, disables every other QR that workspace owns), and a
custom hostname must **refuse short codes from other workspaces**.

When adding to the harness, note that `ctx.waitUntil` needs draining until it stops growing —
callers fire `recordScan` without awaiting it, and it awaits two crypto digests before deferring,
so a single `Promise.all` finds an empty list and the POST surfaces during the *next* test.

**Backend↔Worker KV contract**: `build_kv_content()` (backend) writes the blob the Worker renders
from, and the two repos could only ever test against hand-written fakes of each other. The backend
now generates `kv_contract.json` from the real function; `qr_cf_code` keeps a byte-identical copy
and feeds every payload through the real Worker. Same arrangement as `keys.json`, same reason.
After any change to `build_kv_content` or a scan-page reader:

```bash
cd qr_backend && UPDATE_KV_CONTRACT=1 pytest tests/integration_tests/test_kv_contract.py
cp tests/integration_tests/kv_contract.json ../qr_cf_code/src/integration/
./scripts/check-kv-contract-parity.sh   # manual pre-merge step; no CI job sees both repos
```

### Tests that need a monorepo checkout

Two frontend tests read their sibling repos off disk rather than through a checked-in
artefact: `maps-mirror.test.ts` imports `qr_cf_code/src/utils/maps.js` to prove both
implementations build identical map URLs, and `location-templates.test.ts` reads the Worker
dispatcher and the backend KV shim to prove all three agree on the default `templateId`.

GitHub Actions clones one repo, so both **skip** there — `vitest.config.ts` aliases the
absent sibling to a stub so the import resolves, and the tests skip on the same condition.
A static cross-repo import instead fails at transform time and takes the whole file down,
which is how the frontend's first CI run went red.

Skipping is not passing. Run them before merging anything that touches maps or location
templates — the script fails if they skip rather than reporting a vacuous pass:

```bash
./scripts/check-cross-repo-mirrors.sh
```

Prefer the `keys.json` / `kv_contract.json` pattern for NEW cross-repo checks: a generated
artefact committed to both repos keeps each repo's own CI meaningful. Reaching across the
filesystem only works on a developer's machine.

## Key Data Flow

```
User scans QR → Cloudflare Worker
  → KV lookup (shortCode → { type, content, page_design })
  → if content in KV: render directly (no backend call)
  → else: fetch /internal/{type}/{qr_id} from backend
  → return redirect or HTML landing page
  → ctx.waitUntil: POST /internal/scans (background)

Frontend → authApi (Axios + Supabase JWT) → FastAPI Backend
  → QR create/update: DB write + write_to_kv() (synchronous)
  → Supabase Storage for file uploads
```

## External Services

| Service | Purpose | Key files |
|---------|---------|-----------|
| **Supabase** | Auth (JWT), PostgreSQL, Storage | `src/database/supabase.py`, `src/middleware.ts` |
| **Cloudflare KV** | Edge QR metadata store | `src/utilities/cloudflare_kv.py`, `wrangler.toml` |
| **Razorpay** | Indian payment provider + webhooks | `src/api/routes/razorpay_routes.py` |
| **Resend** | Transactional email (invitations) | `src/utilities/email.py` |
| **Vercel Analytics** | Frontend usage tracking | `src/app/layout.tsx` |

## Environment Setup

**Backend** (`qr_backend/.env`, copy from `.env.example`):
- `ENVIRONMENT` — `DEV|STAGE|PROD` (long forms also accepted; unrecognized ⇒ production)
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- `INTERNAL_SECRET` — shared with Worker
- `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID`, `CF_API_TOKEN`
- `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`
- `RESEND_API_KEY`, `HASHING_SALT`, `ALLOWED_ORIGINS`
- Public URLs, **required in every deployed env** (they get baked into QR images and emails; startup fails if left on localhost): `QR_DYNAMIC_URL`, `PUBLIC_API_URL`, `FRONTEND_URL`, `SITE_URL`

**Frontend** (`qr_frontend/.env.local`):
- `NEXT_PUBLIC_API_URL` — FastAPI backend URL
- `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`

**Worker** (`qr_cf_code/`):
- `wrangler.toml` — KV namespace IDs, `BACKEND_URL`
- `wrangler secret put INTERNAL_SECRET` — shared secret for backend calls

## Multi-Agent System

`.claude/agents/` contains specialized agents: `antigravity` (top-level orchestrator), `frontend-agent`, `backend-agent`, `cloudflare-agent`, `test-agent`, `explore-agent`. Use the `antigravity` agent as the entry point for cross-cutting tasks.
