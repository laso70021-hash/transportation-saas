import {Package,LoaderCircle,AlertTriangle} from 'lucide-react';
export function Empty({title='No records yet',description='Records will appear after they are saved to your connected Supabase project.'}:{title?:string;description?:string}){return <div className="ops-empty"><span><Package size={27}/></span><h3>{title}</h3><p>{description}</p></div>}
export function Loading(){return <div className="ops-empty"><LoaderCircle className="spin" size={26}/><h3>Loading authorized records…</h3></div>}
export function ErrorState({error}:{error:unknown}){return <div className="error-banner" role="alert"><AlertTriangle size={17}/>{error instanceof Error?error.message:typeof error==='object'&&error!==null&&'message' in error?String(error.message):String(error)}</div>}
export function Badge({value}:{value:unknown}){return <span className={'ops-badge '+String(value||'').toLowerCase().replaceAll(' ','-')}>{String(value??'—')}</span>}
