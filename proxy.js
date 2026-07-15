/**
 * Proxy CONFIGURABLE — responsive-proxy
 * --------------------------------------------------------------------------
 * Expone uno o VARIOS backends locales bajo un solo puerto, con host-spoof y
 * CORS. Todo se configura en proxy.env (PORT, HOST_SPOOF, CORS y las RUTAS).
 * No requiere dependencias: solo Node.js.
 *
 * Como funciona:
 *   - Lee proxy.env: el puerto del proxy y las rutas (prefijo -> host:puerto).
 *   - A cada pedido le elige el backend segun el prefijo (el mas largo gana).
 *   - host-spoof: le reenvia "Host: <HOST_SPOOF>" al backend (ej localhost).
 *   - CORS: inyecta los headers para que el navegador no bloquee.
 *   - Reescritura de bundle (opcional/automatica): solo se aplica si aparece la
 *     marca esperada en el bundle /App/assets/*.js; para otras apps es inofensiva.
 *
 * Uso:  node proxy.js   (o ./start.sh / ./tablet.sh)
 */
const http = require('http');
const fs   = require('fs');
const path = require('path');

// ---------- cargar proxy.env ----------
const cfg = {};
const routes = [];
const cfgPath = path.join(__dirname, 'proxy.env');
if (fs.existsSync(cfgPath)) {
  for (const raw of fs.readFileSync(cfgPath, 'utf8').split('\n')) {
    const l = raw.trim();
    if (!l || l.startsWith('#')) continue;
    if (/^ROUTE\s+/i.test(l)) {
      const p = l.split(/\s+/);                       // ROUTE <prefijo> <host:puerto>
      if (p.length >= 3) routes.push({ prefix: p[1], target: p[2] });
    } else {
      const i = l.indexOf('=');
      if (i > 0) cfg[l.slice(0, i).trim().toUpperCase()] = l.slice(i + 1).trim();
    }
  }
}
// default = rutas por defecto (si proxy.env no define rutas)
if (!routes.length) {
  routes.push({ prefix: '/chatkit', target: '127.0.0.1:8000' });
  routes.push({ prefix: '/',        target: '127.0.0.1:80' });
}
routes.sort((a, b) => b.prefix.length - a.prefix.length);   // mas especifico primero

const LISTEN_PORT = parseInt(cfg.PORT, 10) || 8090;
const HOST_SPOOF  = (cfg.HOST_SPOOF === undefined) ? 'localhost' : cfg.HOST_SPOOF;  // '' = no spoof
const CORS_ON     = String(cfg.CORS || 'on').toLowerCase() !== 'off';

// Reescritura de bundle (app-specific, opcional): que la app apunte Moodle/chatkit
// al origen del proxy. Solo actúa si el bundle contiene la marca de REWRITE_FROM.
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
  console.log(`  Proxy corriendo en :${LISTEN_PORT}` + (HOST_SPOOF ? `  (host-spoof: ${HOST_SPOOF})` : '  (sin host-spoof)') + `  CORS:${CORS_ON ? 'on' : 'off'}`);
  routes.forEach(r => console.log(`    ${r.prefix.padEnd(12)} -> ${r.target}`));
  console.log(`  App:  http://localhost:${LISTEN_PORT}/App/#/login`);
  console.log('');
});
