# Accounts and assigned dashboards

Platform administrators open **Accounts & Roles** to see every real Auth account, including customers without a company membership. The directory includes the person's name, email, phone, company, assigned role, password-setup status and last sign-in. Company administrators see accounts only within companies they manage.

The dashboard roles are platform administrator, company administrator, operations officer, dispatcher, finance officer, driver, warehouse staff, company viewer and customer. Staff dashboards adapt their navigation, headings, metrics and shortcuts to their role. Viewer accounts have read-only controls. Drivers receive linked driver records when assigned.

The administrator's **Switch role** menu and **Preview dashboard** buttons show each role's experience using the administrator's own account. A preview banner explains that administrator permissions remain active. Previewing a role never creates a user, signs in as another person or changes anyone's membership.

## Invitation and first login

1. Register the company or institute, then enter the person's full name, email, optional international WhatsApp number, company and assigned role.
2. The deployed `invite-account` Edge Function verifies the administrator's session and database permission, records the invitation, and uses Supabase Auth to email an invitation or password-setup link. Existing platform-admin accounts cannot be modified through this workflow.
3. The database saves the primary role and company. Customers are linked to company client records; staff receive memberships. Invited accounts require password setup before operational access.
4. The recipient opens the secure email link and sets a password. An Auth database trigger observes the actual password change and clears the setup requirement. Client-side calls cannot clear that flag.
5. Login goes through `/access` and automatically opens the assigned dashboard. `/set-password` handles invitation and recovery sessions; `/forgot-password` requests a fresh link.

The server records email provider success or failure. It does not claim inbox delivery. Configure Supabase Auth's redirect allowlist to include the deployed app's `/set-password` address; production email sending may also require SMTP configuration in Supabase. The current browser origin is detected automatically, with `APP_ORIGIN` or an existing `app_url` setting available as server overrides. Localhost links work only on the same computer.

## WhatsApp sharing

**Share on WhatsApp** detects `window.location.origin` at click time and opens WhatsApp Web with the recipient and invitation message filled in. The administrator uses their linked session and presses Send. No Meta API is required. The app does not report the message as delivered merely because the chat was opened. The shared link opens sign-in; password setup remains protected by the recipient's email link. Passwords and bearer sign-in tokens are not included in WhatsApp messages.

## PWA

The production build registers a service worker and supplies 192px, 512px, maskable and Apple touch icons. **Install app** uses the browser's install prompt where available and provides Safari and browser-menu instructions otherwise. The installed app starts at `/access`, preserving role-based login routing.

The service worker caches the static shell, public assets and reconnect page, bypassing authenticated and cross-origin API requests. Separately, the app caches downloaded authorized records and queues supported mutations/attachments in account-scoped IndexedDB. First login, password changes, invitations and financial approvals require connectivity. See [offline behavior](OFFLINE-AND-DASHBOARD-SETTINGS.md) and [authentication](AUTHENTICATION.md) for storage and synchronization limits.

## Validation

`npm test` covers the existing logistics suites plus account isolation, invitation authorization and retries, password-setup enforcement, linked driver assignment, installable icon dimensions, private-request cache bypass and offline navigation. The production build is checked with `npm run build`.

Email delivery to a real recipient, an actual first-login password change through Supabase Auth, WhatsApp Send, and installation on physical phones require their respective live acceptance checks. No development users are inserted into the hosted project by these tests.
