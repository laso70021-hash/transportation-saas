import {useState} from 'react';
import {Link,Navigate} from 'react-router-dom';
import {LockKeyhole} from 'lucide-react';
import {useApi} from '../lib/api';
import {DataForm} from '../components/Forms';
import {Loading,ErrorState} from '../components/Empty';
import {f} from '../lib/modules';

export function PasswordSetup() {
  const api=useApi();const [saved,setSaved]=useState(false);
  if(!api.authReady)return <Loading/>;
  if(saved)return <Navigate to="/access" replace/>;
  return <main className="access-page"><section className="panel"><LockKeyhole size={32}/><h1>Set your own password</h1>
    {!api.session?<><p>Open the secure link in your invitation email to activate this account. If your link has expired, request a new password link.</p><Link to="/forgot-password">Request a password link</Link><p><Link to="/login">Back to sign in</Link></p></>:<>
      <p>{api.session.user.email} · Choose a password before opening your assigned dashboard.</p>
      <DataForm fields={[f('password','New password','password'),f('confirmation','Confirm new password','password')]} label="Save password & open my dashboard" submit={async values=>{
        const password=String(values.password);if(password.length<12)throw new Error('Use at least 12 characters for your password.');if(password!==values.confirmation)throw new Error('The passwords do not match.');
        const response=await api.db!.auth.updateUser({password});if(response.error)throw response.error;
        const identity=await api.identity.refetch();if(identity.error)throw identity.error;if(identity.data?.mustChangePassword)throw new Error('Password setup has not completed. Refresh and try again.');
        api.setRecoveryMode(false);setSaved(true);
      }}/>
    </>}
  </section></main>;
}

export function ForgotPassword() {
  const api=useApi();const [sent,setSent]=useState(false);
  return <main className="access-page"><section className="panel"><LockKeyhole size={32}/><h1>Request a password link</h1><p>We will email a secure link so you can choose a new password.</p>
    {!api.db?<ErrorState error={new Error('Password recovery is temporarily unavailable. Please try again later or contact support.')}/>:<DataForm fields={[f('email','Account email','email')]} label="Email password link" submit={async values=>{
      const r=await api.db!.auth.resetPasswordForEmail(String(values.email),{redirectTo:window.location.origin+'/set-password'});if(r.error)throw r.error;setSent(true);
    }}/>}{sent&&<div className="success-banner">If this email has an account, a password link has been requested. Check your inbox.</div>}<Link to="/login">Back to sign in</Link>
  </section></main>;
}
