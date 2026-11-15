# Swahivo Logistics engineering report

Date: 14 November 2026. Status: development integration; hosted deployment/database acceptance incomplete.

## Actual repository condition

Recovered existing Sites source commit `c4849c4677e76e2b5fcc2da3e6239441e845f4cf`. It was Next.js/JavaScript, despite the requested Vite/TypeScript target. The original source, SQL, public artwork, existing workflows and validation suite are retained. The active frontend now uses Vite/React/TypeScript with React Router. No hosted production records were read, changed or deleted.

No usable Logistics Supabase connection or migration authority was present. Per the user's later direction, work continued in isolated development. `supabase start` was actually attempted and failed because Docker and Podman are unavailable. No unrelated remembered Supabase project was used.

## Phase status and engineering evidence

| Phase | Work and files | Database/routes/operations | Observed result / blockers |
|---|---|---|---|
| 1 Repository audit | Inspected `app/components/{runtime,SaaS,PublicSite,modules}.js`, validation, styles, package/hosting files, all existing SQL and both test suites | Inventoried 3 original workspaces, linked client/order/shipment tracking, billing, support, profiles, reviews and admin tools | Completed source audit; live database inspection unavailable |
| 2 Backend connection | Updated `.env.example`; `src/lib/api.tsx`, `/connect`, `/access`, legacy connection compatibility | One Supabase client per active workspace tree; public keys only, HTTPS/local development validation | Secret-key rejection observed in browser; no live connectivity success claimed |
| 3 Database/security | Added baseline/v3 CLI migrations, `public/operations-upgrade.sql`, development seed | Extended existing `sl_*` schema with verification, booking/quotes, tasks, vehicles, packages, stock, POD, scans, locations, fee history, ledger, settlements/payouts; RLS/grants/private Storage policies | 39 v3 SQL assertions pass. No hosted migration or advisor execution |
| 4 Critical workflow | `src/features/{Records,CreateShipment,Tracking,Proof,Invoice}.tsx`, forms/API | Booking → assignment → quote → acceptance → shipment/invoice; manual fees; task conflict checks; scan gates; proof; audited finance/stock RPCs | SQL workflow pass; actual Auth/Storage/camera/GPS browser flow unverified |
| 5 Admin | Admin sidebar/routes, provider verification, assignment, finance/settlement/payout forms, team and reports | Authenticated mutations and database audit; exports page all filtered rows through RLS | Code/build integrated; full protected-page interaction and visual QA pending backend |
| 6 Provider | Independent request, shipment, pickup, delivery, warehouse, inventory, dispatch, fleet, pricing, earnings/settings routes | Actual persisted records; no invented metrics or payout counters; original supplemental tools retained | SQL assertions cover underlying operations; protected browser acceptance pending |
| 7 Customer/driver/warehouse | Five independent route groups; customer quote approval/payment requests; driver camera/GPS/task controls; warehouse receipt/reserve/pack/release | Same Supabase database, task/owner/role RLS; PWA manifest and asset shell; network-only API writes | Device permissions, actual file bytes, install/background behavior not tested |
| 8 Reference implementation | White/red latest role shell, blue operation controls, tables, split details, creation summary; retained dark public landing | Inspected reference inventory/contact sheet and full booking-assignment reference; public reference compared in browser | Fixed missing stylesheet and heading layout leak. Desktop public and 390px mobile / 768px connection layout screenshots inspected. Every protected page has NOT been visually compared; not claimed matched |
| 9 Testing | Original suites, new `tests/operations.mjs`, optional localhost API runner; `.development/test-results.txt` copied to `docs/test-results.txt` | 26 previous SaaS assertions + original linked workflow suite + 39 v3 SQL assertions | Pass locally. API/device/offline mutations/Realtime end-to-end tests blocked |
| 10 Readiness/package | README, security/workflow docs, migrations, source ZIP and guarded development accounts | Production keys absent; static build compiles, type checking passes, source retained | Production readiness NOT declared |

## Files created/modified

Created `src/main.tsx`, component shell/UI/form/error-state files, API/types/module definitions, dashboard/report/access/records/shipment/tracking/proof/invoice/warehouse-layout features, Vite/TypeScript entry configuration, local provisioning/test runners, Supabase config/migrations/development seed/optional review-payment Edge Function, PWA shell/assets and security adapter files.

Modified `package.json`, lockfile, `.gitignore`, `.env.example`, hosting output directory and documentation. Original `app/` files and preexisting public migrations remain. Ported legacy runtime/public/SaaS files preserve supplementary tooling with documented operational security redirects.

No database migration was applied to a hosted project. Migration names and source inventory are in the delivered repository.

## Observed tests

- `npm run build`: passed, TypeScript + Vite production output. Heavy map/scanner/PDF features are separated from initial public rendering; further bundle tuning remains useful.
- `npm test`: original linked workflow suite passed; 26 previous SaaS checks passed; 39 v3 SQL checks passed. These use PGlite, with minimal Auth/Storage metadata contracts.
- v3 checks include two companies/two customers, tenant read/write denial, viewer denial, warehouse financial denial, eligible provider assignment, idempotent shipment creation, fee history, task notification, driver/vehicle conflict, pickup scan rejection, invalid QR rejection, missing proof rejection, Delivered shipment AND task filtering, duplicate payment/payout rejection, ledger commission snapshot, payout overdraw denial, finalized fee protection, inventory receipt/reservation/release and guarded idempotent development SQL.
- Actual browser: public landing render and stylesheet repair; protected `/admin/dashboard` redirects to access; server-secret test string rejected; 390px public navigation opens; 768px connection form renders; legal route inspection. Protected operational UI has not been exercised with actual Auth.
- `supabase start`: blocked, `docker: command not found (podman also not found)`.

## Incomplete requirements / material limitations

This handoff does not claim every requested feature complete. Remaining work includes full hosted/local Supabase service integration, live-schema-specific repair/advisors, exhaustive per-page reference screenshot comparison, actual 24-step cross-role browser acceptance, camera/device/GPS/Realtime/Storage bytes tests, full offline and rejected-write UI acceptance, hosted auth registration/email flows, staff email invitation delivery, automatic bank/mobile-money/webhook/refund integrations, detailed fuel/maintenance/performance analytics, advanced warehouse cycle counts/transfers/discrepancies and stock billing automation, production subscription payment entitlement reconciliation, commercial map provider capacity/terms, monitoring and evidence retention/orphan cleanup. Basic records/CRUD/RPC paths exist where described; no fake controls are presented as external integrations.

Selectors currently load up to 200 authorized reference options; main record tables paginate 20 and complete reports paginate all results. The old supplemental tools retain their original 100-row loading behavior. Warehouse visual placement is capped for readability; stored coordinates remain intact. Timeline/relationship inspectors cap linked queries at 100. These limits are visible/documented and need server-search selectors for very large tenants.

## Demo account status

Eight proposed local credentials are delivered separately and inside the source ZIP's ignored development folder. They are not provisioned Auth users in this environment. `npm run dev:seed` creates and verifies them only against localhost, then persists the development SQL records. Never import those sample accounts or development administrator into production. Hosted accounts and passwords are not fabricated or claimed verified.
