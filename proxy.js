/**
 * CONFIGURABLE proxy — responsive-proxy
 * --------------------------------------------------------------------------
 * Exposes one or SEVERAL local backends under a single port, with host-spoof
 * and CORS. Everything is configured in proxy.env (PORT, HOST_SPOOF, CORS and
 * the ROUTES). No dependencies required: just Node.js.
 *
 * How it works:
 *   - Reads proxy.env: the proxy port and the routes (prefix -> host:port).
 *   - Picks the backend for each request by prefix (longest one wins).
 *   - host-spoof: forwards "Host: <HOST_SPOOF>" to the backend (e.g. localhost).
 *   - CORS: injects the headers so the browser does not block requests.
 *   - Bundle rewrite (optional/automatic): only applies if the expected marker
 *     appears in the /App/assets/*.js bundle; harmless for other apps.
 *
 * Usage:  node proxy.js   (or ./start.sh / ./tablet.sh)
 */
const http = require('http');
const fs   = require('fs');
const path = require('path');

// ---------- load proxy.env ----------
const cfg = {};
const routes = [];
const cfgPath = path.join(__dirname, 'proxy.env');
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
if (!routes.length) {
  routes.push({ prefix: '/chatkit', target: '127.0.0.1:8000' });
  routes.push({ prefix: '/',        target: '127.0.0.1:80' });
}
routes.sort((a, b) => b.prefix.length - a.prefix.length);

const LISTEN_PORT = parseInt(cfg.PORT, 10) || 8090;
const HOST_SPOOF  = (cfg.HOST_SPOOF === undefined) ? 'localhost' : cfg.HOST_SPOOF;
const CORS_ON     = String(cfg.CORS || 'on').toLowerCase() !== 'off';

const REWRITE_FROM = 'n==="localhost"||n==="127.0.0.1"?xa.localhost:xa.lpv}';
const REWRITE_TO   =
  '{...xa.localhost,wwwroot:window.location.origin+"/moodle",' +
  'chatkitUrl:window.location.origin+"/chatkit"}}';

function pickTarget(url) {
  for (const r of routes) if (url.startsWith(r.prefix)) return r.target;
  return routes[routes.length - 1].target;
}
function corsHeaders(req) {
  return {
    'access-control-allow-origin':      req.headers.origin || '*',
    'access-control-allow-credentials': 'true',
    'access-control-allow-methods':     'GET,POST,PUT,DELETE,PATCH,OPTIONS',
    'access-control-allow-headers':
      req.headers['access-control-request-headers'] ||
      'Content-Type, Authorization, X-Atlassian-Token',
  };
}

const server = http.createServer((req, res) => {
  if (req.method === 'OPTIONS' && CORS_ON) { res.writeHead(204, corsHeaders(req)); res.end(); return; }

  const [thost, tport] = pickTarget(req.url).split(':');
  const isBundle = /^\/App\/assets\/.*\.js(\?|$)/.test(req.url);

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
            if (js.includes(REWRITE_FROM)) js = js.replace(REWRITE_FROM, REWRITE_TO);
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

server.listen(LISTEN_PORT, '0.0.0.0', () => {
  console.log('');
  console.log(`  Proxy running on :${LISTEN_PORT}` + (HOST_SPOOF ? `  (host-spoof: ${HOST_SPOOF})` : '  (no host-spoof)') + `  CORS:${CORS_ON ? 'on' : 'off'}`);
  routes.forEach(r => console.log(`    ${r.prefix.padEnd(12)} -> ${r.target}`));
  console.log(`  App:  http://localhost:${LISTEN_PORT}/App/#/login`);
  console.log('');
});
