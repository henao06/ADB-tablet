/**
 * ADB Tablet Proxy
 * --------------------------------------------------------------------------
 * Exposes one or SEVERAL local backends under a single port, with host-spoof
 * and CORS. Everything is configured in config/proxy.env (PORT, BIND,
 * HOST_SPOOF, CORS and the ROUTES). No dependencies required: just Node.js.
 *
 * How it works:
 *   - Reads config/proxy.env: the proxy port, bind host and the routes
 *     (prefix -> host:port).
 *   - Picks the backend for each request by prefix (longest one wins).
 *   - host-spoof: forwards "Host: <HOST_SPOOF>" to the backend (e.g. localhost).
 *   - CORS: injects the headers so the browser does not block requests.
 *   - Bundle rewrite (optional): only runs when BUNDLE_REWRITE_FROM and
 *     BUNDLE_REWRITE_TO are set in config/proxy.env; otherwise it is a no-op
 *     and the proxy is a clean pass-through.
 *
 * Security notes:
 *   - BIND defaults to 127.0.0.1 (localhost only). This keeps the proxy off
 *     the LAN. Set BIND=0.0.0.0 in config/proxy.env ONLY if you deliberately
 *     want to expose it to the whole network — see the warning below.
 *   - CORS never pairs a reflected Origin with credentials. When CORS_ORIGIN
 *     is empty the proxy reflects the caller Origin WITHOUT credentials (plus
 *     Vary: Origin). Reflecting the Origin while allowing credentials would
 *     turn the proxy into an open credentialed relay: any site could read
 *     authenticated responses from the backends. To allow credentialed
 *     cross-origin access, set CORS_ORIGIN to a single explicit allowlist
 *     origin; only then are credentials enabled, and only for that origin.
 *     See MDN "Cross-Origin Resource Sharing (CORS)".
 *
 * Usage:  node proxy/proxy.js   (or ./sh/start.sh / ./sh/tablet.sh)
 */
const http = require('http');
const fs   = require('fs');
const path = require('path');

const cfg = {};
const routes = [];
const cfgPath = path.join(__dirname, '..', 'config', 'proxy.env');
if (fs.existsSync(cfgPath)) {
  for (const raw of fs.readFileSync(cfgPath, 'utf8').split('\n')) {
    const l = raw.trim();
    if (!l || l.startsWith('#')) continue;
    if (/^ROUTE\s+/i.test(l)) {
      const p = l.split(/\s+/);
      if (p.length >= 3) routes.push({ prefix: p[1], target: p[2] });
    } else {
      const i = l.indexOf('=');
      if (i > 0) cfg[l.slice(0, i).trim().toUpperCase()] = l.slice(i + 1).trim();
    }
  }
}

const DEFAULT_TARGET = cfg.DEFAULT_TARGET || '127.0.0.1:80';
if (!routes.length) routes.push({ prefix: '/', target: DEFAULT_TARGET });
routes.sort((a, b) => b.prefix.length - a.prefix.length);

let port = 8090;
if (cfg.PORT !== undefined) {
  if (!/^\d+$/.test(cfg.PORT)) {
    console.error(`[x] Invalid PORT "${cfg.PORT}" in config/proxy.env — must be an integer 1-65535.`);
    console.error('    Fix: set a valid PORT in config/proxy.env, e.g. PORT=8090');
    process.exit(1);
  }
  port = parseInt(cfg.PORT, 10);
}
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  console.error(`[x] PORT ${port} is out of range in config/proxy.env — must be an integer 1-65535.`);
  console.error('    Fix: set a valid PORT in config/proxy.env, e.g. PORT=8090');
  process.exit(1);
}

const BIND        = cfg.BIND || cfg.HOST || '127.0.0.1';
const HOST_SPOOF  = (cfg.HOST_SPOOF === undefined) ? 'localhost' : cfg.HOST_SPOOF;
const CORS_ON     = String(cfg.CORS || 'on').toLowerCase() !== 'off';
const CORS_ORIGIN = cfg.CORS_ORIGIN || '';

const BUNDLE_REWRITE_FROM = cfg.BUNDLE_REWRITE_FROM || '';
const BUNDLE_REWRITE_TO   = cfg.BUNDLE_REWRITE_TO   || '';
const BUNDLE_ENABLED      = !!(BUNDLE_REWRITE_FROM && BUNDLE_REWRITE_TO);
let bundleRe = null;
if (BUNDLE_ENABLED) {
  try {
    bundleRe = new RegExp(cfg.BUNDLE_MATCH || '^/App/assets/.*\\.js(\\?|$)');
  } catch (e) {
    console.error(`[x] Invalid BUNDLE_MATCH regex in config/proxy.env: ${e.message}`);
    console.error('    Fix: correct BUNDLE_MATCH in config/proxy.env, or remove it to use the default.');
    process.exit(1);
  }
}

function pickTarget(url) {
  for (const r of routes) if (url.startsWith(r.prefix)) return r.target;
  return routes[routes.length - 1].target;
}
function corsHeaders(req) {
  const h = {
    'access-control-allow-methods': 'GET,POST,PUT,DELETE,PATCH,OPTIONS',
    'access-control-allow-headers':
      req.headers['access-control-request-headers'] ||
      'Content-Type, Authorization, X-Atlassian-Token',
  };
  if (CORS_ORIGIN && CORS_ORIGIN !== '*') {
    h['access-control-allow-origin']      = CORS_ORIGIN;
    h['access-control-allow-credentials'] = 'true';
    h['vary']                             = 'Origin';
  } else if (CORS_ORIGIN === '*') {
    h['access-control-allow-origin'] = '*';
  } else {
    h['access-control-allow-origin'] = req.headers.origin || '*';
    if (req.headers.origin) h['vary'] = 'Origin';
  }
  return h;
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS' && CORS_ON) { res.writeHead(204, corsHeaders(req)); res.end(); return; }

  const [thost, tport] = pickTarget(req.url).split(':');
  const isBundle = BUNDLE_ENABLED && bundleRe.test(req.url);

  const headers = { ...req.headers, 'accept-encoding': 'identity' };
  if (HOST_SPOOF) headers.host = HOST_SPOOF;

  const chunks = [];
  req.on('data', c => chunks.push(c));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const up = http.request(
      { hostname: thost, port: parseInt(tport || '80', 10), path: req.url, method: req.method, headers },
      upRes => {
        const cors = CORS_ON ? corsHeaders(req) : {};
        if (isBundle) {
          const buf = [];
          upRes.on('data', c => buf.push(c));
          upRes.on('end', () => {
            let js = Buffer.concat(buf).toString('utf8');
            if (js.includes(BUNDLE_REWRITE_FROM)) js = js.replace(BUNDLE_REWRITE_FROM, BUNDLE_REWRITE_TO);
            const out = Buffer.from(js, 'utf8');
            const h = { ...upRes.headers };
            delete h['content-encoding']; delete h['transfer-encoding'];
            delete h['access-control-allow-origin']; delete h['access-control-allow-credentials'];
            Object.assign(h, cors, { 'content-length': out.length, 'cache-control': 'no-store' });
            res.writeHead(upRes.statusCode, h); res.end(out);
          });
          return;
        }
        const h = { ...upRes.headers };
        delete h['access-control-allow-origin']; delete h['access-control-allow-credentials'];
        Object.assign(h, cors);
        res.writeHead(upRes.statusCode, h); upRes.pipe(res);
      }
    );
    up.on('error', err => {
      if (!res.headersSent) res.writeHead(502, { 'content-type': 'text/plain', ...(CORS_ON ? corsHeaders(req) : {}) });
      res.end('Proxy error: ' + err.message);
    });
    if (body.length) up.write(body);
    up.end();
  });
});

server.on('error', err => {
  if (err.code === 'EADDRINUSE') {
    console.error(`[x] Port ${port} is already in use.`);
    console.error('    Fix: run ./sh/tablet.sh proxy stop, or change PORT in config/proxy.env');
  } else {
    console.error(`[x] Proxy server error: ${err.message}`);
  }
  process.exit(1);
});

server.listen(port, BIND, () => {
  console.log('');
  console.log(`  Proxy running on ${BIND}:${port}` + (HOST_SPOOF ? `  (host-spoof: ${HOST_SPOOF})` : '  (no host-spoof)') + `  CORS:${CORS_ON ? 'on' : 'off'}`);
  routes.forEach(r => console.log(`    ${r.prefix.padEnd(12)} -> ${r.target}`));
  console.log(`  Proxy:  http://localhost:${port}/`);
  console.log('');
});
