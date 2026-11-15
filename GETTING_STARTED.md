# Development setup

Read `README.md` for the current Vite frontend and ordered migration choices. The previous Next.js guide is retained in `docs/ARCHIVE-v2-GETTING_STARTED.md` as historical context.

1. `npm ci` and `npm run dev`.
2. With Docker/Podman available, `npx supabase start` then `npx supabase db reset` against disposable local development only.
3. `npm run dev:seed` provisions and verifies local Auth accounts and persists `supabase/development/seed.sql`.
4. Use the public URL/key shown by local Supabase at `/connect` (never a service-role key).
5. Read `.development/accounts.json` for local credentials. They are not provisioned until the seed runner succeeds.
6. Run `npm test` and `npm run test:hosted`; then complete the actual cross-role browser/device acceptance flow.

The implementation environment had no Docker/Podman, so actual Auth/Storage/Realtime acceptance is pending. The SQL-only results are in `docs/test-results.txt`; limitations are explicit in `docs/ENGINEERING-REPORT.md`.

For an existing hosted project, audit/back up its actual schema before applying an upgrade. Do not reset or import the fresh baseline over production. Production account bootstrap must use trusted administration, not development seed credentials.
