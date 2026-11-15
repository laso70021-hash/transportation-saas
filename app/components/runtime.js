'use client';
import {useState,useEffect,useCallback} from 'react';
import {createClient} from '@supabase/supabase-js';
export const stages=['Pending','Processing','In Transit','Delivered'];
export const currency=n=>new Intl.NumberFormat('en-TZ',{style:'currency',currency:'TZS',maximumFractionDigits:0}).format(Number(n||0));
export const time=d=>d?new Date(d).toLocaleString('en-GB',{timeZone:'Africa/Dar_es_Salaam',dateStyle:'medium',timeStyle:'short'}):'—';
export const short=s=>s?.slice(0,8)||'—';
export function downloadText(text,name,type='text/plain'){const u=URL.createObjectURL(new Blob([text],{type}));const a=document.createElement('a');a.href=u;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(u),1000)}
export function useLogistics(){
 const [config,setConfig]=useState(null),[db,setDb]=useState(null),[session,setSession]=useState(null),[role,setRole]=useState(null),[memberships,setMemberships]=useState([]),[tenant,setTenant]=useState(null),[data,setData]=useState({}),[stats,setStats]=useState(null),[loading,setLoading]=useState(false),[error,setError]=useState(''),[busy,setBusy]=useState(false),[notice,setNotice]=useState('');
 useEffect(()=>{try{let c=JSON.parse(localStorage.getItem('sl.connection'));if(!c&&process.env.NEXT_PUBLIC_SUPABASE_URL)c={url:process.env.NEXT_PUBLIC_SUPABASE_URL,key:process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY};if(c)setConfig(c)}catch{}},[]);
 useEffect(()=>{if(!config)return;try{const client=createClient(config.url,config.key);setDb(client);client.auth.getSession().then(r=>setSession(r.data.session));const {data:listener}=client.auth.onAuthStateChange((event,s)=>{setSession(s);if(event==='SIGNED_OUT'){setRole(null);setTenant(null);setData({});setStats(null)}});return()=>{listener.subscription.unsubscribe();client.removeAllChannels()}}catch(e){setError(e.message)}},[config]);
 const refresh=useCallback(async()=>{if(!db||!session)return;setLoading(true);try{
  const [a,m]=await Promise.all([db.from('sl_platform_admins').select('user_id').eq('user_id',session.user.id),db.from('sl_memberships').select('*').eq('user_id',session.user.id)]);if(a.error)throw a.error;if(m.error)throw m.error;
  const actual=a.data.length?'platform':m.data.length?'company':'customer';setRole(actual);setMemberships(m.data);
  let w=actual==='company'?(m.data.find(x=>x.workspace_id===tenant)||m.data[0])?.workspace_id:null;
  if(actual==='company'&&w!==tenant)setTenant(w);
  const tables=['workspaces','profiles','clients','orders','shipments','tracking_events','notifications','audit','test_runs','services','drivers','facilities','pickups','addresses','plans','subscriptions','invoices','payments','billing_payments','tickets','reviews','locations','settings','commissions','platform_audit'];
  const scoped=new Set(['clients','orders','shipments','tracking_events','notifications','audit','test_runs','drivers','facilities','pickups','subscriptions','invoices','payments','billing_payments','tickets','commissions']);
  const response=await Promise.all(tables.map(t=>{let q=db.from('sl_'+t).select('*').order('created_at',{ascending:false}).limit(100);if(w&&scoped.has(t))q=q.eq('workspace_id',w);if(t==='profiles')q=q.eq('id',session.user.id);return q}));
  const failed=response.find(r=>r.error);if(failed)throw failed.error;
  const next=Object.fromEntries(tables.map((t,i)=>[t,response[i].data]));next.memberships=m.data;setData(next);
  const r=await db.rpc('sl_dashboard',{w});if(r.error)throw r.error;setStats(r.data);
 }catch(e){setError(e.message+' — Check that the SaaS migration is installed.')}finally{setLoading(false)}},[db,session,tenant]);
 useEffect(()=>{if(session)refresh()},[refresh]);
 useEffect(()=>{if(!db||!session)return;const timer=setInterval(refresh,20000);const ch=db.channel('saas-updates').on('postgres_changes',{event:'*',schema:'public'},()=>refresh()).subscribe();return()=>{clearInterval(timer);db.removeChannel(ch)}},[db,session,refresh]);
 function flash(message){setNotice(message);setTimeout(()=>setNotice(''),5000)}
 async function mutate(fn,message){setBusy(true);setError('');try{const r=await fn();if(r.error)throw r.error;if(Array.isArray(r.data)&&!r.data.length)throw Error('No records changed. Access may be denied or the record may have changed.');await refresh();if(message)flash(message);return r.data??true}catch(e){setError(e.message);return false}finally{setBusy(false)}}
 async function connect(url,key){const u=new URL(url);if(u.protocol!=='https:')throw Error('Use an HTTPS Supabase project URL.');if(!key.startsWith('sb_publishable_')){let p;try{p=JSON.parse(atob(key.split('.')[1].replace(/-/g,'+').replace(/_/g,'/')))}catch{throw Error('Use a Supabase publishable key or legacy anon key.')}if(p.role!=='anon')throw Error('Secret and service-role keys are never accepted.');}if(db)await db.auth.signOut();const c={url:u.origin,key};localStorage.setItem('sl.connection',JSON.stringify(c));setData({});setStats(null);setConfig(c);setError('');}
 const company=(data.workspaces||[]).find(w=>w.id===tenant);const member=memberships.find(m=>m.workspace_id===tenant);const staff=role==='platform'||role==='company'&&company?.status==='active'&&['admin','operator'].includes(member?.role);
 return {config,db,session,role,memberships,tenant,setTenant,data,stats,loading,error,setError,busy,notice,flash,refresh,mutate,connect,company,staff,member};
}
