-- Bind owner-only workspace switching to the first existing confirmed account.
-- This is a one-time bootstrap, never an automatic grant to later signups.
begin;
create table public.sl_account_owner (
  singleton boolean primary key default true check (singleton),
  user_id uuid not null unique references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);
alter table public.sl_account_owner enable row level security;
revoke all on public.sl_account_owner from public, anon, authenticated;
grant select on public.sl_account_owner to authenticated;
create policy owner_self on public.sl_account_owner for select to authenticated
  using (user_id = (select auth.uid()));
insert into public.sl_account_owner(user_id)
select id from auth.users where email_confirmed_at is not null
order by created_at, id limit 1
on conflict do nothing;
insert into public.sl_platform_admins(user_id)
select user_id from public.sl_account_owner on conflict do nothing;
notify pgrst, 'reload schema';
commit;
