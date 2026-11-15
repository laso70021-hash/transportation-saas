# API and route inventory

All operations use a single Supabase backend. Every call carries the real authenticated session; RLS is authoritative. These are implemented paths, not a hosted execution report.

## Independent page modules

| Route suffix | Page | Table |
|---|---|---|
| `/providers` | Provider Management | `sl_workspaces` |
| `/verification` | Provider Verification | `sl_provider_verifications` |
| `/bookings` | Booking Assignment | `sl_bookings` |
| `/requests` | Incoming Booking Requests | `sl_bookings` |
| `/quotations` | Quotations | `sl_quotations` |
| `/shipments` | Shipments | `sl_shipments` |
| `/orders` | Orders | `sl_orders` |
| `/pickups` | Pickup Management | `sl_pickups` |
| `/deliveries` | Delivery Management | `sl_delivery_tasks` |
| `/vehicles` | Fleet & Vehicles | `sl_vehicles` |
| `/drivers` | Drivers | `sl_drivers` |
| `/warehouses` | Warehouses | `sl_facilities` |
| `/locations` | Storage Locations | `sl_storage_locations` |
| `/inventory` | Warehouse & Dispatch Operations | `sl_inventory_items` |
| `/movements` | Inventory Movements | `sl_inventory_movements` |
| `/dispatch` | Warehouse Release & Picking Queue | `sl_dispatch_jobs` |
| `/storage` | Storage Bookings | `sl_storage_bookings` |
| `/pricing` | Storage Pricing | `sl_storage_pricing` |
| `/areas` | Service Areas | `sl_service_areas` |
| `/routes` | Routes | `sl_routes` |
| `/stops` | Route Stops | `sl_route_stops` |
| `/customers` | Customers | `sl_clients` |
| `/invoices` | Invoices | `sl_invoices` |
| `/payments` | Payments, Commissions & Payouts | `sl_payments` |
| `/commissions` | Platform Commission | `sl_commissions` |
| `/settlements` | Provider Settlements | `sl_settlements` |
| `/payouts` | Payout Requests | `sl_payout_requests` |
| `/ledger` | Earnings, Billing & Business Settings | `sl_ledger_entries` |
| `/plans` | Subscription Plans | `sl_plans` |
| `/subscriptions` | Organization Subscriptions | `sl_subscriptions` |
| `/settings` | Platform Settings | `sl_settings` |
| `/services` | Business Pricing | `sl_services` |
| `/notifications` | Notifications | `sl_notifications` |
| `/audit` | Audit Logs | `sl_audit` |
| `/tickets` | Support & Disputes | `sl_tickets` |
| `/addresses` | My Addresses | `sl_addresses` |

## Transactional PostgREST RPC endpoints

POST `/rest/v1/rpc/<function>` with JSON arguments and authenticated bearer JWT. Publishable key selects the project, it does not authorize a role.

- `sl_submit_booking(service_type text,origin_city text,destination_city text,pickup_address text,delivery_address text,sender_name text,sender_phone text,recipient_name text,recipient_phone text,weight_kg numeric,description text)`
- `sl_eligible_providers(booking uuid)`
- `sl_assign_booking(booking uuid,provider uuid)`
- `sl_respond_booking(booking uuid,decision text,amount numeric default null,transit_days integer default null,note text default null)`
- `sl_accept_quote(booking uuid)`
- `sl_create_booking_shipment(booking uuid,shipping_fee numeric,package_type text,pickup_at timestamptz default null)`
- `sl_set_shipping_fee(shipment uuid,amount numeric,reason text)`
- `sl_transition_shipment(shipment uuid,target text,note text default '')`
- `sl_assign_task(task_type text,task uuid,driver uuid,vehicle uuid)`
- `sl_scan_shipment(shipment uuid,token uuid,scan_action text)`
- `sl_task_action(task_type text,task uuid,decision text,reason text default '')`
- `sl_record_delivery_proof(shipment uuid,recipient text,photo text,signature text)`
- `sl_review_provider(verification uuid,decision text,reason text default '')`
- `sl_receive_inventory(booking uuid,location uuid,sku text,item_name text,units numeric,weight_per_unit numeric)`
- `sl_request_dispatch(item uuid,units numeric,shipment uuid)`
- `sl_dispatch_action(job uuid,decision text)`
- `sl_create_delivery_task(shipment uuid)`
- `sl_prepare_settlement(provider uuid)`
- `sl_review_settlement(settlement uuid,decision text,reason text default '')`
- `sl_request_payout(settlement uuid,amount numeric,method text,destination text,request_key uuid)`
- `sl_review_payout(payout uuid,decision text,reference text default '',reason text default '')`
- `sl_financial_summary(provider uuid default null)`
- `sl_verify_payment(payment uuid,decision text)`
- `sl_review_payment(payment uuid,decision text,reason text default '')`
- `sl_add_member(w uuid,member_email text,member_role text)`
- `sl_operations_dashboard(w uuid default null)`
- `sl_update_business_profile(w uuid,name text,city text,country text,email text,phone text,address text)`

Optional Edge API: POST `/functions/v1/review-payment` `{payment,decision,reason}`; validates Auth and delegates to `sl_review_payment`. Frontend currently calls the same RPC directly.

## Key boundaries

`sl_workspaces` represents provider organizations; `sl_memberships` represents scoped roles; `sl_clients` represents company-linked customers; `sl_bookings` precedes `sl_orders`/`sl_shipments`; quotation acceptance is recorded before shipment creation. Driver assignments live on pickup/delivery tasks and are transactionally checked against the fleet. Stock changes use immutable movement rows. `sl_audit` / `sl_platform_audit` record operational/global history. A missing connection or rejected database response never returns a substituted success.
