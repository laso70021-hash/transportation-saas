# UI reference integration

The supplied `Swahivo_UI_After_1204/SCREEN_INDEX.md`, `screen-index.json` and 17 screen images informed these additions. The existing React/Vite application, dark navy/red theme, light theme switch, Supabase authentication, role dashboards, PWA and operational workflows were retained. The reference companies, people, prices and counts were not imported.

## Screen coverage

1. Provider service onboarding: `/onboarding`, after company registration; also `/provider/capabilities`. Choose cargo, fleet or both and individual service features.
2. Cargo dashboard: `/provider/dashboard` for company administrators and operators when cargo capabilities are enabled.
3. Fleet dashboard: `/provider/fleet`; also the company dashboard for fleet-only businesses. Actual availability counts, hire dispatch board, maintenance and vehicle records.
4. Combined dashboard: `/provider/dashboard` when cargo and fleet are enabled. All/cargo/fleet views and shipment handoff links.
5. Administrator controls: `/admin/service-capabilities`. Company selection, service changes, reasons, effective dates, review and history. Employee roles remain separate.
6. Customer home: `/account/dashboard`. Saved route preferences, matching published services, drafts, repeat requests and active bookings.
7. Public discovery: `/discover`. Ship, hire, store and store/deliver choices with actual route and cargo filters.
8. Provider profile: `/providers/:providerId`. Published services, coverage, terms and explicitly public business contacts.
9. Cargo request: `/account/request-quote?listing=...`. Origin/destination and sender/receiver sections, packages, dimensions, contacts, collection date, consent, draft and review.
10. Hire request: `/account/hire-vehicle?listing=...`. Vehicle-only or with-driver listing, dates, pickup, usage, trip purpose, cargo, loading help, contacts and review.
11. Customer Covlo: `/account/covlo`, plus embedded panels.
12. Provider Covlo: `/provider/covlo`, plus embedded panels.
13. Booking report: `/account/booking/:bookingId`. Saved shipment location, tracking timeline, quotations, invoice amounts and downloadable text report.
14. Listing builder: `/provider/catalog`. Cargo/hire/storage listings, multiple routes, direction, cargo limits, contact visibility, draft/published/paused status and review before saving.
15. Actual conversations: `/account/messages` and `/provider/messages`. Participant-only threads, persisted messages, related requests and private file attachments.
16. Account matching providers: `/account/find-providers`, `/account/discover`. Comparison and private saved providers.
17. Public matching providers: `/find-providers`. Browsing is public; request and messaging actions require authentication.

Additional fleet routes are `/provider/hire-requests`, `/provider/availability`, `/provider/fleet-maintenance`, `/provider/fleet-expenses` and `/driver/hire-trips`. Existing bookings, shipments, warehouse, finance, invitations and role management routes remain available.

## Data and access

Additive migrations were applied through Supabase MCP to Saas Logistics (`aemoltrbqnqlamexdqqo`):

- `20261114201557_logistics_marketplace_extensions.sql`
- `20261114201931_logistics_marketplace_assignment_guards.sql`

New tables use RLS. Mutation RPCs check the authenticated account, password setup, company access and permitted workflow transition. Anonymous discovery returns only an explicit published projection from active verified companies; private contact fields remain hidden. Messages and uploaded attachments require conversation participation. Fixed-price listings require a price.

Hire assignment locks driver and vehicle rows and reserves both using the same availability states as existing cargo dispatch. Customer acceptance precedes assignment. The assigned driver can record departure and return; return releases the resources. Disabling cargo, warehousing or hire services rejects changes that would strand active records. Historical records are retained.

The hosted database had one booking, zero companies and zero listings at verification. Its 23 unrelated existing tables were preserved. Company setup, verification, service selection and publishing are required before discovery can show providers. No test users, companies or messages were created in the hosted project.

## Practical limits

- Covlo provides guided logistics explanations and summaries grounded in loaded authorized records. No language model service is connected; arbitrary conversational AI and automatic document generation are not claimed.
- Future capability changes are scheduled for administrator review and manual application on or after the effective date; no background scheduler was installed.
- Reports download as text. Existing invoice tools remain available. No fabricated PDF documents, GPS positions, payment confirmations or transit estimates are shown.
- Operational queues use the latest 100 authorized records with exact total counts where displayed. Existing paginated record screens remain available for cargo queues.
- Existing WhatsApp sharing opens a prefilled WhatsApp Web conversation using the detected app URL. The sender presses Send. An address on localhost remains accessible only on that computer.

## Verification

- Production TypeScript/Vite build.
- All existing `npm test` suites passed; the account suite was extended and rerun after the final assignment guards.
- Added database checks cover public contact projection, reverse route matching, weight limits, cross-company access, extended cargo form persistence, messaging isolation, historical conversations, hire purpose, quotation/acceptance/assignment/trip/return, driver reservation and active-service protection.
- Browser checks against the hosted backend covered customer home, existing booking report, company dashboard, fleet metrics, empty messaging, administrator capability selection and the Customer Requests status modal.
- Mobile discovery was checked at 390px, a global-header height conflict was fixed, and document width matched viewport width without horizontal overflow. Screenshots are saved under `.development/ui-integration/`.
- Populated form and multi-account workflows were exercised in isolated local PostgreSQL-compatible tests. Actual hosted attachment bytes, new invitation delivery, camera/GPS permission flows and multi-user realtime were not exercised during this UI integration.

The Supabase advisor reports intentional executable guarded RPCs, including the public discovery RPC. Pre-existing non-logistics policies/functions and Auth password-protection settings were not changed by this work.

For a fresh empty database, `public/complete-install.sql` contains all eleven ordered migrations. On an existing installation, apply only its missing migrations.

## 15 November: workspace and request refinements

- Storage bins generate a company acronym plus an atomic company sequence (for example Company A → CA-0001). Existing bin codes remain intact. Code input is removed from new/edit bin forms.
- Incoming requests and request tables have inline permitted-status selectors. Transitions requiring quotation, assignment or cancellation details open the corresponding form. Respond opens a shared comment form; requesters see those comments in their booking details and tracking page.
- Relationships & history includes comments, quotations, assignment events and audit history. The Database record tab and raw JSON inspection were removed from operational records. The generic booking-workflow explanation was removed.
- Company registration and business settings are kept out of employee views. Provider routes check the assigned role and enterprise tools; service capability navigation reflects cargo/fleet/warehouse configuration. Fleet-only administrator/operator/dispatcher workspaces open Fleet operations after capability loading completes.
- Platform administration → Enterprise Dashboards (/admin/enterprise) configures tool groups for existing assigned people or provisions an individual provider workspace for an independent registered account. Invite a new person from Accounts & Roles first. Individual provisioning requires their own password setup on next login. The feature does not create a paid subscription or record a payment.
- Tool assignments supplement existing roles and tenant isolation: restrictive RLS policies cover operational records, guarded RPCs reject unassigned workflows, and company staff cannot grant their own enterprise tools. Platform administrators can preview a selected person's tools while retaining their own administrator permissions.
- Applied migrations: 20261115064925_logistics_workspace_tools_and_quote_replies.sql and 20261115065503_logistics_enterprise_legacy_guards.sql. The complete fresh installer now contains eleven ordered migrations.
- Existing test suites passed; additional isolated tests verify automatic bin codes, requester-visible comments, comment isolation, enterprise data/RPC restrictions, individual provisioning and first-password requirements. Browser checks verified request controls/history, employee navigation, fleet loading and individual-provider configuration controls. No live comments or provider accounts were created during verification.
