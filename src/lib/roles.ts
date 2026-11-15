import type {Area} from './types';

export const roleDefinitions = [
  {id:'platform_admin', title:'Platform administrator', area:'admin', description:'Companies, account directory, approvals and platform settings.'},
  {id:'admin', title:'Company administrator', area:'provider', description:'Company operations, staff accounts, service pricing and business settings.'},
  {id:'operator', title:'Operations officer', area:'provider', description:'Bookings, shipments, customers, pickups and delivery operations.'},
  {id:'dispatcher', title:'Dispatcher', area:'provider', description:'Booking allocation, driver assignments, vehicles, routes and delivery progress.'},
  {id:'finance', title:'Finance officer', area:'provider', description:'Invoices, payment review, earnings, settlements and payouts.'},
  {id:'driver', title:'Driver', area:'driver', description:'Assigned pickups and deliveries, QR scans, delivery proof and location updates.'},
  {id:'warehouse', title:'Warehouse staff', area:'warehouse', description:'Receiving, stored goods, picking, dispatch and stock movements.'},
  {id:'viewer', title:'Company viewer', area:'provider', description:'Read-only company shipment, order and tracking visibility.'},
  {id:'customer', title:'Customer', area:'account', description:'Own bookings, quotations, shipments, stored goods, invoices and support.'},
] as const;
export type AccountRole = typeof roleDefinitions[number]['id'];
export function isAccountRole(value: unknown): value is AccountRole {return roleDefinitions.some(r=>r.id===value)}
export function roleInfo(value: string | undefined) {return roleDefinitions.find(r=>r.id===value)||roleDefinitions[8]}
export function areaForRole(value: string): Area {return roleInfo(value).area}
export function dashboardForRole(value: string) {return '/'+areaForRole(value)+'/dashboard'}

export const roleNavigation: Partial<Record<AccountRole,string[]>> = {
  operator:['catalog','fleet','hire-requests','availability','fleet-maintenance','fleet-expenses','messages','covlo','dashboard','requests','shipments','create-shipment','pickups','deliveries','orders','customers','drivers','vehicles','routes','stops','services','areas'],
  dispatcher:['fleet','hire-requests','availability','messages','covlo','dashboard','requests','shipments','create-shipment','pickups','deliveries','drivers','vehicles','routes','stops','areas'],
  finance:['fleet-expenses','messages','covlo','dashboard','invoices','payments','ledger','settlements','payouts','reports'],
  viewer:['dashboard','shipments','orders','requests','pickups','deliveries','routes','stops'],
};
