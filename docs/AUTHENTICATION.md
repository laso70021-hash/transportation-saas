# Authentication and authorization

This describes the active Vite application in `src/`. The retained `app/` tree is an older Next.js archive, not the deployment entry point. GitHub authenticates repository operations only; application users use Supabase Auth, not GitHub OAuth.

## Components

- `src/main.tsx` mounts `BackendProvider`, TanStack Query and React Router. Public login/registration still use `src/legacy/components/PublicSite.jsx` and its `runtime.jsx` hook.
- `src/lib/client.ts` shares one Supabase client per URL/public-key pair between modern and retained components. It installs the offline fetch adapter and supplies stored session state while offline.
- `src/lib/api.tsx` owns connection configuration, sessions, Auth listeners, protected identity queries, workspace selection, RPC helpers, Realtime and synchronization.
- `src/features/Access.tsx` chooses the assigned dashboard and defines `PlatformOnly`. `src/components/Shell.tsx` guards operational routes. Browser guards improve navigation; database authorization enforces access.
- `src/features/PasswordSetup.tsx` handles invitation/recovery password changes. `src/features/AccountManagement.tsx` calls the invitation service.
- `supabase/migrations/` implements protected roles, tenant membership, RLS, guarded RPCs and password-setup enforcement. The account-management migration defines `logistics_private.password_ready()` and a password-change trigger on `auth.users`.
- `supabase/functions/invite-account/index.ts` performs privileged invitation delivery. `review-payment/index.ts` is optional; the UI normally calls the payment RPC directly.

## Request flow

1. Vercel serves static assets and rewrites direct page visits, including dashboards and `/set-password`, to `index.html`.
2. The modern provider reads `VITE_SUPABASE_URL` and the publishable key, falling back to `sl.connection` in localStorage. The retained runtime reads saved connection settings first, then environment configuration. Keep them aligned; clear stale `sl.connection` when moving projects.
3. `/login` or `/access` calls `db.auth.signInWithPassword({email, password})`. Registration calls `signUp`; display name and onboarding preference are user metadata, not authority. Email confirmation may be required by hosted Auth settings.
4. Supabase Auth returns a session. `getSession()` restores it on reload and `onAuthStateChange` updates React state. Protected queries read `sl_account_owner`, `sl_platform_admins`, `sl_memberships`, `sl_account_access`, profiles and drivers to determine available areas and the primary role.
5. Accounts with `must_change_password` or a recovery session go to `/set-password`. Others go through `/access` to `dashboardForRole`. Administrator role previews retain that same administrator's identity and permissions; they do not impersonate another user.
6. Supabase JS attaches the public API key and user's access JWT to REST/RPC/Storage requests. Supabase verifies the JWT; database code checks `auth.uid()`, protected role records and tenant relationships. UI role selection and locally decoded JWT contents cannot grant server permissions.
7. Mutations invalidate queries. Realtime and polling refresh records. Sign-out calls Supabase Auth, clears React query/identity state and removes downloaded cache rows for that project/account. Pending offline operations remain scoped to that account.

## Credentials and tokens

Passwords are submitted to Supabase Auth over HTTPS. The active frontend does not persist plaintext passwords or implement its own password hashing; Supabase handles password verification/storage. The ignored development account file is a local provisioning aid excluded from Git and Vercel uploads.

The client does not override Supabase JS browser Auth defaults: `persistSession`, `autoRefreshToken` and `detectSessionInUrl` are enabled, with `flowType: 'implicit'`. The session includes an access JWT and refresh token stored in browser localStorage. The SDK processes email callback fragments. This app has no custom HttpOnly session cookie, Vercel login middleware or server session endpoint. `getSession()` and locally decoded JWTs represent client state, not independent server validation. Expiry and rotation follow hosted Auth settings; local `config.toml` does not configure the hosted project.

Both browser tokens are sensitive: same-origin JavaScript can read them. CSP, dependency review and XSS prevention matter. A publishable key (or compatible legacy `anon` key) is deliberately public and bundled into the client. The connection form rejects privileged keys, but environment variables bypass the form: never put a service-role or secret key in any `VITE_` variable. Service-role keys, SMTP credentials and database passwords belong only in trusted server configuration.

`sl.connection` stores the project URL/public key; role previews use sessionStorage. `src/lib/offline.ts` reads the stored Auth session while offline and extracts the JWT subject only to partition local data. `src/lib/offlineStore.ts` persists downloaded authenticated records and queued operations, including attachment blobs, in IndexedDB by project/account. Application code does not encrypt these records. An offline session may be stale or expired; it enables a local experience only. Reconnection obtains a current session and the server checks authorization through `sl_sync_operation`. Shared-device operators must account for retained pending operations.

`public/sw.js` caches the static shell/assets and bypasses cross-origin API requests and requests carrying Authorization. This does not disable the separate IndexedDB data cache. Private proof files use `sl-documents`; `Proof.tsx` requests signed URLs valid for 60 seconds. Treat those links as temporary bearer capabilities and avoid sharing/logging them.

## Invitation and recovery flow

`invite-account` requires a Bearer JWT, validates it with `service.auth.getUser(token)`, checks protected administrator/membership records using a caller-scoped client, and calls `sl_prepare_account_invitation` as that caller. Only after authorization does the server-only service-role client invite the user, finalize assignment and record delivery status. Existing users receive a password-reset email. Configure `APP_ORIGIN` explicitly in production: the current implementation otherwise falls back to an app setting or request origin and separately permits localhost origins. CORS is not authorization.

The recipient opens the email link at `/set-password`. The UI calls `auth.updateUser({password})` after checking a matching confirmation and at least 12 characters. A database trigger observes the actual `auth.users.encrypted_password` change and clears `must_change_password`; clients cannot clear the flag directly. Recovery uses `resetPasswordForEmail` with the current origin's `/set-password`. Configure the Supabase redirect allowlist and SMTP for the deployed origin. WhatsApp sharing includes a normal login URL, never a password or bearer session link.

The optional payment function calls `auth.getUser()` and forwards the caller JWT to `sl_review_payment`, retaining database authorization. It does not use a service-role client.

## Evidence and limits

See [security boundaries](SECURITY.md), [onboarding](ACCOUNT-ONBOARDING.md), [offline behavior](OFFLINE-AND-DASHBOARD-SETTINGS.md), [API workflows](API-WORKFLOWS.md) and [Vercel deployment](VERCEL-DEPLOYMENT.md). `npm test` exercises isolated SQL/RLS and offline/PWA contracts. It does not prove live email delivery, production session refresh/revocation, Storage or device behavior. The frontend has no MFA enrollment flow; review hosted Auth requirements before commercial use.

Supabase's [session documentation](https://supabase.com/docs/guides/auth/sessions) explains access/refresh tokens. Client defaults above were checked against the installed `@supabase/supabase-js/src/lib/constants.ts`.
