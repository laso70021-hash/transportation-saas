-- Run through the Supabase SQL Editor with trusted database privileges.
-- Replace the email below with an existing, confirmed account you control.
DO $$
DECLARE
  admin_email text := 'REPLACE_WITH_YOUR_CONFIRMED_ADMIN_EMAIL';
  admin_id uuid;
BEGIN
  if admin_email='REPLACE_WITH_YOUR_CONFIRMED_ADMIN_EMAIL' then
    raise exception 'Replace admin_email with your confirmed Supabase account email first';
  end if;
  select id into admin_id from auth.users
  where lower(email)=lower(admin_email) and email_confirmed_at is not null;
  if admin_id is null then
    raise exception 'No confirmed account matches this email';
  end if;
  insert into public.sl_platform_admins(user_id) values(admin_id)
  on conflict(user_id) do nothing;
END;
$$;
