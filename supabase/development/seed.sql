-- DEVELOPMENT ONLY. Auth accounts must first be created by scripts/seed-development.mjs.
-- No passwords, auth table INSERTs, production administrator backdoor or automatic production execution.
begin;
DO $$ declare a uuid;oa uuid;ob uuid;ca uuid;cb uuid;dr uuid;wh uuid;vw uuid;wa uuid;wb uuid;cl uuid;fac uuid;bin uuid;st uuid;b uuid;s uuid;inv uuid;pay uuid;begin
if current_setting('swahivo.development_seed',true) is distinct from 'confirmed-local' then raise exception 'Development-only seed: use the localhost-guarded setup script';end if;
select id into a from auth.users where email='admin@swahivo.test';select id into oa from auth.users where email='provider-a@swahivo.test';select id into ob from auth.users where email='provider-b@swahivo.test';select id into ca from auth.users where email='customer-a@swahivo.test';select id into cb from auth.users where email='customer-b@swahivo.test';select id into dr from auth.users where email='driver@swahivo.test';select id into wh from auth.users where email='warehouse@swahivo.test';select id into vw from auth.users where email='viewer@swahivo.test';
if a is null or oa is null or ob is null or ca is null or cb is null or dr is null or wh is null or vw is null then raise exception 'Provision all eight Auth accounts first';end if;
if exists(select 1 from public.sl_memberships where user_id=oa) then raise notice 'Development accounts already seeded; existing operational records preserved';return;end if;
insert into public.sl_platform_admins(user_id) values(a) on conflict do nothing;
insert into public.sl_profiles(id,display_name) select id,'Development '||split_part(email,'@',1) from auth.users where id in(a,oa,ob,ca,cb,dr,wh,vw) on conflict(id) do nothing;
insert into public.sl_workspaces(name,status,city,email,country,address) values('DEVELOPMENT · Zanzibar Cargo A','active','Dar es Salaam','provider-a@swahivo.test','Tanzania','Development warehouse address') returning id into wa;
insert into public.sl_workspaces(name,status,city,email,country) values('DEVELOPMENT · Arusha Cargo B','active','Arusha','provider-b@swahivo.test','Tanzania') returning id into wb;
insert into public.sl_memberships values(wa,oa,'admin'),(wb,ob,'admin'),(wa,dr,'driver'),(wa,wh,'warehouse'),(wa,vw,'viewer');
-- Approved development company metadata is a fixture, not a real business verification claim.
insert into public.sl_provider_verifications(workspace_id,registration_number,document_path,status,reviewed_by,reviewed_at,reason) values(wa,'DEVELOPMENT-NOT-A-LEGAL-REGISTRATION',wa||'/verification/'||gen_random_uuid()||'/development.txt','approved',a,now(),'Isolated development fixture only'),(wb,'DEVELOPMENT-B-NOT-LEGAL',wb||'/verification/'||gen_random_uuid()||'/development.txt','approved',a,now(),'Isolated development fixture only');
insert into public.sl_service_areas(workspace_id,origin_city,destination_city,service_type) values(wa,'Dar es Salaam','Arusha','Road Freight'),(wb,'Arusha','Moshi','Road Freight');
insert into public.sl_drivers(workspace_id,user_id,name,phone,license_number) values(wa,dr,'Development Driver','000000000','DEVELOPMENT ONLY');
insert into public.sl_vehicles(workspace_id,plate_number,type,capacity_kg) values(wa,'DEV-A-001','Development van',1000),(wb,'DEV-B-001','Development van',1000);
insert into public.sl_clients(workspace_id,user_id,name,email,phone,address) values(wa,ca,'Development Customer A','customer-a@swahivo.test','000000','Development address') returning id into cl;
insert into public.sl_clients(workspace_id,user_id,name,email,phone) values(wb,cb,'Development Customer B','customer-b@swahivo.test','000000');
insert into public.sl_facilities(workspace_id,name,type,city,address,capacity) values(wa,'Development Warehouse','Warehouse','Dar es Salaam','Development address',1000) returning id into fac;
insert into public.sl_storage_locations(workspace_id,warehouse_id,code,capacity_kg,grid_x,grid_y) values(wa,fac,'DEV-A01',500,1,1) returning id into bin;
insert into public.sl_storage_bookings(workspace_id,client_id,warehouse_id,status) values(wa,cl,fac,'approved') returning id into st;
perform set_config('request.jwt.claim.sub',wh::text,true);perform public.sl_receive_inventory(st,bin,'DEV-STOCK-001','Development cartons',40,2);
perform set_config('request.jwt.claim.sub',ca::text,true);b:=public.sl_submit_booking('Road Freight','Dar es Salaam','Arusha','Development pickup','Development delivery','Development Customer A','000000','Development Recipient','000000',8,'Development cargo for workflow validation');
perform set_config('request.jwt.claim.sub',a::text,true);perform public.sl_assign_booking(b,wa);
perform set_config('request.jwt.claim.sub',oa::text,true);perform public.sl_respond_booking(b,'quoted',150000,2,'Development quotation');
perform set_config('request.jwt.claim.sub',ca::text,true);perform public.sl_accept_quote(b);
perform set_config('request.jwt.claim.sub',oa::text,true);s:=public.sl_create_booking_shipment(b,150000,'Box',now()+interval '1 day');
select id into inv from public.sl_invoices where order_id=(select order_id from public.sl_shipments where id=s);
perform set_config('request.jwt.claim.sub',ca::text,true);pay:=public.sl_submit_payment(inv,150000,'DEVELOPMENT-PAYMENT-REFERENCE','Development manual reference');
-- Payment remains submitted for an actual test review. No GPS, POD or carrier activity is fabricated.
insert into public.sl_settings(name,value) values('commission_percent','10') on conflict(name) do nothing;
perform set_config('request.jwt.claim.sub','',true);
end; $$;
commit;
