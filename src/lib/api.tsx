import {offlineNow,storedSession,syncPending,clearLocalCache} from './offline';
import {type AccountRole,isAccountRole,areaForRole} from './roles';
import {projectClient} from './client';
import {createContext,useContext,useEffect,useMemo,useState,useRef,type ReactNode} from 'react';
import {type SupabaseClient,type Session} from '@supabase/supabase-js';
import {useQuery,useQueryClient} from '@tanstack/react-query';
import type {Row,Area,Config} from './types';
const Context=createContext<ReturnType<typeof useBackend>|null>(null);
function readConfig():Config|null{try{const url=import.meta.env.VITE_SUPABASE_URL;const key=import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY||import.meta.env.VITE_SUPABASE_ANON_KEY;if(url&&key&&!key.includes('replace_'))return {url,key};const saved=localStorage.getItem('sl.connection');return saved?JSON.parse(saved):null}catch{return null}}
function useBackend(){const [config,setConfig]=useState<Config|null>(readConfig),[session,setSession]=useState<Session|null>(null),[authReady,setAuthReady]=useState(false),[workspace,setWorkspace]=useState(''),[previewRole,setPreviewRole]=useState<AccountRole|null>(()=>{try{const saved=sessionStorage.getItem('sl.preview-role');return isAccountRole(saved)?saved:null}catch{return null}}),[previewAccount,setPreviewAccount]=useState<string|null>(null),[recoveryMode,setRecoveryMode]=useState(false);const queryClient=useQueryClient();
const sessionRef=useRef(session);sessionRef.current=session;
useEffect(()=>{try{if(previewRole)sessionStorage.setItem('sl.preview-role',previewRole);else sessionStorage.removeItem('sl.preview-role')}catch{}},[previewRole]);
const db=useMemo<SupabaseClient|null>(()=>{if(!config)return null;try{return projectClient(config.url,config.key)}catch{return null}},[config]);
useEffect(()=>{if(!db){setAuthReady(true);return}let active=true;(offlineNow()?Promise.resolve({data:{session:storedSession(config!.url) as Session|null},error:null}):db.auth.getSession()).then(({data,error})=>{if(active){setSession(data.session);setAuthReady(true);if(error)console.error('Session recovery failed')}});const {data}=db.auth.onAuthStateChange((event,s)=>{if(!s&&offlineNow()&&event!=='SIGNED_OUT'){setSession(storedSession(config!.url));return}setSession(s);if(event==='SIGNED_OUT'&&sessionRef.current&&config)void clearLocalCache(config.url,sessionRef.current.user.id);if(event==='PASSWORD_RECOVERY')setRecoveryMode(true);setAuthReady(true);if(!s){setWorkspace('');setPreviewRole(null);setPreviewAccount(null);setRecoveryMode(false);queryClient.clear()}});return()=>{active=false;data.subscription.unsubscribe()}},[db,queryClient]);
useEffect(()=>{if(!db||!session||!config)return;let active=true;const refresh=()=>{if(active)void queryClient.invalidateQueries()};const sync=()=>{if(offlineNow())return;void syncPending(config.url,session.user.id,async()=>{const r=await db.auth.getSession();if(!r.data.session)throw new Error('Sign in again to sync');return new Headers({authorization:'Bearer '+r.data.session.access_token,apikey:config.key})}).then(refresh)};const changed=()=>{refresh();sync()};window.addEventListener('online',sync);window.addEventListener('focus',sync);window.addEventListener('swahivo-offline-change',changed);const timer=setInterval(sync,15000);sync();return()=>{active=false;clearInterval(timer);window.removeEventListener('online',sync);window.removeEventListener('focus',sync);window.removeEventListener('swahivo-offline-change',changed)}},[db,session?.user.id,config,queryClient]);
const identity=useQuery({queryKey:['identity',session?.user.id],enabled:!!db&&!!session,queryFn:async()=>{
  const [owner,admin,memberships,profile,driver,access,companies,tools]=await Promise.all([
    db!.from('sl_account_owner').select('user_id').eq('user_id',session!.user.id),
    db!.from('sl_platform_admins').select('user_id').eq('user_id',session!.user.id),
    db!.from('sl_memberships').select('*').eq('user_id',session!.user.id),
    db!.from('sl_profiles').select('*').eq('id',session!.user.id).maybeSingle(),
    db!.from('sl_drivers').select('*').eq('user_id',session!.user.id),
    db!.from('sl_account_access').select('*').eq('user_id',session!.user.id).maybeSingle(),
    db!.from('sl_workspaces').select('id,name,status,provider_kind').order('name'),db!.from('sl_enterprise_tools').select('*')
  ]);
  for(const result of [owner,admin,memberships,profile,driver,access,companies,tools])if(result.error)throw result.error;
  const members=memberships.data||[];
  const isPlatformAdmin=!!admin.data?.length;
  const primary=isPlatformAdmin?'platform_admin':access.data?.role||members[0]?.role||(driver.data?.length?'driver':'customer');
  const primaryRole:AccountRole=isAccountRole(primary)?primary:'customer';
  const areas:Area[]=isPlatformAdmin?['admin','provider','account','driver','warehouse']:['account'];
  for(const member of members){const area=areaForRole(member.role);if(!areas.includes(area))areas.push(area)}
  if(access.data&&!areas.includes(areaForRole(primaryRole)))areas.push(areaForRole(primaryRole));
  if(driver.data?.length&&!areas.includes('driver'))areas.push('driver');
  return {areas,isOwner:!!owner.data?.length,isPlatformAdmin,primaryRole,
    mustChangePassword:!!access.data?.must_change_password,primaryWorkspace:access.data?.workspace_id||members[0]?.workspace_id||driver.data?.[0]?.workspace_id,
    ownerWorkspaces:companies.data||[],enterpriseTools:tools.data||[],memberships:members,profile:profile.data,drivers:driver.data||[]};
}});
useEffect(()=>{if(!db||!session||!identity.data||offlineNow())return;let cancelled=false;const tables=['sl_workspaces','sl_company_capabilities','sl_bookings','sl_quotations','sl_booking_comments','sl_shipments','sl_orders','sl_clients','sl_pickups','sl_delivery_tasks','sl_vehicles','sl_drivers','sl_hire_requests','sl_facilities','sl_storage_locations','sl_inventory_items','sl_dispatch_jobs','sl_invoices','sl_addresses','sl_conversations','sl_booking_drafts','sl_customer_preferences'];void(async()=>{for(let i=0;i<tables.length&&!cancelled;i+=4)await Promise.allSettled(tables.slice(i,i+4).map(t=>db.from(t).select('*').limit(500)))})();return()=>{cancelled=true}},[db,session?.user.id,identity.data?.primaryWorkspace]);
useEffect(()=>{if(!workspace){const first=identity.data?.primaryWorkspace||(identity.data?.isPlatformAdmin?identity.data.ownerWorkspaces[0]?.id:undefined);if(first)setWorkspace(first)}},[identity.data,workspace]);
useEffect(()=>{if(!db||!session)return;const ch=db.channel('operations:'+session.user.id).on('postgres_changes',{event:'*',schema:'public'},()=>{void queryClient.invalidateQueries({predicate:q=>true})}).subscribe();return()=>{void db.removeChannel(ch)}},[db,session,queryClient]);
async function connect(url:string,key:string){const u=new URL(url);if(!['https:','http:'].includes(u.protocol)||u.protocol==='http:'&&!['127.0.0.1','localhost'].includes(u.hostname))throw Error('Use HTTPS, or localhost for development.');if(!key.startsWith('sb_publishable_')){try{const p=JSON.parse(atob(key.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')));if(p.role!=='anon')throw Error()}catch{throw Error('Only publishable or legacy anon keys are accepted.')}}if(db)await db.auth.signOut();localStorage.setItem('sl.connection',JSON.stringify({url:u.origin,key}));setConfig({url:u.origin,key});queryClient.clear()}
async function rpc(name:string,args:Record<string,unknown>){if(!db||!session)throw Error('Sign in to a connected Supabase project first.');const r=await db.rpc(name,args);if(r.error)throw new Error(r.error.message);await queryClient.invalidateQueries({predicate:q=>q.queryKey[0]!=='identity'});return r.data}
async function save(table:string,values:Record<string,unknown>,id?:string){if(!db||!session)throw Error('Sign in first.');const q=id?db.from(table).update(values).eq('id',id):db.from(table).insert(values);const r=await q.select();if(r.error)throw new Error(r.error.message);if(!r.data?.length)throw Error('No rows changed. Check your permission or refresh the record.');await queryClient.invalidateQueries({predicate:q=>q.queryKey[0]!=='identity'});return r.data[0] as Row}
return {db,config,session,authReady,identity,workspace,setWorkspace,previewRole,setPreviewRole,previewAccount,setPreviewAccount,recoveryMode,setRecoveryMode,connect,rpc,save,queryClient};}
export function BackendProvider({children}:{children:ReactNode}){const value=useBackend();return <Context.Provider value={value}>{children}</Context.Provider>}
export function useApi(){const c=useContext(Context);if(!c)throw Error('BackendProvider missing');return c}
export function useRows(table:string,scope?:string,search?:{field:string;text:string},page=1,status?:string){const api=useApi();return useQuery({queryKey:['rows',table,scope,search,page,status,api.session?.user.id],enabled:!!api.db&&!!api.session,queryFn:async()=>{let q=api.db!.from(table).select('*',{count:'exact'}).order('created_at',{ascending:false}).range((page-1)*20,page*20-1);if(scope)q=q.eq('workspace_id',scope);if(search?.text)q=q.ilike(search.field,'%'+search.text.replace(/[,%()]/g,'')+'%');if(status)q=q.eq('status',status);const r=await q;if(r.error)throw Error(r.error.message);return {rows:r.data as Row[],count:r.count||0}},refetchInterval:30000})}
export function useOptions(table:string,scope?:string){const api=useApi();return useQuery({queryKey:['options',table,scope,api.session?.user.id],enabled:!!api.db&&!!api.session,queryFn:async()=>{let q=api.db!.from(table).select('*').limit(200);if(scope)q=q.eq('workspace_id',scope);const r=await q;if(r.error)throw Error(r.error.message);return r.data as Row[]}})}
export const money=(n:unknown)=>new Intl.NumberFormat('en-TZ',{style:'currency',currency:'TZS',maximumFractionDigits:0}).format(Number(n||0));
export const label=(r:Row)=>String(r.name||r.reference||r.tracking_number||r.number||r.plate_number||r.code||r.sku||r.display_name||r.id.slice(0,8));
export function exportCSV(rows:Row[],name:string){if(!rows.length)throw Error('No records to export.');const keys=Object.keys(rows[0]);const safe=(v:unknown)=>'"'+String(v??'').replace(/^[=+@-]/,"'$&").replaceAll('"','""')+'"';download([keys.map(safe).join(','),...rows.map(r=>keys.map(k=>safe(r[k])).join(','))].join('\n'),name+'.csv','text/csv')}
export function download(text:string,name:string,type='text/plain'){const u=URL.createObjectURL(new Blob([text],{type}));const a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),500)}
