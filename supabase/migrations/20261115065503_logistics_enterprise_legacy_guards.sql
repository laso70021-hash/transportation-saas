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
