// Shared static server for the web benches (SPEC 8.4): one server for every stack, precompressed brotli q11, exact MIME
// types (application/wasm), COOP/COEP on every response (Flutter --wasm/skwasm wants cross-origin isolation for its
// multithreaded renderer; harmless for the others, and the same headers for all stacks keeps the comparison fair),
// Cache-Control: no-store, and per-request byte accounting (body bytes on the wire vs. uncompressed).
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import crypto from 'node:crypto';

export const MIME = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.json': 'application/json',
  '.wasm': 'application/wasm', '.map': 'application/json', '.txt': 'text/plain; charset=utf-8',
  '.symbols': 'text/plain; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.ico': 'image/x-icon', '.webp': 'image/webp', '.gif': 'image/gif', '.woff': 'font/woff',
  '.woff2': 'font/woff2', '.ttf': 'font/ttf', '.otf': 'font/otf', '.bin': 'application/octet-stream',
  '.wgsl': 'text/plain; charset=utf-8', '.xml': 'application/xml',
};
// already-compressed formats: served as-is (br size == raw size)
const NO_BR = new Set(['.png', '.jpg', '.jpeg', '.webp', '.gif', '.woff', '.woff2', '.gz', '.br', '.zip']);

export const BROTLI = { quality: 11, lgwin: 24 };

export const HEADERS = {
  'Cross-Origin-Opener-Policy': 'same-origin',
  'Cross-Origin-Embedder-Policy': 'require-corp',
  'Cross-Origin-Resource-Policy': 'same-origin',
  'Cache-Control': 'no-store',
};

export function walk(root, rel = '') {
  const out = [];
  for (const e of fs.readdirSync(path.join(root, rel), { withFileTypes: true })) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...walk(root, r));
    else if (e.isFile()) out.push(r);
  }
  return out.sort();
}

// Compress every file once (cached by content hash + params), return Map rel -> info.
export function precompress(root, cacheDir, log = () => {}) {
  fs.mkdirSync(cacheDir, { recursive: true });
  const files = new Map();
  for (const rel of walk(root)) {
    const abs = path.join(root, rel);
    const ext = path.extname(rel).toLowerCase();
    const buf = fs.readFileSync(abs);
    const info = { rel, raw: buf.length, ext, type: MIME[ext] || 'application/octet-stream', abs, br: null, brPath: null };
    if (!NO_BR.has(ext) && buf.length > 0) {
      const key = crypto.createHash('sha1').update(buf).update(`|q${BROTLI.quality}|w${BROTLI.lgwin}`).digest('hex');
      const cp = path.join(cacheDir, key + '.br');
      if (!fs.existsSync(cp)) {
        const t0 = Date.now();
        const z = zlib.brotliCompressSync(buf, {
          params: {
            [zlib.constants.BROTLI_PARAM_QUALITY]: BROTLI.quality,
            [zlib.constants.BROTLI_PARAM_LGWIN]: BROTLI.lgwin,
            [zlib.constants.BROTLI_PARAM_SIZE_HINT]: buf.length,
            [zlib.constants.BROTLI_PARAM_MODE]: ['.wasm', '.bin'].includes(ext) ? zlib.constants.BROTLI_MODE_GENERIC : zlib.constants.BROTLI_MODE_TEXT,
          },
        });
        fs.writeFileSync(cp + '.tmp', z);
        fs.renameSync(cp + '.tmp', cp);
        if (buf.length > 500_000) log(`  brotli q11 ${rel}: ${buf.length} -> ${z.length} in ${Date.now() - t0} ms`);
      }
      info.brPath = cp;
      info.br = fs.statSync(cp).size;
    } else {
      info.br = buf.length;
    }
    files.set(rel, info);
  }
  return files;
}

export function manifestOf(files) {
  const list = [...files.values()].map((f) => ({ path: f.rel, raw: f.raw, br: f.br, type: f.type }));
  return {
    files: list,
    total_raw: list.reduce((a, f) => a + f.raw, 0),
    total_br: list.reduce((a, f) => a + f.br, 0),
    brotli: BROTLI,
  };
}

export async function startServer({ root, port = 0, host = '127.0.0.1', cacheDir, log = () => {} }) {
  const files = precompress(root, cacheDir, log);
  let reqs = [];
  const server = http.createServer((req, res) => {
    let p = decodeURIComponent((req.url || '/').split('?')[0]);
    if (p.endsWith('/')) p += 'index.html';
    const rel = p.replace(/^\/+/, '');
    const f = files.get(rel);
    if (!f) {
      res.writeHead(404, HEADERS);
      res.end('not found');
      reqs.push({ path: rel, status: 404, sent: 0, raw: 0, encoding: 'identity' });
      return;
    }
    const wantBr = f.brPath && /\bbr\b/.test(req.headers['accept-encoding'] || '');
    const h = { ...HEADERS, 'Content-Type': f.type, Vary: 'Accept-Encoding' };
    let body, enc = 'identity';
    if (wantBr) {
      body = fs.readFileSync(f.brPath);
      h['Content-Encoding'] = 'br';
      enc = 'br';
    } else {
      body = fs.readFileSync(f.abs);
    }
    h['Content-Length'] = body.length;
    res.writeHead(200, h);
    res.end(req.method === 'HEAD' ? undefined : body);
    reqs.push({ path: rel, status: 200, sent: req.method === 'HEAD' ? 0 : body.length, raw: f.raw, encoding: enc });
  });
  await new Promise((r) => server.listen(port, host, r));
  return {
    server, files, port: server.address().port, manifest: manifestOf(files),
    reset() { reqs = []; },
    snapshot() {
      const ok = reqs.filter((r) => r.status === 200);
      return {
        requests: reqs.length, not_found: reqs.filter((r) => r.status === 404).map((r) => r.path),
        transferred_body_bytes: ok.reduce((a, r) => a + r.sent, 0),
        uncompressed_bytes: ok.reduce((a, r) => a + r.raw, 0),
        files: ok.map((r) => ({ path: r.path, sent: r.sent, raw: r.raw, encoding: r.encoding })),
      };
    },
    close() { return new Promise((r) => server.close(r)); },
  };
}
