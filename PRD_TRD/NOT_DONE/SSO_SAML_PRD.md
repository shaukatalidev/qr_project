# PRD — SSO / SAML (Decision: Enterprise / Contact-Sales only)

**Status:** Decision record · **Author:** Engineering · **Date:** 2026-06-14
**Outcome:** **Do NOT build self-serve SSO.** Handle as enterprise / contact-sales.
**Plan flag:** `sso` — stays `inert` in `FEATURE_ENFORCEMENT`; granted only via custom plans.
**Split from:** `PLAN_LIMITS_ENFORCEMENT_PRD.md` (open question §11.1 — now resolved).

---

## 1. Decision
SSO/SAML is **not** a self-serve feature on Free/Starter/Pro/Agency. It is offered **only through enterprise / contact-sales** deals on a **custom plan** (`plans.is_custom = true`) with `sso = true`. We will not build a self-serve SAML/OIDC integration now.

## 2. Rationale
- **Cost vs. demand:** self-serve SAML/OIDC is a heavy build (per-IdP config, metadata exchange, JIT provisioning, the usual SCIM expectations, IdP-quirk support burden) for an ICP that is SMBs/agencies paying ₹399–₹2,499 / $9–$39 self-serve. The demand signal isn't there.
- **Industry norm:** SSO is almost universally an enterprise gate ("SSO tax"), sold via contact-sales, not self-checkout.
- **No tier was ever assigned** to SSO on the pricing page — it was marketing copy. Resolving it as enterprise-only removes the ambiguity cleanly.

## 3. Actions (small, no feature build)
1. **Pricing page:** the SSO row is currently relabeled "Coming soon" (from the enforcement work). Change it to **"Contact sales"** (or move it into an "Enterprise" callout below the self-serve compare table). Files: `qr_frontend/src/components/pricing/PricingComparisonTable.tsx`, `PricingCards.tsx`.
2. **Registry:** keep `FEATURE_ENFORCEMENT['sso'] = 'inert'` (subscription.py). The feature-gate coverage test stays green (inert is valid). No `check_feature('sso')` gate exists because there is no self-serve surface to gate.
3. **Enterprise provisioning path:** when a deal closes, create a **custom plan** (`is_custom=true`) with `sso=true` for that workspace. `resolve_plan`/`get_plan` are intentionally NOT filtered by `is_public`, so a custom plan works without any pricing-page exposure (the same grandfathering path used for retired tiers).
4. **Sales collateral:** an "Enterprise" contact form / mailto is sufficient; no in-app SSO settings.

## 4. Future build path (only if enterprise demand materializes — out of scope now)
If/when we do build it, the likely implementation — captured so the decision is reversible with context:
- **Provider:** Supabase Auth's native **SAML 2.0 SSO** (it backs our auth already) or **WorkOS** as an SSO/Directory abstraction — avoid hand-rolling SAML.
- **Model:** per-workspace IdP connection, **domain-based routing** (email domain → IdP), **JIT provisioning** into `workspace_members`, optional SCIM for deprovisioning.
- **Gating:** at that point, build the connection UI + flip `sso` `inert→enforced` in the same PR (coverage-test rule), and assign it to a real (enterprise) tier.

## 5. Open Questions (for sales/product, not engineering)
1. Enterprise pricing/packaging (seat minimums, annual-only?).
2. Is SCIM (auto-deprovisioning) table-stakes for the buyers we'd target?
3. Trigger threshold — how many inbound enterprise SSO requests before we revisit §4?

## 6. Appendix — Key Files
| Concern | File |
|---|---|
| Pricing copy (relabel to Contact sales) | `qr_frontend/src/components/pricing/PricingComparisonTable.tsx`, `PricingCards.tsx` |
| Registry (stays inert) | `qr_backend/src/api/routes/subscription.py` (`FEATURE_ENFORCEMENT['sso']`) |
| Custom-plan grandfathering path | `qr_backend/src/api/routes/subscription.py` (`resolve_plan`/`get_plan` — unfiltered by `is_public`) |
