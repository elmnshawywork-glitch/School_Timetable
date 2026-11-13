// EBDA service worker — v10.47: the page opens at once from this device's copy; the newest copy is fetched in the background and,
// when it differs, the open page is told (it reloads by itself on the sign-in screen, otherwise it shows «تحديث الآن»).
// Before v10.47 the whole page (≈ 3.5 MB) was downloaded on every opening before anything was shown.
const VER = 'ebda-2026-11-13-v10.47';
const SHELL = ['./', 'index.html', 'config.js', 'manifest.json'];
self.addEventListener('install', e => {
  self.skipWaiting(); // activate new version immediately
  // each file on its own: a missing one (e.g. config.js) must not cancel the others
  e.waitUntil(caches.open(VER).then(c => Promise.all(SHELL.map(u => fetch(u, { cache: 'no-store' }).then(r => r && r.ok ? c.put(u, r) : null).catch(() => null)))));
});
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const ks = await caches.keys();
    await Promise.all(ks.filter(k => k !== VER).map(k => caches.delete(k))); // drop old caches
    await self.clients.claim();
  })());
});
self.addEventListener('message', e => { if (e.data === 'skipWaiting') self.skipWaiting(); });
// (a navigation request cannot be fetched again with options — its URL is fetched instead)
async function netHTML(req) { return fetch(req.url, { cache: 'no-store', credentials: 'same-origin' }); }
async function refreshHTML(req, cached) {
  try {
    const net = await netHTML(req);
    if (!net || !net.ok) return;
    const c = await caches.open(VER);
    const txt = await net.clone().text();
    const old = cached ? await cached.clone().text() : null;
    await c.put(req.url, net.clone());
    await c.put('index.html', net.clone());
    if (old !== null && old !== txt) {
      const cl = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
      cl.forEach(w => { try { w.postMessage('ebda-html-updated'); } catch (e) {} });
    }
  } catch (e) {}
}
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const isHTML = req.mode === 'navigate' || (req.headers.get('accept')||'').includes('text/html');
  if (isHTML) {
    // the device's copy at once (if any) + the newest one in the background; the first time: the network
    const found = caches.open(VER).then(async c => { const hit = (await c.match(req.url, { ignoreSearch: true })) || (await c.match('index.html')) || (await c.match('./')); return { c, hit, copy: hit ? hit.clone() : null }; }); // copy: to compare with, the page reads hit
    e.respondWith(found.then(async ({ c, hit }) => {
      if (hit) return hit;
      try {
        const net = await netHTML(req);
        if (net && net.ok) { await c.put(req.url, net.clone()); await c.put('index.html', net.clone()); }
        return net;
      } catch (err) { return Response.error(); }
    }));
    e.waitUntil(found.then(({ copy }) => copy ? refreshHTML(req, copy) : null));
    return;
  }
  // other GETs: network first, cache when offline (runtime cache)
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
