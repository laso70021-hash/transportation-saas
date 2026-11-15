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
commit;
