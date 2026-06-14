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
black src/ tests/ && isort src/ tests/
mypy src/
docker-compose up -d
```

### Architecture

**Entry point**: `src/main.py` — FastAPI app factory with lifespan, CORS middleware, and `BearerTokenAuthMiddleware`.

**Request lifecycle**: CORSMiddleware → `BearerTokenAuthMiddleware` (calls `supabase.auth.get_user(token)` on every request, attaches `user_id` to `request.state`) → router → dependency injection → handler.

**Auth dependencies** (`src/api/dependencies/`):
- `get_current_user_id()` — reads from `request.state`
- `get_workspace_role(workspace_id, user_id)` — DB lookup on `workspace_members`
- `require_can_read/create/update/delete` — raise 403 if role insufficient (viewer=1, editor=2, owner=3)

**Public routes** (bypass Bearer auth, defined by exclusion in `auth_bearer.py`):
- `POST /api/v1/auth/register|login|forgot-password|verify-otp`
- `GET /api/v1/health`
- `POST /api/v1/internal/*` — protected by `x-internal-secret` header instead
- `POST /api/v1/razorpay/webhook`

**Database**: Supabase REST client (not SQLAlchemy despite it being in requirements). All queries use the `supabase-py` fluent API: `db.table("x").select("*").eq("id", id).execute()`. The service role key is used (bypasses RLS). Client is a lazy-initialized singleton in `src/database/supabase.py`.

**Config**: `APP_ENV` env var selects settings class (`development`/`staging`/`production`) via `src/config/manager.py`. Settings singleton imported as `from src.config.manager import settings`.

**Cloudflare KV sync** (`src/utilities/cloudflare_kv.py`): Every QR write calls `write_to_kv()` synchronously after the DB write. `build_kv_content(qr_id, qr_type, db)` fetches type-specific content (vcard fields, file paths, event data, etc.) and packages it for the Worker. If the KV write fails, it raises `RuntimeError` — there is no retry.

**Key files by size/complexity**:
- `src/api/routes/qr.py` (~1400 lines) — all QR CRUD, KV sync, file attachment logic. `SELECT_WITH_RELATIONS` string at line ~819 joins all related tables in one query.
- `src/api/routes/razorpay_routes.py` (~977 lines) — billing lifecycle and webhook handler.
- `src/api/routes/internal.py` — Worker-only endpoints (no Bearer auth).

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
npm run deploy        # deploy to staging
npm run deploy:prod   # deploy to production
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
- `APP_ENV` — `development|staging|production`
- `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`
- `INTERNAL_SECRET` — shared with Worker
- `CF_ACCOUNT_ID`, `CF_KV_NAMESPACE_ID`, `CF_API_TOKEN`
- `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`
- `RESEND_API_KEY`, `HASHING_SALT`, `ALLOWED_ORIGINS`, `FRONTEND_URL`

**Frontend** (`qr_frontend/.env.local`):
- `NEXT_PUBLIC_API_URL` — FastAPI backend URL
- `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`

**Worker** (`qr_cf_code/`):
- `wrangler.toml` — KV namespace IDs, `BACKEND_URL`
- `wrangler secret put INTERNAL_SECRET` — shared secret for backend calls

## Multi-Agent System

`.claude/agents/` contains specialized agents: `antigravity` (top-level orchestrator), `frontend-agent`, `backend-agent`, `cloudflare-agent`, `test-agent`, `explore-agent`. Use the `antigravity` agent as the entry point for cross-cutting tasks.
