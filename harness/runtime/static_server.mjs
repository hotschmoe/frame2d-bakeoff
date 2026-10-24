// The shared static server (SPEC 8.4), standalone.
//   node static_server.mjs --root <dir> [--port 8000] [--cache <dir>]   serve until killed
//   node static_server.mjs --root <dir> --manifest                      print {files:[{path,raw,br}],total_raw,total_br} and exit
import path from 'node:path';
import url from 'node:url';
import { startServer, precompress, manifestOf } from './web_common.mjs';

const args = Object.fromEntries(process.argv.slice(2).reduce((a, v, i, all) => {
  if (v.startsWith('--')) a.push([v.slice(2), all[i + 1] && !all[i + 1].startsWith('--') ? all[i + 1] : true]);
  return a;
}, []));
const here = path.dirname(url.fileURLToPath(import.meta.url));
const root = args.root;
if (!root) { console.error('usage: static_server.mjs --root <dir> [--port N] [--cache <dir>] [--manifest]'); process.exit(2); }
const cacheDir = args.cache || path.join(here, '.work', 'brotli-cache');
const log = (m) => console.error(m);
if (args.manifest) {
  console.log(JSON.stringify(manifestOf(precompress(root, cacheDir, log))));
} else {
  const s = await startServer({ root, port: Number(args.port || 0), cacheDir, log });
  console.error(`serving ${root} on http://127.0.0.1:${s.port}/ (brotli q11 precompressed, COOP/COEP on)`);
}
