# QR Generator SaaS — Feature Reference

> Complete feature inventory across all three services: **FastAPI backend**, **Next.js frontend**, and **Cloudflare Worker edge layer**.

---

## Table of Contents

1. [QR Code Types](#1-qr-code-types)
2. [QR Design & Customization](#2-qr-design--customization)
3. [QR Builder Flow](#3-qr-builder-flow)
4. [Smart Routing & Destinations](#4-smart-routing--destinations)
5. [Edge Delivery (Cloudflare Worker)](#5-edge-delivery-cloudflare-worker)
6. [Scan Analytics & Tracking](#6-scan-analytics--tracking)
7. [File & Media Storage](#7-file--media-storage)
8. [Workspace & Team Management](#8-workspace--team-management)
9. [Authentication & Security](#9-authentication--security)
10. [Subscription & Billing](#10-subscription--billing)
11. [Custom Domains](#11-custom-domains)
12. [Folders & Organization](#12-folders--organization)
13. [API & Developer Access](#13-api--developer-access)
14. [Notifications & Support](#14-notifications--support)
15. [Frontend & UX](#15-frontend--ux)

---

## 1. QR Code Types

14 content types are supported. Each type has its own detail schema, landing page renderer, and scan behavior.

### Static / Redirect Types

| Type | Behavior | Edge Handling |
|------|----------|---------------|
| **Website** | HTTP 302 redirect to any URL | Instant KV lookup → redirect |
| **PDF** | Redirects to a hosted PDF file | Fetches signed URL, redirects |
| **Video** | Redirects to a hosted video file | Fetches signed URL, redirects |
| **MP3 / Audio** | Redirects to a hosted audio file | Fetches signed URL, redirects |
| **Images** | Opens an image carousel gallery | Renders HTML gallery page |

### Rich Landing Page Types

| Type | Landing Page Content |
|------|----------------------|
| **vCard** | Contact card with name, phone, email, company, photo; **Download .vcf** button |
| **vCard Plus** | Enhanced vCard — all vCard fields plus a branded landing page |
| **Business** | Business profile: name, tagline, phone, email, address, opening hours, logo |
| **Social Media** | Social profile aggregator: Instagram, Facebook, X/Twitter, LinkedIn, YouTube, TikTok, Snapchat |
| **Event** | Event details: title, date/time, venue/location, organizer, RSVP link |
| **Coupon** | Discount offer: coupon code, discount %, valid dates, terms & conditions |
| **Apps** | Smart app redirect: detects iOS → App Store, Android → Play Store |
| **Link Page** | Multi-link page (bio-link style) with per-link click tracking |
| **Landing Page** | Custom hero page: headline, description, CTA button, theme color, background style, font |

### Bulk Creation

- Create up to **50 QR codes in a single API call** via `POST /qr/bulk`
- Each QR in the batch can have independent type, design, and content

---

## 2. QR Design & Customization

Every QR code has an independent design record with full visual control.

### Dot Patterns

| Option | Values |
|--------|--------|
| **Shape** | `square`, `rounded`, `circle`, `diamond`, `star`, `heart` |
| **Color** | Any hex color |
| **Scale** | 0.5 – 1.1 (controls dot density) |
| **Gradient** | Linear or radial; customizable color stops + rotation angle |

### Corner Eyes

| Option | Values |
|--------|--------|
| **Outer square shape** | `square`, `rounded`, `extra-rounded`, `dot` |
| **Outer fill color** | Any hex color |
| **Outer border color** | Any hex color |
| **Inner dot shape** | `square`, `circle` |
| **Inner dot color** | Any hex color |

### Background

- Solid color (any hex)
- Transparent (for PNG overlay exports)
- Custom border radius (0 – 48px)
- Gradient background (linear/radial)

### Center Logo

| Option | Detail |
|--------|--------|
| Preset icons | Facebook, Twitter/X, LinkedIn, WhatsApp, Globe, User |
| Custom upload | SVG, PNG, JPG up to 2 MB (drag & drop supported) |
| Logo size | 10% – 50% of QR width |
| Opacity | 10% – 100% |
| Border radius | 0 – 64px |
| Padding | 0 – 24px |
| Background color | Configurable background behind logo |
| No quiet zone | Toggle to extend logo over quiet zone |

### Frame & Label

| Option | Detail |
|--------|--------|
| Frame templates | 14 SVG frames: Standard, Modern, Simple, Badge, Tag, Phone, Watch, Envelope, Hand, Sketch, Beer, Delivery, Coffee, No frame |
| Frame text | Custom label (e.g. "SCAN ME") |
| Text color | Any hex color |
| Frame color | Any hex color |
| Frame background color | Any hex color |
| Font family | Inter, Roboto, Outfit, Poppins, Arial, Georgia, Courier New |
| Font size | 10 – 120px |
| Font weight | Normal, Bold, 400/600/700/800/900 |
| Text position | Top, Bottom, Top + Bottom |

### Output Settings

| Option | Detail |
|--------|--------|
| Error correction | L (7%), M (15%), Q (25%), H (30%) |
| Width | 100 – 4096px |
| Margin | 0 – 20 modules (quiet zone) |
| Download format | PNG, SVG, JPEG, WebP |
| QR size presets | Small (300px), Medium (600px), Large (1200px) |

### Landing Page Design

For rich-content QR types (Business, Landing Page, etc.):

- `themeColor` — Primary brand color
- `backgroundStyle` — solid, gradient, pattern
- `fontStyle` — Typography preset
- `buttonStyle` — CTA button shape/style
- `sectionDividers` — Toggle section dividers

---

## 3. QR Builder Flow

A 4-step visual wizard:

```
Step 1: Choose Type  →  Step 2: Add Content  →  Step 3: Page Design  →  Step 4: QR Design
```

| Step | What happens |
|------|-------------|
| **1 — Choose Type** | Select one of 14 content types |
| **2 — Add Content** | Fill type-specific form (URL, vCard fields, business info, etc.) |
| **3 — Page Design** | Customize the landing page appearance (theme, colors, layout) |
| **4 — QR Design** | Customize dots, corners, logo, frame, output format — with live preview |

- **Live preview** updates in real time as settings change
- **NavButton** navigation with validation before advancing
- **Edit flow** available on existing QRs with same step structure

---

## 4. Smart Routing & Destinations

### A/B Split Testing

- Attach multiple **destinations** to a single QR code
- Each destination has a **weight** (percentage) — traffic is distributed accordingly
- Example: 70% → landing page A, 30% → landing page B

### Conditional Routing Rules

Destinations support **rule-based routing** via JSONB conditions:

| Condition Type | Example |
|----------------|---------|
| **Geo (country)** | Redirect French users to `/fr/`, US users to `/en/` |
| **Device type** | Mobile users → App Store, Desktop → website |
| **Time-based** | Show special offer during business hours |

### Short Code Generation

- 6-character alphanumeric short codes (e.g. `abc123`)
- Unique per workspace
- Synced to Cloudflare KV instantly on create/update
- Custom domain support (use your own domain for short URLs)

---

## 5. Edge Delivery (Cloudflare Worker)

The Cloudflare Worker resolves every QR scan at the edge with zero cold-start latency.

### Lookup Flow

```
User scans QR
    ↓
Cloudflare Worker receives /{short_code}
    ↓
KV lookup (sub-millisecond)
    ↓
Determine QR type
    ↓
Redirect   OR   Render HTML landing page
    ↓ (background, fire-and-forget)
POST scan event to backend
```

### Landing Page Rendering

The Worker generates complete HTML pages server-side for:
- vCard display + .vcf download
- Business profiles
- Social media aggregators
- Event detail cards
- Coupon / discount offers
- Multi-link (link page) listings
- Image galleries
- Custom hero landing pages

### Per-Link Click Tracking

- Each link on a Link Page has its own click counter
- Worker fires a background POST to `/internal/link-click/{link_id}` on click
- User is immediately redirected without waiting for the tracking call

### Error States

- **Short code not found** — Custom 404 page
- **QR inactive / scan limit reached** — Friendly "expired" page
- **Backend fetch failure** — Graceful error page
- **Malformed request** — 400 response

---

## 6. Scan Analytics & Tracking

### Per-Scan Data Collected

Every scan event records:

| Field | Detail |
|-------|--------|
| QR ID & short code | Which QR was scanned |
| Timestamp | UTC datetime |
| Country, Region, City | From Cloudflare geo headers |
| Timezone, Lat/Lon | Precise location metadata |
| Device type | `mobile`, `tablet`, `desktop`, `bot` |
| User agent | Full UA string |
| IP hash | SHA-256 hashed (privacy-preserving, not stored raw) |
| ASN | Network/ISP identifier |
| Session ID | Hash of IP + UA + date (enables deduplication) |
| Referrer domain | Where the scan came from |
| Language | Browser/device language |
| Is unique | Determined per session (prevents refresh inflation) |

### Analytics Endpoints & Metrics

| Metric | Description |
|--------|-------------|
| **Total scans** | Lifetime scan count per workspace or QR |
| **Unique visitors** | Session-deduplicated count |
| **Week-over-week change** | % difference vs previous 7-day window |
| **Daily scan series** | Day-by-day counts for the last 30 days (configurable) |
| **Top QR codes** | Top 10 by scan count |
| **Device breakdown** | Mobile / Tablet / Desktop / Bot with percentages |
| **Country breakdown** | Scan distribution by country |
| **Hourly pattern** | Scans aggregated by hour of day |

### Subscription Enforcement

- Each plan has a `max_scans` quota
- When quota is exhausted → dynamic QR codes are automatically disabled
- Worker returns "scan limit reached" page to users

---

## 7. File & Media Storage

Backed by **Supabase Storage** with signed URL delivery.

### Supported Formats

| Category | Formats |
|----------|---------|
| Images | JPG, JPEG, PNG, GIF, WebP, SVG |
| Documents | PDF |
| Video | MP4, MOV, WebM |
| Audio | MP3, WAV, OGG |

### Upload Flows

- **Direct upload** via backend (`POST /storage/upload`) — file posted to API
- **Presigned upload** (`POST /storage/media/upload-url`) — client uploads directly to Supabase, then confirms via `POST /storage/media/confirm`
- **Signed URL retrieval** — configurable expiry from 60 seconds to 7 days

### File Operations

- List all files for a workspace
- Get signed download/view URL for any file
- Delete file from storage
- Files attached to QR codes are tracked with foreign key relations

---

## 8. Workspace & Team Management

### Multi-Tenancy

- Every user belongs to one or more **workspaces**
- Each workspace has its own QR codes, members, subscription, analytics, and settings
- Workspaces are identified by a unique **slug** (used in URLs)
- New users automatically get a **default workspace** on first login

### Roles & Permissions

| Role | Capabilities |
|------|-------------|
| **Owner** | Full access: manage members, billing, settings, all QR operations |
| **Editor** | Create/edit/delete QR codes, manage folders, upload files |
| **Viewer** | Read-only: view QR codes and analytics |

### Invitation Workflow

1. Owner sends invite via email (Resend)
2. Invitee receives invitation email with token link
3. Clicking link → `/(auth)/invite?token=...`
4. Token validated → user joins workspace with assigned role
5. Pending invitations visible in the Members list
6. Invitations can be revoked before acceptance

### Member Management

- View all active members and pending invitations in one list
- Change any member's role (Owner only)
- Remove member from workspace (Owner only)
- Revoke pending invitation (Owner only)

---

## 9. Authentication & Security

### Authentication

- **Supabase Auth** — email/password sign-up and login
- **JWT Bearer tokens** — all API requests authenticated via Authorization header
- **Public routes** excluded from auth middleware (webhook endpoints, internal Worker endpoints with shared secret)
- **OAuth callback** — `/auth/callback` handles Supabase OAuth flows

### API Security

- All protected routes require valid JWT
- Internal Worker → Backend routes protected by `x-internal-secret` shared header
- Razorpay webhooks verified via HMAC signature

### Login History

- Last 50 login events recorded per user
- Recorded fields: IP address, device/user agent, country, city, timestamp

### Security Preferences

Users can configure notification triggers for:
- New login from unknown device/location
- Password change events
- Two-factor authentication changes

### API Tokens

- Create workspace-scoped API tokens for programmatic access
- Token is shown **once** at creation (full value never stored — only hashed)
- Optional expiry (1 – 365 days, or never)
- `last_used_at` tracking
- Only Owners and Editors can create tokens
- Any token can be revoked at any time

### GDPR / Data Privacy

- `GET /security/export-data` — exports all personal data as JSON
- IP addresses are stored as hashed values only (never raw IPs in scan events)
- Session IDs are derived hashes, not persistent identifiers

### Password Security

- bcrypt + argon2 dual-hashing for stored passwords
- Pre-commit hooks enforce code quality

---

## 10. Subscription & Billing

### Plan Tiers

| Plan | Target |
|------|--------|
| **Free** | Individual / trial use |
| **Starter** | Small teams |
| **Pro** | Growing businesses |
| **Business** | Large organizations |
| **Custom** | Enterprise (scoped per workspace, admin-configurable) |

### Plan Limits

Each plan enforces two hard limits:

| Limit | Description |
|-------|-------------|
| `max_qr` | Maximum number of active QR codes |
| `max_scans` | Maximum total scan events |

### Subscription States

```
trialing → active → past_due → canceled
```

### Razorpay Integration

- Create subscription via `POST /razorpay/subscriptions/create`
- Payment verified via HMAC after checkout (`POST /razorpay/subscriptions/verify`)
- Cancel via `POST /razorpay/subscriptions/cancel`
- **Webhooks handled:**
  - `subscription.activated` — marks subscription active
  - `subscription.charged` — records successful payment
  - `subscription.halted` — flags past-due
  - `subscription.cancelled` — marks canceled
  - `payment.failed` — flags failed payment

### Billing Flows (Frontend)

- **/billing** — View current plan, usage, next renewal
- **/billing/upgrade** — Plan comparison + upgrade flow with Razorpay checkout
- **/billing/success** — Post-payment confirmation page
- Limit check endpoint (`GET /subscriptions/limit-check`) used by builder to prevent over-quota creation

---

## 11. Custom Domains

Use your own domain for QR short URLs (e.g. `go.yourbrand.com/abc123`).

### Setup Flow

1. Register domain via `POST /custom-domains/`
2. System generates a unique `TXT` verification token
3. User adds two DNS records to their domain:
   - `TXT` record: `qr-verification=<token>`
   - `CNAME` record: pointing to `cname.qrcode-service.com`
4. Trigger verification via `POST /custom-domains/{id}/verify`
5. System checks DNS resolution — status updated to `verified` or `failed`

### Domain Features

- Multiple custom domains per workspace
- Domain status tracking: `pending` → `verified` / `failed`
- Verified domains available for QR short URL assignment
- Domains can be updated (resets verification)
- Domains can be deleted (QR codes revert to default domain)

---

## 12. Folders & Organization

Hierarchical folder system for organizing QR codes.

### Folder Features

- Unlimited nesting depth (parent/child tree structure)
- **Full tree view** via Postgres RPC (`GET /folders/tree`) — returns recursive tree in a single call
- Create, rename, move (update `parent_id`), delete folders
- Delete cascades to all sub-folders
- QR codes in a deleted folder become unorganized (not deleted)
- Root-level folders and sub-folders handled with `parent_id = null`

### Frontend

- Tree view UI for browsing folder hierarchy
- Drag-and-drop QR code organization
- Folder breadcrumb navigation

---

## 13. API & Developer Access

### REST API

All backend functionality is available as a REST API, documented and accessible to workspace members with valid API tokens.

### API Tokens

- Scoped to a single workspace
- Created via Dashboard → Developers → API Tokens
- Optional expiry; `last_used_at` tracked
- Shown in full **once** at creation — hash stored thereafter
- Used as Bearer token in Authorization header

### Internal Worker API

The Cloudflare Worker communicates with a separate set of internal endpoints, protected by a shared secret header:

| Endpoint | Used for |
|----------|----------|
| `GET /internal/link-page/{qr_id}` | Fetch link page content |
| `GET /internal/business/{qr_id}` | Fetch business profile |
| `GET /internal/vcard/{qr_id}` | Fetch vCard data |
| `GET /internal/social-media/{qr_id}` | Fetch social links |
| `GET /internal/event/{qr_id}` | Fetch event details |
| `GET /internal/coupon/{qr_id}` | Fetch coupon data |
| `GET /internal/apps/{qr_id}` | Fetch app store links |
| `GET /internal/landing-page/{qr_id}` | Fetch landing page content |
| `GET /internal/signed-url/{qr_id}` | Fetch signed URLs for files |
| `POST /internal/scans` | Ingest scan events from Worker |
| `POST /internal/link-click/{link_id}` | Increment link click counter |

---

## 14. Notifications & Support

### Email Notifications (via Resend)

- **Workspace invitation** — Sent to invitee with accept link
- **New login alert** — Notifies user of login from new device/location (if enabled)
- **Password change** — Security notification (if enabled)
- **2FA change** — Security notification (if enabled)
- **Support ticket confirmation** — Auto-reply to user after contact form submission

### In-App Support

- **/help** — FAQ and documentation links
- **/contact** — Support request form

**Contact categories:**
- Technical issue
- Billing question
- Feature request
- General inquiry
- Other

---

## 15. Frontend & UX

### Tech Stack

- **Next.js 14** App Router with route groups for auth and workspace flows
- **TanStack Query v5** for server state management and caching
- **Zustand** for client-side UI state
- **shadcn/ui** (Radix UI primitives) + **Tailwind CSS**
- **Axios** API client with base URL and auth token injection
- **Lucide React** + **React Icons** icon libraries
- **react-hook-form** + **zod** for form validation

### QR Generation Libraries

- `qrcode` — Base QR matrix generation
- `qr-code-styling` — Advanced styled QR code rendering (dots, gradients, logos)

### Dashboard Features

- **Workspace switcher** — Switch between multiple workspaces from sidebar
- **Usage tracker** — Visual progress bars for QR count and scan count vs. plan limits
- **QR list** — Search, filter by type/status, sort by date/scans
- **QR detail view** — Full stats, edit inline, scan history
- **Analytics dashboard** — Charts for daily scans, device breakdown, top QRs, geo
- **Billing page** — Plan overview, usage, upgrade/downgrade
- **Members page** — Invite, role change, remove members
- **Domains page** — Add, verify, manage custom domains
- **Security page** — Login history, API tokens, notification preferences
- **Folders page** — Tree-view folder management

### Payments

- **Razorpay checkout script** injected in root layout (`src/app/layout.tsx`)
- Checkout triggered client-side, verified server-side via HMAC
- Subscription status reflected in UI immediately post-webhook

### Design System

Follows the **QR Architect** design system (`DESIGN_SYSTEM.md`):

- **Primary color:** Indigo `#4648d4`
- **Accent:** Cyan `#06b6d4`
- **Font:** Inter (weights 300–900)
- **Surface hierarchy:** 10-level tonal stack (no heavy borders)
- **Dark mode:** `.dark` class on `<html>`, all tokens overridden via CSS custom properties
- **Component patterns:** `card-surface`, `btn-primary`, `glass-header`, `sidebar-item-active`
- **Elevation:** Atmospheric tonal layering, ambient shadows only (no heavy drop shadows)

---

## Architecture Summary

```
User scans QR
    └── Cloudflare Worker (KV lookup, edge render/redirect, background scan tracking)
            └── FastAPI Backend (scan ingest, content fetch, file signed URLs)
                    └── Supabase PostgreSQL (all data)
                    └── Supabase Storage (files, images, PDFs)
                    └── Razorpay (billing)
                    └── Resend (email)

User uses Dashboard
    └── Next.js Frontend (App Router, TanStack Query)
            └── FastAPI Backend (REST API, JWT auth)
                    └── Cloudflare KV (sync on QR create/update)
```

---

*Last updated: 2026-04-08 | Covers: qr_backend · qr_frontend · qr_cf_code*
