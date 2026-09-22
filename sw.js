// EBDA service worker — network-first for updates, cache fallback offline
const VER = 'ebda-2026-10-18';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.json'];
self.addEventListener('install', e => {
  self.skipWaiting(); // activate new version immediately
  e.waitUntil(caches.open(VER).then(c => c.addAll(SHELL).catch(()=>{})));
});
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const ks = await caches.keys();
    await Promise.all(ks.filter(k => k !== VER).map(k => caches.delete(k))); // drop old caches
    await self.clients.claim();
  })());
});
self.addEventListener('message', e => { if (e.data === 'skipWaiting') self.skipWaiting(); });
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const isHTML = req.mode === 'navigate' || (req.headers.get('accept')||'').includes('text/html');
  if (isHTML) {
    // network-first: always try to get the latest page; fall back to cache offline
    e.respondWith((async () => {
      try {
        const net = await fetch(req, { cache: 'no-store' });
        const c = await caches.open(VER); c.put(req, net.clone());
        return net;
      } catch (err) {
        const c = await caches.open(VER);
        return (await c.match(req)) || (await c.match('index.html')) || (await c.match('./'));
      }
    })());
    return;
  }
  // other GETs: cache-then-network (runtime cache)
  e.respondWith((async () => {
    try {
      const net = await fetch(req);
      if (net && net.ok) { const c = await caches.open(VER); c.put(req, net.clone()); }
      return net;
    } catch (err) {
      const c = await caches.open(VER);
      const hit = await c.match(req);
      if (hit) return hit;
      throw err;
    }
  })());
});
