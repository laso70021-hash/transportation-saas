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
