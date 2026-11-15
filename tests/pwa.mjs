import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';

const manifest=JSON.parse(fs.readFileSync('public/manifest.webmanifest','utf8'));
assert.equal(manifest.start_url,'/access');assert.equal(manifest.display,'standalone');
for(const icon of manifest.icons){const png=fs.readFileSync('public'+icon.src);const [width,height]=icon.sizes.split('x').map(Number);assert.equal(png.readUInt32BE(16),width);assert.equal(png.readUInt32BE(20),height)}
console.log('PASS PWA manifest opens the assigned dashboard and has valid installable PNG icons');
const handlers={};let networkFails=false;const cacheWrites=[];
const cache={match:async()=>null,put:async request=>cacheWrites.push(request.url),addAll:async files=>{for(const file of files)assert.ok(fs.existsSync(file==='/index.html'?'dist/index.html':'public'+file))}};
vm.runInNewContext(fs.readFileSync('public/sw.js','utf8'),{
  URL,self:{location:{origin:'https://logistics.example.test'},addEventListener:(name,fn)=>{handlers[name]=fn},clients:{claim:async()=>{}},skipWaiting:()=>{}},
  caches:{open:async()=>cache,keys:async()=>[],delete:async()=>true,match:async path=>({offline:path})},
  fetch:async()=>{if(networkFails)throw Error('Offline');return {ok:true,type:'basic',clone:()=>({cached:true})}}
});
let installation;handlers.install({waitUntil:promise=>{installation=promise}});await installation;
async function request(path,{method='GET',authorization=false,mode='cors'}={}) {
  let result;handlers.fetch({request:{url:new URL(path,'https://logistics.example.test').href,method,mode,headers:{has:name=>name==='authorization'&&authorization}},respondWith:promise=>{result=promise}});return result?await result:undefined;
}
assert.equal(await request('/rest/v1/sl_shipments'),undefined);
assert.equal(await request('https://backend.supabase.co/auth/v1/user'),undefined);
assert.equal(await request('/functions/v1/invite-account',{method:'POST'}),undefined);
assert.equal(await request('/assets/private.json',{authorization:true}),undefined);
await request('/assets/public-app.js');assert.equal(cacheWrites.length,1);
console.log('PASS Service worker caches public assets and bypasses APIs, writes and authenticated requests');
networkFails=true;assert.deepEqual(await request('/driver/dashboard',{mode:'navigate'}),{offline:'/index.html'});
console.log('PASS Offline navigation opens the cached app shell; private data stays outside the service-worker cache');
