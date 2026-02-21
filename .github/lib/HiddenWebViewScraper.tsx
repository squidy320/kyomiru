import React, { useCallback, useEffect, useRef, useState } from 'react';
import { StyleSheet, View } from 'react-native';
import { WebView } from 'react-native-webview';

const DEV = typeof __DEV__ !== 'undefined' ? __DEV__ : true;
const dlog = (...args: any[]) => {
  if (DEV) console.log(...args);
};

type Request = {
  id: string;
  type: 'episodesByTitle' | 'extractKwik' | 'fetchDownloadLink' | 'runExtension';
  title: string; // for episodes: search title; for extractKwik/fetchDownloadLink: page URL; for runExtension: JS code
  preferredQuality?: string;
  resolve: (value: any) => void;
  reject: (err: any) => void;
};

export default function HiddenWebViewScraperProvider({ children }: { children: React.ReactNode }) {
  const [queue, setQueue] = useState<Request[]>([]);
  const [current, setCurrent] = useState<Request | null>(null);
  const [webUri, setWebUri] = useState('https://animepahe.si/');
  const [webUserAgent, setWebUserAgent] = useState<string | undefined>(undefined);
  const [pageReady, setPageReady] = useState(false);
  const webRef = useRef<any>(null);
  const currentRef = useRef<Request | null>(null);
  const sniffHeadersRef = useRef<Record<string, string> | null>(null);
  const HOME_URI = 'https://animepahe.si/';
  const timerRef = useRef<number | null>(null);
  const injectedRequestIdRef = useRef<string | null>(null);
  const OLD_MOBILE_USER_AGENT =
    'Mozilla/5.0 (iPhone; CPU iPhone OS 4_3_5 like Mac OS X) AppleWebKit/533.17.9 (KHTML, like Gecko) Version/5.0.2 Mobile/8L1 Safari/6533.18.5';

  useEffect(() => {
    // register global requester so non-component modules can queue requests
    (globalThis as any).__WEBVIEW_SCRAPER__ = {
      request: (opts: {
        type: 'episodesByTitle' | 'extractKwik' | 'fetchDownloadLink' | 'runExtension';
        title: string;
        preferredQuality?: string;
      }) => {
        return new Promise((resolve, reject) => {
          const id = Math.random().toString(36).slice(2);
          setQueue((q) => [
            ...q,
            {
              id,
              type: opts.type as any,
              title: opts.title,
              preferredQuality: opts.preferredQuality,
              resolve,
              reject,
            },
          ]);
        });
      },
    };
    return () => {
      try {
        delete (globalThis as any).__WEBVIEW_SCRAPER__;
      } catch {}
      if (timerRef.current) {
        try { clearTimeout(timerRef.current as any); } catch {}
        timerRef.current = null;
      }
    };
  }, []);

  useEffect(() => {
    if (!current && queue.length > 0) {
      setCurrent(queue[0]);
      setQueue((q) => q.slice(1));
    }
  }, [queue, current]);

  useEffect(() => {
    if (!current) return;
    currentRef.current = current;
    injectedRequestIdRef.current = null;
    if (current.type === 'extractKwik' || current.type === 'fetchDownloadLink') {
      setPageReady(false);
      setWebUri(current.title);
      setWebUserAgent(current.type === 'fetchDownloadLink' ? OLD_MOBILE_USER_AGENT : undefined);
    }
  }, [current]);

  useEffect(() => {
    currentRef.current = current;
  }, [current]);

  const finalizeCurrent = useCallback((value: any, isError = false) => {
    const active = currentRef.current;
    if (!active) return;
    try {
      if (isError) active.reject(value);
      else active.resolve(value);
    } catch {}
    if (timerRef.current) {
      try { clearTimeout(timerRef.current as any); } catch {}
      timerRef.current = null;
    }
    if (active.type === 'fetchDownloadLink') {
      setPageReady(false);
      setWebUri(HOME_URI);
      setWebUserAgent(undefined);
      sniffHeadersRef.current = null;
    }
    currentRef.current = null;
    setCurrent(null);
  }, []);

  const maybeFinishFromUrl = useCallback((urlInput: any, contentTypeInput?: any) => {
    const active = currentRef.current;
    if (!active || active.type !== 'fetchDownloadLink') return false;
    const url = String(urlInput ?? '').trim();
    if (!url) return false;
    const lowered = url.toLowerCase();
    if (!lowered.startsWith('http')) return false;
    const contentType = String(contentTypeInput ?? '').toLowerCase();
    const hasMediaExt = /\.(mp4|m3u8|m4v|webm|ts)(?:[\?#]|$)/i.test(url);
    const hasMediaContentType =
      contentType.includes('video/mp4') ||
      contentType.includes('video/webm') ||
      contentType.includes('video/mp2t') ||
      contentType.includes('application/x-mpegurl') ||
      contentType.includes('application/vnd.apple.mpegurl');
    if (!hasMediaExt && !hasMediaContentType) return false;
    try { webRef.current?.stopLoading?.(); } catch {}
    dlog('[WebView] Intercepted sniffed media URL:', {
      url: url.slice(0, 160),
      contentType: contentType || 'n/a',
    });
    const headers = sniffHeadersRef.current ?? undefined;
    finalizeCurrent({ url, headers }, false);
    return true;
  }, [finalizeCurrent]);

  const handleDownloadFound = useCallback((url: string, contentType?: string) => {
    const normalized = String(url ?? '').trim();
    if (!normalized) return false;
    dlog('[Sniffer] Found Video Source:', normalized);
    return maybeFinishFromUrl(normalized, contentType ?? '');
  }, [maybeFinishFromUrl]);

  const handleMessage = useCallback((event: any) => {
    if (!current) return;
    try {
      const data = JSON.parse(event.nativeEvent.data);
      dlog('[WebView] Received message:', data.type, data);
      if (data.type === 'episodes') {
        finalizeCurrent(data.episodes ?? [], false);
        return;
      } else if (data.type === 'kwik') {
        finalizeCurrent(data.url ?? null, false);
        return;
      } else if (data.type === 'downloadLink') {
        const raw = String(data.url ?? '').trim();
        const postedHeaders =
          data?.headers && typeof data.headers === 'object'
            ? (data.headers as Record<string, string>)
            : null;
        if (postedHeaders && Object.keys(postedHeaders).length > 0) {
          sniffHeadersRef.current = postedHeaders;
        }
        if (raw) {
          finalizeCurrent({ url: raw, headers: sniffHeadersRef.current ?? undefined }, false);
          return;
        }
        finalizeCurrent(null, false);
        return;
      } else if (data.type === 'snifferContext') {
        if (data?.headers && typeof data.headers === 'object') {
          sniffHeadersRef.current = data.headers as Record<string, string>;
        }
        return;
      } else if (data.type === 'extensionResult') {
        dlog('[WebView] Resolving extensionResult with:', data.result);
        finalizeCurrent(data.result ?? null, false);
        return;
      } else if (data.type === 'error' || data.type === 'extensionError') {
        dlog('[WebView] Rejecting with error:', data.error);
        finalizeCurrent(new Error(data.error || 'Scrape error'), true);
        return;
      } else {
        finalizeCurrent(new Error('Unknown response'), true);
        return;
      }
    } catch (e) {
      finalizeCurrent(e, true);
    }
  }, [current, finalizeCurrent]);

  // Build injected JS that searches and fetches episode pages then posts back
  const buildInjectedJS = (req: Request) => {
    const esc = (s: string) => s.replace(/\\/g, '\\\\').replace(/'/g, "\\'");
    if (req.type === 'episodesByTitle') {
      const t = esc(req.title);
      return `
        (async function(){
          try{
            const q = encodeURIComponent('${t}');
            const searchUrl = 'https://animepahe.si/api?m=search&q=' + q;
            const searchRes = await fetch(searchUrl, {headers:{'Accept':'application/json'}});
            const searchJson = await searchRes.json();
            const data = Array.isArray(searchJson.data) ? searchJson.data : [];
            if (data.length === 0) {
              window.ReactNativeWebView.postMessage(JSON.stringify({type:'episodes', episodes:[]}));
              return;
            }
            const session = data[0].session;
            const firstReleaseUrl = 'https://animepahe.si/api?m=release&id=' + session + '&sort=episode_asc&page=1';
            const first = await fetch(firstReleaseUrl, {headers:{'Accept':'application/json'}}).then(r=>r.json());
            const lastPage = first.last_page || 1;
            const all = first.data && Array.isArray(first.data) ? [...first.data] : [];
            for (let p = 2; p <= lastPage; p++){
              try{
                const url = 'https://animepahe.si/api?m=release&id=' + session + '&sort=episode_asc&page=' + p;
                const page = await fetch(url, {headers:{'Accept':'application/json'}}).then(r=>r.json());
                if (page.data && Array.isArray(page.data)) all.push(...page.data);
              }catch(e){/* ignore per-page errors */}
            }
            const episodes = all.map(ep=>({id:ep.session, number:ep.episode, title:ep.title, playPageUrl:'https://animepahe.si/play/' + session + '/' + ep.session }));
            window.ReactNativeWebView.postMessage(JSON.stringify({type:'episodes', episodes}));
          }catch(err){
            window.ReactNativeWebView.postMessage(JSON.stringify({type:'error', error: String(err)}));
          }
        })(); true;
      `;
    }
    if (req.type === 'runExtension') {
      // req.title contains JS code that should post a message with {type:'extensionResult', result: ...} or {type:'extensionError', error: ...}
      return `${req.title}\n;true;`;
    }
    if (req.type === 'fetchDownloadLink') {
      return `
        (function(){
          var done = false;
          var startAt = Date.now();
          function getSnifferHeaders(){
            var out = {};
            try {
              var ua = String((navigator && navigator.userAgent) || '').trim();
              if (ua) out['User-Agent'] = ua;
            } catch(e){}
            try {
              var cookie = String(document && document.cookie || '').trim();
              if (cookie) out['Cookie'] = cookie;
            } catch(e){}
            try {
              var ref = String(document && document.referrer || '').trim();
              if (ref) out['Referer'] = ref;
            } catch(e){}
            return out;
          }
          function post(type, payload){
            try{
              window.ReactNativeWebView.postMessage(JSON.stringify(Object.assign({type:type}, payload||{})));
            }catch(e){}
          }
          post('snifferContext', { headers: getSnifferHeaders() });
          function finish(url, contentType){
            if (done) return;
            done = true;
            post('downloadLink', {
              url: url || null,
              contentType: contentType || '',
              headers: getSnifferHeaders(),
            });
          }
          function norm(url){
            try { return new URL(url, location.href).toString(); } catch(e){ return null; }
          }
          function mediaFromUrl(url){
            var u = String(url || '');
            if (/\\.(mp4|m3u8|m4v|webm|ts)(?:[?#]|$)/i.test(u)) return u;
            return null;
          }
          function mediaFromContentType(contentType){
            var ct = String(contentType || '').toLowerCase();
            if (!ct) return false;
            return (
              ct.indexOf('video/mp4') >= 0 ||
              ct.indexOf('video/webm') >= 0 ||
              ct.indexOf('video/mp2t') >= 0 ||
              ct.indexOf('application/x-mpegurl') >= 0 ||
              ct.indexOf('application/vnd.apple.mpegurl') >= 0
            );
          }
          function maybeFinish(url, contentType){
            if (done) return true;
            var normalized = norm(url);
            if (!normalized) return false;
            if (!mediaFromUrl(normalized) && !mediaFromContentType(contentType)) return false;
            finish(normalized, contentType || '');
            return true;
          }
          function tryHeadlessAutoplay(){
            try{
              var videos = document.querySelectorAll('video');
              for (var i = 0; i < videos.length; i++) {
                var v = videos[i];
                try { v.muted = true; } catch(e){}
                try { v.defaultMuted = true; } catch(e){}
                try { v.volume = 0; } catch(e){}
                try { v.autoplay = true; } catch(e){}
                try { v.setAttribute('muted', 'true'); } catch(e){}
                try { v.setAttribute('playsinline', 'true'); } catch(e){}
                try { v.setAttribute('webkit-playsinline', 'true'); } catch(e){}
                try {
                  var src = String(v.currentSrc || v.src || '');
                  if (src) maybeFinish(src, '');
                } catch(e){}
                try {
                  var p = v.play && v.play();
                  if (p && typeof p.catch === 'function') p.catch(function(){});
                } catch(e){}
              }
            } catch(e){}
          }
          function clickPlayLikeButtons(){
            try{
              var els = document.querySelectorAll('button, [role=\"button\"], .play, [aria-label], [title]');
              for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var txt = String(
                  (el.innerText || el.textContent || '') + ' ' +
                  (el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title')) || '')
                ).toLowerCase();
                if (txt.indexOf('play') >= 0 || txt.indexOf('start') >= 0 || txt.indexOf('watch') >= 0) {
                  try { el.click(); } catch(e){}
                }
              }
            } catch(e){}
          }
          function scanDocument(){
            try{
              var html = document.documentElement ? document.documentElement.innerHTML : '';
              var m = String(html || '').match(/https?:\\/\\/[^\\s"'\\\\]+\\.(mp4|m3u8|m4v|webm|ts)(?:\\?[^\\s"'\\\\]*)?/i);
              if (m && m[0] && maybeFinish(m[0], '')) return true;
              var els = document.querySelectorAll('video, video source, source, a[href], [data-src], [src]');
              for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var src = (el.getAttribute && (el.getAttribute('src') || el.getAttribute('href') || el.getAttribute('data-src'))) || '';
                if (src && maybeFinish(src, '')) return true;
              }
            }catch(e){}
            return false;
          }

          if (scanDocument()) return true;
          if (maybeFinish(location.href, '')) return true;
          clickPlayLikeButtons();
          tryHeadlessAutoplay();

          // Global network sniffer: fetch/XHR response URLs + content-type.
          try {
            var _fetch = window.fetch ? window.fetch.bind(window) : null;
            if (_fetch) {
              window.fetch = function(input, init){
                return _fetch(input, init).then(function(resp){
                  try {
                    var ru = String(resp && resp.url ? resp.url : '');
                    var ct = '';
                    try { ct = String(resp && resp.headers && resp.headers.get ? (resp.headers.get('content-type') || '') : ''); } catch(e){}
                    maybeFinish(ru, ct);
                  } catch(e){}
                  return resp;
                });
              };
            }
          } catch(e){}
          try {
            var NativeXHR = window.XMLHttpRequest;
            if (NativeXHR && NativeXHR.prototype) {
              var open = NativeXHR.prototype.open;
              var send = NativeXHR.prototype.send;
              NativeXHR.prototype.open = function(method, url){
                try { this.__snifferUrl = String(url || ''); } catch(e){}
                return open.apply(this, arguments);
              };
              NativeXHR.prototype.send = function(){
                try{
                  this.addEventListener('readystatechange', function(){
                    try{
                      if (this.readyState === 2 || this.readyState === 4) {
                        var ru = String(this.responseURL || this.__snifferUrl || '');
                        var ct = String(this.getResponseHeader ? (this.getResponseHeader('content-type') || '') : '');
                        maybeFinish(ru, ct);
                      }
                    } catch(e){}
                  });
                } catch(e){}
                return send.apply(this, arguments);
              };
            }
          } catch(e){}

          // Media element source hooks.
          try{
            var desc = Object.getOwnPropertyDescriptor(HTMLMediaElement.prototype, 'src');
            if (desc && desc.set) {
              Object.defineProperty(HTMLMediaElement.prototype, 'src', {
                configurable: true,
                enumerable: desc.enumerable,
                get: desc.get,
                set: function(v){
                  try { maybeFinish(String(v || ''), ''); } catch(e){}
                  return desc.set.call(this, v);
                }
              });
            }
            var playFn = HTMLMediaElement.prototype.play;
            if (playFn) {
              HTMLMediaElement.prototype.play = function(){
                try {
                  this.muted = true;
                  this.defaultMuted = true;
                  this.volume = 0;
                } catch(e){}
                try {
                  var src = String(this.currentSrc || this.src || '');
                  if (src) maybeFinish(src, '');
                } catch(e){}
                return playFn.apply(this, arguments);
              };
            }
            var nativeSetAttribute = Element.prototype.setAttribute;
            Element.prototype.setAttribute = function(name, value){
              try{
                if (String(name || '').toLowerCase() === 'src') maybeFinish(String(value || ''), '');
              } catch(e){}
              return nativeSetAttribute.apply(this, arguments);
            };
          } catch(e){}

          var attempts = 0;
          var intv = setInterval(function(){
            if (done) { clearInterval(intv); return; }
            attempts++;
            if (scanDocument()) { clearInterval(intv); return; }
            if (maybeFinish(location.href, '')) { clearInterval(intv); return; }
            clickPlayLikeButtons();
            tryHeadlessAutoplay();
            try {
              if (window.performance && typeof window.performance.getEntriesByType === 'function') {
                var entries = window.performance.getEntriesByType('resource') || [];
                for (var i = 0; i < entries.length; i++) {
                  var name = entries[i] && entries[i].name ? String(entries[i].name) : '';
                  if (maybeFinish(name, '')) { clearInterval(intv); return; }
                }
              }
            } catch(e){}
            if (Date.now() - startAt > 45000) {
              clearInterval(intv);
              finish(null, '');
            }
          }, 700);
          return true;
        })();
      `;
    }
    // extractKwik - run on the actual play page and probe DOM + network activity.
    return `
      (async function(){
        var done = false;
        var found = null;
        var timeoutHandle = setTimeout(function(){
          if (done) return;
          done = true;
          window.ReactNativeWebView.postMessage(JSON.stringify({type:'error', error:'extractKwik timed out after 10s'}));
        }, 10000);
        function finishSuccess(foundUrl){
          if (done) return;
          done = true;
          clearTimeout(timeoutHandle);
          window.ReactNativeWebView.postMessage(JSON.stringify({type:'kwik', url:foundUrl}));
        }
        function finishError(message){
          if (done) return;
          done = true;
          clearTimeout(timeoutHandle);
          window.ReactNativeWebView.postMessage(JSON.stringify({type:'error', error: String(message)}));
        }
        function maybeFinish(url){
          if (!url) return false;
          if (done) return true;
          found = url;
          finishSuccess(url);
          return true;
        }
        function findMediaUrl(text){
          if (!text) return null;
          var s = String(text);
          var m = s.match(/https?:\\/\\/[^\\s"'\\\\]+\\.(m3u8|mp4|mpd)(\\?[^\\s"'\\\\]*)?/i);
          return m && m[0] ? m[0] : null;
        }
        function abs(base, candidate){
          try { return new URL(candidate, base || location.href).toString(); } catch(e){ return null; }
        }
        function scanDocument(){
          try{
            var html = document.documentElement ? document.documentElement.innerHTML : '';
            var direct = findMediaUrl(html);
            if (maybeFinish(direct)) return true;

            var selectors = ['video', 'video source', 'source', 'iframe'];
            for (var si = 0; si < selectors.length; si++) {
              var els = document.querySelectorAll(selectors[si]);
              for (var i = 0; i < els.length; i++) {
                var el = els[i];
                var src = el.getAttribute && (el.getAttribute('src') || el.getAttribute('data-src') || el.getAttribute('href'));
                var full = src ? abs(location.href, src) : null;
                if (maybeFinish(findMediaUrl(full))) return true;
              }
            }

            var scripts = document.getElementsByTagName('script');
            for (var j = 0; j < scripts.length; j++) {
              var txt = scripts[j].textContent || scripts[j].innerText || '';
              if (maybeFinish(findMediaUrl(txt))) return true;
            }
          }catch(e){}
          return false;
        }
        var nativeEval = window.eval ? window.eval.bind(window) : null;
        window.eval = function(code){
          try{
            var hit = findMediaUrl(code);
            if (hit) maybeFinish(hit);
          }catch(e){}
          if (nativeEval) return nativeEval(code);
          return undefined;
        };
        try{
          var nativeFetch = window.fetch ? window.fetch.bind(window) : null;
          if (nativeFetch) {
            window.fetch = function(input, init){
              try {
                var candidate = typeof input === 'string' ? input : (input && input.url ? input.url : '');
                if (maybeFinish(findMediaUrl(candidate))) return nativeFetch(input, init);
              } catch(e){}
              return nativeFetch(input, init).then(function(resp){
                try {
                  var ru = resp && resp.url ? resp.url : '';
                  maybeFinish(findMediaUrl(ru));
                } catch(e){}
                return resp;
              });
            };
          }
        }catch(e){}
        try{
          var NativeXHR = window.XMLHttpRequest;
          if (NativeXHR && NativeXHR.prototype) {
            var open = NativeXHR.prototype.open;
            NativeXHR.prototype.open = function(method, url){
              try { maybeFinish(findMediaUrl(String(url || ''))); } catch(e){}
              return open.apply(this, arguments);
            };
          }
        }catch(e){}

        try{
          if (scanDocument()) return;
          var attempts = 0;
          var interval = setInterval(function(){
            if (done) { clearInterval(interval); return; }
            attempts++;
            if (scanDocument()) { clearInterval(interval); return; }
            try {
              if (window.performance && typeof window.performance.getEntriesByType === 'function') {
                var entries = window.performance.getEntriesByType('resource') || [];
                for (var i = 0; i < entries.length; i++) {
                  var name = entries[i] && entries[i].name ? String(entries[i].name) : '';
                  if (maybeFinish(findMediaUrl(name))) { clearInterval(interval); return; }
                }
              }
            } catch(e){}
            if (attempts >= 30 && !done) {
              clearInterval(interval);
              finishError('No media URL found');
            }
          }, 400);
        }catch(err){
          finishError(err);
        }finally{
          try { if (nativeEval) window.eval = nativeEval; } catch(e) {}
        }
      })(); true;
    `;
  };

  useEffect(() => {
    if (!current || !webRef.current || !pageReady) return;
    if (injectedRequestIdRef.current === current.id) return;

    const js = buildInjectedJS(current);
    injectedRequestIdRef.current = current.id;
    const timeout = setTimeout(() => {
      try {
        webRef.current.injectJavaScript(js);
      } catch (e) {
        try { current.reject(e); } catch {}
        setCurrent(null);
      }
    }, 120);

    // Hard timeout: keep fetchDownloadLink short so it can't block extension queue.
    const requestTimeoutMs = current.type === 'fetchDownloadLink' ? 30000 : 15000;
    const timer = setTimeout(() => {
      if (current) {
        finalizeCurrent(new Error('WebView request timed out'), true);
      }
    }, requestTimeoutMs);
    timerRef.current = timer as any;
    return () => {
      clearTimeout(timeout);
      if (timerRef.current) {
        try { clearTimeout(timerRef.current as any); } catch {};
        timerRef.current = null;
      }
    };
  }, [current, pageReady, finalizeCurrent]);

  useEffect(() => {
    if (!current) {
      injectedRequestIdRef.current = null;
    }
  }, [current]);

  return (
    <>
      {children}
      <View style={styles.container} pointerEvents="none">
        <WebView
          ref={webRef}
          userAgent={webUserAgent}
          originWhitelist={["*"]}
          onShouldStartLoadWithRequest={(request) => {
            if (maybeFinishFromUrl(request?.url)) return false;
            return true;
          }}
          onNavigationStateChange={(navState) => {
            void maybeFinishFromUrl(navState?.url);
          }}
          onLoadProgress={(event) => {
            void maybeFinishFromUrl((event as any)?.nativeEvent?.url);
          }}
          onLoadResource={(event: any) => {
            const nativeEvent = (event as any)?.nativeEvent ?? {};
            const url = String(nativeEvent?.url ?? '').trim();
            if (!url) return;
            if (url.includes('.mp4') || url.includes('.m3u8')) {
              void handleDownloadFound(
                url,
                nativeEvent?.contentType ?? nativeEvent?.mimeType ?? ''
              );
              return;
            }
            void maybeFinishFromUrl(url, nativeEvent?.contentType ?? nativeEvent?.mimeType ?? '');
          }}
          onLoadEnd={() => {
            setPageReady(true);
            injectedRequestIdRef.current = null;
          }}
          onMessage={handleMessage}
          source={{ uri: webUri }}
          javaScriptEnabled
          mixedContentMode="always"
          style={styles.webview}
        />
      </View>
    </>
  );
}

const styles = StyleSheet.create({
  container: { position: 'absolute', left: -9999, top: -9999, width: 1, height: 1 },
  webview: { width: 1, height: 1, opacity: 0 },
});
