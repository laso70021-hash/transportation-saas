# Vercel deployment

## Frontend configuration

Import the GitHub repository into Vercel with the repository root as Root Directory. Select **Vite**, Node.js **24.x**, install command `npm ci`, build command `npm run build`, and output directory `dist`. `vercel.json` explicitly selects Vite despite archived `app/` and `next.config.mjs` files. Do not select Next.js.

Set these public build variables for each intended environment:

```text
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_PUBLISHABLE_KEY=YOUR_PUBLIC_PUBLISHABLE_KEY
```

`VITE_SUPABASE_ANON_KEY` is a compatibility fallback. Every `VITE_` value can enter public JavaScript; never use a service-role or secret key. Rebuild after changing variables. Local environment files, development accounts and generated output are excluded from Git and deployment uploads.

`vercel.json` provides SPA rewrites for direct navigation/Auth callbacks, security headers equivalent to `public/_headers`, and service-worker revalidation. Netlify-style `_redirects` and `_headers` are not Vercel configuration. Static files such as `/sw.js`, manifest, icons and hashed assets must still be served as files. See [Vercel's Vite SPA documentation](https://vercel.com/docs/frameworks/frontend/vite#using-vite-to-make-spas).

The CSP permits standard `*.supabase.co` HTTPS/WebSocket endpoints and OpenStreetMap tiles. Custom Supabase domains require an explicit CSP update. Local HTTP Supabase is for the development server only. Inspect actual deployed headers because dashboard/team configuration may affect them.

## Separate Supabase backend

Vercel hosts the frontend. It does not apply SQL migrations, provision Auth accounts or deploy `supabase/functions/` as Vercel Functions. Audit existing schema and migration history before applying changes; never reset an existing hosted project. Rehearse against isolated staging. `public/complete-install.sql` is an initial installer, not a replacement for reviewing all subsequent migrations.

In the hosted Supabase dashboard:

1. Set Auth Site URL to the stable HTTPS app origin and allow its exact `/set-password` redirect. Add only intended preview callbacks; use a separate staging backend where practical.
2. Configure email confirmation, SMTP, password requirements, JWT lifetime and refresh policy. Hosted settings govern production Auth, not local `supabase/config.toml`.
3. Deploy `invite-account` separately to Supabase. Set server `APP_ORIGIN` to the stable app origin. Keep its service-role credential in the Edge Function environment, never frontend variables.
4. If using `review-payment`, deploy it separately and set `APP_ORIGIN` there too. The UI currently uses the authenticated database RPC directly.
5. Check RLS, function grants, private `sl-documents` Storage policies and Realtime. Bootstrap administrator ownership through a trusted workflow; do not seed development administrators in production.

A fixed `APP_ORIGIN` limits invitation operations to that origin; plan staging before expecting invitations across arbitrary Vercel previews. Clear stale browser connection settings when switching Supabase projects.

## Validation

Run `npm ci`, `npm run build` and `npm test` before release. The included GitHub Actions workflow runs these checks on Ubuntu with Node.js 24 for pushes and pull requests, without production secrets. After deployment verify direct visits to `/login`, `/access`, `/set-password` and dashboards, plus unauthenticated redirects. Check `/sw.js` MIME/revalidation headers, manifest/icons and CSP connectivity.

Exercise real sign-in, reload/refresh, sign-out, invitation email, recovery, first-password gating, private Storage and offline synchronization. Test two independent tenant accounts against each other's records. Local SQL/offline tests do not certify hosted behavior. Adding this configuration does not itself create a Vercel deployment or modify Supabase.
