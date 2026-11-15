import {createClient} from 'https://esm.sh/@supabase/supabase-js@2.80.0';

Deno.serve(async request => {
  const url=Deno.env.get('SUPABASE_URL');
  const serviceKey=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const publicKey=Deno.env.get('SUPABASE_ANON_KEY');
  const origin=request.headers.get('origin');
  const headers:Record<string,string>={'Content-Type':'application/json','Vary':'Origin'};
  const reply=(body:unknown,status=200)=>new Response(JSON.stringify(body),{status,headers});
  if(!url||!serviceKey||!publicKey)return reply({error:'Invitation service is not configured'},503);
  const service=createClient(url,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const setting=await service.from('sl_settings').select('value').eq('name','app_url').maybeSingle();
  let appUrl=Deno.env.get('APP_ORIGIN')||setting.data?.value||origin||'';
  try {const parsed=new URL(appUrl);appUrl=(parsed.protocol==='https:'||parsed.protocol==='http:'&&['localhost','127.0.0.1','[::1]'].includes(parsed.hostname))?parsed.origin:'';} catch {appUrl='';}
  let localOrigin=false;
  try {const parsed=new URL(origin||'');localOrigin=['localhost','127.0.0.1','[::1]'].includes(parsed.hostname);} catch { /* No browser origin. */ }
  if(origin&&origin!==appUrl&&!localOrigin)return reply({error:'Origin is not permitted'},403);
  if(origin)Object.assign(headers,{'Access-Control-Allow-Origin':origin,'Access-Control-Allow-Headers':'authorization,apikey,content-type,x-client-info','Access-Control-Allow-Methods':'POST,OPTIONS'});
  if(request.method==='OPTIONS')return new Response(null,{status:204,headers});
  if(request.method!=='POST')return reply({error:'POST required'},405);
  const authorization=request.headers.get('authorization');
  if(!authorization?.startsWith('Bearer '))return reply({error:'Sign in required'},401);
  const token=authorization.slice(7);
  const auth=await service.auth.getUser(token);
  if(auth.error||!auth.data.user)return reply({error:'Invalid session'},401);
  const caller=createClient(url,publicKey,{global:{headers:{Authorization:authorization}},auth:{persistSession:false,autoRefreshToken:false}});
  const [admin,members]=await Promise.all([
    caller.from('sl_platform_admins').select('user_id').eq('user_id',auth.data.user.id),
    caller.from('sl_memberships').select('workspace_id,role').eq('user_id',auth.data.user.id).eq('role','admin')
  ]);
  if(admin.error||members.error||(!admin.data?.length&&!members.data?.length))return reply({error:'Administrator access required'},403);
  let body;
  try {body=await request.json();} catch {return reply({error:'Valid JSON required'},400);}
  if(body.action==='status')return reply({app_url:appUrl,email_ready:!!appUrl,whatsapp_mode:'web',password_setup:true});
  if(body.action!=='invite')return reply({error:'Unknown invitation action'},400);
  if(!appUrl)return reply({error:'Open the app from a valid HTTPS address or localhost before sending invitations'},409);
  if(typeof body.email!=='string'||typeof body.name!=='string'||typeof body.role!=='string'||typeof body.request_key!=='string'||body.email.length>254||body.name.length>120||typeof(body.phone||'')!=='string'||(body.phone||'').length>40)return reply({error:'Invalid invitation details'},400);
  const prepared=await caller.rpc('sl_prepare_account_invitation',{
    p_workspace:body.workspace_id||null,p_email:body.email,p_name:body.name,
    p_phone:body.phone||'',p_role:body.role,p_request_key:body.request_key
  });
  if(prepared.error)return reply({error:prepared.error.message},403);
  const invitation=prepared.data;
  if(invitation.email_status==='sent')return reply({invitation_id:invitation.id,email_sent:true,login_url:appUrl+'/access',reused:true});
  try {
    let userId=invitation.user_id;
    if(!userId) {
      const invited=await service.auth.admin.inviteUserByEmail(invitation.email,{
        redirectTo:appUrl+'/set-password',data:{display_name:invitation.display_name}
      });
      if(invited.error||!invited.data.user)throw invited.error||new Error('The account could not be invited');
      userId=invited.data.user.id;
      const assigned=await service.rpc('sl_complete_account_invitation',{p_invitation:invitation.id,p_user:userId});
      if(assigned.error)throw assigned.error;
    } else {
      const assigned=await service.rpc('sl_complete_account_invitation',{p_invitation:invitation.id,p_user:userId});
      if(assigned.error)throw assigned.error;
      const sent=await service.auth.resetPasswordForEmail(invitation.email,{redirectTo:appUrl+'/set-password'});
      if(sent.error)throw sent.error;
    }
    const saved=await service.from('sl_account_invitations').update({email_status:'sent',delivery_error:null,sent_at:new Date().toISOString(),user_id:userId}).eq('id',invitation.id);
    if(saved.error)throw saved.error;
    return reply({invitation_id:invitation.id,email_sent:true,login_url:appUrl+'/access'});
  } catch(error) {
    const message=error instanceof Error?error.message:typeof error==='object'&&error!==null&&'message' in error?String(error.message):'Invitation delivery failed';
    await service.from('sl_account_invitations').update({email_status:'failed',delivery_error:message.slice(0,500)}).eq('id',invitation.id);
    return reply({error:message,invitation_id:invitation.id,email_sent:false},502);
  }
});
