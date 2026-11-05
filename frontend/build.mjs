// Bundles the app for GitHub Pages: frontend/src -> docs/app.js. Run: node build.mjs [chainId]
import { build } from 'esbuild';
import { copyFileSync, existsSync } from 'node:fs';
const chainId = process.argv[2] || '11155111';
await build({ entryPoints: ['src/app.js'], bundle: true, minify: true, format: 'iife', target: ['es2022'], outfile: '../docs/app.js', legalComments: 'none', logLevel: 'info' });
const src = `../deployments/${chainId}.json`;
if (existsSync(src)) { copyFileSync(src, '../docs/deployment.json'); console.log(`deployment.json <- deployments/${chainId}.json`); }
else console.log(`no deployments/${chainId}.json yet; docs/deployment.json left as is`);
