import {BookingComments} from './BookingComments';
import {useRef,useState} from 'react';
import {Link} from 'react-router-dom';
import {useQuery} from '@tanstack/react-query';
import {User,Package,ArrowRight,RefreshCw} from 'lucide-react';
import {useApi,money} from '../lib/api';
import {useCurrentRole} from '../components/Shell';
import {DataForm} from '../components/Forms';
import {Button} from '../components/ui/button';
import {Badge,ErrorState,Loading} from '../components/Empty';
import {f} from '../lib/modules';
import type {Row} from '../lib/types';

const human=(value:unknown)=>String(value||'').replaceAll('_',' ').replace(/\b\w/g,c=>c.toUpperCase());
const display=(value:unknown)=>value===null||value===undefined||value===''?'Not provided':String(value);
function Details({items}:{items:[string,unknown][]}) {
  return <dl className="booking-detail-list">{items.map(([title,value])=><div key={title}><dt>{title}</dt><dd>{display(value)}</dd></div>)}</dl>;
}

export function BookingRequestDetails({row,onSaved,statusOnly=false,initialAction=''}:{row:Row;onSaved:()=>void;statusOnly?:boolean;initialAction?:string}) {
  const api=useApi(),role=useCurrentRole();
  const [action,setAction]=useState(initialAction),[success,setSuccess]=useState('');const statusSelect=useRef<HTMLSelectElement>(null);
  const status=String(row.status),customer=row.customer_id===api.session?.user.id;
  const staff=['platform_admin','admin','operator','dispatcher'].includes(role);
  const platform=!!api.identity.data?.isPlatformAdmin&&role==='platform_admin';
  const terminal=['cancelled','shipment_created'].includes(status);
  const canAssign=platform&&['requested','assigned','quoted','declined'].includes(status);
  const canRespond=staff&&!!row.workspace_id&&['assigned','quoted'].includes(status);
  const canAccept=customer&&status==='quoted'&&['customer','platform_admin'].includes(role);
  const canCreate=staff&&status==='accepted';
  const canCancel=(platform||customer&&role==='customer')&&!terminal;
  const actions=[...(canAssign?[{id:'assign',label:'Assign provider → Assigned'}]:[]),...(canRespond?[{id:'quote',label:'Send quotation → Quoted'},{id:'decline',label:'Decline request → Declined'}]:[]),...(canAccept?[{id:'accept',label:'Accept quotation → Accepted'}]:[]),...(canCreate?[{id:'shipment',label:'Create shipment → Shipment created'}]:[]),...(canCancel?[{id:'cancel',label:'Cancel request → Cancelled'}]:[])];
  const selected=actions.some(a=>a.id===action)?action:actions[0]?.id||'';
  const companies=api.identity.data?.ownerWorkspaces||[];
  const provider=companies.find(w=>w.id===row.workspace_id);
  const eligible=useQuery({queryKey:['eligible',row.id],enabled:canAssign&&selected==='assign',queryFn:async()=>{
    const r=await api.db!.rpc('sl_eligible_providers',{booking:row.id});if(r.error)throw new Error(r.error.message);return r.data as Row[];
  }});
  const quotations=useQuery({queryKey:['booking-quotes',row.id,row.updated_at],enabled:!statusOnly,queryFn:async()=>{
    const r=await api.db!.from('sl_quotations').select('*').eq('booking_id',row.id).order('created_at',{ascending:false});if(r.error)throw new Error(r.error.message);return r.data as Row[];
  }});
  async function save(name:string,args:Record<string,unknown>,message:string) {await api.rpc(name,{booking:row.id,...args});setSuccess(message);onSaved();}
  return <>
    {!statusOnly&&<><div className="booking-status-summary"><span>Current request status <Badge value={status}/></span>{actions.length>0&&<Button variant="outline" onClick={()=>{statusSelect.current?.scrollIntoView({behavior:'smooth',block:'center'});statusSelect.current?.focus({preventScroll:true})}}>Update status <RefreshCw size={15}/></Button>}</div>
    <div className="booking-detail-parties">
      <section className="booking-detail-card"><h3><User size={17}/>Sender information</h3><Details items={[
        ['Sender name',row.sender_name],['Sender phone',row.sender_phone],['Origin city',row.origin_city],['Pickup address',row.pickup_address]
      ]}/></section>
      <section className="booking-detail-card"><h3><User size={17}/>Receiver information</h3><Details items={[
        ['Receiver name',row.recipient_name],['Receiver phone',row.recipient_phone],['Destination city',row.destination_city],['Delivery address',row.delivery_address]
      ]}/></section>
    </div>
    <section className="booking-detail-card"><h3><Package size={17}/>Cargo & request information</h3><Details items={[
      ['Service type',row.service_type],['Weight (kg)',row.weight_kg],['Cargo description',row.description],['Assigned provider',provider?.name||(row.workspace_id?'Assigned provider':'Not assigned yet')],
      ['Submitted',row.created_at?new Date(row.created_at).toLocaleString():null],['Last updated',row.updated_at?new Date(String(row.updated_at)).toLocaleString():null]
    ]}/></section>
    {row.shipment_details&&Object.keys(row.shipment_details as object).length>0&&<section className="booking-detail-card"><h3>Additional shipment information</h3><Details items={Object.entries(row.shipment_details as Record<string,unknown>).map(([key,value])=>[human(key),typeof value==='boolean'?(value?'Yes':'No'):value])}/></section>}
    <BookingComments booking={row.id}/></>}
    <section className="booking-status-controls"><div className="panel-title"><h3><RefreshCw size={17}/>Update request status</h3><Badge value={status}/></div>
      {!!row.reason&&<p><strong>Latest reason:</strong> {String(row.reason)}</p>}
      {success&&<div className="success-banner" role="status">{success}</div>}
      {actions.length?<><label>Next status / action<select ref={statusSelect} aria-label="Next request status" value={selected} onChange={e=>{setAction(e.target.value);setSuccess('')}}>{actions.map(a=><option key={a.id} value={a.id}>{a.label}</option>)}</select></label>
        {selected==='assign'&&<><p>Assigning an approved provider changes this request to Assigned.</p>{eligible.isPending?<Loading/>:eligible.error?<ErrorState error={eligible.error}/>:!eligible.data?.length?<><div className="setup-notice"><strong>No eligible provider is available</strong><p>A company must be active, verified and cover this request’s route and service before it can be assigned.</p></div><div className="button-row"><Link className="ui-button outline" to="/admin/providers">Manage provider companies</Link></div></>:<DataForm key={row.id+selected+row.updated_at} fields={[f('provider','Provider','select',{options:eligible.data.map(p=>({value:p.id,label:String(p.name)}))})]} submit={async values=>save('sl_assign_booking',{provider:values.provider},'Provider assigned. Request status is now Assigned.')} label="Assign provider & update status"/>}</>}
        {selected==='quote'&&<DataForm key={row.id+selected} fields={[f('amount','Quoted amount (TZS)','number',{min:0}),f('transit_days','Transit days','number',{min:1}),f('note','Quotation notes','textarea',{required:false})]} submit={async values=>save('sl_respond_booking',{decision:'quoted',...values},'Quotation saved. Request status is now Quoted.')} label="Send quotation & set Quoted"/>}
        {selected==='decline'&&<DataForm key={row.id+selected} fields={[f('note','Reason for declining','textarea')]} submit={async values=>save('sl_respond_booking',{decision:'declined',note:values.note},'Request status is now Declined.')} label="Set request to Declined"/>}
        {selected==='accept'&&<DataForm fields={[]} submit={async()=>save('sl_accept_quote',{},'Quotation accepted. Request status is now Accepted.')} label="Accept quotation & update status"/>}
        {selected==='shipment'&&<><p>Create the linked shipment from this accepted quotation. The request then changes to Shipment created.</p><Link className="ui-button primary" to={'/provider/create-shipment?booking='+row.id}>Create linked shipment <ArrowRight size={16}/></Link></>}
        {selected==='cancel'&&<DataForm key={row.id+selected} fields={[f('reason','Cancellation reason','textarea')]} description="Cancellation is available before a shipment has been created." submit={async values=>save('sl_cancel_booking',{reason:values.reason},'Request status is now Cancelled.')} label="Cancel request & update status"/>}
      </>:<p>{status==='requested'?'Awaiting platform assignment to a qualified provider.':status==='quoted'?'Waiting for the customer to accept the quotation.':status==='accepted'?'The provider can now create the linked shipment.':status==='declined'?'The platform administrator can reassign this request.':status==='shipment_created'?'A shipment has been created. Update delivery progress from the shipment record.':status==='cancelled'?'This request has been cancelled.':role==='viewer'?'This account can view request details; status changes require an authorized staff role.':'No status action is available for your role at this stage.'}</p>}
      
    </section>
    {!statusOnly&&<section className="booking-detail-card"><h3>Saved quotations</h3>{quotations.error?<ErrorState error={quotations.error}/>:quotations.isPending?<Loading/>:!quotations.data?.length?<p>No quotation has been submitted yet.</p>:quotations.data.map(quote=><div className="booking-saved-quote" key={quote.id}><strong>{money(quote.amount)} · {String(quote.transit_days)} days</strong><p>{display(quote.note)}</p><small>{quote.accepted_by_customer?'Accepted by customer':'Awaiting customer approval'}</small></div>)}</section>}
  </>;
}
