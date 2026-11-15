# Swahivo Logistics — development integration

Vite + React + TypeScript, Tailwind, shadcn-style Radix button components, React Router, TanStack Query, React Hook Form/Zod, Recharts and a single Supabase backend.

This is an update to the recovered Swahivo Sites source. The original `app/` source is retained as an archive; Vite serves `src/`. Existing public pages, policies and validation tooling were ported, not replaced with simulated datasets. Additional original billing/review/profile tools remain at `/legacy/platform`, `/legacy/company`, `/legacy/customer`.

**Hosted connection configured on 14 November 2026.** The app uses the existing “Saas Logistics” Supabase project (`aemoltrbqnqlamexdqqo`) through the ignored `.env.local` file with a publishable client key. The baseline, operations upgrade, hosted function permission correction account-owner bootstrap and account-management migration have been applied through Supabase MCP. All 23 pre-existing public tables were preserved; the installation adds 56 Logistics tables with RLS, a private documents bucket and eight Realtime tables. SQL/RLS tests and the production build pass. Authenticated user workflows, actual Storage uploads, Realtime delivery and device acceptance still need validation. Earlier handoff reports in `docs/` describe the pre-connection state.

## Start the frontend

```sh
npm ci
npm run dev
```

Open Vite's displayed URL. `/connect` accepts the existing Supabase URL and publishable key, including local `http://127.0.0.1:54321`. Without a backend, the application shows connection/sign-in states and does not invent operational records.

Environment configuration is optional for browser connection settings. When used, copy `.env.example` to `.env.local` and enter only `VITE_SUPABASE_URL` and `VITE_SUPABASE_PUBLISHABLE_KEY`. `VITE_SUPABASE_ANON_KEY` remains compatible. Never use a service-role/secret key in any `VITE_` variable.

## Local Supabase development

Install Docker Desktop or Podman, then:

```sh
npx supabase start
npx supabase db reset
npm run dev:seed
npm run test:hosted
npm test
```

`db reset` is **local disposable development only**. Never reset an existing hosted database. The seed runner refuses hosted URLs and creates Auth users through the Admin API, then applies `supabase/development/seed.sql` locally. Passwords are generated or read from `.development/accounts.json`; existing passwords are never overwritten. That file and server configuration are ignored by Git and absent from the public build.

The delivered account file contains proposed local-only credentials, **not accounts already provisioned here**. After provisioning succeeds, the script verifies each actual Auth login. Sample company, customer, booking, shipment, invoice, stock and submitted-payment rows are persisted in the local database. Sample verification metadata is explicitly labeled development-only. GPS, POD and external carrier events are not fabricated.

## SQL selection

- Fresh empty Supabase project: `public/complete-install.sql`.
- Existing matching v2 Swahivo schema: audit/back up first, then `public/operations-upgrade.sql`.
- Existing older validation-only schema: review `public/saas-upgrade.sql` first, then the operations upgrade.
- CLI migrations are ordered in `supabase/migrations/`; their versions match the hosted MCP migration history. The final permission migration removes hosted default anonymous function grants.
- Development fixtures: `supabase/development/seed.sql`, run only through the guarded setup script after Auth provisioning.

Do not apply the baseline to an existing database or assume an unrelated project's table names are compatible. The production migration creates no demo administrator and contains no passwords.

## Workspaces

| Route | Data access |
|---|---|
| `/admin/dashboard` | Database-authorized platform administrators |
| `/provider/dashboard` | Company membership; operations governed by individual roles |
| `/account/dashboard` | Own bookings, shipments, stored goods and invoices |
| `/driver` | Assigned pickups, deliveries, scans and GPS |
| `/warehouse` | Authorized storage, stock movement and dispatch workflows |
| `/validation` | Retained relationship/RLS inspection tools |

Mutations use authenticated Supabase REST/RPC APIs. Transactions validate authority, relationships and transitions, then write timeline/audit evidence. TanStack Query invalidation and Realtime subscriptions refresh authorized data. Lists refresh every 30 seconds as a fallback. No operational data is stored in localStorage.

## API and security

See [authentication architecture](docs/AUTHENTICATION.md) for components, request flow, credentials, tokens and offline sessions. [Vercel deployment](docs/VERCEL-DEPLOYMENT.md) covers hosting settings and separate Supabase configuration.

See `docs/SECURITY.md` and `docs/API-WORKFLOWS.md`. The optional `supabase/functions/review-payment` endpoint validates the user's Auth session and delegates final authorization to the same transactional RPC. Configure its `APP_ORIGIN` server secret before enabling it. The frontend currently calls the authenticated RPC directly.

## Checks

```sh
npm run build
npm test
```

`test:db` retains the original linked-record suite; `test:saas` runs 26 previous SaaS assertions; `test:operations` runs 39 additional SQL assertions. These use PGlite and a minimal Auth/Storage schema contract; they do not implement or prove the actual Supabase services. The separately named `test:hosted` script currently targets **localhost only**, and records real Auth/API results once local Supabase is running.

Camera scanning and GPS require browser permission and HTTPS (or localhost); delivery files use private Storage and short-lived signed URLs. Map tiles use OpenStreetMap without invented markers. External payment transfers are performed outside this application; staff record reviewed references. No bank transfer is executed by a visual confirmation.

## Account owner and appearance

The first existing confirmed account, `admin@swahivo.com`, is the platform administrator. Only the account recorded in `sl_account_owner` gets the header role switch for administration, cargo company, customer, driver and warehouse workspaces. It uses the same account and retains its administrator permissions; it does not impersonate other users or alter their roles. Ownership is read-only through the client API and later signups receive no owner or administrator grant.

Dark is the default theme across the public pages and operational workspaces. The sun/moon button changes the theme and saves the preference in this browser. Quotation requests group sender information on the left, receiver information on the right and cargo details below; mobile screens stack the groups.

## Accounts, invitations and installable app

Open **Accounts & Roles** for the registered-account directory and role dashboard previews. Invited users receive a primary company and role, set their password through the Auth email link, and land on their assigned dashboard at login. **Share on WhatsApp** detects the current app origin and opens the linked WhatsApp Web chat; the sender presses Send there. Configure Supabase Auth redirects for the actual app origin before accepting email invitations.

The production app includes install controls, mobile icons, an offline reconnect page and update notices. Read `docs/ACCOUNT-ONBOARDING.md` for setup, authorization boundaries and acceptance-test limits.

Reference-screen additions, routes and verification: [UI integration notes](docs/UI-REFERENCE-INTEGRATION.md).
