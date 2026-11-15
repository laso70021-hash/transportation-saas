import {createContext,useContext,useEffect,useState,type ReactNode} from 'react';
import {useApi} from '../lib/api';
const Context=createContext<{view:'modern'|'legacy';setView:(view:'modern'|'legacy')=>void}>({view:'modern',setView:()=>{}});
export function WorkspacePreferences({children}:{children:ReactNode}){const api=useApi(),key='sl.dashboard-view.'+(api.session?.user.id||'guest'),[view,setViewState]=useState<'modern'|'legacy'>('modern');useEffect(()=>{setViewState(localStorage.getItem(key)==='legacy'?'legacy':'modern')},[key]);function setView(value:'modern'|'legacy'){localStorage.setItem(key,value);setViewState(value)}return <Context.Provider value={{view,setView}}>{children}</Context.Provider>}
export const useWorkspacePreferences=()=>useContext(Context);
