-- Swahivo Logistics SaaS upgrade. Run AFTER the original sl_ schema.
-- No legacy operational records are dropped. Run this upgrade once.
begin;
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
