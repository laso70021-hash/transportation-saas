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
