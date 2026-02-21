const g = globalThis;
const extensions = {}; // map id -> extension manifest
let defaultExtensionId = null;
const DEV = typeof __DEV__ !== 'undefined' ? __DEV__ : true;
const dlog = (...args) => {
  if (DEV) console.log(...args);
};
const dwarn = (...args) => {
  if (DEV) console.warn(...args);
};

function ensureProvider() {
  if (!g.__WEBVIEW_SCRAPER__ || typeof g.__WEBVIEW_SCRAPER__.request !== 'function') {
    throw new Error('HiddenWebViewScraper provider is not mounted');
  }
}

export function loadExtension(extJson) {
  dlog('[ExtensionEngine] loadExtension called with:', extJson?.id);
  if (!extJson) {
    dwarn('[ExtensionEngine] loadExtension: extJson is null/undefined');
    return;
  }
  if (Array.isArray(extJson)) {
    extJson.forEach((e) => {
      if (e && e.id) extensions[e.id] = e;
      if (!defaultExtensionId && e && e.id) defaultExtensionId = e.id;
    });
    dlog('[ExtensionEngine] Loaded', extJson.length, 'extensions, defaultId:', defaultExtensionId);
    return;
  }
  if (extJson.id) {
    extensions[extJson.id] = extJson;
    if (!defaultExtensionId) defaultExtensionId = extJson.id;
    dlog('[ExtensionEngine] Loaded extension:', extJson.id, 'is now default');
  } else {
    const gid = 'ext_' + Math.random().toString(36).slice(2);
    extensions[gid] = extJson;
    if (!defaultExtensionId) defaultExtensionId = gid;
    dlog('[ExtensionEngine] Loaded extension with generated id:', gid);
  }
  dlog('[ExtensionEngine] Total extensions loaded:', Object.keys(extensions).length);
}

export function listExtensions() {
  return Object.keys(extensions).map((id) => ({ id, name: extensions[id].name || id }));
}

function pickExtension(moduleId) {
  dlog('[ExtensionEngine] pickExtension called with moduleId:', moduleId, 'available extensions:', Object.keys(extensions), 'defaultId:', defaultExtensionId);
  if (moduleId && extensions[moduleId]) {
    dlog('[ExtensionEngine] Found requested extension by moduleId:', moduleId);
    return extensions[moduleId];
  }
  if (defaultExtensionId && extensions[defaultExtensionId]) {
    dlog('[ExtensionEngine] Using default extension:', defaultExtensionId);
    return extensions[defaultExtensionId];
  }
  const keys = Object.keys(extensions);
  if (keys.length) {
    dlog('[ExtensionEngine] Using first available extension:', keys[0]);
    return extensions[keys[0]];
  }
  dwarn('[ExtensionEngine] No extensions available!');
  return null;
}

async function execInWebView(jsCode) {
  ensureProvider();
  const providerPromise = g.__WEBVIEW_SCRAPER__.request({ type: 'runExtension', title: jsCode });
  const timeoutMs = 20000; // 20s timeout (matches WebView per-request timeout)
  const timeoutPromise = new Promise((_, reject) => setTimeout(() => reject(new Error('Extension execution timed out')), timeoutMs));
  return Promise.race([providerPromise, timeoutPromise]);
}

async function runExtensionFunction(fnRaw, arg1, arg2) {
  const fn = typeof fnRaw === 'string' ? fnRaw : JSON.stringify(fnRaw);
  const code = `;(async function(){ try{\n    const extFn = ${JSON.stringify(fn)};\n    const fn = (typeof extFn === 'string') ? eval('(' + extFn + ')') : extFn;\n    if (typeof fn !== 'function') throw new Error('Extension entry is not a function');\n    const result = await fn(${JSON.stringify(arg1)}, ${JSON.stringify(arg2 ?? {})});\n    window.ReactNativeWebView.postMessage(JSON.stringify({type:'extensionResult', result: result}));\n  }catch(e){\n    window.ReactNativeWebView.postMessage(JSON.stringify({type:'extensionError', error: String(e)}));\n  }})(); true;`;
  return execInWebView(code);
}

export async function search(query, moduleId) {
  const extension = pickExtension(moduleId);
  if (!extension || !extension.search) return [];
  const res = await runExtensionFunction(extension.search, query, {});
  return res ?? [];
}

export async function fetchEpisodesForAnime(animeId, meta) {
  const extModuleId = meta && meta.moduleId ? meta.moduleId : undefined;
  const extension = pickExtension(extModuleId);
  if (!extension || (!extension.getEpisodes && !extension.episodes)) return [];
  const fnRaw = extension.getEpisodes || extension.episodes;
  const res = await runExtensionFunction(fnRaw, animeId, meta ?? {});
  return res ?? [];
}

export async function fetchSourcesForEpisode(episodeId, meta) {
  dlog('[ExtensionEngine] fetchSourcesForEpisode called with episodeId:', episodeId);
  const extModuleId = meta && meta.moduleId ? meta.moduleId : undefined;
  const extension = pickExtension(extModuleId);
  dlog('[ExtensionEngine] Picked extension:', extension?.id, 'has getSources:', !!extension?.getSources, 'has get_sources:', !!extension?.get_sources, 'has sources:', !!extension?.sources);
  if (!extension || (!extension.getSources && !extension.get_sources && !extension.sources)) {
    dlog('[ExtensionEngine] No extension or getSources function found, returning empty');
    return [];
  }
  const fnRaw = extension.getSources || extension.get_sources || extension.sources;
  dlog('[ExtensionEngine] Executing fetchSourcesForEpisode code in WebView');
  const res = await runExtensionFunction(fnRaw, episodeId, meta ?? {});
  dlog('[ExtensionEngine] fetchSourcesForEpisode result count:', Array.isArray(res) ? res.length : 0);
  return res ?? [];
}

export default {
  loadExtension,
  search,
  fetchEpisodesForAnime,
  fetchSourcesForEpisode,
  listExtensions,
};
