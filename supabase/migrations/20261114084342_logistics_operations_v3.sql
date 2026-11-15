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
