---
trigger: model_decision
---

Code Style & Architecture Enforcement Prompt
You are working in a QR Code SaaS monorepo. Follow these rules strictly for all frontend work:

Design Workflow (MANDATORY — do this first)
Before writing any UI component or page:

Use the Stitch MCP to fetch the design reference for the feature being built.
Analyze the design for layout, spacing, color tokens, and component boundaries.
Map each design element to an existing shadcn/ui component before considering custom implementations.
Frontend Component Rules
Use shadcn/ui first — always.

Every UI element must use a shadcn/ui primitive if one exists: Button, Card, Dialog, Input, Select, Table, Tabs, Badge, Sheet, Dropdown, Tooltip, Form, Avatar, Skeleton, etc.
Do NOT write raw HTML elements (<button>, <input>, <select>) when a shadcn/ui equivalent exists.
Do NOT install a third-party UI library if shadcn/ui already covers the use case.
Extend shadcn/ui components via className + cva variants — never override with inline styles.
Component-based architecture.

Every piece of UI must live in its own file inside src/components/.
Organize by feature: src/components/qr/, src/components/workspace/, src/components/analytics/, etc.
Shared/generic components go in src/components/ui/ (shadcn lives here already).
Pages (src/app/) must be thin — they compose components, they do not contain business logic or raw JSX blocks.
Reusability rules.

If the same UI pattern appears more than once, extract it into a shared component immediately.
Components must accept props for all variable content — no hardcoded strings or values inside component files.
Use TypeScript interfaces for all component props — no any, no implicit types.
Compound components (e.g. Card > CardHeader > CardContent) are preferred over monolithic blobs.
Styling.

Tailwind CSS utility classes only — no style={{}} inline styles.
Use cn() (from src/lib/utils.ts) for conditional class merging.
Follow existing color/spacing tokens from tailwind.config.ts — do not hardcode hex values.
State & Data
Server state: TanStack Query (useQuery, useMutation) — never useEffect + fetch.
Client/UI state: Zustand stores in src/store/.
Forms: react-hook-form + zod schema validation — no uncontrolled inputs.
General Code Quality
No component file should exceed 200 lines. Split if it does.
Export one component per file.
Name files in kebab-case, components in PascalCase.
Do not duplicate logic — check src/hooks/ before writing a new one.