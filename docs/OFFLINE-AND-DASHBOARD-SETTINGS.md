# Dashboard settings and offline work

Implemented 15 November 2026 in the existing application and colour themes.

- Fleet companies open Fleet operations using their saved service capabilities. New company registration offers Cargo, Fleet or Combined services. Approval and assigned employee roles still govern access. The platform owner can preview each business mode without creating fake companies.
- App settings provides a per-account Modern / Legacy preference. Legacy features render inside the shared navigation; old dashboard URLs redirect into the current workspace. Fleet operations remains available in either view.
- Production builds precache the application shell and lazy screen assets. Private records use account/project-scoped IndexedDB, separate from the service-worker cache. Open screens online first; common permitted tables also download up to 500 rows per table. This is downloaded data, not an unlimited database replica.
- Supported requests, comments, shipment/task actions, inventory/dispatch actions, messages, selected record forms and attachments queue on this device while offline. Queued changes sync when the signed-in app reconnects, opens, regains focus or retries on its 15-second timer. Keep the app open to sync; closed-app authenticated background execution is not promised.
- The server applies current permissions and workflow checks. Stable operation IDs and transaction receipts prevent duplicate replay after a lost reply. Conflicting edits and rejected operations remain visible in Settings for review. A second offline change to the same pending record requires syncing the first.
- First sign-in, password/account changes, unsupported forms and financial approvals require internet. Payment-reference submission can queue; verification remains online. Expired sessions require renewed authentication before server sync. Explicit sign-out clears downloaded private cache; owner-scoped pending operations remain for that same account to resume.
- Native installation opens directly when the browser supplies an install prompt. Otherwise the button reads Install options and provides browser-specific instructions. The app cannot force a browser to offer native installation.

Applied additive migration: `20261115121537_logistics_offline_sync.sql`. The fresh installer contains eleven ordered migrations. Existing 23 unrelated public tables were preserved; no hosted test companies, accounts, comments or payments were created.

Validation: production build and all npm test suites passed. Isolated tests cover persistent queue/cache, account isolation, attachment replay, lost replies, stale conflicts, server RLS, forbidden administrative RPCs, preference upserts and validated status actions. Signed-in browser checks covered shared Legacy navigation, Fleet preview, Modern settings, offline reload of the existing customer request and return to online mode. Native OS installation and a live queued business mutation were not performed.

Supabase advisories still include intentional guarded RPC execution and pre-existing unrelated table/function/Auth findings. The new sync endpoint uses security invoker; no new logistics RLS-without-policy finding was reported. Advisor documentation: https://supabase.com/docs/guides/database/database-linter
