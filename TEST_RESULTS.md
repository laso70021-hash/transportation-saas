# Validation results

- Production Next.js export: passed.
- Original client → order → shipment SQL/RLS suite: passed.
- SaaS SQL/RLS suite: 26 checks passed.
- Desktop browser QA: landing, platform, company, customer and privacy layouts inspected; admin navigation and booking modal inspected.
- Mobile browser QA: all three dashboards rendered in 390px-wide frames; menu and booking modal verified.
- Hosted Supabase validation: **not run — intended Logistics project not connected**.

Run `npm test` to reproduce local database tests. Run `/validation/` with two real, active company accounts after applying the migration to your hosted Logistics backend.

See GETTING_STARTED.md for the correct fresh-install versus upgrade path.
