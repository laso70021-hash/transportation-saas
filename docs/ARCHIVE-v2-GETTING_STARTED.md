# Swahivo Logistics SaaS — installation and migration

## Choose one database path

| Database state | SQL to run once |
| --- | --- |
| No previous Swahivo `sl_` tables | `public/install.sql` |
| Original Swahivo Logistics migration already installed | `public/saas-upgrade.sql` |

Do not run both files. `public/setup.sql` is retained only as the original v1 schema for compatibility and tests. The SaaS upgrade is additive and preserves v1 operational records. Scripts deliberately fail if reapplied instead of silently overwriting objects. Apply to the intended Logistics project only. This session did not connect or modify a hosted Logistics database.

## Start the app

1. Install Node.js 20.9+.
2. Run `npm ci` and `npm run dev` from the extracted project folder.
3. Open http://localhost:3000.
4. Open Login → backend connection settings, and enter your Supabase HTTPS URL and publishable key. A legacy anon key is accepted. Never use a service-role or secret key.
5. For a centrally configured deployment, set `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` before building. These are public client configuration, not secret credentials. Browser-local connection settings take precedence.
6. In Supabase Auth settings, set the Site URL and allowed redirects to your deployment, configure email confirmation/SMTP, and enable email/password sign-in. The app uses native Supabase Auth email/password registration and login.

## Bootstrap the platform administrator

1. Register and confirm an account you control.
2. Open `supabase/bootstrap_admin.sql`, replace the placeholder email and run it with trusted SQL Editor access.
3. Sign out and sign back in. Open `/platform/`.

No public signup flow can create a platform administrator. The browser never writes directly to `sl_platform_admins`.

## Onboard cargo companies and customers

1. A cargo-company owner registers, confirms email and opens `/company/`.
2. They submit a company application. It is `pending`, and cannot self-approve.
3. Platform admin opens Providers → Edit → selects `active` and saves.
4. Platform admin creates the required plan, then assigns a subscription and expiry to the company. Assigned expired plans and monthly shipment limits are enforced by the database. Companies without an assigned subscription retain unmetered access for migration compatibility; configure subscriptions before commercial onboarding.
5. The company owner saves company details, publishes a service with a base price and per-kg price, and adds drivers/facilities/team members as needed. A new team member must already have a confirmed Supabase account.
6. A customer registers, opens `/customer/`, and books from the service marketplace. The server creates the customer/company link, order, pending shipment, first tracking event, notification and invoice atomically.
7. The customer submits a real payment reference. Company finance staff verifies or rejects it. Verification updates invoice balance; it does not execute a bank/mobile-money transaction.
8. Staff progress shipments Pending → Processing → In Transit → Delivered. Every status change creates timeline and audit evidence.

## Subscription payments and commissions

Company admins submit platform subscription payment references from the Subscription page. Platform admin reviews them in Subscription payments. Subscription assignment/activation remains an explicit platform action. No payment gateway or automatic recurring charge is configured.

Set `commission_percent` in System settings to a numeric value between 0 and 100 to calculate commission rows when freight payments are verified. Commission records are accounting entries, not payouts.

## Printing and tracking

Invoices → Inspect opens a printable A4 invoice populated from the stored cargo-company and customer records. Shipment tracking → Shipping document opens a printable shipment document. Use Print / save as PDF.

Device GPS sharing is opt-in, runs only while the current shipment view remains active, and stops when navigating away or signing out. Saved location timestamps show freshness. The OpenStreetMap embed receives displayed coordinates. There is no background rider app or simulated movement.

## Tests

- `npm run test:db`: original client/order/shipment/RLS validation in PGlite.
- `npm run test:saas`: multi-company onboarding, customers, payments, subscriptions, suspension and security checks in PGlite.
- `npm test`: both local suites.
- `npm run build`: production static export in `out/`.
- `/validation/`: retained in-app workflow workspace with two-account live Supabase tests, recorded pass/fail/blocked results and cleanup. Both test staff accounts must belong to separate active companies and have room under assigned shipment quotas. Retained audit, notification and test-run evidence is intentional.

Local PGlite checks use real database roles and policies in an isolated local database. They do not establish that the intended hosted Supabase project has been migrated or tested. Run the hosted suite after connection and migration.

## Before public launch

Confirm the operating legal entity, support contact, retention periods and actual commercial terms. The terms, privacy and cookie pages describe implemented behavior and need the deployment owner's business-specific review. The current cookie controls enable no optional analytics or advertising scripts. The Site publication remains owner-private until you explicitly change its audience.
