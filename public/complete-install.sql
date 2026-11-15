-- FRESH INSTALL ONLY. Existing sl_ installation: use saas-upgrade.sql.
-- Swahivo Logistics: additive schema, no changes to existing tables.
-- Review and apply to the intended Logistics project only.
begin;
create schema if not exists logistics_private;
revoke all on schema logistics_private from public;
create table public.sl_workspaces(id uuid primary key default gen_random_uuid(), name text not null, created_at timestamptz not null default now());
create table public.sl_memberships(workspace_id uuid references public.sl_workspaces on delete cascade,user_id uuid references auth.users on delete cascade,role text not null check(role in ('admin','operator','viewer')),primary key(workspace_id,user_id));
create function logistics_private.has_role(w uuid,roles text[]) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.sl_memberships where workspace_id=w and user_id=auth.uid() and role=any(roles)) $$;
revoke all on function logistics_private.has_role(uuid,text[]) from public;
grant usage on schema logistics_private to authenticated;
grant execute on function logistics_private.has_role(uuid,text[]) to authenticated;
create table public.sl_clients(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,name text not null check(length(trim(name))>0),email text not null,phone text,address text,created_at timestamptz not null default now(),unique(workspace_id,id));
create table public.sl_orders(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,client_id uuid not null,reference text not null,description text,value numeric not null default 0 check(value>=0),created_at timestamptz not null default now(),unique(workspace_id,id),foreign key(workspace_id,client_id) references public.sl_clients(workspace_id,id) on delete restrict);
create table public.sl_shipments(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,order_id uuid not null,tracking_number text not null default ('SW-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))) unique,origin text not null,destination text not null,status text not null default 'Pending' check(status in('Pending','Processing','In Transit','Delivered')),latitude double precision check(latitude between -90 and 90),longitude double precision check(longitude between -180 and 180),gps_at timestamptz,created_at timestamptz not null default now(),unique(workspace_id,id),foreign key(workspace_id,order_id) references public.sl_orders(workspace_id,id) on delete restrict);
create table public.sl_tracking_events(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null,status text not null,message text not null,actor_id uuid,created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id) on delete cascade);
create table public.sl_notifications(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,shipment_id uuid, message text not null,created_at timestamptz not null default now());
create table public.sl_audit(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,entity text not null,record_id uuid not null,action text not null,actor_id uuid,details jsonb,created_at timestamptz not null default now());
create table public.sl_test_runs(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,actor_id uuid not null default auth.uid(),results jsonb not null,created_at timestamptz not null default now());
create function public.sl_create_workspace(workspace_name text) returns uuid language plpgsql security definer set search_path='' as $$ declare w uuid; begin if auth.uid() is null then raise exception 'Sign in required'; end if; if length(trim(workspace_name))=0 then raise exception 'Name required'; end if; if exists(select 1 from public.sl_memberships where user_id=auth.uid()) then raise exception 'Account already belongs to a workspace';end if; insert into public.sl_workspaces(name) values(workspace_name) returning id into w;insert into public.sl_memberships values(w,auth.uid(),'admin');return w; end; $$;
revoke all on function public.sl_create_workspace(text) from public;
grant execute on function public.sl_create_workspace(text) to authenticated;
create function logistics_private.guard_shipment() returns trigger language plpgsql set search_path='' as $$ declare states text[]:=array['Pending','Processing','In Transit','Delivered'];begin if TG_OP='INSERT' and new.status<>'Pending' then raise exception 'Shipments must begin Pending';end if; if TG_OP='UPDATE' then if new.workspace_id<>old.workspace_id or new.order_id<>old.order_id or new.id<>old.id or new.tracking_number<>old.tracking_number then raise exception 'Shipment relationship is immutable';end if;if new.status<>old.status and array_position(states,new.status)<>array_position(states,old.status)+1 then raise exception 'Only the next shipment status is allowed';end if;end if;return new;end; $$;
create trigger sl_shipment_guard before insert or update on public.sl_shipments for each row execute function logistics_private.guard_shipment();
create function logistics_private.shipment_event() returns trigger language plpgsql security definer set search_path='' as $$ begin if TG_OP='INSERT' or new.status is distinct from old.status then insert into public.sl_tracking_events(workspace_id,shipment_id,status,message,actor_id) values(new.workspace_id,new.id,new.status,'Shipment '||lower(new.status),auth.uid());insert into public.sl_notifications(workspace_id,shipment_id,message) values(new.workspace_id,new.id,new.tracking_number||' · '||new.status);end if;return new;end; $$;
create trigger sl_shipment_event after insert or update on public.sl_shipments for each row execute function logistics_private.shipment_event();
create function logistics_private.audit_change() returns trigger language plpgsql security definer set search_path='' as $$ declare r jsonb;begin if TG_OP='DELETE' then r:=to_jsonb(old);else r:=to_jsonb(new);end if;insert into public.sl_audit(workspace_id,entity,record_id,action,actor_id,details) values((r->>'workspace_id')::uuid,TG_TABLE_NAME,(r->>'id')::uuid,TG_OP,auth.uid(),jsonb_build_object('status',r->>'status','tracking_number',r->>'tracking_number'));if TG_OP='DELETE' then return old;end if;return new;end; $$;
DO $$ declare t text;begin foreach t in array array['sl_clients','sl_orders','sl_shipments'] loop execute format('create trigger sl_audit_change after insert or update or delete on public.%I for each row execute function logistics_private.audit_change()',t);end loop;end; $$;
revoke all on all functions in schema logistics_private from public;
-- Trigger functions have no client EXECUTE; only the membership predicate is callable.
grant execute on function logistics_private.has_role(uuid,text[]) to authenticated;
DO $$ declare t text;begin foreach t in array array['sl_memberships','sl_clients','sl_orders','sl_shipments','sl_tracking_events','sl_notifications','sl_audit','sl_test_runs'] loop execute format('alter table public.%I enable row level security',t); execute format('grant select on public.%I to authenticated',t); execute format('create policy member_read on public.%I for select to authenticated using (logistics_private.has_role(workspace_id,array[''admin'',''operator'',''viewer'']))',t);end loop;end; $$;
-- Workspaces uses id rather than workspace_id.
alter table public.sl_workspaces enable row level security;
grant select on public.sl_workspaces to authenticated;
create policy workspace_read on public.sl_workspaces for select to authenticated using(logistics_private.has_role(id,array['admin','operator','viewer']));
DO $$ declare t text;begin foreach t in array array['sl_clients','sl_orders','sl_shipments'] loop
execute format('grant insert,update,delete on public.%I to authenticated',t);
execute format('create policy operator_insert on public.%I for insert to authenticated with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'']))',t);
execute format('create policy operator_update on public.%I for update to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator''])) with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'']))',t);
execute format('create policy admin_delete on public.%I for delete to authenticated using(logistics_private.has_role(workspace_id,array[''admin'']))',t);
execute format('create index on public.%I(workspace_id)',t);
end loop;end; $$;
grant insert on public.sl_test_runs to authenticated;
create policy test_insert on public.sl_test_runs for insert to authenticated with check(actor_id=auth.uid() and logistics_private.has_role(workspace_id,array['admin']));
create index on public.sl_tracking_events(workspace_id,shipment_id,created_at);
create index on public.sl_notifications(workspace_id,created_at);
create index on public.sl_audit(workspace_id,created_at);
-- Assign teammate roles only through trusted administration, never user-editable metadata.
-- Example (replace UUIDs): insert into public.sl_memberships values ('workspace UUID','auth user UUID','operator');
-- Swahivo Logistics SaaS upgrade. Run AFTER the original sl_ schema.
-- No legacy operational records are dropped. Run this upgrade once.

alter table public.sl_workspaces add column status text not null default 'active' check(status in('pending','active','suspended','rejected'));
alter table public.sl_workspaces add column country text not null default 'Tanzania';
alter table public.sl_workspaces add column city text;
alter table public.sl_workspaces add column email text;
alter table public.sl_workspaces add column phone text;
alter table public.sl_workspaces add column address text;
alter table public.sl_workspaces add column description text;
alter table public.sl_workspaces add column logo_url text;
alter table public.sl_workspaces add column website text;
alter table public.sl_clients add column user_id uuid references auth.users(id);
create unique index sl_customer_company on public.sl_clients(workspace_id,user_id) where user_id is not null;
alter table public.sl_shipments add column weight numeric not null default 0 check(weight>=0);
alter table public.sl_shipments add column mode text not null default 'Road Freight';
alter table public.sl_shipments add column recipient_name text;
alter table public.sl_shipments add column recipient_phone text;
alter table public.sl_shipments add column eta timestamptz;
alter table public.sl_shipments add column driver_id uuid;
create table public.sl_platform_admins(user_id uuid primary key references auth.users on delete cascade,created_at timestamptz not null default now());
alter table public.sl_platform_admins enable row level security;
revoke all on public.sl_platform_admins from anon,authenticated;
grant select on public.sl_platform_admins to authenticated;
create policy admin_self on public.sl_platform_admins for select to authenticated using(user_id=auth.uid());
create function logistics_private.platform_admin() returns boolean language sql stable security definer set search_path='' as $$ select auth.uid() is not null and exists(select 1 from public.sl_platform_admins where user_id=auth.uid()) $$;
revoke all on function logistics_private.platform_admin() from public;
grant execute on function logistics_private.platform_admin() to authenticated;
create or replace function logistics_private.has_role(w uuid,roles text[]) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.platform_admin() or exists(select 1 from public.sl_memberships m join public.sl_workspaces t on t.id=m.workspace_id where m.workspace_id=w and m.user_id=auth.uid() and m.role=any(roles) and t.status='active') $$;
create table public.sl_profiles(id uuid primary key references auth.users on delete cascade,display_name text not null,phone text,created_at timestamptz not null default now());
alter table public.sl_profiles enable row level security;
grant select,insert,update on public.sl_profiles to authenticated;
create policy own_profile on public.sl_profiles for select to authenticated using(id=auth.uid() or logistics_private.platform_admin());
create policy create_profile on public.sl_profiles for insert to authenticated with check(id=auth.uid());
create policy edit_profile on public.sl_profiles for update to authenticated using(id=auth.uid()) with check(id=auth.uid());
create function logistics_private.create_profile() returns trigger language plpgsql security definer set search_path='' as $$ begin
insert into public.sl_profiles(id,display_name) values(new.id,coalesce(nullif(trim(new.raw_user_meta_data->>'display_name'),''),split_part(new.email,'@',1),'User')) on conflict(id) do nothing;return new;end; $$;
create trigger sl_auth_profile after insert on auth.users for each row execute function logistics_private.create_profile();
insert into public.sl_profiles(id,display_name) select id,coalesce(nullif(trim(raw_user_meta_data->>'display_name'),''),split_part(email,'@',1),'User') from auth.users on conflict(id) do nothing;
-- Pending owners can read their own membership and application without operational access.
create policy own_membership on public.sl_memberships for select to authenticated using(user_id=auth.uid());
create policy company_directory on public.sl_workspaces for select to authenticated using(status='active' or logistics_private.platform_admin() or exists(select 1 from public.sl_memberships m where m.workspace_id=id and m.user_id=auth.uid()));
grant update on public.sl_workspaces to authenticated;
create policy platform_manage_company on public.sl_workspaces for update to authenticated using(logistics_private.platform_admin()) with check(logistics_private.platform_admin());
create or replace function public.sl_create_workspace(workspace_name text) returns uuid language plpgsql security definer set search_path='' as $$ declare w uuid;begin
if auth.uid() is null then raise exception 'Sign in required';end if;
if length(trim(workspace_name))<2 then raise exception 'Company name is required';end if;
if exists(select 1 from public.sl_memberships where user_id=auth.uid()) then raise exception 'You already belong to a cargo company';end if;
insert into public.sl_workspaces(name,status) values(trim(workspace_name),'pending') returning id into w;
insert into public.sl_memberships values(w,auth.uid(),'admin');return w;end; $$;
create function public.sl_update_company(w uuid,company_name text,company_email text,company_phone text,company_address text,company_description text) returns void language plpgsql security definer set search_path='' as $$ begin
if auth.uid() is null or not logistics_private.has_role(w,array['admin']) then raise exception 'Company admin permission required';end if;
if length(trim(company_name))<2 then raise exception 'Name required';end if;
update public.sl_workspaces set name=trim(company_name),email=company_email,phone=company_phone,address=company_address,description=company_description where id=w;end; $$;
create function public.sl_add_member(w uuid,member_email text,member_role text) returns void language plpgsql security definer set search_path='' as $$ declare u uuid;begin
if auth.uid() is null or not logistics_private.has_role(w,array['admin']) then raise exception 'Company admin permission required';end if;
if member_role not in('admin','operator','viewer') then raise exception 'Invalid role';end if;
select id into u from auth.users where lower(email)=lower(trim(member_email)) and email_confirmed_at is not null;
if u is null then raise exception 'A confirmed user with this email must register first';end if;
if u=auth.uid() then raise exception 'You cannot change your own role here';end if;
insert into public.sl_memberships(workspace_id,user_id,role) values(w,u,member_role) on conflict(workspace_id,user_id) do update set role=excluded.role;end; $$;
create function public.sl_remove_member(w uuid,member uuid) returns void language plpgsql security definer set search_path='' as $$ begin
if auth.uid() is null or not logistics_private.has_role(w,array['admin']) or member=auth.uid() then raise exception 'Admin permission required; cannot remove yourself';end if;
delete from public.sl_memberships where workspace_id=w and user_id=member;end; $$;
-- Tenant-aware service and operations records.
create table public.sl_services(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,name text not null,mode text not null check(mode in('Road Freight','Air Freight','Ocean Freight','Rail Freight','Multimodal','Warehouse + Shipping')),origin text not null,destination text not null,base_price numeric not null default 0 check(base_price>=0),per_kg numeric not null default 0 check(per_kg>=0),active boolean not null default true,created_at timestamptz not null default now(),unique(workspace_id,id));
create table public.sl_drivers(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,name text not null,phone text not null,vehicle text,license_number text,status text not null default 'available' check(status in('available','assigned','inactive')),created_at timestamptz not null default now(),unique(workspace_id,id));
alter table public.sl_shipments add foreign key(workspace_id,driver_id) references public.sl_drivers(workspace_id,id) on delete restrict;
create table public.sl_facilities(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,name text not null,type text not null check(type in('Warehouse','Hub','Office','Port')),city text not null,address text not null,capacity numeric not null default 0 check(capacity>=0),created_at timestamptz not null default now());
create table public.sl_pickups(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null,address text not null,scheduled_at timestamptz not null,status text not null default 'requested' check(status in('requested','scheduled','completed','cancelled')),driver_id uuid,created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id) on delete restrict,foreign key(workspace_id,driver_id) references public.sl_drivers(workspace_id,id));
create table public.sl_addresses(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users,name text not null,city text not null,address text not null,phone text,created_at timestamptz not null default now());
alter table public.sl_addresses enable row level security;
grant select,insert,update,delete on public.sl_addresses to authenticated;
create policy address_read on public.sl_addresses for select to authenticated using(user_id=auth.uid());
create policy address_create on public.sl_addresses for insert to authenticated with check(user_id=auth.uid());
create policy address_edit on public.sl_addresses for update to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy address_delete on public.sl_addresses for delete to authenticated using(user_id=auth.uid());
create table public.sl_plans(id uuid primary key default gen_random_uuid(),name text not null,monthly_price numeric not null check(monthly_price>=0),shipment_limit integer check(shipment_limit>0),description text,active boolean not null default true,created_at timestamptz not null default now());
create table public.sl_subscriptions(id uuid primary key default gen_random_uuid(),workspace_id uuid not null unique references public.sl_workspaces,plan_id uuid not null references public.sl_plans,status text not null check(status in('trial','active','expired','cancelled')),starts_at timestamptz not null default now(),expires_at timestamptz not null,created_at timestamptz not null default now(),check(expires_at>starts_at));
create table public.sl_invoices(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,order_id uuid not null,number text not null default ('INV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12))),total numeric not null check(total>=0),currency text not null default 'TZS' check(currency='TZS'),due_at timestamptz,status text not null default 'unpaid' check(status in('unpaid','part_paid','paid')),created_at timestamptz not null default now(),foreign key(workspace_id,order_id) references public.sl_orders(workspace_id,id),unique(workspace_id,id));
create table public.sl_payments(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,invoice_id uuid not null,amount numeric not null check(amount>0),reference text not null,method text not null,status text not null default 'submitted' check(status in('submitted','verified','rejected')),submitted_by uuid not null default auth.uid() references auth.users,verified_by uuid references auth.users,created_at timestamptz not null default now(),foreign key(workspace_id,invoice_id) references public.sl_invoices(workspace_id,id));
create unique index sl_payment_reference_once on public.sl_payments(workspace_id,reference);
create table public.sl_billing_payments(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,amount numeric not null check(amount>0),reference text not null,method text not null,status text not null default 'submitted' check(status in('submitted','verified','rejected')),created_at timestamptz not null default now());
create table public.sl_tickets(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,user_id uuid not null default auth.uid() references auth.users,subject text not null,message text not null,type text not null default 'support' check(type in('support','dispute')),status text not null default 'open' check(status in('open','in_progress','resolved')),response text,created_at timestamptz not null default now());
create table public.sl_reviews(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,user_id uuid not null default auth.uid() references auth.users,rating integer not null check(rating between 1 and 5),comment text not null,status text not null default 'pending' check(status in('pending','approved','rejected')),created_at timestamptz not null default now());
create table public.sl_locations(id uuid primary key default gen_random_uuid(),country text not null,city text not null,active boolean not null default true,created_at timestamptz not null default now());
create table public.sl_settings(id uuid primary key default gen_random_uuid(),name text not null unique,value text not null,created_at timestamptz not null default now());
create table public.sl_commissions(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,payment_id uuid not null unique references public.sl_payments,rate numeric not null check(rate between 0 and 100),amount numeric not null check(amount>=0),created_at timestamptz not null default now());
-- Record-level customer ownership uses trusted links, never user metadata.
create function logistics_private.client_access(w uuid,c uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.has_role(w,array['admin','operator','viewer']) or exists(select 1 from public.sl_clients where workspace_id=w and id=c and user_id=auth.uid()) $$;
create function logistics_private.shipment_access(w uuid,s uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.has_role(w,array['admin','operator','viewer']) or exists(select 1 from public.sl_shipments sh join public.sl_orders o on o.id=sh.order_id join public.sl_clients c on c.id=o.client_id where sh.id=s and sh.workspace_id=w and c.user_id=auth.uid()) $$;
create function logistics_private.invoice_access(w uuid,i uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.has_role(w,array['admin','operator','viewer']) or exists(select 1 from public.sl_invoices inv join public.sl_orders o on o.id=inv.order_id join public.sl_clients c on c.id=o.client_id where inv.id=i and inv.workspace_id=w and c.user_id=auth.uid()) $$;
create policy customer_client on public.sl_clients for select to authenticated using(user_id=auth.uid());
create policy customer_orders on public.sl_orders for select to authenticated using(logistics_private.client_access(workspace_id,client_id));
create policy customer_shipments on public.sl_shipments for select to authenticated using(logistics_private.shipment_access(workspace_id,id));
create policy customer_events on public.sl_tracking_events for select to authenticated using(logistics_private.shipment_access(workspace_id,shipment_id));
create policy customer_notifications on public.sl_notifications for select to authenticated using(logistics_private.shipment_access(workspace_id,shipment_id));
DO $$ declare t text;begin foreach t in array array['sl_services','sl_drivers','sl_facilities','sl_pickups','sl_invoices','sl_payments','sl_billing_payments','sl_tickets','sl_reviews','sl_subscriptions','sl_commissions'] loop
execute format('alter table public.%I enable row level security',t);
execute format('revoke all on public.%I from anon,authenticated',t);
execute format('grant select on public.%I to authenticated',t);
execute format('create policy staff_read on public.%I for select to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''viewer'']))',t);
execute format('create index on public.%I(workspace_id)',t);
end loop;end; $$;
DO $$ declare t text;begin foreach t in array array['sl_services','sl_drivers','sl_facilities','sl_pickups'] loop
execute format('grant insert,update,delete on public.%I to authenticated',t);
execute format('create policy staff_create on public.%I for insert to authenticated with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'']))',t);
execute format('create policy staff_edit on public.%I for update to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator''])) with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'']))',t);
execute format('create policy admin_remove on public.%I for delete to authenticated using(logistics_private.has_role(workspace_id,array[''admin'']))',t);
end loop;end; $$;
create policy marketplace_read on public.sl_services for select to authenticated using(active and exists(select 1 from public.sl_workspaces where id=workspace_id and status='active'));
create policy customer_pickups on public.sl_pickups for select to authenticated using(logistics_private.shipment_access(workspace_id,shipment_id));
create policy customer_invoices on public.sl_invoices for select to authenticated using(logistics_private.invoice_access(workspace_id,id));
create policy customer_payments on public.sl_payments for select to authenticated using(logistics_private.invoice_access(workspace_id,invoice_id));
create policy own_tickets on public.sl_tickets for select to authenticated using(user_id=auth.uid());
create policy own_reviews on public.sl_reviews for select to authenticated using(user_id=auth.uid());
create policy public_reviews on public.sl_reviews for select to authenticated using(status='approved');
grant insert on public.sl_tickets,public.sl_reviews,public.sl_billing_payments to authenticated;
create policy ticket_create on public.sl_tickets for insert to authenticated with check(user_id=auth.uid() and status='open' and response is null and (logistics_private.has_role(workspace_id,array['admin','operator']) or exists(select 1 from public.sl_clients c where c.workspace_id=sl_tickets.workspace_id and c.user_id=auth.uid())));
create policy review_create on public.sl_reviews for insert to authenticated with check(user_id=auth.uid() and status='pending' and exists(select 1 from public.sl_clients c join public.sl_orders o on o.client_id=c.id join public.sl_shipments s on s.order_id=o.id where c.workspace_id=sl_reviews.workspace_id and c.user_id=auth.uid() and s.status='Delivered'));
create policy billing_submit on public.sl_billing_payments for insert to authenticated with check(logistics_private.has_role(workspace_id,array['admin']) and status='submitted');
grant update(status,response) on public.sl_tickets to authenticated;
create policy ticket_respond on public.sl_tickets for update to authenticated using(logistics_private.has_role(workspace_id,array['admin','operator'])) with check(logistics_private.has_role(workspace_id,array['admin','operator']));
grant update on public.sl_reviews,public.sl_subscriptions,public.sl_billing_payments to authenticated;
grant insert,delete on public.sl_subscriptions to authenticated;
DO $$ declare t text;begin foreach t in array array['sl_reviews','sl_subscriptions','sl_billing_payments'] loop
execute format('create policy platform_edit on public.%I for update to authenticated using(logistics_private.platform_admin()) with check(logistics_private.platform_admin())',t);end loop;end; $$;
create policy platform_sub_create on public.sl_subscriptions for insert to authenticated with check(logistics_private.platform_admin());
create policy platform_sub_delete on public.sl_subscriptions for delete to authenticated using(logistics_private.platform_admin());
DO $$ declare t text;begin foreach t in array array['sl_plans','sl_locations','sl_settings'] loop
execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select,insert,update,delete on public.%I to authenticated',t);
execute format('create policy platform_create on public.%I for insert to authenticated with check(logistics_private.platform_admin())',t);
execute format('create policy platform_edit on public.%I for update to authenticated using(logistics_private.platform_admin()) with check(logistics_private.platform_admin())',t);
execute format('create policy platform_delete on public.%I for delete to authenticated using(logistics_private.platform_admin())',t);end loop;end; $$;
create policy plans_read on public.sl_plans for select to authenticated using(active or logistics_private.platform_admin());
create policy locations_read on public.sl_locations for select to authenticated using(active or logistics_private.platform_admin());
create policy settings_read on public.sl_settings for select to authenticated using(logistics_private.platform_admin());
-- Subscription and quota enforcement on new shipments. Existing companies without an assigned
-- subscription remain usable (migration compatibility); an assigned expired plan blocks new shipments.
create function logistics_private.check_quota(w uuid) returns void language plpgsql security definer set search_path='' as $$ declare sub record;n bigint;begin
perform 1 from public.sl_workspaces where id=w and status='active' for update;if not found then raise exception 'Cargo company is not active';end if;
select s.*,p.shipment_limit into sub from public.sl_subscriptions s join public.sl_plans p on p.id=s.plan_id where s.workspace_id=w;
if found then
if sub.status not in('trial','active') or sub.expires_at<=now() then raise exception 'Company subscription has expired';end if;
if sub.shipment_limit is not null then select count(*) into n from public.sl_shipments where workspace_id=w and created_at>=date_trunc('month',now());if n>=sub.shipment_limit then raise exception 'Monthly shipment quota reached';end if;end if;end if;end; $$;
create function logistics_private.shipment_quota_trigger() returns trigger language plpgsql set search_path='' as $$ begin perform logistics_private.check_quota(new.workspace_id);return new;end; $$;
create trigger sl_shipment_quota before insert on public.sl_shipments for each row execute function logistics_private.shipment_quota_trigger();
create function public.sl_book_shipment(service uuid,weight_kg numeric,sender_name text,sender_email text,sender_phone text,pickup_address text,recipient text,recipient_contact text,delivery_address text) returns uuid language plpgsql security definer set search_path='' as $$ declare svc record;c uuid;o uuid;s uuid;price numeric;begin
if auth.uid() is null then raise exception 'Sign in required';end if;
if weight_kg<=0 or weight_kg>100000 or length(trim(sender_name))=0 or length(trim(recipient))=0 or length(trim(delivery_address))=0 then raise exception 'Valid weight, sender, recipient and address required';end if;
select * into svc from public.sl_services where id=service and active;if not found then raise exception 'Service unavailable';end if;
perform logistics_private.check_quota(svc.workspace_id);
select id into c from public.sl_clients where workspace_id=svc.workspace_id and user_id=auth.uid();
if c is null then insert into public.sl_clients(workspace_id,user_id,name,email,phone,address) values(svc.workspace_id,auth.uid(),sender_name,sender_email,sender_phone,pickup_address) returning id into c;end if;
price:=round(svc.base_price+svc.per_kg*weight_kg,2);
insert into public.sl_orders(workspace_id,client_id,reference,description,value) values(svc.workspace_id,c,'ORD-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10)),svc.name,price) returning id into o;
insert into public.sl_shipments(workspace_id,order_id,origin,destination,weight,mode,recipient_name,recipient_phone) values(svc.workspace_id,o,pickup_address,delivery_address,weight_kg,svc.mode,recipient,recipient_contact) returning id into s;
insert into public.sl_invoices(workspace_id,order_id,total) values(svc.workspace_id,o,price);return s;end; $$;
create function public.sl_request_pickup(shipment uuid,pickup_address text,pickup_time timestamptz) returns uuid language plpgsql security definer set search_path='' as $$ declare w uuid;r uuid;begin
select workspace_id into w from public.sl_shipments where id=shipment;if auth.uid() is null or not (logistics_private.has_role(w,array['admin','operator']) or exists(select 1 from public.sl_shipments sh join public.sl_orders o on o.id=sh.order_id join public.sl_clients c on c.id=o.client_id where sh.id=shipment and sh.workspace_id=w and c.user_id=auth.uid())) then raise exception 'Shipment write access denied';end if;
if pickup_time<now() or length(trim(pickup_address))=0 then raise exception 'Future pickup time and address required';end if;
insert into public.sl_pickups(workspace_id,shipment_id,address,scheduled_at) values(w,shipment,pickup_address,pickup_time) returning id into r;return r;end; $$;
create function public.sl_submit_payment(invoice uuid,payment_amount numeric,payment_reference text,payment_method text) returns uuid language plpgsql security definer set search_path='' as $$ declare inv record;paid numeric;r uuid;begin
select * into inv from public.sl_invoices where id=invoice for update;
if auth.uid() is null or not (logistics_private.has_role(inv.workspace_id,array['admin','operator']) or exists(select 1 from public.sl_orders o join public.sl_clients c on c.id=o.client_id where o.id=inv.order_id and c.user_id=auth.uid())) then raise exception 'Invoice write access denied';end if;
select coalesce(sum(amount),0) into paid from public.sl_payments where invoice_id=invoice and status='verified';
if payment_amount<=0 or payment_amount>inv.total-paid or length(trim(payment_reference))<3 then raise exception 'Invalid amount or reference';end if;
insert into public.sl_payments(workspace_id,invoice_id,amount,reference,method) values(inv.workspace_id,invoice,payment_amount,payment_reference,payment_method) returning id into r;return r;end; $$;
create function public.sl_verify_payment(payment uuid,decision text) returns void language plpgsql security definer set search_path='' as $$ declare p record;inv record;paid numeric;rate numeric;begin
select * into p from public.sl_payments where id=payment for update;if not found then raise exception 'Payment not found';end if;
if auth.uid() is null or not logistics_private.has_role(p.workspace_id,array['admin','operator']) then raise exception 'Finance permission required';end if;
if decision not in('verified','rejected') or p.status<>'submitted' then raise exception 'Payment already reviewed or invalid decision';end if;
select * into inv from public.sl_invoices where id=p.invoice_id for update;
select coalesce(sum(amount),0) into paid from public.sl_payments where invoice_id=p.invoice_id and status='verified';
if decision='verified' and paid+p.amount>inv.total then raise exception 'Payment exceeds outstanding balance';end if;
update public.sl_payments set status=decision,verified_by=auth.uid() where id=payment;
if decision='verified' then paid:=paid+p.amount;update public.sl_invoices set status=case when paid>=total then 'paid' when paid>0 then 'part_paid' else 'unpaid' end where id=p.invoice_id;
select value::numeric into rate from public.sl_settings where name='commission_percent' and value ~ '^[0-9]+(\.[0-9]+)?$';
if rate between 0 and 100 then insert into public.sl_commissions(workspace_id,payment_id,rate,amount) values(p.workspace_id,p.id,rate,round(p.amount*rate/100,2));end if;end if;end; $$;
-- Derived finance rows are changed only through guarded functions.
grant insert on public.sl_invoices to authenticated;
create policy invoice_create on public.sl_invoices for insert to authenticated with check(status='unpaid' and logistics_private.has_role(workspace_id,array['admin','operator']));
-- Add server audit evidence for new tenant entities. Platform/global changes use a separate trail.
create table public.sl_platform_audit(id uuid primary key default gen_random_uuid(),entity text not null,record_id uuid not null,action text not null,actor_id uuid,created_at timestamptz not null default now());
alter table public.sl_platform_audit enable row level security;grant select on public.sl_platform_audit to authenticated;
create policy platform_audit_read on public.sl_platform_audit for select to authenticated using(logistics_private.platform_admin());
create function logistics_private.platform_audit_change() returns trigger language plpgsql security definer set search_path='' as $$ declare r jsonb;begin if TG_OP='DELETE' then r:=to_jsonb(old);else r:=to_jsonb(new);end if;insert into public.sl_platform_audit(entity,record_id,action,actor_id) values(TG_TABLE_NAME,(r->>'id')::uuid,TG_OP,auth.uid());if TG_OP='DELETE' then return old;end if;return new;end; $$;
DO $$ declare t text;begin foreach t in array array['sl_services','sl_drivers','sl_facilities','sl_pickups','sl_invoices','sl_payments','sl_billing_payments','sl_tickets','sl_reviews','sl_subscriptions','sl_commissions'] loop execute format('create trigger sl_saas_audit after insert or update or delete on public.%I for each row execute function logistics_private.audit_change()',t);end loop;
foreach t in array array['sl_workspaces','sl_plans','sl_settings','sl_locations'] loop execute format('create trigger sl_global_audit after insert or update or delete on public.%I for each row execute function logistics_private.platform_audit_change()',t);end loop;end; $$;
-- Revoke PostgreSQL default public function execution; allow only intended authenticated RPCs.
DO $$ declare fn record;begin for fn in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('sl_update_company','sl_add_member','sl_remove_member','sl_book_shipment','sl_request_pickup','sl_submit_payment','sl_verify_payment') loop execute format('revoke all on function %s from public',fn.signature);execute format('grant execute on function %s to authenticated',fn.signature);end loop;end; $$;
revoke all on all functions in schema logistics_private from public;
grant execute on function logistics_private.platform_admin(),logistics_private.has_role(uuid,text[]),logistics_private.client_access(uuid,uuid),logistics_private.shipment_access(uuid,uuid),logistics_private.invoice_access(uuid,uuid),logistics_private.check_quota(uuid) to authenticated;

create function public.sl_dashboard(w uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$
select jsonb_build_object(
'providers',(select count(*) from public.sl_workspaces),
'active_providers',(select count(*) from public.sl_workspaces where status='active'),
'pending_providers',(select count(*) from public.sl_workspaces where status='pending'),
'customers',(select count(*) from public.sl_clients where w is null or workspace_id=w),
'orders',(select count(*) from public.sl_orders where w is null or workspace_id=w),
'shipments',(select count(*) from public.sl_shipments where w is null or workspace_id=w),
'active_shipments',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status<>'Delivered'),
'delivered',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status='Delivered'),
'pending',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status='Pending'),
'processing',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status='Processing'),
'in_transit',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status='In Transit'),
'verified_payments',(select coalesce(sum(amount),0) from public.sl_payments where (w is null or workspace_id=w) and status='verified'),
'platform_revenue',(select coalesce(sum(amount),0) from public.sl_billing_payments where (w is null or workspace_id=w) and status='verified'),
'open_tickets',(select count(*) from public.sl_tickets where (w is null or workspace_id=w) and status<>'resolved'),
'volume',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (select to_char(created_at at time zone 'Africa/Dar_es_Salaam','YYYY-MM-DD') as "day",count(*) total,count(*) filter(where status='Delivered') delivered from public.sl_shipments where (w is null or workspace_id=w) and created_at>now()-interval '14 days' group by 1 order by 1) x),
'destinations',(select coalesce(jsonb_agg(x),'[]'::jsonb) from (select destination,count(*) total from public.sl_shipments where w is null or workspace_id=w group by destination order by total desc limit 5) x)
); $$;
revoke all on function public.sl_dashboard(uuid) from public;
grant execute on function public.sl_dashboard(uuid) to authenticated;


create table public.sl_contact_messages(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users,subject text not null,message text not null,status text not null default 'open' check(status in('open','in_progress','resolved')),response text,created_at timestamptz not null default now());
alter table public.sl_contact_messages enable row level security;
revoke all on public.sl_contact_messages from anon,authenticated;
grant select,insert on public.sl_contact_messages to authenticated;
grant update(status,response) on public.sl_contact_messages to authenticated;
create policy contact_read on public.sl_contact_messages for select to authenticated using(user_id=auth.uid() or logistics_private.platform_admin());
create policy contact_create on public.sl_contact_messages for insert to authenticated with check(user_id=auth.uid() and status='open' and response is null);
create policy contact_respond on public.sl_contact_messages for update to authenticated using(logistics_private.platform_admin()) with check(logistics_private.platform_admin());
create trigger sl_contact_audit after insert or update on public.sl_contact_messages for each row execute function logistics_private.platform_audit_change();

-- No platform admin is created automatically. Bootstrap a confirmed auth user with trusted SQL:
-- insert into public.sl_platform_admins(user_id) select id from auth.users where email='YOUR_ADMIN_EMAIL';
-- Then approve pending cargo companies from the platform dashboard.
commit;


-- SWAHIVO Logistics operations upgrade: additive, apply after v2.
begin;
alter table public.sl_memberships drop constraint if exists sl_memberships_role_check;
alter table public.sl_memberships add constraint sl_memberships_role_check check(role in('admin','operator','viewer','dispatcher','finance','driver','warehouse'));
alter table public.sl_drivers add column user_id uuid references auth.users;
create unique index sl_driver_user on public.sl_drivers(workspace_id,user_id) where user_id is not null;
create table public.sl_provider_verifications(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,registration_number text not null,document_path text not null,status text not null default 'pending' check(status in('pending','approved','rejected')),reason text,reviewed_by uuid references auth.users,reviewed_at timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.sl_service_areas(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,origin_city text not null,destination_city text not null,service_type text not null,active boolean not null default true,created_at timestamptz not null default now(),unique(workspace_id,origin_city,destination_city,service_type));
create table public.sl_vehicles(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,plate_number text not null,type text not null,capacity_kg numeric not null check(capacity_kg>0),status text not null default 'available' check(status in('available','assigned','maintenance','inactive')),last_service date,next_service date,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(workspace_id,id),unique(workspace_id,plate_number));
create table public.sl_routes(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,name text not null,origin text not null,destination text not null,active boolean not null default true,created_at timestamptz not null default now());
create table public.sl_route_stops(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,route_id uuid not null references public.sl_routes,position integer not null check(position>0),name text not null,latitude numeric check(latitude between -90 and 90),longitude numeric check(longitude between -180 and 180),created_at timestamptz not null default now(),unique(route_id,position));
create table public.sl_bookings(id uuid primary key default gen_random_uuid(),customer_id uuid not null references auth.users,workspace_id uuid references public.sl_workspaces,reference text not null unique default ('BK-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),service_type text not null,origin_city text not null,destination_city text not null,pickup_address text not null,delivery_address text not null,sender_name text not null,sender_phone text not null,recipient_name text not null,recipient_phone text not null,weight_kg numeric not null check(weight_kg>0),description text not null,status text not null default 'requested' check(status in('requested','assigned','quoted','accepted','declined','shipment_created','cancelled')),reason text,assigned_by uuid references auth.users,assigned_at timestamptz,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.sl_quotations(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,booking_id uuid not null references public.sl_bookings,amount numeric not null check(amount>=0),transit_days integer not null check(transit_days>0),note text,accepted_by_customer boolean not null default false,created_at timestamptz not null default now(),unique(booking_id,workspace_id));
create table public.sl_booking_assignments(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,booking_id uuid not null references public.sl_bookings,actor_id uuid not null references auth.users,created_at timestamptz not null default now());
alter table public.sl_shipments add column booking_id uuid unique references public.sl_bookings;
alter table public.sl_shipments add column qr_token uuid not null default gen_random_uuid();
alter table public.sl_shipments add column updated_at timestamptz not null default now();
alter table public.sl_shipments drop constraint if exists sl_shipments_status_check;
alter table public.sl_shipments add constraint sl_shipments_status_check check(status in('Pending','Processing','Picked Up','In Transit','Out for Delivery','Delivered','Failed Delivery','Exception','Returned','Cancelled'));
alter table public.sl_pickups add column vehicle_id uuid;
alter table public.sl_pickups add foreign key(workspace_id,vehicle_id) references public.sl_vehicles(workspace_id,id);
alter table public.sl_pickups drop constraint if exists sl_pickups_status_check;
alter table public.sl_pickups add constraint sl_pickups_status_check check(status in('requested','scheduled','accepted','collected','completed','cancelled','declined','failed'));
create table public.sl_shipment_packages(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null,package_type text not null,weight_kg numeric not null check(weight_kg>0),length_cm numeric check(length_cm>0),width_cm numeric check(width_cm>0),height_cm numeric check(height_cm>0),description text,created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id));
create table public.sl_delivery_tasks(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null unique,driver_id uuid,vehicle_id uuid,status text not null default 'requested' check(status in('requested','assigned','accepted','out_for_delivery','delivered','failed','returned','declined','cancelled')),reason text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id),foreign key(workspace_id,driver_id) references public.sl_drivers(workspace_id,id),foreign key(workspace_id,vehicle_id) references public.sl_vehicles(workspace_id,id));
create table public.sl_scan_events(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null,actor_id uuid not null default auth.uid() references auth.users,action text not null check(action in('inspect','pickup','warehouse_receive','dispatch','delivery')),created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id));
create table public.sl_delivery_proofs(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null unique,recipient_name text not null,photo_path text not null,signature_path text not null,received_by uuid not null references auth.users,created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id));
create table public.sl_location_updates(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null,actor_id uuid not null default auth.uid(),latitude double precision not null check(latitude between -90 and 90),longitude double precision not null check(longitude between -180 and 180),accuracy numeric check(accuracy>=0),created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id));
create table public.sl_fee_history(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,shipment_id uuid not null,previous_amount numeric not null,new_amount numeric not null check(new_amount>=0),reason text not null,actor_id uuid not null default auth.uid(),created_at timestamptz not null default now(),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id));
create table public.sl_storage_locations(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,warehouse_id uuid not null references public.sl_facilities,code text not null,capacity_kg numeric not null check(capacity_kg>0),grid_x integer not null default 0 check(grid_x>=0),grid_y integer not null default 0 check(grid_y>=0),created_at timestamptz not null default now(),unique(workspace_id,id),unique(warehouse_id,code));
create table public.sl_storage_pricing(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,name text not null,daily_rate numeric not null check(daily_rate>=0),unit text not null check(unit in('kg','unit','m3')),minimum_days integer not null default 1 check(minimum_days>0),created_at timestamptz not null default now());
create table public.sl_storage_bookings(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,client_id uuid not null,warehouse_id uuid not null references public.sl_facilities,pricing_id uuid references public.sl_storage_pricing,status text not null default 'requested' check(status in('requested','approved','completed','rejected')),starts_at timestamptz not null default now(),ends_at timestamptz,created_at timestamptz not null default now(),foreign key(workspace_id,client_id) references public.sl_clients(workspace_id,id));
create table public.sl_inventory_items(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,storage_booking_id uuid not null references public.sl_storage_bookings,location_id uuid,sku text not null,name text not null,quantity numeric not null default 0 check(quantity>=0),reserved numeric not null default 0 check(reserved>=0 and reserved<=quantity),weight_per_unit numeric not null check(weight_per_unit>0),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(workspace_id,id),foreign key(workspace_id,location_id) references public.sl_storage_locations(workspace_id,id));
create table public.sl_inventory_movements(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,item_id uuid not null,quantity numeric not null check(quantity<>0),type text not null check(type in('receive','release','adjustment')),reason text not null,actor_id uuid not null default auth.uid(),created_at timestamptz not null default now(),foreign key(workspace_id,item_id) references public.sl_inventory_items(workspace_id,id));
create table public.sl_dispatch_jobs(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,item_id uuid not null,shipment_id uuid,quantity numeric not null check(quantity>0),status text not null default 'requested' check(status in('requested','picked','packed','released','cancelled')),requested_by uuid not null default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),foreign key(workspace_id,item_id) references public.sl_inventory_items(workspace_id,id),foreign key(workspace_id,shipment_id) references public.sl_shipments(workspace_id,id));
create table public.sl_ledger_entries(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,source_type text not null check(source_type in('payment','payout')),source_id uuid not null,account text not null check(account in('gross_revenue','platform_commission','provider_payable')),amount numeric not null,created_at timestamptz not null default now(),unique(source_type,source_id,account));
create table public.sl_settlements(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,amount numeric not null check(amount>=0),status text not null default 'pending' check(status in('pending','approved','rejected')),reviewed_by uuid references auth.users,reason text,created_at timestamptz not null default now());
create table public.sl_settlement_lines(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,settlement_id uuid not null references public.sl_settlements,payment_id uuid not null unique references public.sl_payments,amount numeric not null check(amount>=0),created_at timestamptz not null default now());
create table public.sl_payout_requests(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,settlement_id uuid not null references public.sl_settlements,amount numeric not null check(amount>0),status text not null default 'requested' check(status in('requested','approved','paid','rejected')),method text not null,destination text not null,transfer_reference text,reason text,idempotency_key uuid not null unique,reviewed_by uuid references auth.users,created_at timestamptz not null default now());
alter table public.sl_notifications add column user_id uuid references auth.users;
alter table public.sl_notifications add column visibility text not null default 'customer' check(visibility in('customer','provider','driver','warehouse','platform'));
create function logistics_private.assigned_driver(w uuid,s uuid) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.sl_drivers d join public.sl_shipments sh on sh.driver_id=d.id and sh.workspace_id=d.workspace_id join public.sl_workspaces w on w.id=sh.workspace_id where sh.id=s and sh.workspace_id=$1 and d.user_id=auth.uid() and w.status='active') $$;
create or replace function logistics_private.shipment_access(w uuid,s uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.has_role(w,array['admin','operator','dispatcher','finance','warehouse','viewer']) or logistics_private.assigned_driver(w,s) or exists(select 1 from public.sl_shipments sh join public.sl_orders o on o.id=sh.order_id join public.sl_clients c on c.id=o.client_id where sh.id=s and sh.workspace_id=w and c.user_id=auth.uid()) $$;
create function logistics_private.inventory_access(w uuid,i uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.has_role(w,array['admin','operator','warehouse','viewer']) or exists(select 1 from public.sl_inventory_items i join public.sl_storage_bookings b on b.id=i.storage_booking_id join public.sl_clients c on c.id=b.client_id where i.id=$2 and i.workspace_id=w and c.user_id=auth.uid()) $$;
create function logistics_private.booking_access(b uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.platform_admin() or exists(select 1 from public.sl_bookings where id=b and (customer_id=auth.uid() or logistics_private.has_role(workspace_id,array['admin','operator','dispatcher','viewer']))) $$;
create function public.sl_submit_booking(service_type text,origin_city text,destination_city text,pickup_address text,delivery_address text,sender_name text,sender_phone text,recipient_name text,recipient_phone text,weight_kg numeric,description text) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare r uuid;begin
if auth.uid() is null then raise exception 'Sign in required';end if;if weight_kg<=0 or weight_kg>100000 or length(trim(description))=0 then raise exception 'Valid cargo description and weight required';end if;
insert into public.sl_bookings(customer_id,service_type,origin_city,destination_city,pickup_address,delivery_address,sender_name,sender_phone,recipient_name,recipient_phone,weight_kg,description) values(auth.uid(),service_type,origin_city,destination_city,pickup_address,delivery_address,sender_name,sender_phone,recipient_name,recipient_phone,weight_kg,description) returning id into r;return r;end; $$;
create function public.sl_eligible_providers(booking uuid) returns table(id uuid,name text) language plpgsql stable security definer set search_path='' as $$
#variable_conflict use_variable
 declare b record;begin
if not logistics_private.platform_admin() then raise exception 'Platform administrator required';end if;select * into b from public.sl_bookings where sl_bookings.id=booking;
return query select distinct w.id,w.name from public.sl_workspaces w join public.sl_service_areas a on a.workspace_id=w.id where w.status='active' and a.active and lower(a.origin_city)=lower(b.origin_city) and lower(a.destination_city)=lower(b.destination_city) and a.service_type=b.service_type and exists(select 1 from public.sl_provider_verifications v where v.workspace_id=w.id and v.status='approved');end; $$;
create function public.sl_assign_booking(booking uuid,provider uuid) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare b record;begin
if not logistics_private.platform_admin() then raise exception 'Platform administrator required';end if;select * into b from public.sl_bookings where id=booking for update;if b.status not in('requested','assigned','quoted','declined') then raise exception 'Booking cannot be reassigned';end if;
if not exists(select 1 from public.sl_eligible_providers(booking) where id=provider) then raise exception 'Provider does not meet verification and coverage requirements';end if;
update public.sl_bookings set workspace_id=provider,status='assigned',assigned_by=auth.uid(),assigned_at=now(),updated_at=now() where id=booking;
insert into public.sl_booking_assignments(workspace_id,booking_id,actor_id) values(provider,booking,auth.uid());
insert into public.sl_notifications(workspace_id,message,visibility) values(provider,'New booking assigned: '||b.reference,'provider');insert into public.sl_notifications(workspace_id,message,user_id,visibility) values(provider,'A provider has been assigned to '||b.reference,b.customer_id,'customer');end; $$;
create function public.sl_respond_booking(booking uuid,decision text,amount numeric default null,transit_days integer default null,note text default null) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare b record;begin
select * into b from public.sl_bookings where id=booking for update;if not logistics_private.has_role(b.workspace_id,array['admin','operator','dispatcher']) then raise exception 'Provider operations permission required';end if;if b.status not in('assigned','quoted') then raise exception 'Booking is not awaiting provider response';end if;
if decision='declined' then if length(trim(coalesce(note,'')))<3 then raise exception 'A decline reason is required';end if;update public.sl_bookings set status='declined',reason=note,updated_at=now() where id=booking;
elsif decision='quoted' then if amount<0 or amount is null or transit_days<=0 or transit_days is null then raise exception 'Valid amount and transit time required';end if;insert into public.sl_quotations(workspace_id,booking_id,amount,transit_days,note) values(b.workspace_id,booking,amount,transit_days,note) on conflict(booking_id,workspace_id) do update set amount=excluded.amount,transit_days=excluded.transit_days,note=excluded.note,accepted_by_customer=false;update public.sl_bookings set status='quoted',updated_at=now() where id=booking;
else raise exception 'Decision must be quoted or declined';end if;
insert into public.sl_notifications(workspace_id,message,user_id) values(b.workspace_id,b.reference||' is '||decision,b.customer_id);end; $$;
create function public.sl_accept_quote(booking uuid) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare b record;begin
select * into b from public.sl_bookings where id=booking for update;if b.customer_id<>auth.uid() or auth.uid() is null or b.status<>'quoted' then raise exception 'Customer quote acceptance required';end if;update public.sl_quotations set accepted_by_customer=true where booking_id=booking and workspace_id=b.workspace_id;update public.sl_bookings set status='accepted',updated_at=now() where id=booking;insert into public.sl_notifications(workspace_id,message,visibility) values(b.workspace_id,'Quote accepted: '||b.reference,'provider');end; $$;
create function public.sl_create_booking_shipment(booking uuid,shipping_fee numeric,package_type text,pickup_at timestamptz default null) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare b record;c uuid;o uuid;s uuid;begin
select * into b from public.sl_bookings where id=booking for update;if not logistics_private.has_role(b.workspace_id,array['admin','operator','dispatcher']) then raise exception 'Provider operations permission required';end if;
select id into s from public.sl_shipments where booking_id=booking;if s is not null then return s;end if;if b.status<>'accepted' then raise exception 'Customer must accept the quotation first';end if;if shipping_fee is null or shipping_fee<0 then raise exception 'Valid fee required';end if;
select id into c from public.sl_clients where workspace_id=b.workspace_id and user_id=b.customer_id;if c is null then insert into public.sl_clients(workspace_id,user_id,name,email,phone,address) values(b.workspace_id,b.customer_id,b.sender_name,(select email from auth.users where id=b.customer_id),b.sender_phone,b.pickup_address) returning id into c;end if;
insert into public.sl_orders(workspace_id,client_id,reference,description,value) values(b.workspace_id,c,b.reference,b.description,shipping_fee) returning id into o;
insert into public.sl_shipments(workspace_id,order_id,booking_id,origin,destination,weight,mode,recipient_name,recipient_phone) values(b.workspace_id,o,b.id,b.pickup_address,b.delivery_address,b.weight_kg,b.service_type,b.recipient_name,b.recipient_phone) returning id into s;
insert into public.sl_shipment_packages(workspace_id,shipment_id,package_type,weight_kg,description) values(b.workspace_id,s,package_type,b.weight_kg,b.description);
insert into public.sl_invoices(workspace_id,order_id,total) values(b.workspace_id,o,shipping_fee);
insert into public.sl_fee_history(workspace_id,shipment_id,previous_amount,new_amount,reason) values(b.workspace_id,s,0,shipping_fee,'Initial authorized shipping fee');
if pickup_at is not null then insert into public.sl_pickups(workspace_id,shipment_id,address,scheduled_at) values(b.workspace_id,s,b.pickup_address,pickup_at);end if;update public.sl_bookings set status='shipment_created',updated_at=now() where id=b.id;return s;end; $$;
create function public.sl_set_shipping_fee(shipment uuid,amount numeric,reason text) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;o record;begin
select * into s from public.sl_shipments where id=shipment for update;if not logistics_private.has_role(s.workspace_id,array['admin','finance']) then raise exception 'Finance permission required';end if;if amount<0 or amount is null or length(trim(coalesce(reason,'')))<3 then raise exception 'Valid fee and reason required';end if;
select * into o from public.sl_orders where id=s.order_id for update;perform 1 from public.sl_invoices where order_id=o.id for update;
if exists(select 1 from public.sl_payments p join public.sl_invoices i on i.id=p.invoice_id where i.order_id=o.id and p.status='verified') then raise exception 'Finalized financial records cannot be repriced';end if;
update public.sl_orders set value=amount where id=o.id;update public.sl_invoices set total=amount where order_id=o.id and status='unpaid';insert into public.sl_fee_history(workspace_id,shipment_id,previous_amount,new_amount,reason) values(s.workspace_id,s.id,o.value,amount,reason);end; $$;
create or replace function logistics_private.guard_shipment() returns trigger language plpgsql set search_path='' as $$
#variable_conflict use_variable
 begin
if TG_OP='INSERT' and new.status<>'Pending' then raise exception 'Shipments begin Pending';end if;
if TG_OP='UPDATE' then if new.workspace_id<>old.workspace_id or new.order_id<>old.order_id or new.id<>old.id or new.tracking_number<>old.tracking_number or new.qr_token<>old.qr_token then raise exception 'Shipment identity and ownership are immutable';end if;
if (new.status<>old.status or new.driver_id is distinct from old.driver_id) and current_user in('authenticated','anon') then raise exception 'Use the authorized status or assignment API';end if;end if;new.updated_at=now();return new;end; $$;
create function public.sl_transition_shipment(shipment uuid,target text,note text default '') returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;allowed boolean;begin
select * into s from public.sl_shipments where id=shipment for update;if auth.uid() is null or not(logistics_private.has_role(s.workspace_id,array['admin','operator','dispatcher']) or logistics_private.assigned_driver(s.workspace_id,s.id)) then raise exception 'Shipment operations permission required';end if;
allowed:=case s.status when 'Pending' then target in('Processing','Cancelled') when 'Processing' then target in('Picked Up','In Transit','Exception','Cancelled') when 'Picked Up' then target='In Transit' when 'In Transit' then target in('Out for Delivery','Exception','Returned') when 'Out for Delivery' then target in('Delivered','Failed Delivery','Exception') when 'Failed Delivery' then target in('Out for Delivery','Returned') when 'Exception' then target in('Processing','In Transit','Returned') else false end;
if not coalesce(allowed,false) then raise exception 'Invalid status transition: % → %',s.status,target;end if;
if target in('Failed Delivery','Exception','Returned','Cancelled') and length(trim(coalesce(note,'')))<3 then raise exception 'A reason is required';end if;
if target='Picked Up' and not exists(select 1 from public.sl_scan_events where shipment_id=s.id and action='pickup' and actor_id=auth.uid() and created_at>now()-interval '6 hours') then raise exception 'Scan the shipment before collection';end if;
if target='Delivered' and not exists(select 1 from public.sl_delivery_proofs where shipment_id=s.id) then raise exception 'Delivery photo, signature and recipient confirmation are required';end if;
update public.sl_shipments set status=target where id=s.id;
if target='Delivered' then update public.sl_delivery_tasks set status='delivered',updated_at=now() where shipment_id=s.id;update public.sl_drivers set status='available' where id=s.driver_id;update public.sl_vehicles set status='available' where id in(select vehicle_id from public.sl_delivery_tasks where shipment_id=s.id);end if;
if target in('Returned','Cancelled') then update public.sl_delivery_tasks set status=case when target='Returned' then 'returned' else 'cancelled' end,reason=note,updated_at=now() where shipment_id=s.id;update public.sl_pickups set status='cancelled' where shipment_id=s.id and status in('requested','scheduled','accepted');update public.sl_drivers set status='available' where id=s.driver_id;update public.sl_vehicles set status='available' where id in(select vehicle_id from public.sl_delivery_tasks where shipment_id=s.id union select vehicle_id from public.sl_pickups where shipment_id=s.id);end if;
if target='Failed Delivery' then update public.sl_delivery_tasks set status='failed',reason=note,updated_at=now() where shipment_id=s.id;end if;
end; $$;
create function public.sl_assign_task(task_type text,task uuid,driver uuid,vehicle uuid) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare t record;d record;v record;shipment_weight numeric;begin
if task_type='pickup' then select * into t from public.sl_pickups where id=task for update;elsif task_type='delivery' then select * into t from public.sl_delivery_tasks where id=task for update;else raise exception 'Invalid task type';end if;
if not logistics_private.has_role(t.workspace_id,array['admin','operator','dispatcher']) then raise exception 'Dispatcher permission required';end if;
if t.driver_id=driver and t.vehicle_id=vehicle and t.status in('scheduled','assigned','accepted') then return;end if;
if t.driver_id is not null then raise exception 'Cancel the existing assignment before reassigning';end if;
select * into d from public.sl_drivers where id=driver and workspace_id=t.workspace_id for update;select * into v from public.sl_vehicles where id=vehicle and workspace_id=t.workspace_id for update;
if d.id is null or d.user_id is null or d.status<>'available' or v.id is null or v.status<>'available' then raise exception 'An available, linked driver and vehicle are required';end if;
select weight into shipment_weight from public.sl_shipments where id=t.shipment_id;if v.capacity_kg<shipment_weight then raise exception 'Vehicle capacity is insufficient';end if;
if exists(select 1 from public.sl_pickups where (driver_id=driver or vehicle_id=vehicle) and status in('scheduled','accepted')) or exists(select 1 from public.sl_delivery_tasks where (driver_id=driver or vehicle_id=vehicle) and status in('assigned','accepted','out_for_delivery','failed')) then raise exception 'Driver or vehicle has a conflicting active task';end if;
if task_type='pickup' then update public.sl_pickups set driver_id=driver,vehicle_id=vehicle,status='scheduled' where id=task;else update public.sl_delivery_tasks set driver_id=driver,vehicle_id=vehicle,status='assigned',updated_at=now() where id=task;end if;
update public.sl_shipments set driver_id=driver where id=t.shipment_id;update public.sl_drivers set status='assigned' where id=driver;update public.sl_vehicles set status='assigned' where id=vehicle;
insert into public.sl_notifications(workspace_id,shipment_id,message,user_id,visibility) values(t.workspace_id,t.shipment_id,'New '||task_type||' task assigned',d.user_id,'driver');end; $$;
create function public.sl_scan_shipment(shipment uuid,token uuid,scan_action text) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;r uuid;begin
select * into s from public.sl_shipments where id=shipment;if auth.uid() is null or s.qr_token is distinct from token or not logistics_private.shipment_access(s.workspace_id,s.id) then raise exception 'Invalid or unauthorized QR code';end if;
if scan_action<>'inspect' and not(logistics_private.has_role(s.workspace_id,array['admin','operator','dispatcher','warehouse']) or logistics_private.assigned_driver(s.workspace_id,s.id)) then raise exception 'Operational scan permission required';end if;
insert into public.sl_scan_events(workspace_id,shipment_id,action) values(s.workspace_id,s.id,scan_action) returning id into r;return r;end; $$;
create function public.sl_task_action(task_type text,task uuid,decision text,reason text default '') returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare t record;d record;s record;begin
if task_type not in('pickup','delivery') then raise exception 'Invalid task type';end if;if task_type='pickup' then select * into t from public.sl_pickups where id=task for update;else select * into t from public.sl_delivery_tasks where id=task for update;end if;if not found then raise exception 'Task not found';end if;select * into d from public.sl_drivers where id=t.driver_id;
if auth.uid() is null or not(coalesce(d.user_id=auth.uid(),false) or logistics_private.has_role(t.workspace_id,array['admin','operator','dispatcher'])) then raise exception 'Assigned driver permission required';end if;
select * into s from public.sl_shipments where id=t.shipment_id;
if decision='accepted' then if t.status not in('scheduled','assigned') then raise exception 'Task cannot be accepted';end if;if task_type='pickup' then update public.sl_pickups set status='accepted' where id=t.id;else update public.sl_delivery_tasks set status='accepted' where id=t.id;end if;
elsif decision='declined' then if t.status not in('scheduled','assigned') or length(trim(reason))<3 then raise exception 'A reason and pending task are required';end if;if task_type='pickup' then update public.sl_pickups set status='requested',driver_id=null,vehicle_id=null where id=t.id;else update public.sl_delivery_tasks set status='requested',driver_id=null,vehicle_id=null,reason=reason where id=t.id;end if;update public.sl_shipments set driver_id=null where id=t.shipment_id;update public.sl_drivers set status='available' where id=d.id;update public.sl_vehicles set status='available' where id=t.vehicle_id;
elsif decision='collected' and task_type='pickup' then if t.status<>'accepted' then raise exception 'Accept the task before collection';end if;if s.status='Pending' then perform public.sl_transition_shipment(s.id,'Processing','');end if;perform public.sl_transition_shipment(s.id,'Picked Up','');update public.sl_pickups set status='collected' where id=t.id;insert into public.sl_delivery_tasks(workspace_id,shipment_id,driver_id,vehicle_id,status) values(t.workspace_id,t.shipment_id,t.driver_id,t.vehicle_id,'accepted') on conflict(shipment_id) do nothing;
elsif decision='out_for_delivery' and task_type='delivery' then if s.status='Picked Up' then perform public.sl_transition_shipment(s.id,'In Transit','');end if;perform public.sl_transition_shipment(s.id,'Out for Delivery','');update public.sl_delivery_tasks set status='out_for_delivery' where id=t.id;
elsif decision='failed' and task_type='delivery' then perform public.sl_transition_shipment(s.id,'Failed Delivery',reason);
else raise exception 'Invalid task action';end if;
end; $$;
create function public.sl_record_delivery_proof(shipment uuid,recipient text,photo text,signature text) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;r uuid;prefix text;begin
select * into s from public.sl_shipments where id=shipment;if auth.uid() is null or not(logistics_private.has_role(s.workspace_id,array['admin','operator','dispatcher']) or logistics_private.assigned_driver(s.workspace_id,s.id)) then raise exception 'Delivery permission required';end if;
if s.status<>'Out for Delivery' or length(trim(recipient))<2 then raise exception 'Confirm the recipient during an active delivery';end if;prefix:=s.workspace_id||'/proof/'||s.id||'/';if left(photo,length(prefix))<>prefix or left(signature,length(prefix))<>prefix or not exists(select 1 from storage.objects where bucket_id='sl-documents' and name=photo) or not exists(select 1 from storage.objects where bucket_id='sl-documents' and name=signature) then raise exception 'Upload both proof files to the protected shipment path first';end if;
insert into public.sl_delivery_proofs(workspace_id,shipment_id,recipient_name,photo_path,signature_path,received_by) values(s.workspace_id,s.id,recipient,photo,signature,auth.uid()) returning id into r;return r;end; $$;
create function public.sl_review_provider(verification uuid,decision text,reason text default '') returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare v record;begin
if not logistics_private.platform_admin() then raise exception 'Platform administrator required';end if;if decision not in('approved','rejected') or (decision='rejected' and length(trim(reason))<3) then raise exception 'Valid review decision and rejection reason required';end if;select * into v from public.sl_provider_verifications where id=verification for update;if not found then raise exception 'Verification not found';end if;if decision='approved' and (left(v.document_path,length(v.workspace_id::text)+14)<>v.workspace_id::text||'/verification/' or not exists(select 1 from storage.objects where bucket_id='sl-documents' and name=v.document_path)) then raise exception 'Review requires an uploaded verification document';end if;update public.sl_provider_verifications set status=decision,reason=reason,reviewed_by=auth.uid(),reviewed_at=now(),updated_at=now() where id=verification;if decision='approved' then update public.sl_workspaces set status='active' where id=v.workspace_id;end if;end; $$;
create function public.sl_receive_inventory(booking uuid,location uuid,sku text,item_name text,units numeric,weight_per_unit numeric) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare b record;l record;r uuid;used numeric;begin
select * into b from public.sl_storage_bookings where id=booking for update;if not logistics_private.has_role(b.workspace_id,array['admin','operator','warehouse']) or b.status<>'approved' then raise exception 'Approved storage booking and warehouse permission required';end if;
select * into l from public.sl_storage_locations where id=location and workspace_id=b.workspace_id and warehouse_id=b.warehouse_id for update;if l.id is null or units<=0 or weight_per_unit<=0 then raise exception 'Valid bin, quantity and unit weight required';end if;
select coalesce(sum(quantity*i.weight_per_unit),0) into used from public.sl_inventory_items i where location_id=l.id;if used+units*weight_per_unit>l.capacity_kg then raise exception 'Bin capacity exceeded';end if;
insert into public.sl_inventory_items(workspace_id,storage_booking_id,location_id,sku,name,quantity,weight_per_unit) values(b.workspace_id,b.id,l.id,sku,item_name,units,weight_per_unit) returning id into r;insert into public.sl_inventory_movements(workspace_id,item_id,quantity,type,reason) values(b.workspace_id,r,units,'receive','Goods received against approved storage booking');return r;end; $$;
create function public.sl_request_dispatch(item uuid,units numeric,shipment uuid) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare i record;s record;r uuid;begin
select * into i from public.sl_inventory_items where id=item for update;if auth.uid() is null or not logistics_private.inventory_access(i.workspace_id,i.id) then raise exception 'Inventory access denied';end if;
if not logistics_private.has_role(i.workspace_id,array['admin','operator','warehouse']) and not exists(select 1 from public.sl_storage_bookings b join public.sl_clients c on c.id=b.client_id where b.id=i.storage_booking_id and c.user_id=auth.uid()) then raise exception 'Inventory owner permission required';end if;
select * into s from public.sl_shipments where id=shipment and workspace_id=i.workspace_id;if not logistics_private.shipment_access(s.workspace_id,s.id) or s.id is null or s.status not in('Pending','Processing') then raise exception 'Select an authorized pending shipment within this company';end if;
if units<=0 or units>i.quantity-i.reserved then raise exception 'Insufficient available inventory';end if;
insert into public.sl_dispatch_jobs(workspace_id,item_id,shipment_id,quantity) values(i.workspace_id,i.id,s.id,units) returning id into r;return r;end; $$;
create function public.sl_dispatch_action(job uuid,decision text) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare j record;i record;begin
select * into j from public.sl_dispatch_jobs where id=job for update;select * into i from public.sl_inventory_items where id=j.item_id for update;if not logistics_private.has_role(j.workspace_id,array['admin','operator','warehouse']) then raise exception 'Warehouse permission required';end if;
if decision='picked' and j.status='requested' then if j.quantity>i.quantity-i.reserved then raise exception 'Insufficient inventory';end if;update public.sl_inventory_items set reserved=reserved+j.quantity,updated_at=now() where id=i.id;
elsif decision='packed' and j.status='picked' then null;
elsif decision='released' and j.status='packed' then
if not exists(select 1 from public.sl_scan_events where shipment_id=j.shipment_id and action='dispatch' and actor_id=auth.uid() and created_at>now()-interval '6 hours') then raise exception 'Scan the shipment before releasing goods';end if;
if not exists(select 1 from public.sl_delivery_tasks where shipment_id=j.shipment_id and driver_id is not null and vehicle_id is not null and status in('assigned','accepted')) then raise exception 'Assign a driver and vehicle before release';end if;
update public.sl_inventory_items set quantity=quantity-j.quantity,reserved=reserved-j.quantity,updated_at=now() where id=i.id;insert into public.sl_inventory_movements(workspace_id,item_id,quantity,type,reason) values(j.workspace_id,i.id,-j.quantity,'release','Dispatch job '||j.id);
elsif decision='cancelled' and j.status in('requested','picked','packed') then if j.status in('picked','packed') then update public.sl_inventory_items set reserved=reserved-j.quantity where id=i.id;end if;
else raise exception 'Invalid dispatch stage';end if;
update public.sl_dispatch_jobs set status=decision,updated_at=now() where id=j.id;
end; $$;
create function public.sl_create_delivery_task(shipment uuid) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;r uuid;begin
select * into s from public.sl_shipments where id=shipment;if not logistics_private.has_role(s.workspace_id,array['admin','operator','dispatcher']) then raise exception 'Dispatcher permission required';end if;
insert into public.sl_delivery_tasks(workspace_id,shipment_id) values(s.workspace_id,s.id) on conflict(shipment_id) do update set shipment_id=excluded.shipment_id returning id into r;return r;end; $$;
create function logistics_private.post_payment_ledger() returns trigger language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare rate numeric:=0;fee numeric;begin
if new.status='verified' and old.status is distinct from 'verified' then select coalesce(value::numeric,0) into rate from public.sl_settings where name='commission_percent' and value ~ '^[0-9]+(\.[0-9]+)?$';rate:=coalesce(rate,0);if rate<0 or rate>100 then raise exception 'Commission rate configuration invalid';end if;fee:=round(new.amount*rate/100,2);
insert into public.sl_ledger_entries(workspace_id,source_type,source_id,account,amount) values(new.workspace_id,'payment',new.id,'gross_revenue',new.amount),(new.workspace_id,'payment',new.id,'platform_commission',fee),(new.workspace_id,'payment',new.id,'provider_payable',new.amount-fee) on conflict(source_type,source_id,account) do nothing;end if;return new;end; $$;
create trigger sl_payment_ledger after update on public.sl_payments for each row execute function logistics_private.post_payment_ledger();
insert into public.sl_ledger_entries(workspace_id,source_type,source_id,account,amount,created_at) select p.workspace_id,'payment',p.id,v.account,v.amount,p.created_at from public.sl_payments p left join public.sl_commissions c on c.payment_id=p.id cross join lateral (values('gross_revenue',p.amount),('platform_commission',coalesce(c.amount,0)),('provider_payable',p.amount-coalesce(c.amount,0))) v(account,amount) where p.status='verified' on conflict(source_type,source_id,account) do nothing;
create function public.sl_prepare_settlement(provider uuid) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare r uuid;total numeric;begin
if not logistics_private.platform_admin() then raise exception 'Platform finance permission required';end if;perform 1 from public.sl_workspaces where id=provider for update;
select sum(l.amount) into total from public.sl_ledger_entries l where l.workspace_id=provider and l.source_type='payment' and l.account='provider_payable' and not exists(select 1 from public.sl_settlement_lines sl where sl.payment_id=l.source_id);
if coalesce(total,0)<=0 then raise exception 'No unsettled verified earnings';end if;insert into public.sl_settlements(workspace_id,amount) values(provider,total) returning id into r;
insert into public.sl_settlement_lines(workspace_id,settlement_id,payment_id,amount) select provider,r,l.source_id,l.amount from public.sl_ledger_entries l where l.workspace_id=provider and l.source_type='payment' and l.account='provider_payable' and not exists(select 1 from public.sl_settlement_lines sl where sl.payment_id=l.source_id);return r;end; $$;
create function public.sl_review_settlement(settlement uuid,decision text,reason text default '') returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;begin
if not logistics_private.platform_admin() then raise exception 'Platform finance permission required';end if;select * into s from public.sl_settlements where id=settlement for update;if s.status<>'pending' or decision not in('approved','rejected') then raise exception 'Invalid settlement review';end if;if decision='rejected' and length(trim(reason))<3 then raise exception 'Reason required';end if;update public.sl_settlements set status=decision,reviewed_by=auth.uid(),reason=reason where id=s.id;end; $$;
create function public.sl_request_payout(settlement uuid,amount numeric,method text,destination text,request_key uuid) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare s record;reserved numeric;r uuid;begin
select id into r from public.sl_payout_requests where idempotency_key=request_key and logistics_private.has_role(workspace_id,array['admin','finance']);if r is not null then return r;end if;
select * into s from public.sl_settlements where id=settlement for update;if not logistics_private.has_role(s.workspace_id,array['admin','finance']) or s.status<>'approved' then raise exception 'Approved settlement and finance permission required';end if;
select coalesce(sum(p.amount),0) into reserved from public.sl_payout_requests p where settlement_id=s.id and status<>'rejected';if amount<=0 or amount>s.amount-reserved or length(trim(destination))<3 then raise exception 'Payout exceeds available approved settlement or invalid destination';end if;
insert into public.sl_payout_requests(workspace_id,settlement_id,amount,method,destination,idempotency_key) values(s.workspace_id,s.id,amount,method,destination,request_key) returning id into r;return r;end; $$;
create function public.sl_review_payout(payout uuid,decision text,reference text default '',reason text default '') returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare p record;begin
if not logistics_private.platform_admin() then raise exception 'Platform finance permission required';end if;select * into p from public.sl_payout_requests where id=payout for update;if not found then raise exception 'Payout not found';end if;
if decision='approved' and p.status='requested' then null;elsif decision='rejected' and p.status in('requested','approved') and length(trim(reason))>=3 then null;elsif decision='paid' and p.status='approved' and length(trim(reference))>=3 then
insert into public.sl_ledger_entries(workspace_id,source_type,source_id,account,amount) values(p.workspace_id,'payout',p.id,'provider_payable',-p.amount);
else raise exception 'Invalid payout transition; recording a paid payout requires a completed transfer reference';end if;
update public.sl_payout_requests set status=decision,transfer_reference=nullif(reference,''),reason=reason,reviewed_by=auth.uid() where id=p.id;end; $$;
create function public.sl_financial_summary(provider uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$ select jsonb_build_object(
'gross_revenue',(select coalesce(sum(amount),0) from public.sl_ledger_entries where account='gross_revenue' and (provider is null or workspace_id=provider)),
'commission',(select coalesce(sum(amount),0) from public.sl_ledger_entries where account='platform_commission' and (provider is null or workspace_id=provider)),
'net_earnings',(select coalesce(sum(amount),0) from public.sl_ledger_entries where account='provider_payable' and source_type='payment' and (provider is null or workspace_id=provider)),
'pending_payouts',(select coalesce(sum(amount),0) from public.sl_payout_requests where status in('requested','approved') and (provider is null or workspace_id=provider)),
'paid_payouts',(select coalesce(sum(amount),0) from public.sl_payout_requests where status='paid' and (provider is null or workspace_id=provider)),
'available_balance',(select coalesce(sum(amount),0) from public.sl_settlements where status='approved' and (provider is null or workspace_id=provider))-(select coalesce(sum(amount),0) from public.sl_payout_requests where status<>'rejected' and (provider is null or workspace_id=provider))
); $$;
-- Own-row and organization policies for every new table.
DO $$ declare t text;begin foreach t in array array['sl_provider_verifications','sl_service_areas','sl_vehicles','sl_routes','sl_route_stops','sl_bookings','sl_quotations','sl_booking_assignments','sl_shipment_packages','sl_delivery_tasks','sl_scan_events','sl_delivery_proofs','sl_location_updates','sl_fee_history','sl_storage_locations','sl_storage_pricing','sl_storage_bookings','sl_inventory_items','sl_inventory_movements','sl_dispatch_jobs','sl_ledger_entries','sl_settlements','sl_settlement_lines','sl_payout_requests'] loop
execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);execute format('create policy organization_read on public.%I for select to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''dispatcher'',''finance'',''warehouse'',''viewer'']))',t);
execute format('create index on public.%I(workspace_id)',t);
execute format('create trigger sl_operations_audit after insert or update or delete on public.%I for each row execute function logistics_private.audit_change()',t);
end loop;end; $$;
-- Bookings may be unassigned: their audit uses a separate guarded trail to avoid null tenant keys.
drop trigger sl_operations_audit on public.sl_bookings;
create trigger sl_booking_audit after insert or update on public.sl_bookings for each row execute function logistics_private.platform_audit_change();
create policy own_bookings on public.sl_bookings for select to authenticated using(customer_id=auth.uid() or logistics_private.platform_admin());
create policy own_quotes on public.sl_quotations for select to authenticated using(logistics_private.booking_access(booking_id));
DO $$ declare t text;begin foreach t in array array['sl_shipment_packages','sl_delivery_tasks','sl_scan_events','sl_delivery_proofs','sl_location_updates','sl_fee_history'] loop execute format('create policy shipment_read on public.%I for select to authenticated using(logistics_private.shipment_access(workspace_id,shipment_id))',t);end loop;end; $$;
create policy own_inventory on public.sl_inventory_items for select to authenticated using(logistics_private.inventory_access(workspace_id,id));
create policy own_movements on public.sl_inventory_movements for select to authenticated using(logistics_private.inventory_access(workspace_id,item_id));
create policy own_dispatch on public.sl_dispatch_jobs for select to authenticated using(logistics_private.inventory_access(workspace_id,item_id));
create policy own_storage_bookings on public.sl_storage_bookings for select to authenticated using(exists(select 1 from public.sl_clients c where c.id=client_id and c.user_id=auth.uid()));
create policy driver_own_record on public.sl_drivers for select to authenticated using(user_id=auth.uid());
create policy driver_pickups on public.sl_pickups for select to authenticated using(exists(select 1 from public.sl_drivers d where d.id=driver_id and d.user_id=auth.uid()));
-- Account roles may read reference records needed for assigned work, without other company data.
create policy active_vehicle_reference on public.sl_vehicles for select to authenticated using(exists(select 1 from public.sl_memberships m where m.workspace_id=sl_vehicles.workspace_id and m.user_id=auth.uid() and m.role='driver'));
create policy warehouse_reference on public.sl_facilities for select to authenticated using(logistics_private.has_role(workspace_id,array['admin','operator','warehouse','viewer']));
create policy own_invoice_driver_denied on public.sl_orders for select to authenticated using(logistics_private.has_role(workspace_id,array['dispatcher','finance','warehouse']));
create policy driver_assigned_clients on public.sl_clients for select to authenticated using(exists(select 1 from public.sl_orders o join public.sl_shipments sh on sh.order_id=o.id join public.sl_drivers d on d.id=sh.driver_id where o.client_id=sl_clients.id and d.user_id=auth.uid()));
DO $$ declare t text;begin foreach t in array array['sl_service_areas','sl_vehicles','sl_routes','sl_route_stops','sl_storage_locations','sl_storage_pricing','sl_storage_bookings'] loop
execute format('grant insert,update on public.%I to authenticated',t);
execute format('create policy manage_create on public.%I for insert to authenticated with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''warehouse'',''dispatcher'']))',t);
execute format('create policy manage_edit on public.%I for update to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''warehouse'',''dispatcher''])) with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''warehouse'',''dispatcher'']))',t);
end loop;end; $$;
grant insert on public.sl_provider_verifications to authenticated;
create policy verification_submit on public.sl_provider_verifications for insert to authenticated with check(status='pending' and reviewed_by is null and reviewed_at is null and exists(select 1 from public.sl_memberships m where m.workspace_id=sl_provider_verifications.workspace_id and m.user_id=auth.uid() and m.role='admin'));
create policy pending_verification_read on public.sl_provider_verifications for select to authenticated using(exists(select 1 from public.sl_memberships m where m.workspace_id=sl_provider_verifications.workspace_id and m.user_id=auth.uid() and m.role='admin'));
revoke insert,update,delete on public.sl_delivery_proofs,public.sl_delivery_tasks,public.sl_inventory_items,public.sl_inventory_movements,public.sl_dispatch_jobs,public.sl_ledger_entries,public.sl_settlements,public.sl_settlement_lines,public.sl_payout_requests,public.sl_scan_events from authenticated;
revoke insert,update on public.sl_pickups from authenticated;
grant update(address,scheduled_at) on public.sl_pickups to authenticated;
-- Status API enforces the new POD/assignment workflow; legacy direct bookings are retired.
revoke execute on function public.sl_book_shipment(uuid,numeric,text,text,text,text,text,text,text) from authenticated;
-- Location updates are accepted only for the assigned driver or authorized operations staff.
grant insert on public.sl_location_updates to authenticated;
create policy location_submit on public.sl_location_updates for insert to authenticated with check(actor_id=auth.uid() and (logistics_private.assigned_driver(workspace_id,shipment_id) or logistics_private.has_role(workspace_id,array['admin','operator','dispatcher'])));
create function logistics_private.sync_location() returns trigger language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 begin update public.sl_shipments set latitude=new.latitude,longitude=new.longitude,gps_at=new.created_at where id=new.shipment_id and workspace_id=new.workspace_id;return new;end; $$;
create trigger sl_sync_location after insert on public.sl_location_updates for each row execute function logistics_private.sync_location();
-- No financial history or quote can be changed through general browser UPDATE grants.
create function logistics_private.guard_final_order() returns trigger language plpgsql set search_path='' as $$
#variable_conflict use_variable
 begin if new.value is distinct from old.value and exists(select 1 from public.sl_invoices i join public.sl_payments p on p.invoice_id=i.id where i.order_id=old.id and p.status='verified') then raise exception 'Verified financial history is immutable';end if;return new;end; $$;
create trigger sl_final_order before update on public.sl_orders for each row execute function logistics_private.guard_final_order();
-- Private Storage bucket. No public URLs and no evidence overwrite/delete permissions.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('sl-documents','sl-documents',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do nothing;
create function logistics_private.storage_access(path text,write_access boolean) returns boolean language plpgsql stable security definer set search_path='' as $$
#variable_conflict use_variable
 declare w uuid;entity uuid;category text;begin
if auth.uid() is null then return false;end if;begin w:=split_part(path,'/',1)::uuid;category:=split_part(path,'/',2);entity:=split_part(path,'/',3)::uuid;exception when others then return false;end;
if category='proof' then if write_access then return logistics_private.has_role(w,array['admin','operator','dispatcher']) or logistics_private.assigned_driver(w,entity);else return logistics_private.shipment_access(w,entity);end if;
elsif category='verification' then return logistics_private.platform_admin() or exists(select 1 from public.sl_memberships m where m.workspace_id=w and m.user_id=auth.uid() and m.role='admin');
elsif category='receipt' then return logistics_private.invoice_access(w,entity);
else return false;end if;end; $$;
create policy sl_document_read on storage.objects for select to authenticated using(bucket_id='sl-documents' and logistics_private.storage_access(name,false));
create policy sl_document_upload on storage.objects for insert to authenticated with check(bucket_id='sl-documents' and logistics_private.storage_access(name,true));
-- Every RPC is explicitly authenticated; no global PUBLIC execution.
DO $$ declare f record;begin for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('sl_submit_booking','sl_eligible_providers','sl_assign_booking','sl_respond_booking','sl_accept_quote','sl_create_booking_shipment','sl_set_shipping_fee','sl_transition_shipment','sl_assign_task','sl_scan_shipment','sl_task_action','sl_record_delivery_proof','sl_review_provider','sl_receive_inventory','sl_request_dispatch','sl_dispatch_action','sl_create_delivery_task','sl_prepare_settlement','sl_review_settlement','sl_request_payout','sl_review_payout','sl_financial_summary') loop execute format('revoke all on function %s from public',f.signature);execute format('grant execute on function %s to authenticated',f.signature);end loop;end; $$;
revoke all on all functions in schema logistics_private from public;
grant execute on function logistics_private.assigned_driver(uuid,uuid),logistics_private.inventory_access(uuid,uuid),logistics_private.booking_access(uuid),logistics_private.storage_access(text,boolean) to authenticated;
-- Enable Realtime only if the project has its normal publication. No records are modified.
DO $$ declare t text;begin if exists(select 1 from pg_publication where pubname='supabase_realtime') then foreach t in array array['sl_shipments','sl_notifications','sl_bookings','sl_pickups','sl_delivery_tasks','sl_inventory_items','sl_dispatch_jobs','sl_payments'] loop if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then execute format('alter publication supabase_realtime add table public.%I',t);end if;end loop;end if;end; $$;

create or replace function public.sl_verify_payment(payment uuid,decision text) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare p record;inv record;paid numeric;rate numeric;begin
select * into p from public.sl_payments where id=payment for update;if not found then raise exception 'Payment not found';end if;
if auth.uid() is null or not logistics_private.has_role(p.workspace_id,array['admin','operator','finance']) then raise exception 'Finance permission required';end if;
if decision not in('verified','rejected') or p.status<>'submitted' then raise exception 'Payment already reviewed or invalid decision';end if;
select * into inv from public.sl_invoices where id=p.invoice_id for update;
select coalesce(sum(amount),0) into paid from public.sl_payments where invoice_id=p.invoice_id and status='verified';
if decision='verified' and paid+p.amount>inv.total then raise exception 'Payment exceeds outstanding balance';end if;
update public.sl_payments set status=decision,verified_by=auth.uid() where id=payment;
if decision='verified' then paid:=paid+p.amount;update public.sl_invoices set status=case when paid>=total then 'paid' when paid>0 then 'part_paid' else 'unpaid' end where id=p.invoice_id;
select value::numeric into rate from public.sl_settings where name='commission_percent' and value ~ '^[0-9]+(\.[0-9]+)?$';
if rate between 0 and 100 then insert into public.sl_commissions(workspace_id,payment_id,rate,amount) values(p.workspace_id,p.id,rate,round(p.amount*rate/100,2));end if;end if;end; $$;

alter table public.sl_payments add column rejection_reason text;
alter table public.sl_payments add column verified_at timestamptz;
create table public.sl_payment_reviews(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,payment_id uuid not null references public.sl_payments,decision text not null check(decision in('verified','rejected')),reason text,actor_id uuid not null default auth.uid(),created_at timestamptz not null default now());
alter table public.sl_payment_reviews enable row level security;grant select on public.sl_payment_reviews to authenticated;
create policy finance_review_read on public.sl_payment_reviews for select to authenticated using(logistics_private.has_role(workspace_id,array['admin','finance','operator']));
create function public.sl_review_payment(payment uuid,decision text,reason text default '') returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare p record;begin
select * into p from public.sl_payments where id=payment for update;if not logistics_private.has_role(p.workspace_id,array['admin','operator','finance']) then raise exception 'Finance permission required';end if;
if decision='rejected' and length(trim(reason))<3 then raise exception 'Rejection reason required';end if;perform public.sl_verify_payment(payment,decision);update public.sl_payments set rejection_reason=nullif(reason,''),verified_at=now() where id=payment;insert into public.sl_payment_reviews(workspace_id,payment_id,decision,reason) values(p.workspace_id,p.id,decision,reason);end; $$;
revoke all on function public.sl_review_payment(uuid,text,text) from public;grant execute on function public.sl_review_payment(uuid,text,text) to authenticated;
revoke execute on function public.sl_verify_payment(uuid,text) from authenticated;
DO $$ declare t text;begin foreach t in array array['sl_clients','sl_orders','sl_invoices','sl_payments','sl_commissions','sl_billing_payments','sl_subscriptions'] loop execute format('create policy financial_staff_read on public.%I for select to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''finance'']))',t);end loop;end; $$;
-- Registration metadata never authorizes operational roles.
create or replace function public.sl_add_member(w uuid,member_email text,member_role text) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
 declare u uuid;begin
if auth.uid() is null or not logistics_private.has_role(w,array['admin']) then raise exception 'Company admin permission required';end if;
if member_role not in('admin','operator','viewer','dispatcher','finance','driver','warehouse') then raise exception 'Invalid role';end if;
select id into u from auth.users where lower(email)=lower(trim(member_email)) and email_confirmed_at is not null;if u is null then raise exception 'Confirmed registered user required';end if;if u=auth.uid() then raise exception 'Cannot change your own role';end if;
insert into public.sl_memberships(workspace_id,user_id,role) values(w,u,member_role) on conflict(workspace_id,user_id) do update set role=excluded.role;end; $$;

alter table public.sl_facilities add unique(workspace_id,id);
alter table public.sl_routes add unique(workspace_id,id);
alter table public.sl_storage_pricing add unique(workspace_id,id);
alter table public.sl_storage_bookings add unique(workspace_id,id);
alter table public.sl_settlements add unique(workspace_id,id);
alter table public.sl_payments add unique(workspace_id,id);
alter table public.sl_route_stops add foreign key(workspace_id,route_id) references public.sl_routes(workspace_id,id);
alter table public.sl_storage_locations add foreign key(workspace_id,warehouse_id) references public.sl_facilities(workspace_id,id);
alter table public.sl_storage_bookings add foreign key(workspace_id,warehouse_id) references public.sl_facilities(workspace_id,id);
alter table public.sl_storage_bookings add foreign key(workspace_id,pricing_id) references public.sl_storage_pricing(workspace_id,id);
alter table public.sl_inventory_items add foreign key(workspace_id,storage_booking_id) references public.sl_storage_bookings(workspace_id,id);
alter table public.sl_settlement_lines add foreign key(workspace_id,settlement_id) references public.sl_settlements(workspace_id,id);
alter table public.sl_settlement_lines add foreign key(workspace_id,payment_id) references public.sl_payments(workspace_id,id);
alter table public.sl_payout_requests add foreign key(workspace_id,settlement_id) references public.sl_settlements(workspace_id,id);
create policy customer_company_history on public.sl_workspaces for select to authenticated using(exists(select 1 from public.sl_clients c where c.workspace_id=sl_workspaces.id and c.user_id=auth.uid()));
create function public.sl_operations_dashboard(w uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$ select jsonb_build_object(
'shipments',(select count(*) from public.sl_shipments where w is null or workspace_id=w),
'active_jobs',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status not in('Delivered','Cancelled','Returned')),
'pending_pickups',(select count(*) from public.sl_pickups where (w is null or workspace_id=w) and status in('requested','scheduled','accepted')),
'in_transit',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status in('In Transit','Out for Delivery')),
'delivered',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status='Delivered'),
'exceptions',(select count(*) from public.sl_shipments where (w is null or workspace_id=w) and status in('Exception','Failed Delivery')),
'available_drivers',(select count(*) from public.sl_drivers where (w is null or workspace_id=w) and status='available'),
'active_vehicles',(select count(*) from public.sl_vehicles where (w is null or workspace_id=w) and status in('available','assigned')),
'pending_bookings',(select count(*) from public.sl_bookings where (w is null or workspace_id=w) and status in('requested','assigned','quoted')),
'providers',(select count(*) from public.sl_workspaces),
'pending_providers',(select count(*) from public.sl_workspaces where status='pending'),
'customers',(select count(*) from public.sl_clients where w is null or workspace_id=w),
'inventory_units',(select coalesce(sum(quantity),0) from public.sl_inventory_items where w is null or workspace_id=w),
'pending_picking',(select count(*) from public.sl_dispatch_jobs where (w is null or workspace_id=w) and status<>'released' and status<>'cancelled'),
'finance',public.sl_financial_summary(w),
'statuses',(select coalesce(jsonb_agg(r),'[]') from(select status,count(*) as total from public.sl_shipments where w is null or workspace_id=w group by status)r),
'volume',(select coalesce(jsonb_agg(r),'[]') from(select to_char(created_at at time zone 'Africa/Dar_es_Salaam','YYYY-MM-DD') as day,count(*) as total,count(*) filter(where status='Delivered') as delivered from public.sl_shipments where (w is null or workspace_id=w) and created_at>now()-interval '7 days' group by 1 order by 1)r)
); $$;
revoke all on function public.sl_operations_dashboard(uuid) from public;grant execute on function public.sl_operations_dashboard(uuid) to authenticated;

-- Domain-level privilege boundaries supplement tenant isolation.
DO $$ declare t text;begin foreach t in array array['sl_ledger_entries','sl_settlements','sl_settlement_lines','sl_payout_requests'] loop
execute format('alter policy organization_read on public.%I using(logistics_private.has_role(workspace_id,array[''admin'',''finance'']))',t);
end loop;
foreach t in array array['sl_service_areas','sl_storage_pricing'] loop
execute format('alter policy manage_create on public.%I with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'']))',t);
execute format('alter policy manage_edit on public.%I using(logistics_private.has_role(workspace_id,array[''admin'',''operator''])) with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'']))',t);
end loop;end; $$;
alter policy verification_submit on public.sl_provider_verifications with check(status='pending' and reviewed_by is null and reviewed_at is null and left(document_path,length(workspace_id::text)+14)=workspace_id::text||'/verification/' and exists(select 1 from public.sl_memberships m where m.workspace_id=sl_provider_verifications.workspace_id and m.user_id=auth.uid() and m.role='admin'));
create function logistics_private.guard_vehicle_assignment() returns trigger language plpgsql set search_path='' as $$
#variable_conflict use_variable
begin if current_user in('authenticated','anon') and (old.status='assigned' or new.status='assigned') then raise exception 'Assigned vehicle changes require the audited task workflow';end if;return new;end; $$;
create trigger sl_vehicle_assignment_guard before update on public.sl_vehicles for each row execute function logistics_private.guard_vehicle_assignment();


create function public.sl_update_business_profile(w uuid,name text,city text,country text,email text,phone text,address text) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
begin
if auth.uid() is null or not(logistics_private.platform_admin() or exists(select 1 from public.sl_memberships m where m.workspace_id=w and m.user_id=auth.uid() and m.role='admin')) then raise exception 'Company owner required';end if;
if length(trim(name))<2 or length(trim(country))<2 then raise exception 'Company name and country required';end if;
update public.sl_workspaces set name=trim(name),city=trim(city),country=trim(country),email=trim(email),phone=trim(phone),address=trim(address) where id=w;
if not found then raise exception 'Company not found';end if;
end; $$;
revoke all on function public.sl_update_business_profile(uuid,text,text,text,text,text,text) from public;
grant execute on function public.sl_update_business_profile(uuid,text,text,text,text,text,text) to authenticated;


-- PostgreSQL numeric accepts special values; API callers must not inject non-finite financial or stock values.
DO $$ declare c record;begin for c in select table_name,column_name from information_schema.columns where table_schema='public' and table_name like 'sl_%' and data_type='numeric' loop
execute format('alter table public.%I add check(%I not in(''NaN''::numeric,''Infinity''::numeric,''-Infinity''::numeric))',c.table_name,c.column_name);
end loop;end; $$;

commit;


-- Hosted Supabase can grant EXECUTE directly to anon via default privileges.
-- Revoking PUBLIC alone does not remove those direct grants.
-- Preserve each existing authenticated grant, including disabled legacy RPCs.
begin;
do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as signature
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where (n.nspname='public' and left(p.proname,3)='sl_')
       or n.nspname='logistics_private'
  loop
    execute format('revoke execute on function %s from public, anon', f.signature);
  end loop;
end;
$$;
notify pgrst, 'reload schema';
commit;


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


begin;
create function public.sl_cancel_booking(booking uuid,reason text) returns void
language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare b public.sl_bookings;
begin
  if not logistics_private.password_ready() then raise exception 'Sign in and complete password setup first';end if;
  select * into b from public.sl_bookings where id=booking for update;
  if not found then raise exception 'Booking not found';end if;
  if not (logistics_private.platform_admin() or b.customer_id=auth.uid()) then raise exception 'Only the customer or platform administrator may cancel this booking';end if;
  if b.status not in('requested','assigned','quoted','accepted','declined') or exists(select 1 from public.sl_shipments where booking_id=b.id) then raise exception 'This booking cannot be cancelled after shipment creation or cancellation';end if;
  if length(trim(coalesce(reason,'')))<3 then raise exception 'A cancellation reason is required';end if;
  update public.sl_bookings set status='cancelled',reason=trim(reason),updated_at=now() where id=booking;
  if b.workspace_id is not null then
    insert into public.sl_notifications(workspace_id,message,visibility) values(b.workspace_id,'Booking cancelled: '||b.reference,'provider');
    insert into public.sl_notifications(workspace_id,message,user_id,visibility) values(b.workspace_id,'Booking cancelled: '||b.reference,b.customer_id,'customer');
  end if;
end;$$;
revoke all on function public.sl_cancel_booking(uuid,text) from public,anon;
grant execute on function public.sl_cancel_booking(uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;


-- Additive cargo/fleet marketplace, capability controls and direct conversations.
begin;
create table public.sl_company_capabilities(workspace_id uuid primary key references public.sl_workspaces,freight boolean not null default true,last_mile boolean not null default true,warehousing boolean not null default false,vehicle_only boolean not null default false,with_driver boolean not null default false,dispatch boolean not null default true,updated_at timestamptz not null default now());
insert into public.sl_company_capabilities(workspace_id,warehousing) select w.id,exists(select 1 from public.sl_facilities f where f.workspace_id=w.id) from public.sl_workspaces w;
create function logistics_private.init_capabilities() returns trigger language plpgsql security definer set search_path='' as $$ begin insert into public.sl_company_capabilities(workspace_id) values(new.id);return new;end;$$;
create trigger sl_company_capabilities_init after insert on public.sl_workspaces for each row execute function logistics_private.init_capabilities();
create table public.sl_service_changes(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,features jsonb not null,reason text not null,effective_date date not null default current_date,status text not null default 'pending' check(status in('pending','scheduled','applied','rejected')),requested_by uuid not null default auth.uid() references auth.users,reviewed_by uuid references auth.users,created_at timestamptz not null default now(),reviewed_at timestamptz);
create table public.sl_service_listings(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,title text not null,category text not null check(category in('Air Freight','Ocean Freight','Road Freight','Rail Freight','Multimodal','Warehousing','Warehouse + Shipping','Vehicle Hire')),description text not null default '',status text not null default 'draft' check(status in('draft','published','paused')),cargo_categories text[] not null default '{}',options text[] not null default '{}',min_weight numeric not null default 0 check(min_weight>=0 and min_weight<1000000000),max_weight numeric not null default 100000 check(max_weight>=min_weight and max_weight<1000000000),pricing_method text not null default 'quote' check(pricing_method in('quote','fixed')),price numeric check(price>=0 and price<1000000000000),transit_time text,public_contacts boolean not null default false,contact_name text,contact_email text,contact_phone text,vehicle_id uuid,hire_mode text check(hire_mode in('vehicle_only','with_driver')),terms text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(workspace_id,id),foreign key(workspace_id,vehicle_id) references public.sl_vehicles(workspace_id,id),check(category<>'Vehicle Hire' or hire_mode is not null));
create table public.sl_listing_routes(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,listing_id uuid not null,origin_country text not null,origin_city text not null,destination_country text not null,destination_city text not null,direction text not null default 'one_way' check(direction in('one_way','round_trip')),created_at timestamptz not null default now(),foreign key(workspace_id,listing_id) references public.sl_service_listings(workspace_id,id));
create table public.sl_customer_preferences(user_id uuid primary key references auth.users on delete cascade,origin_country text,origin_city text,destination_country text,destination_city text,cargo_category text,weight_kg numeric check(weight_kg>0 and weight_kg<1000000000),service_type text,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.sl_saved_providers(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users,workspace_id uuid not null references public.sl_workspaces,created_at timestamptz not null default now(),unique(user_id,workspace_id));
create table public.sl_booking_drafts(id uuid primary key default gen_random_uuid(),user_id uuid not null default auth.uid() references auth.users,listing_id uuid references public.sl_service_listings,details jsonb not null default '{}',created_at timestamptz not null default now(),updated_at timestamptz not null default now());
alter table public.sl_bookings add column listing_id uuid references public.sl_service_listings;
alter table public.sl_bookings add column shipment_details jsonb not null default '{}';
create table public.sl_hire_requests(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,listing_id uuid not null,customer_id uuid not null default auth.uid() references auth.users,reference text not null unique default ('HR-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10))),mode text not null check(mode in('vehicle_only','with_driver')),pickup_city text not null,pickup_address text not null,usage_area text not null,starts_at timestamptz not null,ends_at timestamptz not null,cargo_description text not null,weight_kg numeric not null check(weight_kg>0 and weight_kg<1000000000),contact_name text not null,contact_phone text not null,contact_email text not null,organization text,loading_help boolean not null default false,shipment_id uuid references public.sl_shipments,vehicle_id uuid,driver_id uuid,status text not null default 'requested' check(status in('requested','quoted','accepted','assigned','on_trip','returned','completed','declined','cancelled')),amount numeric check(amount>=0 and amount<1000000000000),note text,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(workspace_id,id),foreign key(workspace_id,listing_id) references public.sl_service_listings(workspace_id,id),foreign key(workspace_id,vehicle_id) references public.sl_vehicles(workspace_id,id),foreign key(workspace_id,driver_id) references public.sl_drivers(workspace_id,id),check(ends_at>starts_at));
create table public.sl_fleet_maintenance(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,vehicle_id uuid not null,service_type text not null,due_date date not null,status text not null default 'scheduled' check(status in('scheduled','completed','cancelled')),cost numeric check(cost>=0 and cost<1000000000000),notes text,created_at timestamptz not null default now(),foreign key(workspace_id,vehicle_id) references public.sl_vehicles(workspace_id,id));
create table public.sl_fleet_expenses(id uuid primary key default gen_random_uuid(),workspace_id uuid not null,vehicle_id uuid not null,type text not null check(type in('fuel','maintenance','other')),amount numeric not null check(amount>0 and amount<1000000000000),expense_date date not null,reference text not null,notes text,created_at timestamptz not null default now(),foreign key(workspace_id,vehicle_id) references public.sl_vehicles(workspace_id,id));
create table public.sl_conversations(id uuid primary key default gen_random_uuid(),workspace_id uuid not null references public.sl_workspaces,customer_id uuid not null references auth.users,listing_id uuid references public.sl_service_listings,booking_id uuid references public.sl_bookings,hire_id uuid references public.sl_hire_requests,subject text not null,created_at timestamptz not null default now(),updated_at timestamptz not null default now());
create table public.sl_messages(id uuid primary key default gen_random_uuid(),conversation_id uuid not null references public.sl_conversations,sender_id uuid not null default auth.uid() references auth.users,body text not null check(length(trim(body)) between 1 and 4000),attachment_path text,created_at timestamptz not null default now());

create function logistics_private.market_service_enabled(w uuid,category text,mode text default null) returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from public.sl_company_capabilities c where c.workspace_id=w and case when category='Vehicle Hire' then case when mode='with_driver' then c.with_driver else c.vehicle_only end when category='Warehousing' then c.warehousing when category='Warehouse + Shipping' then c.warehousing and c.freight else c.freight or c.last_mile end) $$;
create function logistics_private.apply_service_features(w uuid,features jsonb) returns void language plpgsql security definer set search_path='' as $$
declare freight boolean:=coalesce((features->>'freight')::boolean,false);last_mile boolean:=coalesce((features->>'last_mile')::boolean,false);warehouse boolean:=coalesce((features->>'warehousing')::boolean,false);self_drive boolean:=coalesce((features->>'vehicle_only')::boolean,false);driver boolean:=coalesce((features->>'with_driver')::boolean,false);
begin
if not(freight or last_mile or warehouse or self_drive or driver) then raise exception 'Choose at least one business service';end if;
if not(freight or last_mile) and (exists(select 1 from public.sl_shipments where workspace_id=w and status not in('Delivered','Cancelled','Returned')) or exists(select 1 from public.sl_bookings where workspace_id=w and status not in('cancelled','declined','shipment_created'))) then raise exception 'Finish active cargo jobs before disabling cargo services';end if;
if not warehouse and exists(select 1 from public.sl_inventory_items where workspace_id=w and quantity>0) then raise exception 'Release stored inventory before disabling warehousing';end if;
if exists(select 1 from public.sl_hire_requests where workspace_id=w and status not in('completed','cancelled','declined') and ((mode='vehicle_only' and not self_drive) or (mode='with_driver' and not driver))) then raise exception 'Finish active hires before disabling their service';end if;
insert into public.sl_company_capabilities(workspace_id,freight,last_mile,warehousing,vehicle_only,with_driver,dispatch) values(w,freight,last_mile,warehouse,self_drive,driver,coalesce((features->>'dispatch')::boolean,false)) on conflict(workspace_id) do update set freight=excluded.freight,last_mile=excluded.last_mile,warehousing=excluded.warehousing,vehicle_only=excluded.vehicle_only,with_driver=excluded.with_driver,dispatch=excluded.dispatch,updated_at=now();
end;$$;
create function public.sl_request_service_change(w uuid,features jsonb,reason text,effective_date date default current_date) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare r uuid;initial boolean;
begin
if not (logistics_private.platform_admin() or logistics_private.password_ready() and exists(select 1 from public.sl_memberships where workspace_id=w and user_id=auth.uid() and role='admin')) then raise exception 'Company administrator required';end if;
if length(trim(coalesce(reason,'')))<3 or effective_date is null then raise exception 'Reason and effective date required';end if;
select status='pending' into initial from public.sl_workspaces where id=w;
insert into public.sl_service_changes(workspace_id,features,reason,effective_date,requested_by) values(w,features,reason,effective_date,auth.uid()) returning id into r;
if (logistics_private.platform_admin() or initial) and effective_date<=current_date then perform logistics_private.apply_service_features(w,features);update public.sl_service_changes set status='applied',reviewed_by=auth.uid(),reviewed_at=now() where id=r;end if;
return r;end;$$;
create function public.sl_review_service_change(change_id uuid,decision text) returns void language plpgsql security definer set search_path='' as $$
declare r public.sl_service_changes;begin
if not logistics_private.platform_admin() then raise exception 'Platform administrator required';end if;
select * into r from public.sl_service_changes where id=change_id for update;if not found or r.status not in('pending','scheduled') then raise exception 'Change is no longer pending';end if;
if decision='rejected' then update public.sl_service_changes set status='rejected',reviewed_by=auth.uid(),reviewed_at=now() where id=r.id;
elsif decision='approved' then if r.effective_date>current_date then update public.sl_service_changes set status='scheduled',reviewed_by=auth.uid(),reviewed_at=now() where id=r.id;else perform logistics_private.apply_service_features(r.workspace_id,r.features);update public.sl_service_changes set status='applied',reviewed_by=auth.uid(),reviewed_at=now() where id=r.id;end if;
else raise exception 'Invalid decision';end if;end;$$;
create function public.sl_save_service_listing(listing uuid,details jsonb,routes jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare w uuid;r uuid;route jsonb;v uuid;published boolean;begin
w:=(details->>'workspace_id')::uuid;if not (logistics_private.has_role(w,array['admin','operator']) or logistics_private.password_ready() and coalesce(details->>'status','draft')='draft' and exists(select 1 from public.sl_memberships where workspace_id=w and user_id=auth.uid() and role='admin')) then raise exception 'Service management permission required';end if;
if length(trim(coalesce(details->>'title','')))<3 or jsonb_typeof(routes)<>'array' or jsonb_array_length(routes)=0 then raise exception 'Listing title and route coverage required';end if;
if listing is not null and not exists(select 1 from public.sl_service_listings where id=listing and workspace_id=w) then raise exception 'Listing does not belong to this company';end if;
published:=details->>'status'='published';
if published and (not logistics_private.market_service_enabled(w,details->>'category',details->>'hire_mode') or not exists(select 1 from public.sl_workspaces where id=w and status='active') or not exists(select 1 from public.sl_provider_verifications where workspace_id=w and status='approved')) then raise exception 'Publishing requires an active verified company and enabled service capability';end if;
v:=nullif(details->>'vehicle_id','')::uuid;
insert into public.sl_service_listings(id,workspace_id,title,category,description,status,cargo_categories,options,min_weight,max_weight,pricing_method,price,transit_time,public_contacts,contact_name,contact_email,contact_phone,vehicle_id,hire_mode,terms)
values(coalesce(listing,gen_random_uuid()),w,trim(details->>'title'),details->>'category',coalesce(details->>'description',''),coalesce(details->>'status','draft'),array(select jsonb_array_elements_text(coalesce(details->'cargo_categories','[]'))),array(select jsonb_array_elements_text(coalesce(details->'options','[]'))),coalesce((details->>'min_weight')::numeric,0),coalesce((details->>'max_weight')::numeric,100000),coalesce(details->>'pricing_method','quote'),nullif(details->>'price','')::numeric,details->>'transit_time',coalesce((details->>'public_contacts')::boolean,false),details->>'contact_name',details->>'contact_email',details->>'contact_phone',v,nullif(details->>'hire_mode',''),details->>'terms')
on conflict(id) do update set title=excluded.title,category=excluded.category,description=excluded.description,status=excluded.status,cargo_categories=excluded.cargo_categories,options=excluded.options,min_weight=excluded.min_weight,max_weight=excluded.max_weight,pricing_method=excluded.pricing_method,price=excluded.price,transit_time=excluded.transit_time,public_contacts=excluded.public_contacts,contact_name=excluded.contact_name,contact_email=excluded.contact_email,contact_phone=excluded.contact_phone,vehicle_id=excluded.vehicle_id,hire_mode=excluded.hire_mode,terms=excluded.terms,updated_at=now() returning id into r;
delete from public.sl_listing_routes where listing_id=r;
for route in select * from jsonb_array_elements(routes) loop
if length(trim(coalesce(route->>'origin_city','')))=0 or length(trim(coalesce(route->>'destination_city','')))=0 then raise exception 'Every coverage route needs origin and destination cities';end if;
insert into public.sl_listing_routes(workspace_id,listing_id,origin_country,origin_city,destination_country,destination_city,direction) values(w,r,coalesce(route->>'origin_country',''),trim(route->>'origin_city'),coalesce(route->>'destination_country',''),trim(route->>'destination_city'),coalesce(route->>'direction','one_way'));
if published and details->>'category' not in('Vehicle Hire','Warehousing') then insert into public.sl_service_areas(workspace_id,origin_city,destination_city,service_type) values(w,trim(route->>'origin_city'),trim(route->>'destination_city'),details->>'category') on conflict(workspace_id,origin_city,destination_city,service_type) do nothing;end if;
end loop;return r;end;$$;

-- This is the sole anonymous marketplace API. It projects only published fields.
create function public.sl_discover_listings(search jsonb default '{}') returns jsonb language sql stable security definer set search_path='' as $$
select coalesce(jsonb_agg(item order by item->>'company_name',item->>'title'),'[]'::jsonb) from (
select jsonb_build_object('id',l.id,'workspace_id',l.workspace_id,'title',l.title,'category',l.category,'description',l.description,'cargo_categories',l.cargo_categories,'options',l.options,'min_weight',l.min_weight,'max_weight',l.max_weight,'pricing_method',l.pricing_method,'price',l.price,'transit_time',l.transit_time,'hire_mode',l.hire_mode,'terms',l.terms,'company_name',w.name,'company_city',w.city,'company_country',w.country,'verified',true,'contact_name',case when l.public_contacts then l.contact_name end,'contact_email',case when l.public_contacts then l.contact_email end,'contact_phone',case when l.public_contacts then l.contact_phone end,'vehicle',case when v.id is not null then jsonb_build_object('type',v.type,'capacity_kg',v.capacity_kg,'status',v.status) end,'routes',(select coalesce(jsonb_agg(jsonb_build_object('origin_country',r.origin_country,'origin_city',r.origin_city,'destination_country',r.destination_country,'destination_city',r.destination_city,'direction',r.direction)),'[]') from public.sl_listing_routes r where r.listing_id=l.id)) item
from public.sl_service_listings l join public.sl_workspaces w on w.id=l.workspace_id left join public.sl_vehicles v on v.id=l.vehicle_id
where l.status='published' and w.status='active' and exists(select 1 from public.sl_provider_verifications where workspace_id=w.id and status='approved') and logistics_private.market_service_enabled(w.id,l.category,l.hire_mode)
and (coalesce(search->>'workspace_id','')='' or w.id=nullif(search->>'workspace_id','')::uuid)
and (coalesce(search->>'listing_id','')='' or l.id=nullif(search->>'listing_id','')::uuid)
and (coalesce(search->>'category','')='' or l.category=search->>'category')
and (coalesce(search->>'cargo_category','')='' or cardinality(l.cargo_categories)=0 or lower(search->>'cargo_category')=any(select lower(x) from unnest(l.cargo_categories) x))
and (coalesce(search->>'weight_kg','')='' or nullif(search->>'weight_kg','')::numeric between l.min_weight and l.max_weight)
and (
  (coalesce(search->>'origin_city','')='' and coalesce(search->>'destination_city','')='')
  or exists(select 1 from public.sl_listing_routes r where r.listing_id=l.id and (
    ((coalesce(search->>'origin_city','')='' or lower(r.origin_city)=lower(trim(search->>'origin_city')))
      and (coalesce(search->>'destination_city','')='' or lower(r.destination_city)=lower(trim(search->>'destination_city'))))
    or (r.direction='round_trip'
      and (coalesce(search->>'origin_city','')='' or lower(r.destination_city)=lower(trim(search->>'origin_city')))
      and (coalesce(search->>'destination_city','')='' or lower(r.origin_city)=lower(trim(search->>'destination_city'))))
  ))
)
) public_items $$;

create function public.sl_request_cargo_quote(listing uuid,details jsonb,consent boolean) returns uuid language plpgsql security definer set search_path='' as $$
declare l public.sl_service_listings;b uuid;begin
if not logistics_private.password_ready() or consent is distinct from true then raise exception 'Sign in and consent to sharing this request with the selected provider';end if;
select * into l from public.sl_service_listings where id=listing;if not found or l.category='Vehicle Hire' then raise exception 'Cargo service not found';end if;
if jsonb_array_length(public.sl_discover_listings(jsonb_build_object('listing_id',listing,'origin_city',details->>'origin_city','destination_city',details->>'destination_city','weight_kg',details->>'weight_kg','cargo_category',coalesce(details->>'cargo_category',''))))=0 then raise exception 'The selected service does not cover these shipment details';end if;
if length(trim(coalesce(details->>'sender_name','')))=0 or length(trim(coalesce(details->>'recipient_name','')))=0 or length(trim(coalesce(details->>'pickup_address','')))=0 or length(trim(coalesce(details->>'delivery_address','')))=0 then raise exception 'Sender, receiver and address details are required';end if;
if coalesce((details->>'package_count')::int,1)<1 then raise exception 'Package count must be positive';end if;
b:=public.sl_submit_booking(l.category,details->>'origin_city',details->>'destination_city',details->>'pickup_address',details->>'delivery_address',details->>'sender_name',details->>'sender_phone',details->>'recipient_name',details->>'recipient_phone',(details->>'weight_kg')::numeric,details->>'description');
update public.sl_bookings set listing_id=l.id,workspace_id=l.workspace_id,status='assigned',assigned_by=auth.uid(),assigned_at=now(),shipment_details=details,updated_at=now() where id=b;
insert into public.sl_booking_assignments(workspace_id,booking_id,actor_id) values(l.workspace_id,b,auth.uid());
insert into public.sl_notifications(workspace_id,message,visibility) values(l.workspace_id,'New customer quotation request: '||(select reference from public.sl_bookings where id=b),'provider');return b;end;$$;

create function public.sl_request_vehicle_hire(listing uuid,details jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare l public.sl_service_listings;r uuid;s uuid;begin
if not logistics_private.password_ready() or (details->>'consent')::boolean is distinct from true then raise exception 'Sign in, set your password and consent to sharing this request';end if;
select * into l from public.sl_service_listings where id=listing;if not found or l.category<>'Vehicle Hire' or jsonb_array_length(public.sl_discover_listings(jsonb_build_object('listing_id',listing,'origin_city',details->>'pickup_city','weight_kg',details->>'weight_kg')))=0 then raise exception 'This vehicle hire service is not available for this cargo';end if;
s:=nullif(details->>'shipment_id','')::uuid;if s is not null and not exists(select 1 from public.sl_shipments sh where sh.id=s and logistics_private.has_role(sh.workspace_id,array['admin','operator','dispatcher'])) then raise exception 'Shipment handoff permission required';end if;
if length(trim(coalesce(details->>'pickup_address','')))<3 or length(trim(coalesce(details->>'contact_name','')))<2 or length(trim(coalesce(details->>'contact_phone','')))<5 then raise exception 'Pickup and contact details required';end if;
if (details->>'starts_at')::timestamptz<now()-interval '5 minutes' then raise exception 'Choose a future hire start time';end if;
insert into public.sl_hire_requests(workspace_id,listing_id,customer_id,mode,pickup_city,pickup_address,usage_area,starts_at,ends_at,cargo_description,weight_kg,contact_name,contact_phone,contact_email,organization,loading_help,shipment_id)
values(l.workspace_id,l.id,auth.uid(),l.hire_mode,details->>'pickup_city',details->>'pickup_address',details->>'usage_area',(details->>'starts_at')::timestamptz,(details->>'ends_at')::timestamptz,details->>'cargo_description',(details->>'weight_kg')::numeric,details->>'contact_name',details->>'contact_phone',details->>'contact_email',details->>'organization',coalesce((details->>'loading_help')::boolean,false),s) returning id into r;
insert into public.sl_notifications(workspace_id,message,visibility) values(l.workspace_id,'New vehicle hire request: '||(select reference from public.sl_hire_requests where id=r),'provider');return r;end;$$;
create function public.sl_hire_action(request uuid,decision text,amount numeric default null,note text default null,vehicle uuid default null,driver uuid default null) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare r public.sl_hire_requests;staff boolean;begin
if not logistics_private.password_ready() then raise exception 'Sign in and complete password setup';end if;
select * into r from public.sl_hire_requests where id=request for update;if not found then raise exception 'Hire request not found';end if;
staff:=logistics_private.has_role(r.workspace_id,array['admin','operator','dispatcher']);
if decision='quoted' and staff and r.status in('requested','quoted') then if amount is null or amount<0 then raise exception 'Quoted amount required';end if;update public.sl_hire_requests set status='quoted',amount=amount,note=note,updated_at=now() where id=r.id;
elsif decision='accepted' and r.customer_id=auth.uid() and r.status='quoted' then update public.sl_hire_requests set status='accepted',updated_at=now() where id=r.id;
elsif decision='declined' and staff and r.status in('requested','quoted') then if length(trim(coalesce(note,'')))<3 then raise exception 'Decline reason required';end if;update public.sl_hire_requests set status='declined',note=note,updated_at=now() where id=r.id;
elsif decision='cancelled' and (r.customer_id=auth.uid() or logistics_private.platform_admin()) and r.status in('requested','quoted','accepted') then if length(trim(coalesce(note,'')))<3 then raise exception 'Cancellation reason required';end if;update public.sl_hire_requests set status='cancelled',note=note,updated_at=now() where id=r.id;
elsif decision='assigned' and staff and r.status='accepted' then
perform pg_advisory_xact_lock(hashtextextended(vehicle::text,0));
if not exists(select 1 from public.sl_vehicles where id=vehicle and workspace_id=r.workspace_id and status='available' and capacity_kg>=r.weight_kg) then raise exception 'Choose an available vehicle with sufficient capacity';end if;
if exists(select 1 from public.sl_hire_requests where vehicle_id=vehicle and id<>r.id and status in('assigned','on_trip') and starts_at<r.ends_at and ends_at>r.starts_at) then raise exception 'Vehicle is already assigned for this period';end if;
if r.mode='with_driver' and not exists(select 1 from public.sl_drivers where id=driver and workspace_id=r.workspace_id and status='available' and user_id is not null) then raise exception 'An available linked driver is required';end if;
if r.mode='with_driver' then perform pg_advisory_xact_lock(hashtextextended(driver::text,0));if exists(select 1 from public.sl_hire_requests where driver_id=driver and id<>r.id and status in('assigned','on_trip') and starts_at<r.ends_at and ends_at>r.starts_at) then raise exception 'Driver is already assigned for this period';end if;end if;
update public.sl_hire_requests set status='assigned',vehicle_id=vehicle,driver_id=case when r.mode='with_driver' then driver end,updated_at=now() where id=r.id;update public.sl_vehicles set status='assigned' where id=vehicle;
elsif ((staff or exists(select 1 from public.sl_drivers where id=r.driver_id and user_id=auth.uid())) and ((decision='on_trip' and r.status='assigned') or (decision='returned' and r.status='on_trip'))) or (staff and decision='completed' and r.status='returned') then
update public.sl_hire_requests set status=decision,note=coalesce(note,sl_hire_requests.note),updated_at=now() where id=r.id;
if decision='returned' then update public.sl_vehicles set status='available' where id=r.vehicle_id;end if;
else raise exception 'This status transition is not permitted for your account';end if;
insert into public.sl_notifications(workspace_id,user_id,message,visibility) values(r.workspace_id,r.customer_id,'Hire '||r.reference||': '||decision,'customer');end;$$;

create function logistics_private.conversation_access(c uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.password_ready() and exists(select 1 from public.sl_conversations where id=c and (customer_id=auth.uid() or logistics_private.has_role(workspace_id,array['admin','operator','dispatcher','finance']))) $$;
create function public.sl_start_conversation(listing uuid,booking uuid default null,hire uuid default null) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare l public.sl_service_listings;r uuid;begin
if not logistics_private.password_ready() then raise exception 'Sign in to message a provider';end if;
select * into l from public.sl_service_listings where id=listing;if not found then raise exception 'Provider service not found';end if;if jsonb_array_length(public.sl_discover_listings(jsonb_build_object('listing_id',listing)))=0 and booking is null and hire is null then raise exception 'Published provider service not found';end if;
if booking is not null and not exists(select 1 from public.sl_bookings where id=booking and customer_id=auth.uid() and workspace_id=l.workspace_id) then raise exception 'Booking does not belong to this account and provider';end if;
if hire is not null and not exists(select 1 from public.sl_hire_requests where id=hire and customer_id=auth.uid() and workspace_id=l.workspace_id) then raise exception 'Hire does not belong to this account and provider';end if;
perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||l.id::text,0));
select id into r from public.sl_conversations where customer_id=auth.uid() and listing_id=l.id and booking_id is not distinct from booking and hire_id is not distinct from hire limit 1;
if r is null then insert into public.sl_conversations(workspace_id,customer_id,listing_id,booking_id,hire_id,subject) values(l.workspace_id,auth.uid(),l.id,booking,hire,l.title) returning id into r;end if;return r;end;$$;
create function public.sl_send_message(conversation uuid,body text,attachment text default null) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare r uuid;c public.sl_conversations;begin
if not logistics_private.conversation_access(conversation) then raise exception 'Conversation access denied';end if;
if attachment is not null and (split_part(attachment,'/',1)<>conversation::text or not exists(select 1 from storage.objects where bucket_id='sl-messages' and name=attachment)) then raise exception 'Attachment must be uploaded to this conversation first';end if;
select * into c from public.sl_conversations where id=conversation;
insert into public.sl_messages(conversation_id,sender_id,body,attachment_path) values(conversation,auth.uid(),trim(body),attachment) returning id into r;
update public.sl_conversations set updated_at=now() where id=conversation;
insert into public.sl_notifications(workspace_id,user_id,message,visibility) values(c.workspace_id,case when c.customer_id<>auth.uid() then c.customer_id end,'New message: '||c.subject,case when c.customer_id=auth.uid() then 'provider' else 'customer' end);return r;end;$$;

-- All new private records use the same authenticated database roles as existing operations.
do $$ declare t text;begin
foreach t in array array['sl_company_capabilities','sl_service_changes','sl_service_listings','sl_listing_routes','sl_hire_requests','sl_fleet_maintenance','sl_fleet_expenses','sl_conversations'] loop
execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select on public.%I to authenticated',t);
execute format('create policy staff_read on public.%I for select to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''dispatcher'',''finance'',''warehouse'',''viewer'']))',t);
execute format('create index on public.%I(workspace_id)',t);
execute format('create trigger sl_marketplace_audit after insert or update or delete on public.%I for each row execute function logistics_private.platform_audit_change()',t);
end loop;end;$$;
do $$ declare t text;begin foreach t in array array['sl_company_capabilities','sl_service_changes','sl_service_listings','sl_listing_routes'] loop
execute format('create policy company_owner_read on public.%I for select to authenticated using(logistics_private.password_ready() and exists(select 1 from public.sl_memberships where workspace_id=%I.workspace_id and user_id=auth.uid() and role=''admin''))',t,t);
end loop;end;$$;
-- Capability primary keys are workspace IDs, so use a separate audit history above.
drop trigger sl_marketplace_audit on public.sl_company_capabilities;
create policy capability_owner_read on public.sl_company_capabilities for select to authenticated using(exists(select 1 from public.sl_memberships where workspace_id=sl_company_capabilities.workspace_id and user_id=auth.uid()));
create policy own_hires on public.sl_hire_requests for select to authenticated using(customer_id=auth.uid() or exists(select 1 from public.sl_drivers where id=driver_id and user_id=auth.uid()));
create policy conversation_customer_read on public.sl_conversations for select to authenticated using(customer_id=auth.uid());
alter table public.sl_messages enable row level security;revoke all on public.sl_messages from anon,authenticated;grant select on public.sl_messages to authenticated;
create policy participant_messages on public.sl_messages for select to authenticated using(logistics_private.conversation_access(conversation_id));
create index sl_message_conversation_created on public.sl_messages(conversation_id,created_at);
create index sl_hire_customer on public.sl_hire_requests(customer_id,created_at desc);
create index sl_conversation_customer on public.sl_conversations(customer_id,updated_at desc);
do $$ declare t text;begin foreach t in array array['sl_customer_preferences','sl_saved_providers','sl_booking_drafts'] loop
execute format('alter table public.%I enable row level security',t);execute format('revoke all on public.%I from anon,authenticated',t);execute format('grant select,insert,update,delete on public.%I to authenticated',t);
execute format('create policy own_records on public.%I for all to authenticated using(user_id=auth.uid() and logistics_private.password_ready()) with check(user_id=auth.uid() and logistics_private.password_ready())',t);
end loop;end;$$;
do $$ declare t text;begin foreach t in array array['sl_fleet_maintenance','sl_fleet_expenses'] loop
execute format('grant insert,update on public.%I to authenticated',t);
execute format('create policy manage_records on public.%I for all to authenticated using(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''finance''])) with check(logistics_private.has_role(workspace_id,array[''admin'',''operator'',''finance'']))',t);
end loop;end;$$;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('sl-messages','sl-messages',false,10485760,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do nothing;
create function logistics_private.message_file_access(path text) returns boolean language plpgsql stable security definer set search_path='' as $$ begin return logistics_private.conversation_access(split_part(path,'/',1)::uuid);exception when invalid_text_representation then return false;end;$$;
create policy sl_message_file_read on storage.objects for select to authenticated using(bucket_id='sl-messages' and logistics_private.message_file_access(name));
create policy sl_message_file_upload on storage.objects for insert to authenticated with check(bucket_id='sl-messages' and logistics_private.message_file_access(name));
do $$ declare f record;begin for f in select p.oid::regprocedure signature from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in('sl_request_service_change','sl_review_service_change','sl_save_service_listing','sl_request_cargo_quote','sl_request_vehicle_hire','sl_hire_action','sl_start_conversation','sl_send_message') loop execute format('revoke all on function %s from public,anon',f.signature);execute format('grant execute on function %s to authenticated',f.signature);end loop;end;$$;
revoke all on function public.sl_discover_listings(jsonb) from public;grant execute on function public.sl_discover_listings(jsonb) to anon,authenticated;
revoke all on all functions in schema logistics_private from public,anon;
grant execute on function logistics_private.market_service_enabled(uuid,text,text),logistics_private.conversation_access(uuid),logistics_private.message_file_access(text) to authenticated;
do $$ declare t text;begin if exists(select 1 from pg_publication where pubname='supabase_realtime') then foreach t in array array['sl_service_listings','sl_hire_requests','sl_conversations','sl_messages','sl_service_changes'] loop execute format('alter publication supabase_realtime add table public.%I',t);end loop;end if;end;$$;

create function public.sl_fleet_dashboard(w uuid default null) returns jsonb language sql stable security invoker set search_path='' as $$ select jsonb_build_object(
'available_vehicles',(select count(*) from public.sl_vehicles where (w is null or workspace_id=w) and status='available'),
'active_hires',(select count(*) from public.sl_hire_requests where (w is null or workspace_id=w) and status in('accepted','assigned','on_trip','returned')),
'available_drivers',(select count(*) from public.sl_drivers where (w is null or workspace_id=w) and status='available'),
'maintenance_due',(select count(distinct vehicle_id) from public.sl_fleet_maintenance where (w is null or workspace_id=w) and status='scheduled' and due_date<=current_date)) $$;
revoke all on function public.sl_fleet_dashboard(uuid) from public,anon;grant execute on function public.sl_fleet_dashboard(uuid) to authenticated;
create function public.sl_conversation_messages(conversation uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$ begin
if not logistics_private.conversation_access(conversation) then raise exception 'Conversation access denied';end if;
return coalesce((select jsonb_agg(jsonb_build_object('id',m.id,'sender_id',m.sender_id,'sender_name',coalesce(p.display_name,'Account'),'body',m.body,'attachment_path',m.attachment_path,'created_at',m.created_at) order by m.created_at) from public.sl_messages m left join public.sl_profiles p on p.id=m.sender_id where m.conversation_id=conversation),'[]');end;$$;
create function public.sl_start_provider_conversation(booking uuid) returns uuid language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare b public.sl_bookings;r uuid;begin select * into b from public.sl_bookings where id=booking;
if not found or not logistics_private.has_role(b.workspace_id,array['admin','operator','dispatcher','finance']) then raise exception 'Provider conversation permission required';end if;
perform pg_advisory_xact_lock(hashtextextended(b.id::text,0));select id into r from public.sl_conversations where booking_id=b.id and workspace_id=b.workspace_id and customer_id=b.customer_id limit 1;
if r is null then insert into public.sl_conversations(workspace_id,customer_id,listing_id,booking_id,subject) values(b.workspace_id,b.customer_id,b.listing_id,b.id,'Booking '||b.reference) returning id into r;end if;return r;end;$$;
revoke all on function public.sl_conversation_messages(uuid),public.sl_start_provider_conversation(uuid) from public,anon;grant execute on function public.sl_conversation_messages(uuid),public.sl_start_provider_conversation(uuid) to authenticated;
alter policy staff_read on public.sl_conversations using(logistics_private.has_role(workspace_id,array['admin','operator','dispatcher','finance']));
do $$ declare t text;begin foreach t in array array['sl_company_capabilities','sl_service_changes','sl_service_listings','sl_listing_routes','sl_hire_requests','sl_fleet_maintenance','sl_fleet_expenses','sl_conversations'] loop
execute format('create policy password_setup_read on public.%I as restrictive for select to authenticated using(logistics_private.password_ready())',t);
execute format('create trigger sl_require_password_setup before insert or update or delete on public.%I for each row execute function logistics_private.require_password_setup()',t);
end loop;end;$$;
notify pgrst,'reload schema';
commit;


-- Coordinate hire assignments with existing cargo dispatch locks and preserve trip purpose.
begin;
alter table public.sl_hire_requests add column purpose text;
alter table public.sl_service_listings add constraint sl_fixed_listing_price check(pricing_method<>'fixed' or price is not null);
alter policy staff_read on public.sl_fleet_expenses using(logistics_private.has_role(workspace_id,array['admin','operator','finance']));
create or replace function public.sl_request_vehicle_hire(listing uuid,details jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare l public.sl_service_listings;r uuid;s uuid;begin
if not logistics_private.password_ready() or (details->>'consent')::boolean is distinct from true then raise exception 'Sign in, set your password and consent to sharing this request';end if;
select * into l from public.sl_service_listings where id=listing;if not found or l.category<>'Vehicle Hire' or jsonb_array_length(public.sl_discover_listings(jsonb_build_object('listing_id',listing,'origin_city',details->>'pickup_city','weight_kg',details->>'weight_kg')))=0 then raise exception 'This vehicle hire service is not available for this cargo';end if;
s:=nullif(details->>'shipment_id','')::uuid;if s is not null and not exists(select 1 from public.sl_shipments sh where sh.id=s and logistics_private.has_role(sh.workspace_id,array['admin','operator','dispatcher'])) then raise exception 'Shipment handoff permission required';end if;
if length(trim(coalesce(details->>'pickup_address','')))<3 or length(trim(coalesce(details->>'contact_name','')))<2 or length(trim(coalesce(details->>'contact_phone','')))<5 then raise exception 'Pickup and contact details required';end if;
if (details->>'starts_at')::timestamptz<now()-interval '5 minutes' then raise exception 'Choose a future hire start time';end if;
insert into public.sl_hire_requests(workspace_id,listing_id,customer_id,mode,pickup_city,pickup_address,usage_area,starts_at,ends_at,cargo_description,weight_kg,contact_name,contact_phone,contact_email,organization,loading_help,shipment_id,purpose)
values(l.workspace_id,l.id,auth.uid(),l.hire_mode,details->>'pickup_city',details->>'pickup_address',details->>'usage_area',(details->>'starts_at')::timestamptz,(details->>'ends_at')::timestamptz,details->>'cargo_description',(details->>'weight_kg')::numeric,details->>'contact_name',details->>'contact_phone',details->>'contact_email',details->>'organization',coalesce((details->>'loading_help')::boolean,false),s,details->>'purpose') returning id into r;
insert into public.sl_notifications(workspace_id,message,visibility) values(l.workspace_id,'New vehicle hire request: '||(select reference from public.sl_hire_requests where id=r),'provider');return r;end;$$;
create or replace function public.sl_hire_action(request uuid,decision text,amount numeric default null,note text default null,vehicle uuid default null,driver uuid default null) returns void language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare r public.sl_hire_requests;staff boolean;begin
if not logistics_private.password_ready() then raise exception 'Sign in and complete password setup';end if;
select * into r from public.sl_hire_requests where id=request for update;if not found then raise exception 'Hire request not found';end if;
staff:=logistics_private.has_role(r.workspace_id,array['admin','operator','dispatcher']);
if decision='quoted' and staff and r.status in('requested','quoted') then if amount is null or amount<0 then raise exception 'Quoted amount required';end if;update public.sl_hire_requests set status='quoted',amount=amount,note=note,updated_at=now() where id=r.id;
elsif decision='accepted' and r.customer_id=auth.uid() and r.status='quoted' then update public.sl_hire_requests set status='accepted',updated_at=now() where id=r.id;
elsif decision='declined' and staff and r.status in('requested','quoted') then if length(trim(coalesce(note,'')))<3 then raise exception 'Decline reason required';end if;update public.sl_hire_requests set status='declined',note=note,updated_at=now() where id=r.id;
elsif decision='cancelled' and (r.customer_id=auth.uid() or logistics_private.platform_admin()) and r.status in('requested','quoted','accepted') then if length(trim(coalesce(note,'')))<3 then raise exception 'Cancellation reason required';end if;update public.sl_hire_requests set status='cancelled',note=note,updated_at=now() where id=r.id;
elsif decision='assigned' and staff and r.status='accepted' then
if r.mode='with_driver' then perform 1 from public.sl_drivers where id=driver and workspace_id=r.workspace_id for update;end if;
perform 1 from public.sl_vehicles where id=vehicle and workspace_id=r.workspace_id for update;
perform pg_advisory_xact_lock(hashtextextended(vehicle::text,0));
if not exists(select 1 from public.sl_vehicles where id=vehicle and workspace_id=r.workspace_id and status='available' and capacity_kg>=r.weight_kg) then raise exception 'Choose an available vehicle with sufficient capacity';end if;
if exists(select 1 from public.sl_hire_requests where vehicle_id=vehicle and id<>r.id and status in('assigned','on_trip') and starts_at<r.ends_at and ends_at>r.starts_at) then raise exception 'Vehicle is already assigned for this period';end if;
if r.mode='with_driver' and not exists(select 1 from public.sl_drivers where id=driver and workspace_id=r.workspace_id and status='available' and user_id is not null) then raise exception 'An available linked driver is required';end if;
if r.mode='with_driver' then perform pg_advisory_xact_lock(hashtextextended(driver::text,0));if exists(select 1 from public.sl_hire_requests where driver_id=driver and id<>r.id and status in('assigned','on_trip') and starts_at<r.ends_at and ends_at>r.starts_at) then raise exception 'Driver is already assigned for this period';end if;end if;
update public.sl_hire_requests set status='assigned',vehicle_id=vehicle,driver_id=case when r.mode='with_driver' then driver end,updated_at=now() where id=r.id;update public.sl_vehicles set status='assigned' where id=vehicle;if r.mode='with_driver' then update public.sl_drivers set status='assigned' where id=driver;end if;
elsif ((staff or exists(select 1 from public.sl_drivers where id=r.driver_id and user_id=auth.uid())) and ((decision='on_trip' and r.status='assigned') or (decision='returned' and r.status='on_trip'))) or (staff and decision='completed' and r.status='returned') then
update public.sl_hire_requests set status=decision,note=coalesce(note,sl_hire_requests.note),updated_at=now() where id=r.id;
if decision='returned' then update public.sl_vehicles set status='available' where id=r.vehicle_id;update public.sl_drivers set status='available' where id=r.driver_id;end if;
else raise exception 'This status transition is not permitted for your account';end if;
insert into public.sl_notifications(workspace_id,user_id,message,visibility) values(r.workspace_id,r.customer_id,'Hire '||r.reference||': '||decision,'customer');end;$$;
notify pgrst,'reload schema';
commit;


begin;
-- Generate new bin codes atomically; retain existing/manual historical codes.
create table logistics_private.bin_counters(workspace_id uuid primary key references public.sl_workspaces,next_number bigint not null);
create function logistics_private.generate_bin_code() returns trigger language plpgsql security definer set search_path='' as $$
declare prefix text;n bigint;begin
if coalesce(trim(new.code),'')<>'' then return new;end if;
select upper(string_agg(left(part,1),'' order by ord)) into prefix from public.sl_workspaces w cross join lateral regexp_split_to_table(trim(regexp_replace(w.name,'[^[:alnum:] ]',' ','g')),'[[:space:]]+') with ordinality as words(part,ord) where w.id=new.workspace_id and part<>'';
prefix:=left(coalesce(nullif(prefix,''),'BIN'),8);
loop
insert into logistics_private.bin_counters values(new.workspace_id,1) on conflict(workspace_id) do update set next_number=logistics_private.bin_counters.next_number+1 returning next_number into n;
new.code:=prefix||'-'||lpad(n::text,greatest(4,length(n::text)),'0');
exit when not exists(select 1 from public.sl_storage_locations where workspace_id=new.workspace_id and code=new.code);
end loop;return new;end;$$;
alter table public.sl_storage_locations alter column code set default '';
create trigger sl_generate_bin_code before insert on public.sl_storage_locations for each row execute function logistics_private.generate_bin_code();
revoke all on function logistics_private.generate_bin_code() from public,anon,authenticated;

create table public.sl_booking_comments(id uuid primary key default gen_random_uuid(),booking_id uuid not null references public.sl_bookings,workspace_id uuid references public.sl_workspaces,author_id uuid not null references auth.users,body text not null check(length(trim(body)) between 1 and 4000),created_at timestamptz not null default now());
alter table public.sl_booking_comments enable row level security;
revoke all on public.sl_booking_comments from public,anon,authenticated;grant select on public.sl_booking_comments to authenticated;
create policy booking_participants on public.sl_booking_comments for select to authenticated using(logistics_private.password_ready() and logistics_private.booking_access(booking_id));
create index sl_booking_comments_booking on public.sl_booking_comments(booking_id,created_at);
create function public.sl_add_booking_comment(booking uuid,comment text) returns uuid language plpgsql security definer set search_path='' as $$
declare b public.sl_bookings;r uuid;begin
select * into b from public.sl_bookings where id=booking;
if not found or not logistics_private.password_ready() or not (b.customer_id=auth.uid() or logistics_private.has_role(b.workspace_id,array['admin','operator','dispatcher']) or logistics_private.platform_admin()) then raise exception 'Request response permission required';end if;
insert into public.sl_booking_comments(booking_id,workspace_id,author_id,body) values(b.id,b.workspace_id,auth.uid(),trim(comment)) returning id into r;
insert into public.sl_notifications(workspace_id,user_id,message,visibility) values(b.workspace_id,case when b.customer_id<>auth.uid() then b.customer_id end,'New comment on request '||b.reference,case when b.customer_id=auth.uid() then 'provider' else 'customer' end);return r;end;$$;
revoke all on function public.sl_add_booking_comment(uuid,text) from public,anon;grant execute on function public.sl_add_booking_comment(uuid,text) to authenticated;
do $$ begin if exists(select 1 from pg_publication where pubname='supabase_realtime') then alter publication supabase_realtime add table public.sl_booking_comments;end if;end;$$;

alter table public.sl_workspaces add column provider_kind text not null default 'company' check(provider_kind in('company','individual'));
create table public.sl_enterprise_tools(workspace_id uuid not null references public.sl_workspaces,user_id uuid not null references auth.users,tools text[] not null,assigned_by uuid not null references auth.users,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),primary key(workspace_id,user_id));
alter table public.sl_enterprise_tools enable row level security;
revoke all on public.sl_enterprise_tools from public,anon,authenticated;grant select on public.sl_enterprise_tools to authenticated;
create policy assigned_tools_read on public.sl_enterprise_tools for select to authenticated using(user_id=auth.uid() or logistics_private.platform_admin());
create function logistics_private.tool_allowed(w uuid,tool text) returns boolean language sql stable security definer set search_path='' as $$
select logistics_private.password_ready() and (logistics_private.platform_admin() or not exists(select 1 from public.sl_enterprise_tools where workspace_id=w and user_id=auth.uid()) or exists(select 1 from public.sl_enterprise_tools where workspace_id=w and user_id=auth.uid() and tool=any(tools))) $$;
create function logistics_private.require_tool(tool text) returns void language plpgsql stable security definer set search_path='' as $$
declare w uuid;begin
if logistics_private.platform_admin() then return;end if;
select workspace_id into w from public.sl_account_access where user_id=auth.uid();
if w is not null and not logistics_private.tool_allowed(w,tool) then raise exception 'This tool has not been assigned to your enterprise account';end if;end;$$;
revoke all on function logistics_private.tool_allowed(uuid,text),logistics_private.require_tool(text) from public,anon;
grant execute on function logistics_private.tool_allowed(uuid,text),logistics_private.require_tool(text) to authenticated;
create function public.sl_set_enterprise_tools(target uuid,w uuid,tools text[]) returns void language plpgsql security definer set search_path='' as $$
begin
if not logistics_private.platform_admin() then raise exception 'Platform administrator required';end if;
if cardinality(tools)=0 or tools is null or not tools<@array['cargo','fleet','warehouse','finance','services','messages','team','reports','covlo'] then raise exception 'Choose valid dashboard tools';end if;
if not exists(select 1 from public.sl_memberships where workspace_id=w and user_id=target) or exists(select 1 from public.sl_platform_admins where user_id=target) then raise exception 'Select an assigned provider account';end if;
if exists(select 1 from public.sl_account_access where user_id=target and workspace_id is distinct from w) then raise exception 'Configure tools for the account primary workspace';end if;
insert into public.sl_account_access(user_id,workspace_id,role,must_change_password,assigned_by) select target,w,role,false,auth.uid() from public.sl_memberships where workspace_id=w and user_id=target on conflict(user_id) do nothing;
insert into public.sl_enterprise_tools(workspace_id,user_id,tools,assigned_by) values(w,target,tools,auth.uid()) on conflict(workspace_id,user_id) do update set tools=excluded.tools,assigned_by=excluded.assigned_by,updated_at=now();
insert into public.sl_platform_audit(actor_id,action,entity,record_id) values(auth.uid(),'enterprise_tools','sl_enterprise_tools',target);
end;$$;
create function public.sl_create_individual_provider(target uuid,provider_name text,mode text,tools text[]) returns uuid language plpgsql security definer set search_path='' as $$
declare w uuid;begin
if not logistics_private.platform_admin() then raise exception 'Platform administrator required';end if;
if mode not in('cargo','fleet','combined') or length(trim(coalesce(provider_name,'')))<2 then raise exception 'Provider name and service mode required';end if;
if not exists(select 1 from auth.users where id=target) or exists(select 1 from public.sl_platform_admins where user_id=target) or exists(select 1 from public.sl_memberships where user_id=target) then raise exception 'Choose an independent non-administrator account';end if;
insert into public.sl_workspaces(name,status,provider_kind) values(trim(provider_name),'active','individual') returning id into w;
insert into public.sl_memberships(workspace_id,user_id,role) values(w,target,'admin');
insert into public.sl_account_access(user_id,workspace_id,role,must_change_password,assigned_by) values(target,w,'admin',true,auth.uid()) on conflict(user_id) do update set workspace_id=w,role='admin',must_change_password=true,assigned_by=auth.uid(),password_set_at=null;
perform logistics_private.apply_service_features(w,jsonb_build_object('freight',mode<>'fleet','last_mile',mode<>'fleet','warehousing',false,'vehicle_only',mode<>'cargo','with_driver',mode<>'cargo','dispatch',true));
perform public.sl_set_enterprise_tools(target,w,tools);return w;end;$$;
revoke all on function public.sl_set_enterprise_tools(uuid,uuid,text[]),public.sl_create_individual_provider(uuid,text,text,text[]) from public,anon;
grant execute on function public.sl_set_enterprise_tools(uuid,uuid,text[]),public.sl_create_individual_provider(uuid,text,text,text[]) to authenticated;

-- Restrict enterprise record access in addition to existing role/tenant policies.
do $$ declare item record;t text;begin
for item in select * from (values
('cargo',array['sl_bookings','sl_quotations','sl_booking_assignments','sl_orders','sl_shipments','sl_pickups','sl_delivery_tasks','sl_tracking_events','sl_scan_events','sl_delivery_proofs','sl_shipment_packages','sl_fee_history','sl_location_updates','sl_routes','sl_route_stops']),
('fleet',array['sl_vehicles','sl_drivers','sl_hire_requests','sl_fleet_maintenance','sl_fleet_expenses']),
('warehouse',array['sl_facilities','sl_storage_locations','sl_storage_pricing','sl_storage_bookings','sl_inventory_items','sl_inventory_movements','sl_dispatch_jobs']),
('finance',array['sl_invoices','sl_payments','sl_ledger_entries','sl_settlements','sl_settlement_lines','sl_payout_requests']),
('services',array['sl_service_listings','sl_listing_routes','sl_service_areas','sl_services']),
('messages',array['sl_conversations'])
) as groups(tool,tables) loop foreach t in array item.tables loop
execute format('create policy enterprise_tool_access on public.%I as restrictive for all to authenticated using(logistics_private.tool_allowed(workspace_id,%L)) with check(logistics_private.tool_allowed(workspace_id,%L))',t,item.tool,item.tool);
end loop;end loop;end;$$;
create or replace function logistics_private.conversation_access(c uuid) returns boolean language sql stable security definer set search_path='' as $$ select logistics_private.password_ready() and exists(select 1 from public.sl_conversations where id=c and logistics_private.tool_allowed(workspace_id,'messages') and (customer_id=auth.uid() or logistics_private.has_role(workspace_id,array['admin','operator','dispatcher','finance']))) $$;
create policy enterprise_comment_access on public.sl_booking_comments as restrictive for select to authenticated using(logistics_private.tool_allowed(workspace_id,'cargo'));
create policy enterprise_member_access on public.sl_memberships as restrictive for select to authenticated using(user_id=auth.uid() or logistics_private.tool_allowed(workspace_id,'team'));
create policy enterprise_invitation_access on public.sl_account_invitations as restrictive for select to authenticated using(logistics_private.tool_allowed(workspace_id,'team'));
-- Apply the same tool checks at RPC entry, including SECURITY DEFINER workflows.
do $$ declare item record;f record;definition text;begin
for item in select * from (values
('cargo',array['sl_submit_booking','sl_assign_booking','sl_respond_booking','sl_accept_quote','sl_cancel_booking','sl_create_booking_shipment','sl_transition_shipment','sl_assign_task','sl_task_action','sl_request_pickup','sl_create_delivery_task','sl_scan_shipment','sl_record_delivery_proof','sl_request_cargo_quote','sl_add_booking_comment','sl_set_shipping_fee']),
('fleet',array['sl_request_vehicle_hire','sl_hire_action']),
('warehouse',array['sl_receive_inventory','sl_request_dispatch','sl_dispatch_action']),
('finance',array['sl_submit_payment','sl_review_payment','sl_prepare_settlement','sl_review_settlement','sl_request_payout','sl_review_payout']),
('services',array['sl_save_service_listing','sl_update_business_profile','sl_update_company','sl_request_service_change']),
('messages',array['sl_start_conversation','sl_start_provider_conversation','sl_send_message','sl_conversation_messages']),
('team',array['sl_prepare_account_invitation','sl_add_member','sl_account_directory'])
) as groups(tool,functions) loop
for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(item.functions) loop
definition:=pg_get_functiondef(f.oid);definition:=regexp_replace(definition,'\m[Bb][Ee][Gg][Ii][Nn]\M','begin perform logistics_private.require_tool('||quote_literal(item.tool)||');');execute definition;
end loop;end loop;end;$$;
notify pgrst,'reload schema';
commit;


begin;
create policy enterprise_client_access on public.sl_clients as restrictive for all to authenticated using(logistics_private.tool_allowed(workspace_id,'cargo') or logistics_private.tool_allowed(workspace_id,'warehouse') or logistics_private.tool_allowed(workspace_id,'finance')) with check(logistics_private.tool_allowed(workspace_id,'cargo') or logistics_private.tool_allowed(workspace_id,'warehouse') or logistics_private.tool_allowed(workspace_id,'finance'));
create policy enterprise_audit_access on public.sl_audit as restrictive for select to authenticated using(logistics_private.tool_allowed(workspace_id,case when entity in('sl_vehicles','sl_drivers','sl_hire_requests','sl_fleet_maintenance','sl_fleet_expenses') then 'fleet' when entity in('sl_facilities','sl_storage_locations','sl_storage_bookings','sl_inventory_items','sl_inventory_movements','sl_dispatch_jobs') then 'warehouse' when entity in('sl_invoices','sl_payments','sl_settlements','sl_payout_requests','sl_ledger_entries') then 'finance' else 'cargo' end));
do $$ declare item record;f record;definition text;begin
for item in select * from (values ('cargo',array['sl_book_shipment','sl_eligible_providers']),('team',array['sl_remove_member']),('finance',array['sl_verify_payment'])) as groups(tool,functions) loop
for f in select p.oid from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=any(item.functions) loop
definition:=pg_get_functiondef(f.oid);definition:=regexp_replace(definition,'\m[Bb][Ee][Gg][Ii][Nn]\M','begin perform logistics_private.require_tool('||quote_literal(item.tool)||');');execute definition;
end loop;end loop;end;$$;
notify pgrst,'reload schema';
commit;


begin;
create table logistics_private.sync_receipts(user_id uuid not null references auth.users,operation_id uuid not null,signature text not null,completed boolean not null default false,result jsonb,created_at timestamptz not null default now(),primary key(user_id,operation_id));
create function logistics_private.sync_claim(operation uuid,signature text) returns jsonb language plpgsql security definer set search_path='' as $$
#variable_conflict use_variable
declare r logistics_private.sync_receipts;begin
if not logistics_private.password_ready() or operation is null then raise exception 'Sign in and complete password setup before syncing';end if;
perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||operation::text,0));
select * into r from logistics_private.sync_receipts where user_id=auth.uid() and operation_id=operation;
if found then if r.signature<>signature then raise exception 'Operation ID was already used with different data';end if;return jsonb_build_object('done',r.completed,'result',r.result);end if;
insert into logistics_private.sync_receipts(user_id,operation_id,signature) values(auth.uid(),operation,signature);return jsonb_build_object('done',false);end;$$;
create function logistics_private.sync_finish(operation uuid,value jsonb) returns void language plpgsql security definer set search_path='' as $$ begin update logistics_private.sync_receipts set completed=true,result=value where user_id=auth.uid() and operation_id=operation;end;$$;
revoke all on function logistics_private.sync_claim(uuid,text),logistics_private.sync_finish(uuid,jsonb) from public,anon;
grant execute on function logistics_private.sync_claim(uuid,text),logistics_private.sync_finish(uuid,jsonb) to authenticated;

create function logistics_private.sync_check_base(target_table text,target_id uuid,base jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r jsonb;w uuid;allowed boolean;begin
if not logistics_private.password_ready() or target_table<>all(array['sl_bookings','sl_shipments','sl_hire_requests','sl_dispatch_jobs','sl_pickups','sl_delivery_tasks']) then raise exception 'Sync access denied';end if;
execute format('select to_jsonb(t) from public.%I t where id=$1',target_table) into r using target_id;w:=(r->>'workspace_id')::uuid;
allowed:=logistics_private.has_role(w,array['admin','operator','dispatcher','warehouse','viewer','finance']) or r->>'customer_id'=auth.uid()::text or exists(select 1 from public.sl_drivers where id=nullif(r->>'driver_id','')::uuid and user_id=auth.uid());
if not coalesce(allowed,false) or not logistics_private.tool_allowed(w,case when target_table='sl_hire_requests' then 'fleet' when target_table='sl_dispatch_jobs' then 'warehouse' else 'cargo' end) then raise exception 'Sync access denied';end if;
execute format('select to_jsonb(t) from public.%I t where id=$1 for update',target_table) into r using target_id;
if r is null or not r@>base then raise exception 'Sync conflict: this record changed or your access changed. Review it before retrying';end if;end;$$;
revoke all on function logistics_private.sync_check_base(text,uuid,jsonb) from public,anon;grant execute on function logistics_private.sync_check_base(text,uuid,jsonb) to authenticated;

create function public.sl_sync_operation(operation uuid,kind text,resource text,payload jsonb,record_id uuid default null,base jsonb default null) returns jsonb language plpgsql security invoker set search_path='' as $$
declare claim jsonb;result jsonb;current_record jsonb;cols text;sets text;args text;f record;target_table text;target_id uuid;
begin
claim:=logistics_private.sync_claim(operation,md5(jsonb_build_array(kind,resource,payload,record_id,base)::text));
if (claim->>'done')::boolean then return claim->'result';end if;
if jsonb_typeof(payload)<>'object' then raise exception 'Sync payload must be an object';end if;
if kind='rpc' then
if resource<>all(array['sl_submit_booking','sl_request_cargo_quote','sl_request_vehicle_hire','sl_add_booking_comment','sl_respond_booking','sl_accept_quote','sl_cancel_booking','sl_create_booking_shipment','sl_transition_shipment','sl_assign_task','sl_task_action','sl_request_pickup','sl_create_delivery_task','sl_scan_shipment','sl_record_delivery_proof','sl_receive_inventory','sl_request_dispatch','sl_dispatch_action','sl_hire_action','sl_start_conversation','sl_start_provider_conversation','sl_send_message','sl_save_service_listing','sl_submit_payment']) then raise exception 'This action requires a live connection';end if;
target_table:=case when resource in('sl_respond_booking','sl_accept_quote','sl_cancel_booking','sl_create_booking_shipment') then 'sl_bookings' when resource='sl_transition_shipment' then 'sl_shipments' when resource='sl_hire_action' then 'sl_hire_requests' when resource='sl_dispatch_action' then 'sl_dispatch_jobs' when resource='sl_task_action' then case when payload->>'task_type'='pickup' then 'sl_pickups' else 'sl_delivery_tasks' end end;
target_id:=coalesce(nullif(payload->>'booking',''),nullif(payload->>'shipment',''),nullif(payload->>'request',''),nullif(payload->>'job',''),nullif(payload->>'task',''))::uuid;
if target_table is not null and base is not null then
perform logistics_private.sync_check_base(target_table,target_id,base);end if;
select p.* into f from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname=resource and array(select jsonb_object_keys(payload))<@p.proargnames limit 1;
if not found then raise exception 'Unknown action arguments';end if;
select string_agg(format('%I => %s',f.proargnames[i],case when format_type(f.proargtypes[i-1],null)='jsonb' then format('($1->%L)',f.proargnames[i]) else format('($1->>%L)::%s',f.proargnames[i],format_type(f.proargtypes[i-1],null)) end),', ' order by i) into args from generate_series(1,f.pronargs) i where payload?f.proargnames[i];
perform set_config('swahivo.sync_operation',operation::text,true);perform set_config('swahivo.sync_resource',case when resource='sl_save_service_listing' and nullif(payload->>'listing','') is not null then '' else resource end,true);
execute format('select to_jsonb(public.%I(%s))',resource,coalesce(args,'')) into result using payload;
else
if kind not in('insert','update','upsert') or resource<>all(array['sl_addresses','sl_orders','sl_vehicles','sl_drivers','sl_facilities','sl_storage_locations','sl_storage_bookings','sl_routes','sl_route_stops','sl_booking_drafts','sl_customer_preferences','sl_saved_providers','sl_tickets','sl_fleet_maintenance','sl_fleet_expenses']) then raise exception 'This change requires a live connection';end if;
if exists(select 1 from jsonb_object_keys(payload) k where not exists(select 1 from pg_attribute a where a.attrelid=('public.'||quote_ident(resource))::regclass and a.attname=k and a.attnum>0 and not a.attisdropped)) then raise exception 'Unknown record field';end if;
if kind='upsert' then
if resource not in('sl_booking_drafts','sl_customer_preferences','sl_saved_providers') then raise exception 'This upsert needs a live connection';end if;
if resource='sl_saved_providers' then select to_jsonb(t) into current_record from public.sl_saved_providers t where t.user_id=(payload->>'user_id')::uuid and t.workspace_id=(payload->>'workspace_id')::uuid;
else execute format('select to_jsonb(t) from public.%I t where %I=$1 for update',resource,case when resource='sl_customer_preferences' then 'user_id' else 'id' end) into current_record using coalesce(record_id,nullif(payload->>'id','')::uuid);end if;
if current_record is not null then
if resource='sl_saved_providers' then result:=jsonb_build_array(current_record);perform logistics_private.sync_finish(operation,result);return result;end if;
if base is null or not current_record@>base then raise exception 'Sync conflict: this record changed. Refresh before retrying';end if;
end if;
select string_agg(quote_ident(k),',') into cols from jsonb_object_keys(payload) k;
select string_agg(format('%1$I=excluded.%1$I',k),',') into sets from jsonb_object_keys(payload) k where k<>case when resource='sl_customer_preferences' then 'user_id' else 'id' end;
execute format('insert into public.%1$I(%2$s) select %2$s from jsonb_populate_record(null::public.%1$I,$1) on conflict(%3$I) do update set %4$s returning to_jsonb(%1$I.*)',resource,cols,case when resource='sl_customer_preferences' then 'user_id' else 'id' end,sets) into result using payload;
elsif kind='insert' then
select string_agg(quote_ident(k),',') into cols from jsonb_object_keys(payload) k;
execute format('insert into public.%1$I(%2$s) select %2$s from jsonb_populate_record(null::public.%1$I,$1) returning to_jsonb(%1$I.*)',resource,cols) into result using payload;
else
if record_id is null then raise exception 'Record ID required';end if;
execute format('select to_jsonb(t) from public.%I t where id=$1 for update',resource) into current_record using record_id;
if current_record is null or base is not null and not current_record@>base then raise exception 'Sync conflict: this record changed or your access changed. Review it before retrying';end if;
select string_agg(format('%1$I=r.%1$I',k),',') into sets from jsonb_object_keys(payload) k where k<>'id';
execute format('update public.%1$I t set %2$s from jsonb_populate_record(null::public.%1$I,$1) r where t.id=$2 returning to_jsonb(t.*)',resource,sets) into result using payload,record_id;
end if;
result:=jsonb_build_array(result);
end if;
perform logistics_private.sync_finish(operation,result);return result;end;$$;
revoke all on function public.sl_sync_operation(uuid,text,text,jsonb,uuid,jsonb) from public,anon;grant execute on function public.sl_sync_operation(uuid,text,text,jsonb,uuid,jsonb) to authenticated;
-- Stable create IDs let queued records keep their links after reconnecting.
create function logistics_private.sync_record_id() returns trigger language plpgsql set search_path='' as $$
declare resource text:=current_setting('swahivo.sync_resource',true);operation text:=current_setting('swahivo.sync_operation',true);begin
if nullif(operation,'') is not null and ((tg_table_name='sl_bookings' and resource in('sl_submit_booking','sl_request_cargo_quote')) or (tg_table_name='sl_hire_requests' and resource='sl_request_vehicle_hire') or (tg_table_name='sl_booking_comments' and resource='sl_add_booking_comment') or (tg_table_name='sl_messages' and resource='sl_send_message') or (tg_table_name='sl_conversations' and resource in('sl_start_conversation','sl_start_provider_conversation')) or (tg_table_name='sl_shipments' and resource='sl_create_booking_shipment') or (tg_table_name='sl_dispatch_jobs' and resource='sl_request_dispatch') or (tg_table_name='sl_payments' and resource='sl_submit_payment') or (tg_table_name='sl_service_listings' and resource='sl_save_service_listing')) then new.id:=operation::uuid;end if;return new;end;$$;
revoke all on function logistics_private.sync_record_id() from public,anon,authenticated;
do $$ declare t text;begin foreach t in array array['sl_bookings','sl_hire_requests','sl_booking_comments','sl_messages','sl_conversations','sl_shipments','sl_dispatch_jobs','sl_service_listings','sl_payments'] loop execute format('create trigger sl_sync_record_id before insert on public.%I for each row execute function logistics_private.sync_record_id()',t);end loop;end;$$;
notify pgrst,'reload schema';
commit;
