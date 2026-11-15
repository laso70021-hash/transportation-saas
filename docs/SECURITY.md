# Security boundaries and deployment requirements

## Keys and configuration

A Supabase publishable key is public client configuration. Hiding it in `.env` or moving a copy into Supabase cannot make a browser credential secret. Every `VITE_` variable is eligible for bundling. RLS, grants, validated Auth sessions and trusted transactional APIs enforce security.

Secret/service-role keys are prohibited in browser forms, frontend code, Git, downloadable production configuration and public assets. The connector rejects them. The local account provisioning script uses a server credential only in its trusted Node process; it is never imported by the web build. The optional payment Edge Function uses the caller's JWT and a publishable key, retaining RLS and RPC role checks.

## Authorization

- Roles come from protected membership/platform-admin tables, never user-editable signup metadata.
- All new public tables have RLS and explicit grants. Compound tenant foreign keys prevent cross-company relationships.
- Operational financial, assignment, warehouse, status, verification and proof writes use guarded database functions with empty search paths, explicit execution grants and transactional locks. Public execution is revoked.
- Warehouse roles cannot read payout destinations or the financial ledger. Viewer roles cannot mutate operations.
- Assignment locks driver/vehicle rows, requires active confirmed driver linkage, checks capacity and conflicting tasks; direct assigned-vehicle edits are rejected.
- Shipment identity is immutable. Status and driver changes cannot bypass their RPC through general UPDATE grants.
- Pickup requires an authorized persisted scan. Delivery requires private uploaded photo/signature metadata and recipient evidence. Customer knowledge of the QR payload is not operational authorization.
- Payments stay submitted until authorized review. Verified history cannot be repriced, ledger rows snapshot commission once, settlement/payout balances are locked and retries use unique keys.
- Non-finite numeric values are rejected at database boundaries.

## Storage and privacy

`sl-documents` is private, size/MIME constrained, scoped to tenant/category/entity paths. Browser evidence overwrite/delete is not granted. A failed multi-file upload can leave an orphan; retention and server-side orphan cleanup remain operator tasks. Database object existence does not prove the legal authenticity of uploaded evidence; reviewers must inspect it.

GPS sharing is opt-in, stops when the component unmounts and saves actual device coordinates. Map tiles disclose network information and displayed location to the map provider. Consider a contracted map/tile service for commercial volume. There is no simulated GPS route or background location guarantee.

Auth sessions remain in Supabase browser storage; protect against XSS, keep dependencies reviewed and revoke sessions when changing critical access. Successful SQL authorization tests are not a penetration test.

## Before commercial deployment

1. Confirm the correct existing Logistics project and audit its live schema, policies, triggers, migrations and data. Back up and rehearse on a staging branch.
2. Run actual Supabase migrations and database advisors. Test every API as each role, including expired/suspended organizations and two independent companies/customers.
3. Review Auth signup, email confirmation, password/MFA policies, refresh/JWT lifetime, redirect allowlist, rate limits and admin bootstrap through a trusted secure channel.
4. Configure actual server secrets, external providers and `APP_ORIGIN`; never add production keys to public SQL/settings tables. `sl_settings` is for non-secret settings only.
5. Verify hosting honors security headers, SPA rewrites and CSP. Vercel uses the supplied `vercel.json`; `_headers` and `_redirects` target hosts supporting that format. Adjust Supabase custom domains deliberately. Local HTTP is development-only. TLS and appropriate security headers must be verified on the selected host.
6. Execute actual Storage byte upload/download and policy tests, Realtime subscription checks, device camera/GPS/signature/PWA tests and offline/rejected-mutation behavior.
7. Reconcile historical verified payments/commissions, settlement allocations and payouts with source evidence before using the new ledger commercially. Existing historical data was not accessible here.
8. Set retention, backup/restore, monitoring, incident handling and legal entity/contact policies. No hosted advisor or production security certification is claimed in this handoff.

## Compatibility changes

The previous instant marketplace booking RPC and direct status/assignment updates are intentionally revoked in v3. They bypassed the new quote approval, assignment or proof rules. The original additional-tools booking/progression controls now direct users to the new workflow pages. The archived validation mutator may report a deliberate policy rejection against v3; inspect there, execute operational transitions in the v3 shipment UI.
