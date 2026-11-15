import {useState} from 'react';
import {Link,useNavigate} from 'react-router-dom';
import {useQuery} from '@tanstack/react-query';
import {Users,Mail,MessageCircle,ExternalLink,Search,ShieldCheck} from 'lucide-react';
import {useApi} from '../lib/api';
import {roleDefinitions,roleInfo,dashboardForRole,type AccountRole,isAccountRole} from '../lib/roles';
import {DataForm} from '../components/Forms';
import {Button} from '../components/ui/button';
import {Empty,ErrorState,Loading,Badge} from '../components/Empty';
import {f} from '../lib/modules';

type Account={id:string;email:string;display_name:string;phone:string|null;role:AccountRole;company:string|null;workspace_id:string|null;must_change_password:boolean;confirmed:boolean;last_sign_in_at:string|null;assignments:{role:string;company:string;workspace_id:string}[]};
type Invitation={id:string;email:string;display_name:string;phone:string|null;role:string;workspace_id:string|null;email_status:string;delivery_error:string|null;created_at:string};
type DeliveryStatus={app_url:string;email_ready:boolean;whatsapp_mode:string};

function whatsappLink(phone:string,message:string) {
  const digits=phone.replace(/\D/g,'');
  return 'https://web.whatsapp.com/send?phone='+digits+'&text='+encodeURIComponent(message);
}

export function AccountManagement() {
  const api=useApi(),navigate=useNavigate();
  const [search,setSearch]=useState(''),[roleFilter,setRoleFilter]=useState('all');
  const [requestKey,setRequestKey]=useState(()=>crypto.randomUUID());
  const [result,setResult]=useState<{email:string;phone:string;role:string;name:string;login_url:string}|null>(null);
  
  const platform=!!api.identity.data?.isPlatformAdmin;
  const companies=(api.identity.data?.ownerWorkspaces||[]).filter(w=>platform||api.identity.data?.memberships.some(m=>m.workspace_id===w.id&&m.role==='admin'));
  const directory=useQuery({queryKey:['account-directory',api.session?.user.id],queryFn:async()=>{
    const r=await api.db!.rpc('sl_account_directory');if(r.error)throw new Error(r.error.message);return r.data as Account[];
  }});
  const invitations=useQuery({queryKey:['account-invitations',api.session?.user.id],queryFn:async()=>{
    const r=await api.db!.from('sl_account_invitations').select('*').order('created_at',{ascending:false}).limit(50);
    if(r.error)throw new Error(r.error.message);return r.data as Invitation[];
  }});
  const delivery=useQuery({queryKey:['invitation-delivery-status',api.session?.user.id],retry:false,queryFn:async()=>{
    const r=await api.db!.functions.invoke('invite-account',{body:{action:'status'}});
    if(r.error)throw new Error('Invitation service: '+r.error.message);return r.data as DeliveryStatus;
  }});
  const accounts=directory.data||[];
  const filtered=accounts.filter(a=>(roleFilter==='all'||a.role===roleFilter||a.assignments.some(m=>m.role===roleFilter))&&[a.display_name,a.email,a.company,roleInfo(a.role).title].join(' ').toLowerCase().includes(search.toLowerCase()));
  function preview(role:string,workspace?:string|null,person?:string) {
    if(!platform||!isAccountRole(role))return;
    api.setPreviewRole(role);api.setPreviewAccount(person||null);if(workspace)api.setWorkspace(workspace);navigate(dashboardForRole(role));
  }
  async function invite(v:Record<string,unknown>) {
    if(v.role!=='customer'&&(!v.workspace_id||v.workspace_id==='none'))throw new Error('Register or select a company before assigning a staff role.');
    const phone=String(v.phone||'');
    if(phone&&!/^\+[1-9]\d{7,14}$/.test(phone))throw new Error('Use the international WhatsApp number, for example +255700000000.');
    const r=await api.db!.functions.invoke('invite-account',{body:{action:'invite',name:v.name,email:v.email,phone,role:v.role,workspace_id:v.workspace_id==='none'?null:v.workspace_id,request_key:requestKey}});
    if(r.error){let message=r.error.message;try {const payload=await r.error.context?.json();if(payload?.error)message=payload.error;}catch{/* Keep the transport error. */}await invitations.refetch();throw new Error(message);}
    if(!r.data?.email_sent)throw new Error(r.data?.error||'Email was not sent.');
    setResult({email:String(v.email),phone,role:String(v.role),name:String(v.name),login_url:window.location.origin+'/access'});
    setRequestKey(crypto.randomUUID());await Promise.all([directory.refetch(),invitations.refetch()]);
  }
  function message(name:string,role:string,link:string) {return `Hello ${name}, you have been invited to Swahivo Logistics as ${roleInfo(role).title}. Open the invitation email to set your password, then sign in here: ${link}`;}
  return <>
    <div className="page-heading"><div><h1>Accounts & Role Dashboards</h1><p>{platform?'Every registered account, its company, assigned role and first-login status.':'Accounts and invitations for the companies you administer.'}</p></div><Badge value={accounts.length+' accounts'}/></div>
    <section className="panel"><div className="panel-title"><h2><ShieldCheck size={20}/>Roles & dashboards</h2><span>Choose a role to filter accounts</span></div>
      <div className="role-catalog">{roleDefinitions.filter(r=>platform||r.id!=='platform_admin').map(role=><article key={role.id} className={roleFilter===role.id?'selected':''}>
        <button className="role-filter" onClick={()=>setRoleFilter(roleFilter===role.id?'all':role.id)}><strong>{role.title}</strong><Badge value={accounts.filter(a=>a.role===role.id||a.assignments.some(m=>m.role===role.id)).length}/></button>
        <p>{role.description}</p>{platform&&<Button size="sm" variant="outline" onClick={()=>preview(role.id,api.workspace)}>Preview dashboard <ExternalLink size={12}/></Button>}
      </article>)}</div>
    </section>
    <section className="panel"><div className="panel-title"><h2><Users size={20}/>Account directory</h2><Button variant="outline" onClick={()=>void directory.refetch()}>Refresh accounts</Button></div>
      <div className="filter-bar"><label className="search-field"><Search size={17}/><input aria-label="Search accounts" placeholder="Search name, email, company or role…" value={search} onChange={e=>setSearch(e.target.value)}/></label><select aria-label="Filter account role" value={roleFilter} onChange={e=>setRoleFilter(e.target.value)}><option value="all">All roles</option>{roleDefinitions.map(r=><option key={r.id} value={r.id}>{r.title}</option>)}</select></div>
      {directory.error?<ErrorState error={directory.error}/>:directory.isPending?<Loading/>:!filtered.length?<Empty title="No accounts for this filter" description="New staff and customer accounts appear here after registration or invitation. Role previews do not create accounts."/>:<div className="table-wrap"><table><thead><tr><th>Person & email</th><th>Role / dashboard</th><th>Company</th><th>Sign-in status</th><th>Action</th></tr></thead><tbody>{filtered.map(a=><tr key={a.id}>
        <td><strong>{a.display_name}</strong><small className="cell-subtitle">{a.email}</small>{a.phone&&<small className="cell-subtitle">{a.phone}</small>}</td>
        <td><Badge value={roleInfo(a.role).title}/><small className="cell-subtitle">{a.assignments.filter(m=>m.role!==a.role).map(m=>roleInfo(m.role).title).join(' · ')}</small></td>
        <td>{a.company|| (a.role==='platform_admin'?'Platform':'Independent customer')}{api.identity.data?.ownerWorkspaces.find(w=>w.id===a.workspace_id)?.provider_kind==='individual'&&<small className="cell-subtitle">Individual provider · Enterprise dashboard</small>}{a.assignments.length>1&&<small className="cell-subtitle">{a.assignments.map(m=>m.company).filter((v,i,list)=>list.indexOf(v)===i).join(' · ')}</small>}</td>
        <td>{a.must_change_password?'Password setup required':a.confirmed?'Ready to sign in':'Email confirmation pending'}<small className="cell-subtitle">{a.last_sign_in_at?'Last sign-in: '+new Date(a.last_sign_in_at).toLocaleString():'Has not signed in'}</small></td>
        <td>{platform?<Button size="sm" variant="outline" onClick={()=>preview(a.role,a.workspace_id,a.id)}>Preview role</Button>:<span>Company account</span>}</td>
      </tr>)}</tbody></table></div>}
    </section>
    <section className="panel"><h2><Mail size={20}/>Invite a person & assign their dashboard</h2><p>Enter their details and choose a company and role. They receive an email invitation, set their own password, and land on their assigned dashboard when signing in.</p>
      {delivery.error&&<ErrorState error={delivery.error}/>}
      <div className="setup-notice"><strong>Invitation links use this app’s address automatically</strong><p>Share link: {window.location.origin}/access</p>{['localhost','127.0.0.1','[::1]'].includes(window.location.hostname)&&<p>This address works only on this computer. When you publish the app, sharing automatically uses its public address.</p>}</div>
      <DataForm key={requestKey} fields={[f('name','Full name'),f('email','Email address','email'),f('phone','WhatsApp number (international format)','text',{required:false}),f('workspace_id','Company / institute','select',{options:[...(platform?[{value:'none',label:'Independent customer (no company)'}]:[]),...companies.map(w=>({value:w.id,label:w.name}))]}),f('role','Assigned role','select',{options:roleDefinitions.filter(r=>r.id!=='platform_admin').map(r=>({value:r.id,label:r.title}))})]} defaults={{workspace_id:api.workspace||(platform?'none':''),role:'customer'}} submit={invite} label="Create account & email invitation"/>
      {!companies.length&&<p className="small-note">No company is registered yet. Company setup is available from the company administrator dashboard.</p>}
      {result&&<div className="success-banner"><span>Invitation emailed to <strong>{result.email}</strong>. Their dashboard is {roleInfo(result.role).title}.</span>{result.phone&&<a className="ui-button outline" target="_blank" rel="noopener noreferrer" href={whatsappLink(result.phone,message(result.name,result.role,result.login_url))}><MessageCircle size={16}/>Share on WhatsApp</a>}</div>}
      <p className="small-note">WhatsApp opens your linked browser session with the recipient and message filled in. Press Send there. Passwords and sign-in tokens are never shared in the WhatsApp message.</p>
    </section>
    <section className="panel"><h2>Recent invitations</h2>{invitations.error?<ErrorState error={invitations.error}/>:invitations.isPending?<Loading/>:!invitations.data?.length?<Empty title="No invitations sent yet" description="Each invitation records its account, role and email delivery result here."/>:<div className="table-wrap"><table><thead><tr><th>Recipient</th><th>Role</th><th>Email</th><th>WhatsApp Web</th><th>Details</th></tr></thead><tbody>{invitations.data.map(i=><tr key={i.id}><td>{i.display_name}<small className="cell-subtitle">{i.email}</small></td><td>{roleInfo(i.role).title}</td><td><Badge value={i.email_status}/></td><td>{i.phone&&i.email_status==='sent'?<a className="ui-button outline sm" target="_blank" rel="noopener noreferrer" href={whatsappLink(i.phone,message(i.display_name,i.role,window.location.origin+'/access'))}>Share on WhatsApp <MessageCircle size={13}/></a>:'—'}</td><td>{i.delivery_error||new Date(i.created_at).toLocaleString()}</td></tr>)}</tbody></table></div>}</section>
  </>;
}
