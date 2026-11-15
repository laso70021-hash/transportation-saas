# Swahivo Logistics — multi-company SaaS

A Next.js + React logistics platform using Supabase Auth/Postgres/RLS. Public landing, service, about, contact, secure tracking, login, registration, terms, privacy and cookie pages; separate platform, cargo-company and customer dashboards.

See **GETTING_STARTED.md** for fresh install vs upgrade, platform-admin bootstrap, company approval, subscriptions, marketplace bookings, and live tests.

## Implemented workflows

- Platform: company approvals/suspension, plans/subscriptions, payment reference review, commission configuration, customer directory, marketplace oversight, reports, support inbox, disputes, review moderation, locations, team access, and protected audit views.
- Cargo company: scoped clients/orders/shipments; team roles; service and route publishing; driver/facility management; pickup scheduling; delivery queue; scanner-input tracking lookup; invoice creation/printing; manual payment verification; operational reports; company settings and subscription payment submission.
- Customer: marketplace booking with server-calculated pricing; own shipment tracking/timelines/GPS inspection; pickup requests; saved addresses; invoice viewing/printing; payment reference submission; support/disputes; delivered-shipment reviews; profile and session management.
- Shipment transitions are one-way: Pending → Processing → In Transit → Delivered. Database triggers create events, notifications and audit entries atomically. Shipping documents fetch actual company/contact/order data.
- Original validation workspace retained at `/validation/`.

## Security model

Platform admins are stored in a protected table and bootstrapped by trusted SQL only. Company admins/operators/viewers come from membership rows. User-editable metadata is used only for display/onboarding intent, never authorization. Pending owners cannot self-approve. Suspended company staff lose operational access while customers retain their own historical records.

All exposed tables have RLS; tenant foreign keys prevent cross-company relations. Customers have no general operational write policy. Guarded RPCs create bookings, request pickups and submit payments. Customers cannot verify their own payments or forge timeline events. Verified payments update invoice state under row locks. The browser uses publishable keys only.

## Verification and current limits

Production build and local database tests are provided. No Logistics backend was available in the connected Supabase account during implementation, so hosted persistence/auth/realtime have not been verified. Applying the SQL and configuring an intended Logistics project is required before real records can load.

List views use server pagination (20 records), filtering and exact counts. CSV exports export the current visible page. Dashboard metrics are exact RLS-scoped SQL aggregates; chart series use actual recorded data. Dashboard recent activity and relation dropdowns load the latest 100 accessible rows; large directories should add searchable relation selectors. There is no seeded operational/demo data. Empty dashboards intentionally show dashes until connected.

The web scanner accepts a scanner's typed barcode/tracking value; no camera SDK is configured. GPS is foreground device sharing, not background driver telemetry. Notifications are in-app; email/SMS/push delivery is not wired. Payments/subscriptions use explicit manual verification and ledger entries, not an integrated payment gateway. Operational insights are labeled calculations, not a connected AI model. Public tracking requires sign-in and ownership permission; there is no anonymous disclosure of shipment PII.

Legal pages describe current behavior, with sections and in-page contents. They require operator/entity/retention/commercial review before broad commercial launch. No fabricated testimonials, carrier partnerships, revenue figures or service guarantees are included.

## Routes

`/` · `/services/` · `/tracking/` · `/about/` · `/contact/` · `/login/` · `/register/` · `/platform/` · `/company/` · `/customer/` · `/terms/` · `/privacy/` · `/cookies/` · `/validation/`

The implementation uses the supplied visual references and hero artwork. The shared ChatGPT reference could not be retrieved in this session. Site identity and existing audience are preserved.
