begin;
create table public.sl_account_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  workspace_id uuid references public.sl_workspaces(id),
  role text not null check(role in('admin','operator','dispatcher','finance','driver','warehouse','viewer','customer')),
  must_change_password boolean not null default true,
  assigned_by uuid references auth.users(id),
  password_set_at timestamptz,
  created_at timestamptz not null default now(),
  check(workspace_id is not null or role='customer')
);
alter table public.sl_account_access enable row level security;
revoke all on public.sl_account_access from public,anon,authenticated;
grant select on public.sl_account_access to authenticated;
create policy account_access_self on public.sl_account_access for select to authenticated using(user_id=(select auth.uid()));

create function logistics_private.password_ready() returns boolean language sql stable security definer set search_path='' as $$
  select auth.uid() is not null and not exists(select 1 from public.sl_account_access where user_id=auth.uid() and must_change_password)
$$;
revoke all on function logistics_private.password_ready() from public,anon;
grant execute on function logistics_private.password_ready() to authenticated;
create or replace function logistics_private.platform_admin() returns boolean language sql stable security definer set search_path='' as $$
  select logistics_private.password_ready() and exists(select 1 from public.sl_platform_admins where user_id=auth.uid())
$$;
create or replace function logistics_private.has_role(w uuid,roles text[]) returns boolean language sql stable security definer set search_path='' as $$
  select logistics_private.password_ready() and (logistics_private.platform_admin() or exists(
    select 1 from public.sl_memberships m join public.sl_workspaces t on t.id=m.workspace_id
    where m.workspace_id=w and m.user_id=auth.uid() and m.role=any(roles) and t.status='active'))
$$;
create function logistics_private.password_changed() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.encrypted_password is distinct from old.encrypted_password and coalesce(new.encrypted_password,'')<>'' then
    update public.sl_account_access set must_change_password=false,password_set_at=now() where user_id=new.id;
  end if;
  return new;
end;$$;
revoke all on function logistics_private.password_changed() from public,anon,authenticated;
create trigger sl_password_changed after update of encrypted_password on auth.users for each row execute function logistics_private.password_changed();

create table public.sl_account_invitations (
  id uuid primary key default gen_random_uuid(), request_key uuid not null unique,
  workspace_id uuid references public.sl_workspaces(id),
  email text not null, display_name text not null, phone text,
  role text not null check(role in('admin','operator','dispatcher','finance','driver','warehouse','viewer','customer')),
  user_id uuid references auth.users(id), invited_by uuid not null references auth.users(id),
  email_status text not null default 'pending' check(email_status in('pending','sent','failed')),
  whatsapp_status text not null default 'not_requested' check(whatsapp_status in('not_requested','ready','opened')),
  delivery_error text, created_at timestamptz not null default now(), sent_at timestamptz,
  check(workspace_id is not null or role='customer')
);
alter table public.sl_account_invitations enable row level security;
revoke all on public.sl_account_invitations from public,anon,authenticated;
grant select on public.sl_account_invitations to authenticated;
create policy invitation_admin_read on public.sl_account_invitations for select to authenticated
  using(logistics_private.platform_admin() or logistics_private.has_role(workspace_id,array['admin']));
create index sl_account_invitation_workspace on public.sl_account_invitations(workspace_id,created_at desc);
create index sl_account_invitation_actor on public.sl_account_invitations(invited_by,created_at desc);
create index sl_account_access_workspace on public.sl_account_access(workspace_id);

create function public.sl_prepare_account_invitation(p_workspace uuid,p_email text,p_name text,p_phone text,p_role text,p_request_key uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare invitation public.sl_account_invitations; target uuid;
begin
  if not (logistics_private.platform_admin() or logistics_private.has_role(p_workspace,array['admin'])) then raise exception 'Company or platform administrator required';end if;
  if p_role is null or p_role not in('admin','operator','dispatcher','finance','driver','warehouse','viewer','customer') then raise exception 'Invalid account role';end if;
  if p_workspace is null and (p_role<>'customer' or not logistics_private.platform_admin()) then raise exception 'Choose a company for this role';end if;
  if p_workspace is not null and not exists(select 1 from public.sl_workspaces where id=p_workspace) then raise exception 'Company not found';end if;
  if p_email is null or p_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or length(trim(coalesce(p_name,'')))<2 then raise exception 'A valid email and full name are required';end if;
  if p_request_key is null then raise exception 'Request key required';end if;
  select id into target from auth.users where lower(email)=lower(trim(p_email));
  if target=auth.uid() then raise exception 'Use a different account; your own role and password cannot be changed here';end if;
  if exists(select 1 from public.sl_platform_admins where user_id=target) then raise exception 'Platform administrator accounts are managed separately';end if;
  if exists(select 1 from public.sl_account_access where user_id=target and workspace_id is distinct from p_workspace) and not logistics_private.platform_admin() then raise exception 'This account already belongs to another company';end if;
  select * into invitation from public.sl_account_invitations where request_key=p_request_key;
  if found then
    if invitation.invited_by<>auth.uid() or invitation.email<>lower(trim(p_email)) or invitation.role<>p_role or invitation.workspace_id is distinct from p_workspace then raise exception 'Request key does not match this invitation';end if;
    if target is not null and invitation.user_id is null then update public.sl_account_invitations set user_id=target where id=invitation.id returning * into invitation;end if;
    return to_jsonb(invitation);
  end if;
  if (select count(*) from public.sl_account_invitations where invited_by=auth.uid() and created_at>now()-interval '1 hour')>=20 then raise exception 'Hourly invitation limit reached';end if;
  insert into public.sl_account_invitations(request_key,workspace_id,email,display_name,phone,role,user_id,invited_by)
  values(p_request_key,p_workspace,lower(trim(p_email)),trim(p_name),nullif(trim(p_phone),''),p_role,target,auth.uid()) returning * into invitation;
  update public.sl_account_invitations set whatsapp_status=case when phone is null then 'not_requested' else 'ready' end where id=invitation.id returning * into invitation;
  return to_jsonb(invitation);
end;$$;

-- Called only by the authenticated invitation service, never by public clients.
create function public.sl_complete_account_invitation(p_invitation uuid,p_user uuid) returns void language plpgsql security definer set search_path='' as $$
declare i public.sl_account_invitations;
begin
  select * into i from public.sl_account_invitations where id=p_invitation for update;
  if not found or not exists(select 1 from auth.users where id=p_user and lower(email)=i.email) then raise exception 'Invitation account mismatch';end if;
  if i.email_status='sent' then return;end if;
  if exists(select 1 from public.sl_platform_admins where user_id=p_user) then raise exception 'Cannot change a platform administrator';end if;
  if not (exists(select 1 from public.sl_platform_admins where user_id=i.invited_by) or exists(select 1 from public.sl_memberships m join public.sl_workspaces w on w.id=m.workspace_id where m.user_id=i.invited_by and m.workspace_id=i.workspace_id and m.role='admin' and w.status='active')) then raise exception 'Inviting administrator no longer has permission';end if;
  insert into public.sl_account_access(user_id,workspace_id,role,must_change_password,assigned_by)
  values(p_user,i.workspace_id,i.role,true,i.invited_by)
  on conflict(user_id) do update set workspace_id=excluded.workspace_id,role=excluded.role,must_change_password=true,assigned_by=excluded.assigned_by,password_set_at=null;
  update public.sl_profiles set display_name=i.display_name,phone=coalesce(i.phone,phone) where id=p_user;
  if i.role='customer' and i.workspace_id is not null then
    delete from public.sl_memberships where user_id=p_user and workspace_id=i.workspace_id;
    insert into public.sl_clients(workspace_id,user_id,name,email,phone) values(i.workspace_id,p_user,i.display_name,i.email,i.phone)
    on conflict(workspace_id,user_id) where user_id is not null do nothing;
  elsif i.workspace_id is not null then
    insert into public.sl_memberships(workspace_id,user_id,role) values(i.workspace_id,p_user,i.role)
    on conflict(workspace_id,user_id) do update set role=excluded.role;
    if i.role='driver' then
      insert into public.sl_drivers(workspace_id,user_id,name,phone) values(i.workspace_id,p_user,i.display_name,coalesce(i.phone,''))
      on conflict(workspace_id,user_id) where user_id is not null do nothing;
    end if;
  end if;
  update public.sl_account_invitations set user_id=p_user where id=i.id;
  insert into public.sl_platform_audit(entity,record_id,action,actor_id) values('sl_account_invitations',i.id,'ACCOUNT_ROLE_ASSIGNED',i.invited_by);
end;$$;

create function public.sl_account_directory() returns jsonb language plpgsql stable security definer set search_path='' as $$
begin
  if not (logistics_private.platform_admin() or exists(select 1 from public.sl_memberships m where m.user_id=auth.uid() and m.role='admin' and logistics_private.has_role(m.workspace_id,array['admin']))) then raise exception 'Administrator required';end if;
  return coalesce((select jsonb_agg(row_data order by row_data->>'email') from (
    select jsonb_build_object('id',u.id,'email',u.email,'display_name',coalesce(p.display_name,u.email),'phone',p.phone,
      'role',case when exists(select 1 from public.sl_platform_admins where user_id=u.id) then 'platform_admin' else coalesce(a.role,(select role from public.sl_memberships where user_id=u.id and (logistics_private.platform_admin() or logistics_private.has_role(workspace_id,array['admin'])) order by workspace_id limit 1),'customer') end,
      'workspace_id',coalesce(a.workspace_id,(select workspace_id from public.sl_memberships where user_id=u.id and (logistics_private.platform_admin() or logistics_private.has_role(workspace_id,array['admin'])) order by workspace_id limit 1)),
      'company',coalesce(w.name,(select w2.name from public.sl_memberships m2 join public.sl_workspaces w2 on w2.id=m2.workspace_id where m2.user_id=u.id and (logistics_private.platform_admin() or logistics_private.has_role(m2.workspace_id,array['admin'])) order by m2.workspace_id limit 1)),
      'must_change_password',coalesce(a.must_change_password,false),'confirmed',u.email_confirmed_at is not null,'last_sign_in_at',u.last_sign_in_at,
      'assignments',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (
        select m.role,w3.name as company,m.workspace_id from public.sl_memberships m join public.sl_workspaces w3 on w3.id=m.workspace_id where m.user_id=u.id and (logistics_private.platform_admin() or logistics_private.has_role(m.workspace_id,array['admin']))
        union select 'customer',w4.name,c.workspace_id from public.sl_clients c join public.sl_workspaces w4 on w4.id=c.workspace_id where c.user_id=u.id and (logistics_private.platform_admin() or logistics_private.has_role(c.workspace_id,array['admin']))
      ) x)) row_data
    from auth.users u left join public.sl_profiles p on p.id=u.id left join public.sl_account_access a on a.user_id=u.id and (logistics_private.platform_admin() or logistics_private.has_role(a.workspace_id,array['admin'])) left join public.sl_workspaces w on w.id=a.workspace_id
    where logistics_private.platform_admin() or exists(select 1 from public.sl_memberships m where m.user_id=u.id and logistics_private.has_role(m.workspace_id,array['admin'])) or exists(select 1 from public.sl_clients c where c.user_id=u.id and logistics_private.has_role(c.workspace_id,array['admin']))
  ) accounts),'[]'::jsonb);
end;$$;

-- Block operational reads and mutations until the invited user has actually set a password.
create function logistics_private.require_password_setup() returns trigger language plpgsql security definer set search_path='' as $$
begin
  if auth.uid() is not null and not logistics_private.password_ready() then raise exception 'Set your password before using this workspace';end if;
  if TG_OP='DELETE' then return old;end if;return new;
end;$$;
revoke all on function logistics_private.require_password_setup() from public,anon,authenticated;
do $$ declare t record;begin
  for t in select tablename from pg_tables where schemaname='public' and left(tablename,3)='sl_' and tablename not in('sl_account_access','sl_account_owner','sl_platform_admins','sl_profiles','sl_memberships','sl_account_invitations') loop
    execute format('create policy password_setup_read on public.%I as restrictive for select to authenticated using (logistics_private.password_ready())',t.tablename);
    execute format('create trigger sl_require_password_setup before insert or update or delete on public.%I for each row execute function logistics_private.require_password_setup()',t.tablename);
  end loop;
end;$$;
revoke all on function public.sl_prepare_account_invitation(uuid,text,text,text,text,uuid),public.sl_account_directory() from public,anon;
grant execute on function public.sl_prepare_account_invitation(uuid,text,text,text,text,uuid),public.sl_account_directory() to authenticated;
revoke all on function public.sl_complete_account_invitation(uuid,uuid) from public,anon,authenticated;
grant execute on function public.sl_complete_account_invitation(uuid,uuid) to service_role;
grant all on public.sl_account_access,public.sl_account_invitations to service_role;
notify pgrst,'reload schema';
commit;
