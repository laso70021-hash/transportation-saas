import {createOfflineFetch,offlineNow,storedSession} from './offline';
import{createClient,type SupabaseClient}from'@supabase/supabase-js';
const clients=new Map<string,SupabaseClient>();
export function projectClient(url:string,key:string){const identity=url+'|'+key;let client=clients.get(identity);if(!client){client=createClient(url,key,{global:{fetch:createOfflineFetch(url)}});const liveSession=client.auth.getSession.bind(client.auth);client.auth.getSession=async()=>offlineNow()?{data:{session:storedSession(url)},error:null}:liveSession();clients.set(identity,client)}return client}
