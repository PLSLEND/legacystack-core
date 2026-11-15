// Bundles the app for GitHub Pages: frontend/src -> docs/app.js. Run: node build.mjs [chainId]
import { build } from 'esbuild';
import { copyFileSync, existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
const chainId = process.argv[2] || '11155111';
await build({ entryPoints: ['src/app.js'], bundle: true, minify: true, format: 'iife', target: ['es2022'], outfile: '../docs/app.js', legalComments: 'none', logLevel: 'info' });
const src = `../deployments/${chainId}.json`;
if (existsSync(src)) { copyFileSync(src, '../docs/deployment.json'); console.log(`deployment.json <- deployments/${chainId}.json`); }
else console.log(`no deployments/${chainId}.json yet; docs/deployment.json left as is`);

// The machine-readable brief for agents and integrators: constants, invariants, risks and the current addresses
if (existsSync(src)) {
  const d = JSON.parse(readFileSync(src, 'utf8'));
  const brief = JSON.parse(readFileSync('agent-brief.json', 'utf8'));
  brief.deployment = { chainId: d.chainId, network: d.chainId === 11155111 ? 'sepolia' : String(d.chainId), status: d.chainId === 11155111 ? 'testnet, unaudited; nothing here has value' : 'see agent.md', addresses: d };
  brief.generatedAt = new Date().toISOString().slice(0, 10);
  mkdirSync('../docs/.well-known', { recursive: true });
  writeFileSync('../docs/.well-known/legacystack.json', JSON.stringify(brief, null, 2) + '\n');
  console.log('.well-known/legacystack.json <- agent-brief.json + deployment');
}
