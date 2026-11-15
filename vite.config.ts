import {defineConfig} from 'vite';
import react from '@vitejs/plugin-react';
import tailwindcss from '@tailwindcss/vite';
import fs from 'node:fs';
import {createHash} from 'node:crypto';
const offlineShell={name:'swahivo-offline-shell',closeBundle(){if(!fs.existsSync('dist/index.html'))return;const files=fs.readdirSync('dist/assets').filter(f=>!f.endsWith('.map')).map(f=>'/assets/'+f);const version=createHash('sha256').update(fs.readFileSync('dist/index.html')).digest('hex').slice(0,12);const source=fs.readFileSync('public/sw.js','utf8').replace('__BUILD_ID__',version).replace('/*__BUILD_ASSETS__*/[]',JSON.stringify(files));fs.writeFileSync('dist/sw.js',source)}};
export default defineConfig({plugins:[react(),tailwindcss(),offlineShell],build:{outDir:'dist',chunkSizeWarningLimit:1500},server:{host:'0.0.0.0'},preview:{host:'0.0.0.0',port:5173,strictPort:true}});
