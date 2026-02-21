// ScraperService - AnimePahe module interpreter + Sora fallback for sources.
import ExtensionEngine from '@/services/ExtensionEngine.js';

const MODULE_URL =
  'https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.json';

type ModuleJson = {
  baseUrl?: string;
  searchBaseUrl?: string;
  scriptUrl?: string;
  searchUrlTemplate?: string;
  releaseUrlTemplate?: string;
  animeHrefTemplate?: string;
  playHrefTemplate?: string;
  animeIdRegex?: string;
};

type ModuleRuntime = {
  baseUrl: string;
  searchUrlTemplate: string;
  releaseUrlTemplate: string;
  animeHrefTemplate: string;
  playHrefTemplate: string;
  animeIdRegex: RegExp;
};

type AnimePaheSearchItem = {
  id: string;
  title: string;
  image?: string;
  href: string;
};

let runtimeCache: ModuleRuntime | null = null;
let runtimeCacheAt = 0;
const CACHE_TTL_MS = 5 * 60 * 1000;

export type EpisodeItem = {
  id: string;
  number: number;
  title?: string;
  playPageUrl?: string;
  streamUrl?: string;
};

function templateFill(template: string, vars: Record<string, string | number>) {
  return template.replace(/\$\{([^}]+)\}/g, (_, key) => String(vars[key] ?? ''));
}

function normalizeRegex(input: string | undefined, fallback: RegExp): RegExp {
  if (!input) return fallback;
  try {
    return new RegExp(input);
  } catch {
    return fallback;
  }
}

function extractScriptTemplate(script: string, pattern: RegExp, fallback: string) {
  const match = script.match(pattern);
  return match?.[1] ?? fallback;
}

async function fetchModuleRuntime(): Promise<ModuleRuntime> {
  if (runtimeCache && Date.now() - runtimeCacheAt < CACHE_TTL_MS) return runtimeCache;

  const fallbackBaseUrl = 'https://animepahe.si/';
  const fallbackSearchTemplate = 'https://animepahe.si/api?m=search&q=${encodedKeyword}';
  const fallbackReleaseTemplate =
    'https://animepahe.si/api?m=release&id=${id}&sort=episode_asc&page=${page}';
  const fallbackAnimeHrefTemplate = 'https://animepahe.si/anime/${session}';
  const fallbackPlayHrefTemplate = 'https://animepahe.si/play/${id}/${session}';
  const fallbackAnimeIdRegex = /\/anime\/([^/]+)/;

  try {
    const moduleRes = await fetch(MODULE_URL);
    if (!moduleRes.ok) throw new Error(`module fetch failed: ${moduleRes.status}`);
    const moduleJson = (await moduleRes.json()) as ModuleJson;

    const baseUrl = moduleJson.baseUrl ?? moduleJson.searchBaseUrl ?? fallbackBaseUrl;
    let searchUrlTemplate = moduleJson.searchUrlTemplate ?? fallbackSearchTemplate;
    let releaseUrlTemplate = moduleJson.releaseUrlTemplate ?? fallbackReleaseTemplate;
    let animeHrefTemplate = moduleJson.animeHrefTemplate ?? fallbackAnimeHrefTemplate;
    let playHrefTemplate = moduleJson.playHrefTemplate ?? fallbackPlayHrefTemplate;
    let animeIdRegex = normalizeRegex(moduleJson.animeIdRegex, fallbackAnimeIdRegex);

    if (moduleJson.scriptUrl) {
      try {
        const scriptRes = await fetch(moduleJson.scriptUrl);
        if (scriptRes.ok) {
          const script = await scriptRes.text();
          searchUrlTemplate = extractScriptTemplate(
            script,
            /fetchWithBypass\(`([^`]*api\?m=search&q=\$\{encodedKeyword\}[^`]*)`\)/,
            searchUrlTemplate
          );
          releaseUrlTemplate = extractScriptTemplate(
            script,
            /const apiUrl = `([^`]*api\?m=release&id=\$\{id\}&sort=episode_asc&page=\$\{pageNum\}[^`]*)`/,
            releaseUrlTemplate
          );
          if (!/pageNum/.test(releaseUrlTemplate)) {
            releaseUrlTemplate = extractScriptTemplate(
              script,
              /const apiUrl1 = `([^`]*api\?m=release&id=\$\{id\}&sort=episode_asc&page=\$\{page\}[^`]*)`/,
              releaseUrlTemplate
            );
          }
          animeHrefTemplate = extractScriptTemplate(
            script,
            /href:\s*`([^`]*\/anime\/\$\{result\.session\}[^`]*)`/,
            animeHrefTemplate
          );
          playHrefTemplate = extractScriptTemplate(
            script,
            /href:\s*`([^`]*\/play\/\$\{id\}\/\$\{item\.session\}[^`]*)`/,
            playHrefTemplate
          );
          const idRegexMatch = script.match(/url\.match\((\/\\\/anime\\\/\(\[\^\\\/\]\+\)\/)\)/);
          if (idRegexMatch?.[1]) {
            try {
              animeIdRegex = new RegExp(idRegexMatch[1].slice(1, -1));
            } catch {}
          }
        }
      } catch (scriptErr) {
        console.warn('[ScraperService] failed to parse scriptUrl templates', scriptErr);
      }
    }

    runtimeCache = {
      baseUrl,
      searchUrlTemplate,
      releaseUrlTemplate,
      animeHrefTemplate,
      playHrefTemplate,
      animeIdRegex,
    };
    runtimeCacheAt = Date.now();
    return runtimeCache;
  } catch (err) {
    console.warn('[ScraperService] module interpreter fallback activated', err);
    runtimeCache = {
      baseUrl: fallbackBaseUrl,
      searchUrlTemplate: fallbackSearchTemplate,
      releaseUrlTemplate: fallbackReleaseTemplate,
      animeHrefTemplate: fallbackAnimeHrefTemplate,
      playHrefTemplate: fallbackPlayHrefTemplate,
      animeIdRegex: fallbackAnimeIdRegex,
    };
    runtimeCacheAt = Date.now();
    return runtimeCache;
  }
}

export async function searchAnimePahe(query: string): Promise<AnimePaheSearchItem[]> {
  try {
    const runtime = await fetchModuleRuntime();
    const searchUrl = templateFill(runtime.searchUrlTemplate, {
      encodedKeyword: encodeURIComponent(query),
      keyword: query,
      query,
    });
    const res = await fetch(searchUrl, { headers: { Accept: 'application/json' } });
    if (!res.ok) return [];
    const json = await res.json();
    const data = Array.isArray(json?.data) ? json.data : [];

    return data
      .map((item: any): AnimePaheSearchItem | null => {
        const session = item?.session ? String(item.session) : '';
        if (!session) return null;
        return {
          id: session,
          title: String(item?.title ?? 'Unknown'),
          image: item?.poster ? String(item.poster) : undefined,
          href: templateFill(runtime.animeHrefTemplate, { session, id: session }),
        };
      })
      .filter((item: AnimePaheSearchItem | null): item is AnimePaheSearchItem => item != null);
  } catch (e) {
    console.warn('[ScraperService] searchAnimePahe failed', e);
    return [];
  }
}

export async function fetchEpisodesFromAnimePage(animeId: string): Promise<EpisodeItem[]> {
  try {
    const runtime = await fetchModuleRuntime();
    const idMatch = animeId.match(runtime.animeIdRegex);
    const sessionId = idMatch?.[1] ?? animeId;
    if (!sessionId) return [];

    const pageOneUrl = templateFill(runtime.releaseUrlTemplate, {
      id: sessionId,
      page: 1,
      pageNum: 1,
    });
    const firstRes = await fetch(pageOneUrl, { headers: { Accept: 'application/json' } });
    if (!firstRes.ok) return [];
    const firstJson = await firstRes.json();

    const totalPages = Number(firstJson?.last_page ?? 1);
    const allRaw = Array.isArray(firstJson?.data) ? [...firstJson.data] : [];

    for (let p = 2; p <= totalPages; p++) {
      try {
        const url = templateFill(runtime.releaseUrlTemplate, {
          id: sessionId,
          page: p,
          pageNum: p,
        });
        const resp = await fetch(url, { headers: { Accept: 'application/json' } });
        if (!resp.ok) continue;
        const pageJson = await resp.json();
        if (Array.isArray(pageJson?.data)) allRaw.push(...pageJson.data);
      } catch {
        // continue on per-page failures
      }
    }

    return allRaw
      .map((item: any, idx: number): EpisodeItem | null => {
        const epSession = item?.session ? String(item.session) : '';
        const number = Number(item?.episode ?? idx + 1);
        if (!epSession || !Number.isFinite(number)) return null;
        return {
          id: `${sessionId}/${epSession}`,
          number,
          title: item?.title ? String(item.title) : undefined,
          playPageUrl: templateFill(runtime.playHrefTemplate, {
            id: sessionId,
            session: epSession,
            episodeSession: epSession,
          }),
        };
      })
      .filter((item: EpisodeItem | null): item is EpisodeItem => item != null)
      .sort((a, b) => a.number - b.number);
  } catch (e) {
    console.warn('[ScraperService] fetchEpisodesFromAnimePage failed', e);
    return [];
  }
}

// Fetch sources using Sora extension's getSources function
export async function fetchSourcesForEpisode(episodeId: string, meta?: any): Promise<any[]> {
  try {
    if (__DEV__) {
      console.log('[ScraperService] Fetching sources via Sora extension for episodeId:', episodeId);
    }
    const sources = await ExtensionEngine.fetchSourcesForEpisode(episodeId, meta);
    if (__DEV__) {
      console.log('[ScraperService] Sora extension returned sources count:', Array.isArray(sources) ? sources.length : 0);
    }
    if (!Array.isArray(sources)) {
      console.warn('[ScraperService] Sources is not an array:', typeof sources);
      return [];
    }
    return sources;
  } catch (e) {
    console.warn('[ScraperService] fetchSourcesForEpisode failed:', e);
    return [];
  }
}

import webviewClient from './webviewScraperClient';
import type { SniffedDownloadLink } from './webviewScraperClient';

export async function extractKwik(playPageUrl: string): Promise<string | null> {
  try {
    // Delegate to the hidden WebView provider's extractor
    if (!webviewClient || typeof webviewClient.extractKwikWithWebView !== 'function') return null;
    const url = await webviewClient.extractKwikWithWebView(playPageUrl);
    return url;
  } catch (e) {
    if (__DEV__) console.log('[ScraperService] extractKwik fallback:', String((e as any)?.message ?? e));
    return null;
  }
}

export async function fetchDownloadLink(
  playPageUrl: string,
  preferredQuality?: string
): Promise<SniffedDownloadLink | null> {
  try {
    if (!webviewClient || typeof webviewClient.fetchDownloadLinkWithWebView !== 'function') return null;
    const sniffed = await webviewClient.fetchDownloadLinkWithWebView(playPageUrl, preferredQuality);
    const normalized = String((sniffed as any)?.url ?? '').trim();
    if (!normalized || !/\.(mp4|m3u8|m4v|webm|ts)(?:[\?#]|$)/i.test(normalized)) return null;
    const headers = (sniffed as any)?.headers && typeof (sniffed as any).headers === 'object'
      ? ((sniffed as any).headers as Record<string, string>)
      : undefined;
    return { url: normalized, headers };
  } catch (e) {
    // Best-effort path only; timeout/failure should silently fall back to HLS sources.
    if (__DEV__) console.log('[ScraperService] fetchDownloadLink fallback:', String((e as any)?.message ?? e));
    return null;
  }
}

const firstMatch = (text: string, regex: RegExp) => text.match(regex)?.[0] ?? null;

const findDirectMp4 = (text: string): string | null => {
  const blob = String(text ?? '');
  const candidates = [
    /https?:\/\/[^\s"'\\]+\.mp4(?:\?[^\s"'\\]*)?/i,
    /["'](https?:\/\/[^"']+\.mp4(?:\?[^"']*)?)["']/i,
    /file:\s*["'](https?:\/\/[^"']+\.mp4(?:\?[^"']*)?)["']/i,
    /source:\s*["'](https?:\/\/[^"']+\.mp4(?:\?[^"']*)?)["']/i,
  ];
  for (const rx of candidates) {
    const m = blob.match(rx);
    if (m?.[1]) return m[1];
    if (m?.[0]?.startsWith('http')) return m[0];
  }
  return null;
};

const asAbsolute = (base: string, candidate: string): string | null => {
  try {
    return new URL(candidate, base).toString();
  } catch {
    return null;
  }
};

const collectKwikCandidates = (html: string, base: string): string[] => {
  const out: string[] = [];
  const seen = new Set<string>();
  const push = (u: string | null) => {
    const v = String(u ?? '').trim();
    if (!v || seen.has(v)) return;
    seen.add(v);
    out.push(v);
  };
  const kwikRe = /(data-src|src|href)=["']([^"']*kwik[^"']*)["']/gi;
  let m: RegExpExecArray | null;
  while ((m = kwikRe.exec(html)) !== null) {
    push(asAbsolute(base, m[2] ?? ''));
  }
  return out;
};

const collectDownloadCandidates = (html: string, base: string): string[] => {
  const out: string[] = [];
  const seen = new Set<string>();
  const push = (u: string | null) => {
    const v = String(u ?? '').trim();
    if (!v || seen.has(v)) return;
    seen.add(v);
    out.push(v);
  };

  const downloadRe = /(href|data-src|src)=["']([^"']*(?:\/d\/|download|dl=)[^"']*)["']/gi;
  let m: RegExpExecArray | null;
  while ((m = downloadRe.exec(html)) !== null) {
    push(asAbsolute(base, m[2] ?? ''));
  }

  return out;
};

const resolveMp4ViaRedirect = async (
  candidateUrl: string,
  headers: Record<string, string>
): Promise<string | null> => {
  const tryLocation = (loc: string | null) => {
    if (!loc) return null;
    const abs = asAbsolute(candidateUrl, loc) ?? loc;
    if (/\.mp4(?:[\?#]|$)/i.test(abs)) return abs;
    return null;
  };

  try {
    const head = await fetch(candidateUrl, {
      method: 'HEAD',
      redirect: 'manual',
      headers,
    });
    const fromHead = tryLocation(head.headers.get('location'));
    if (fromHead) return fromHead;
    if (head.ok && /\.mp4(?:[\?#]|$)/i.test(candidateUrl)) return candidateUrl;
  } catch {}

  try {
    const get = await fetch(candidateUrl, {
      method: 'GET',
      redirect: 'manual',
      headers,
    });
    const fromGet = tryLocation(get.headers.get('location'));
    if (fromGet) return fromGet;
    const finalUrl = String((get as any)?.url ?? candidateUrl);
    if (/\.mp4(?:[\?#]|$)/i.test(finalUrl)) return finalUrl;
    if (get.ok) {
      const body = await get.text();
      const inline = findDirectMp4(body);
      if (inline) return inline;
    }
  } catch {}

  return null;
};

export async function extractDirectMp4FromPlayPage(
  playPageUrl: string
): Promise<{ url: string; headers?: Record<string, string> } | null> {
  try {
    const playPage = String(playPageUrl ?? '').trim();
    if (!playPage) return null;
    const playHtml = await fetch(playPage, {
      headers: {
        Accept: 'text/html',
        'User-Agent':
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      },
    }).then((r) => (r.ok ? r.text() : ''));
    if (!playHtml) return null;

    const directFromPlay = findDirectMp4(playHtml) ?? firstMatch(playHtml, /https?:\/\/[^\s"'\\]+\.mp4(?:\?[^\s"'\\]*)?/i);
    if (directFromPlay) {
      return { url: directFromPlay, headers: { Referer: playPage } };
    }

    const kwikCandidates = collectKwikCandidates(playHtml, playPage);
    for (const kwikUrl of kwikCandidates) {
      try {
        const kwikHtml = await fetch(kwikUrl, {
          headers: {
            Referer: playPage,
            Accept: 'text/html',
            'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
          },
        }).then((r) => (r.ok ? r.text() : ''));
        if (!kwikHtml) continue;
        const direct = findDirectMp4(kwikHtml) ?? firstMatch(kwikHtml, /https?:\/\/[^\s"'\\]+\.mp4(?:\?[^\s"'\\]*)?/i);
        if (!direct) continue;
        let origin = '';
        try {
          origin = new URL(kwikUrl).origin;
        } catch {}
        return {
          url: direct,
          headers: {
            Referer: kwikUrl,
            ...(origin ? { Origin: origin } : {}),
          },
        };
      } catch {
        // continue candidates
      }
    }

    // Fallback: parse explicit download endpoints and follow redirects to MP4.
    const kwikAndPlayPages = [playPage, ...kwikCandidates];
    for (const pageUrl of kwikAndPlayPages) {
      try {
        const referer = pageUrl === playPage ? playPage : playPage;
        const pageHtml = await fetch(pageUrl, {
          headers: {
            Referer: referer,
            Accept: 'text/html',
            'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
          },
        }).then((r) => (r.ok ? r.text() : ''));
        if (!pageHtml) continue;
        const downloadCandidates = collectDownloadCandidates(pageHtml, pageUrl);
        for (const downloadUrl of downloadCandidates) {
          let origin = '';
          try {
            origin = new URL(pageUrl).origin;
          } catch {}
          const headers: Record<string, string> = {
            Referer: pageUrl,
            ...(origin ? { Origin: origin } : {}),
            'User-Agent':
              'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
          };
          const resolved = await resolveMp4ViaRedirect(downloadUrl, headers);
          if (resolved) {
            return { url: resolved, headers };
          }
        }
      } catch {
        // continue
      }
    }

    return null;
  } catch (e) {
    console.warn('extractDirectMp4FromPlayPage failed', e);
    return null;
  }
}

export async function extractDirectMp4FromKwikPage(
  kwikUrl: string,
  playPageReferer?: string
): Promise<{ url: string; headers?: Record<string, string> } | null> {
  try {
    const kwik = String(kwikUrl ?? '').trim();
    if (!kwik) return null;
    const referer = String(playPageReferer ?? '').trim();
    const kwikOrigin = (() => {
      try {
        return new URL(kwik).origin;
      } catch {
        return '';
      }
    })();
    const baseHeaders: Record<string, string> = {
      Accept: 'text/html',
      'User-Agent':
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1',
      ...(referer ? { Referer: referer } : {}),
      ...(kwikOrigin ? { Origin: kwikOrigin } : {}),
    };

    const kwikHtml = await fetch(kwik, { headers: baseHeaders }).then((r) => (r.ok ? r.text() : ''));
    if (!kwikHtml) return null;

    const direct = findDirectMp4(kwikHtml) ?? firstMatch(kwikHtml, /https?:\/\/[^\s"'\\]+\.mp4(?:\?[^\s"'\\]*)?/i);
    if (direct) {
      return {
        url: direct,
        headers: {
          Referer: kwik,
          ...(kwikOrigin ? { Origin: kwikOrigin } : {}),
        },
      };
    }

    const downloadCandidates = collectDownloadCandidates(kwikHtml, kwik);
    for (const downloadUrl of downloadCandidates) {
      const resolved = await resolveMp4ViaRedirect(downloadUrl, {
        ...baseHeaders,
        Referer: kwik,
      });
      if (!resolved) continue;
      return {
        url: resolved,
        headers: {
          Referer: kwik,
          ...(kwikOrigin ? { Origin: kwikOrigin } : {}),
        },
      };
    }

    return null;
  } catch (e) {
    console.warn('extractDirectMp4FromKwikPage failed', e);
    return null;
  }
}

export default {
  searchAnimePahe,
  fetchEpisodesFromAnimePage,
  fetchSourcesForEpisode,
  extractKwik,
  fetchDownloadLink,
  extractDirectMp4FromPlayPage,
  extractDirectMp4FromKwikPage,
};
