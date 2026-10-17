// Injected into the 哔哩哔哩 app's Electron main process through the Node inspector,
// while the app is paused on its first line (--inspect-brk), so it runs before the app's own code.
//
// Electron allows one listener per webRequest event per session, and the app already uses
// onBeforeSendHeaders (it sets Referer/Origin for the CDN). So instead of replacing listeners we
// wrap the session's webRequest API: the app's listeners keep working, and ours run first.
//
//   onBeforeRequest:     video requests to overseas nodes (cosov/aliov/hwov, Akamai) are
//                        redirected to the node in config.json.
//   onBeforeSendHeaders: a redirected request is shown to the app's listener under its original
//                        URL, so the app adds the same headers it would have for the overseas node.
//
// Evaluated with includeCommandLineAPI so `require` is available.
(() => {
  if (global.__biliCdn) return JSON.stringify({ ok: true, already: true, pid: process.pid });

  const { app } = require('electron');
  const fs = require('fs');
  const path = require('path');

  const DEFAULT_TARGET = 'upos-sz-mirror08c.bilivideo.com';
  const dir = path.join(app.getPath('home'), 'Library/Application Support/BiliCDN');
  const cfgFile = path.join(dir, 'config.json');
  const statsFile = path.join(dir, 'stats.json');
  try { fs.mkdirSync(dir, { recursive: true }); } catch {}

  const st = global.__biliCdn = {
    pid: process.pid, since: Date.now(), target: DEFAULT_TARGET, enabled: true,
    redirects: 0, sessions: 0, appListeners: [], last: null, err: null,
  };

  let dirty = true;
  const flush = () => {
    if (!dirty) return;
    dirty = false;
    try { fs.writeFileSync(statsFile, JSON.stringify(st)); } catch {}
  };
  const loadConfig = () => {
    try {
      const c = JSON.parse(fs.readFileSync(cfgFile, 'utf8'));
      st.target = c.target || DEFAULT_TARGET;
      st.enabled = c.enabled !== false;
    } catch {
      st.target = DEFAULT_TARGET;
      st.enabled = true;
    }
    dirty = true;
  };
  loadConfig();
  fs.watchFile(cfgFile, { interval: 1000 }, loadConfig);
  const timer = setInterval(flush, 2000);
  if (timer.unref) timer.unref();

  // Overseas nodes: upos-sz-mirrorcosov / aliov / hwov (+ suffixes) and Akamai.
  const OVERSEAS = /^upos-[a-z0-9]+-mirror(cos|ali|hw)ov[a-z0-9]*\.bilivideo\.com$|^upos-[a-z0-9]+-mirrorakam\.akamaized\.net$/;

  const rewrite = (url) => {
    if (!st.enabled) return null;
    let u;
    try { u = new URL(url); } catch { return null; }
    if (!OVERSEAS.test(u.hostname) || u.hostname === st.target) return null;
    const from = u.hostname;
    u.hostname = st.target;
    st.redirects++;
    st.last = { from, to: st.target, t: Date.now() };
    dirty = true;
    return u.toString();
  };

  // Chrome match patterns ("https://*.bilivideo.com/*", "<all_urls>") -> RegExp.
  const patternRe = (p) => p === '<all_urls>'
    ? /^/
    : new RegExp('^' + p.split('*').map((s) => s.replace(/[.+?^${}()|[\]\\/]/g, '\\$&')).join('.*') + '$');
  const matches = (filter, url) => {
    const urls = filter && filter.urls;
    if (!urls || urls.length === 0) return true;
    return urls.some((p) => patternRe(p).test(url));
  };
  const parseArgs = (args) => {
    if (typeof args[0] === 'function' || args[0] == null && args.length === 1) return { filter: null, fn: args[0] || null };
    return { filter: args[0] || null, fn: args[1] || null };
  };

  const patch = (ses) => {
    const wr = ses && ses.webRequest;
    if (!wr || wr.__biliCdn) return;
    wr.__biliCdn = true;
    st.sessions++;
    dirty = true;

    const realBefore = wr.onBeforeRequest.bind(wr);
    const realHeaders = wr.onBeforeSendHeaders.bind(wr);
    let appBefore = null;
    let appHeaders = null;
    const original = new Map(); // request id -> URL before our redirect

    wr.onBeforeRequest = (...args) => { appBefore = parseArgs(args); st.appListeners.push('onBeforeRequest'); dirty = true; };
    wr.onBeforeSendHeaders = (...args) => { appHeaders = parseArgs(args); st.appListeners.push('onBeforeSendHeaders'); dirty = true; };

    realBefore((details, callback) => {
      try {
        const to = rewrite(details.url);
        if (to) {
          original.set(details.id, details.url);
          if (original.size > 500) original.delete(original.keys().next().value);
          return callback({ redirectURL: to });
        }
      } catch (e) { st.err = String(e); dirty = true; }
      if (appBefore && appBefore.fn && matches(appBefore.filter, details.url)) return appBefore.fn(details, callback);
      callback({});
    });

    realHeaders((details, callback) => {
      const orig = original.get(details.id);
      const app = appHeaders && appHeaders.fn && matches(appHeaders.filter, orig || details.url) ? appHeaders.fn : null;
      if (!orig) return app ? app(details, callback) : callback({});

      // Redirected request: Chromium drops the Referer on our redirect, and the CDN answers 403
      // without one. Let the app's listener see the original URL, then make sure the
      // Referer/Origin the app normally sends are present.
      const finish = (resp) => {
        resp = resp || {};
        if (resp.cancel) return callback(resp);
        const h = { ...(resp.requestHeaders || details.requestHeaders) };
        const has = (k) => Object.keys(h).some((x) => x.toLowerCase() === k);
        if (!has('referer')) h.Referer = 'https://www.bilibili.com/client';
        if (!has('origin')) h.origin = 'https://www.bilibili.com';
        callback({ ...resp, requestHeaders: h });
      };
      if (app) return app({ ...details, url: orig }, finish);
      finish({});
    });
  };

  // session-created fires as each session (including the default one) is constructed,
  // before the app can register its own listeners on it.
  app.on('session-created', patch);
  if (app.isReady()) {
    const { session, webContents } = require('electron');
    patch(session.defaultSession);
    for (const wc of webContents.getAllWebContents()) patch(wc.session);
  }
  flush();

  return JSON.stringify({ ok: true, pid: process.pid, ready: app.isReady(), target: st.target });
})()
