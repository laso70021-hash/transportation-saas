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
