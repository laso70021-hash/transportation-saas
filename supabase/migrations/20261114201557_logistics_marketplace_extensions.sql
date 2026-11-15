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
