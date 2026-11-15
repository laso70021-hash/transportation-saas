// Only the shell and public assets enter this cache. Records use account-scoped IndexedDB.
const CACHE='swahivo-shell-__BUILD_ID__';
const BUILD_ASSETS=/*__BUILD_ASSETS__*/[];
const PUBLIC_FILES=['/index.html','/offline.html','/icon.svg','/icons/icon-192.png','/icons/icon-512.png','/icons/maskable-512.png','/manifest.webmanifest'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll([...PUBLIC_FILES,...BUILD_ASSETS]))));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('swahivo-')&&key!==CACHE).map(key=>caches.delete(key)))).then(()=>self.clients.claim())));
self.addEventListener('message',event=>{if(event.data?.type==='SKIP_WAITING')self.skipWaiting()});
self.addEventListener('sync',event=>{if(event.tag==='swahivo-outbox')event.waitUntil(self.clients.matchAll({type:'window'}).then(clients=>{for(const client of clients)client.postMessage({type:'SYNC_PENDING'})}))});
self.addEventListener('fetch',event=>{
  const request=event.request,url=new URL(request.url);
  if(request.method!=='GET'||url.origin!==self.location.origin||request.headers.has('authorization'))return;
  if(request.mode==='navigate'){event.respondWith(fetch(request).catch(async()=>await caches.match('/index.html')||await caches.match('/offline.html')));return;}
  if(!url.pathname.startsWith('/assets/')&&!PUBLIC_FILES.includes(url.pathname))return;
  event.respondWith(caches.open(CACHE).then(async cache=>{const saved=await cache.match(request);if(saved)return saved;const response=await fetch(request);if(response.ok&&response.type==='basic')await cache.put(request,response.clone());return response;}));
});
