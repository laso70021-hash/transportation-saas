import {createContext,useContext,useEffect,useState,type ReactNode} from 'react';
import {Download,WifiOff,RefreshCw} from 'lucide-react';
import {Button} from './ui/button';
import {Modal} from './Forms';
type InstallPrompt=Event&{prompt:()=>Promise<void>;userChoice:Promise<{outcome:string}>};
const Context=createContext<{online:boolean;installed:boolean;prompt:InstallPrompt|null;waiting:ServiceWorker|null;clearPrompt:()=>void}|null>(null);
export function PwaProvider({children}:{children:ReactNode}) {
  const [online,setOnline]=useState(navigator.onLine),[prompt,setPrompt]=useState<InstallPrompt|null>(null);
  const [installed,setInstalled]=useState(()=>window.matchMedia('(display-mode: standalone)').matches);
  const [waiting,setWaiting]=useState<ServiceWorker|null>(null);
  useEffect(()=>{
    const connected=()=>setOnline(true),disconnected=()=>setOnline(false);
    const available=(e:Event)=>{e.preventDefault();setPrompt(e as InstallPrompt)};
    const installedEvent=()=>{setInstalled(true);setPrompt(null)};
    window.addEventListener('online',connected);window.addEventListener('offline',disconnected);
    window.addEventListener('beforeinstallprompt',available);window.addEventListener('appinstalled',installedEvent);const syncMessage=(e:MessageEvent)=>{if(e.data?.type==='SYNC_PENDING')window.dispatchEvent(new Event('online'))};navigator.serviceWorker?.addEventListener('message',syncMessage);
    let active=true;
    if(import.meta.env.PROD&&'serviceWorker' in navigator)void navigator.serviceWorker.register('/sw.js').then(registration=>{
      if(!active)return;if(registration.waiting)setWaiting(registration.waiting);
      registration.addEventListener('updatefound',()=>{const worker=registration.installing;worker?.addEventListener('statechange',()=>{if(active&&worker.state==='installed'&&navigator.serviceWorker.controller)setWaiting(worker)})});
    }).catch(()=>{/* Records still use the network when offline support is unavailable. */});
    return()=>{active=false;window.removeEventListener('online',connected);window.removeEventListener('offline',disconnected);window.removeEventListener('beforeinstallprompt',available);window.removeEventListener('appinstalled',installedEvent);navigator.serviceWorker?.removeEventListener('message',syncMessage)};
  },[]);
  return <Context.Provider value={{online,installed,prompt,waiting,clearPrompt:()=>setPrompt(null)}}>{children}</Context.Provider>;
}
export function PwaStatus() {
  const status=useContext(Context);if(!status)return null;
  return <>{status.waiting&&<div className="pwa-status update" role="status"><RefreshCw size={17}/>An app update is ready.<Button size="sm" onClick={()=>{navigator.serviceWorker.addEventListener('controllerchange',()=>window.location.reload(),{once:true});status.waiting?.postMessage({type:'SKIP_WAITING'})}}>Update app</Button></div>}</>;
}
export function InstallApp() {
  const status=useContext(Context),[open,setOpen]=useState(false),[error,setError]=useState(''),[copied,setCopied]=useState(false);
  if(!status||status.installed)return null;
  const nativeInstall=(navigator as Navigator&{install?:()=>Promise<unknown>}).install;
  async function install(){setError('');try{if(status!.prompt){await status!.prompt.prompt();await status!.prompt.userChoice;status!.clearPrompt();return}if(nativeInstall){await nativeInstall.call(navigator);return}setOpen(true)}catch{setOpen(true);setError('Installation was not completed. Use your browser’s install menu or try again.')}}
  return <><Button variant="outline" className="install-app" onClick={()=>void install()}><Download aria-hidden="true" size={15}/><span>{status.prompt||nativeInstall?'Install app':'Install options'}</span></Button>{open&&<Modal title="Install on your device" close={()=>setOpen(false)}>
    {/iPhone|iPad|iPod/.test(navigator.userAgent)?<p>Open this app in Safari, tap Share, then Add to Home Screen.</p>:<><p>This browser has not offered a native installer. Open Swahivo in Chrome or Edge, then choose Install app from the address bar or browser menu.</p><p>On Android, choose Install app or Add to Home Screen.</p></>}
    <Button variant="outline" onClick={async()=>{try{await navigator.clipboard.writeText(window.location.origin);setCopied(true)}catch{setError('Copy the address from your browser address bar.')}}}>{copied?'Address copied':'Copy app address'}</Button>
    {error&&<div className="error-banner">{error}</div>}<p className="small-note">Downloaded records open offline. Supported changes and attachments sync when this app reconnects. First sign-in needs internet.</p>
  </Modal>}</>;
}
