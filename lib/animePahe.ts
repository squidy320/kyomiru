import * as FileSystem from 'expo-file-system';

// Client-side AnimePahe helper.
// We call AnimePahe's public JSON API directly from the app to get
// the REAL episode list. Names are matched with AniList (romaji/english/native)
// and episode count is aligned to what AniList shows.
// For streaming, we still use a safe public test HLS URL.

export type AniListMatchOptions = {
  episodeCount: number | null;
  titles: {
    romaji?: string | null;
    english?: string | null;
    native?: string | null;
  };
};

export type Episode = {
  id: string;
  number: number;
  title?: string;
  streamUrl: string;
  download: () => Promise<void>;
};

type FetchEpisodesOptions = {
  animePaheSessionId?: string | null;
  onPartialEpisodes?: (episodes: Episode[], loadedPages: number, totalPages: number) => void;
};

export type AnimePaheAnime = {
  session: string;
  title: string;
};

async function downloadToLocal(pathName: string, url: string) {
  const downloadsDir = (FileSystem as any).documentDirectory + 'downloads/';
  await FileSystem.makeDirectoryAsync(downloadsDir, { intermediates: true });
  const fileUri = downloadsDir + pathName;

  const downloadResumable = FileSystem.createDownloadResumable(url, fileUri);
  await downloadResumable.downloadAsync();
}

const DEFAULT_HEADERS = {
  'User-Agent':
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
  Accept: 'application/json',
  'Accept-Language': 'en-US,en;q=0.9',
};

async function fetchJsonSafe(url: string): Promise<any> {
  const res = await fetch(url, { headers: DEFAULT_HEADERS });
  if (!res.ok) return null;
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    return null;
  }
}

async function fetchHtmlSafe(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, {
      headers: {
        ...DEFAULT_HEADERS,
        Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      },
    });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  }
}

/** Search AnimePahe and return list of anime with session IDs and titles */
export async function searchAnimePahe(query: string): Promise<AnimePaheAnime[]> {
  const searchHtml = await fetchHtmlSafe(
    `https://animepahe.si/?q=${encodeURIComponent(query)}`
  );
  if (!searchHtml) return [];

  // Parse session IDs from links: href="/anime/SESSION"
  const sessionRegex = /href=["']\/anime\/([a-zA-Z0-9_-]+)["']/g;
  const matches = [...searchHtml.matchAll(sessionRegex)];
  const sessionIds = [...new Set(matches.map((m) => m[1]))];

  // Try to get titles from link text: <a href="/anime/xxx">Title</a>
  const linkTitleRegex = /href=["']\/anime\/([a-zA-Z0-9_-]+)["'][^>]*>([^<]+)</g;
  const linkMatches = [...searchHtml.matchAll(linkTitleRegex)];
  const sessionToTitle: Record<string, string> = {};
  for (const m of linkMatches) {
    if (m[1] && m[2] && !sessionToTitle[m[1]]) sessionToTitle[m[1]] = m[2].trim();
  }

  const results: AnimePaheAnime[] = sessionIds.map((sid) => ({
    session: sid,
    title: sessionToTitle[sid] ?? sid,
  }));

  return results;
}

/** Scrape AnimePahe: get session from search HTML, then try API release or parse anime page. */
async function scrapeAnimePaheEpisodes(
  searchQuery: string,
  titles: AniListMatchOptions['titles'],
  maxEpisodes: number | null
): Promise<Episode[]> {
  const safeTitle = searchQuery.replace(/[^a-z0-9]/gi, '_').toLowerCase();
  const demoStreamUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

  const searchHtml = await fetchHtmlSafe(
    `https://animepahe.si/?q=${encodeURIComponent(searchQuery)}`
  );
  if (!searchHtml) return [];

  // Parse session IDs from links: href="/anime/SESSION" or href='/anime/SESSION'
  const sessionRegex = /href=["']\/anime\/([a-zA-Z0-9_-]+)["']/g;
  const matches = [...searchHtml.matchAll(sessionRegex)];
  const sessionIds = [...new Set(matches.map((m) => m[1]))];
  if (sessionIds.length === 0) return [];

  // Try to get titles from link text: <a href="/anime/xxx">Title</a>
  const linkTitleRegex = /href=["']\/anime\/([a-zA-Z0-9_-]+)["'][^>]*>([^<]+)</g;
  const linkMatches = [...searchHtml.matchAll(linkTitleRegex)];
  const sessionToTitle: Record<string, string> = {};
  for (const m of linkMatches) {
    if (m[1] && m[2] && !sessionToTitle[m[1]]) sessionToTitle[m[1]] = m[2].trim();
  }

  let bestSession: string | null = null;
  let bestScore = 0;
  for (const sid of sessionIds) {
    const title = sessionToTitle[sid] ?? '';
    const score = scoreMatch(title, titles);
    if (score > bestScore) {
      bestScore = score;
      bestSession = sid;
    }
  }
  const sessionId = bestSession ?? sessionIds[0];
  if (!sessionId) return [];

  // Try API release with scraped session (in case only search was blocked)
  const firstRelease = await fetchJsonSafe(
    `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=1`
  );
  if (firstRelease?.data && Array.isArray(firstRelease.data)) {
    const allRaw: any[] = [...(firstRelease.data || [])];
    const totalPages = firstRelease.last_page ?? 1;
    for (let page = 2; page <= totalPages; page++) {
      const p = await fetchJsonSafe(
        `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=${page}`
      );
      if (p?.data && Array.isArray(p.data)) allRaw.push(...p.data);
    }
    if (allRaw.length > 0) {
      let episodes: Episode[] = allRaw
        .map((ep) => {
          const epNumber = ep.episode as number;
          const id = ep.session as string;
          const fileName = `${safeTitle}_episode_${epNumber}.mp4`;
          return {
            id,
            number: epNumber,
            title:
              typeof ep.title === 'string' && ep.title.trim()
                ? ep.title
                : `${searchQuery} - Episode ${epNumber}`,
            streamUrl: demoStreamUrl,
            download: () => downloadToLocal(fileName, demoStreamUrl),
          };
        })
        .sort((a, b) => a.number - b.number);
      if (maxEpisodes != null && maxEpisodes > 0 && episodes.length > maxEpisodes) {
        episodes = episodes.filter((ep) => ep.number <= maxEpisodes);
      }
      return episodes;
    }
  }

  // Scrape anime page for episode list (embedded in script or table)
  const animeHtml = await fetchHtmlSafe(`https://animepahe.si/anime/${sessionId}`);
  if (!animeHtml) return [];

  const episodes: Episode[] = [];
  // Match "episode":N or "episode": N in JSON-like blocks
  const episodeNumRegex = /"episode"\s*:\s*(\d+)/g;
  let epMatch;
  const seen = new Set<number>();
  while ((epMatch = episodeNumRegex.exec(animeHtml)) !== null) {
    const num = parseInt(epMatch[1], 10);
    if (num >= 1 && num <= 2000 && !seen.has(num)) {
      seen.add(num);
      episodes.push({
        id: `${sessionId}_ep_${num}`,
        number: num,
        title: `${searchQuery} - Episode ${num}`,
        streamUrl: demoStreamUrl,
        download: () =>
          downloadToLocal(`${safeTitle}_episode_${num}.mp4`, demoStreamUrl),
      });
    }
  }
  if (episodes.length === 0) return [];

  const sorted = episodes.sort((a, b) => a.number - b.number);
  const capped =
    maxEpisodes != null && maxEpisodes > 0 && sorted.length > maxEpisodes
      ? sorted.filter((ep) => ep.number <= maxEpisodes)
      : sorted;
  return capped;
}

function normalizeForMatch(s: string): string {
  if (typeof s !== 'string') return '';
  return s
    .toLowerCase()
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/[^\w\s]/g, '');
}

function scoreMatch(animePaheTitle: string, anilistTitles: AniListMatchOptions['titles']): number {
  const normalized = normalizeForMatch(animePaheTitle ?? '');
  if (!normalized) return 0;
  const candidates = [
    anilistTitles?.romaji,
    anilistTitles?.english,
    anilistTitles?.native,
  ].filter((t): t is string => typeof t === 'string' && t.length > 0);
  for (const t of candidates) {
    const n = normalizeForMatch(t);
    const normQuery = n.replace(/\s/g, '');
    const normPahe = normalized.replace(/\s/g, '');
    if (normQuery === normPahe) return 100;
    if (normPahe.includes(normQuery) || normQuery.includes(normPahe)) return 80;
    const wordsA = new Set(normalized.split(/\s+/).filter(Boolean));
    const wordsB = new Set(n.split(/\s+/).filter(Boolean));
    if (wordsA.size === 0 || wordsB.size === 0) continue;
    const intersect = [...wordsA].filter((x) => wordsB.has(x)).length;
    const ratio = intersect / Math.min(wordsA.size, wordsB.size);
    if (ratio >= 0.8) return 70;
    if (ratio >= 0.5) return 50;
  }
  return 0;
}

function buildFallbackEpisodes(animeTitle: string, episodeCount?: number | null): Episode[] {
  const safeTitle = animeTitle.replace(/[^a-z0-9]/gi, '_').toLowerCase();
  const demoStreamUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
  const count = episodeCount != null && episodeCount > 0 ? Math.min(episodeCount, 200) : 12;

  return Array.from({ length: count }).map((_, index) => {
    const epNumber = index + 1;
    const id = `${safeTitle}_ep_${epNumber}`;
    const fileName = `${safeTitle}_episode_${epNumber}.mp4`;

    return {
      id,
      number: epNumber,
      title: `${animeTitle} - Episode ${epNumber}`,
      streamUrl: demoStreamUrl,
      download: () => downloadToLocal(fileName, demoStreamUrl),
    };
  });
}

async function fetchEpisodesBySessionId(
  sessionIdRaw: string,
  animeTitle: string,
  anilistMatch?: AniListMatchOptions | null
): Promise<Episode[]> {
  const sessionId = String(sessionIdRaw || '').trim();
  if (!sessionId) return [];
  const safeTitle = animeTitle.replace(/[^a-z0-9]/gi, '_').toLowerCase();

  // Prefer extension runtime first so behavior stays consistent with source extraction.
  try {
    const Engine = await import('@/services/ExtensionEngine.js');
    const extEpisodes = await Engine.fetchEpisodesForAnime(sessionId, { title: animeTitle });
    if (Array.isArray(extEpisodes) && extEpisodes.length > 0) {
      const mapped = extEpisodes
        .map((ep: any, idx: number) => {
          const num = Number(ep?.number ?? ep?.episode ?? idx + 1);
          if (!Number.isFinite(num)) return null;
          const rawId = String(ep?.id ?? '').trim();
          const normalizedId = rawId
            ? (rawId.includes('/') ? rawId : `${sessionId}/${rawId}`)
            : `${sessionId}/${num}`;
          const stream =
            ep?.streamUrl ?? ep?.url ?? 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
          return {
            id: normalizedId,
            number: num,
            title:
              typeof ep?.title === 'string' && ep.title.trim()
                ? ep.title
                : `${animeTitle} - Episode ${num}`,
            streamUrl: stream,
            download: () => downloadToLocal(`${safeTitle}_episode_${num}.mp4`, stream),
          } as Episode;
        })
        .filter((ep: Episode | null): ep is Episode => ep != null)
        .sort((a: Episode, b: Episode) => a.number - b.number);

      const maxEpisodes = anilistMatch?.episodeCount ?? null;
      if (maxEpisodes != null && maxEpisodes > 0 && mapped.length > maxEpisodes) {
        return mapped.filter((ep) => ep.number <= maxEpisodes);
      }
      return mapped;
    }
  } catch {}

  // Direct API fallback by known session id.
  try {
    const firstRelease = await fetchJsonSafe(
      `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=1`
    );
    if (!firstRelease?.data || !Array.isArray(firstRelease.data)) return [];
    const allRaw: any[] = [...firstRelease.data];
    const totalPages = firstRelease.last_page ?? 1;
    for (let page = 2; page <= totalPages; page++) {
      const p = await fetchJsonSafe(
        `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=${page}`
      );
      if (p?.data && Array.isArray(p.data)) allRaw.push(...p.data);
    }

    const demoStreamUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
    let episodes: Episode[] = allRaw
      .map((ep) => {
        const epNumber = Number(ep.episode);
        const epSession = String(ep.session ?? '').trim();
        if (!Number.isFinite(epNumber) || !epSession) return null;
        return {
          id: `${sessionId}/${epSession}`,
          number: epNumber,
          title:
            typeof ep.title === 'string' && ep.title.trim()
              ? ep.title
              : `${animeTitle} - Episode ${epNumber}`,
          streamUrl: demoStreamUrl,
          download: () => downloadToLocal(`${safeTitle}_episode_${epNumber}.mp4`, demoStreamUrl),
        } as Episode;
      })
      .filter((ep: Episode | null): ep is Episode => ep != null)
      .sort((a, b) => a.number - b.number);

    const maxEpisodes = anilistMatch?.episodeCount ?? null;
    if (maxEpisodes != null && maxEpisodes > 0 && episodes.length > maxEpisodes) {
      episodes = episodes.filter((ep) => ep.number <= maxEpisodes);
    }
    return episodes;
  } catch {
    return [];
  }
}

// Fetch REAL episodes from AnimePahe; match name with AniList titles and align episode count.
// Tries Consumet (react-native-consumet) first, then direct API, then scraper, then fallback.
export async function fetchEpisodesForAnime(
  animeTitle: string,
  anilistMatch?: AniListMatchOptions | null,
  options?: FetchEpisodesOptions
): Promise<Episode[]> {
  const safeTitle = animeTitle.replace(/[^a-z0-9]/gi, '_').toLowerCase();
  const titles = anilistMatch?.titles ?? {
    romaji: animeTitle,
    english: null,
    native: null,
  };
  const titleQueries = [
    titles.english,
    titles.romaji,
    titles.native,
    animeTitle,
  ]
    .map((s) => String(s ?? '').trim())
    .filter(Boolean)
    .filter((v, i, arr) => arr.indexOf(v) === i);
  const searchQuery = titleQueries[0] || animeTitle;

  const forcedSessionId = String(options?.animePaheSessionId ?? '').trim();
  if (forcedSessionId) {
    const forced = await fetchEpisodesBySessionId(forcedSessionId, animeTitle, anilistMatch);
    if (forced.length > 0) return forced;
  }

  try {
    // 0) Try ExtensionEngine (Sora-compatible extension) first
    try {
      const Engine = await import('@/services/ExtensionEngine.js');
      let best: any = null;
      let bestScore = 0;
      let bestQuery = searchQuery;

      for (const q of titleQueries) {
        const extSearchResults = await Engine.search(q);
        if (!Array.isArray(extSearchResults) || extSearchResults.length === 0) continue;
        for (const item of extSearchResults) {
          const score = scoreMatch(String(item?.title ?? item?.name ?? ''), titles);
          if (score > bestScore) {
            bestScore = score;
            best = item;
            bestQuery = q;
          }
        }
        if (bestScore >= 95) break;
      }

      // Prevent wrong-anime picks from weak fuzzy matches.
      if (best && bestScore >= 60) {
        const animeId = String(best?.id ?? best?.session ?? '');
        if (animeId) {
          const extEpisodes = await Engine.fetchEpisodesForAnime(animeId, { title: bestQuery, titles });
          if (Array.isArray(extEpisodes) && extEpisodes.length > 0) {
            const mapped = extEpisodes
              .map((ep: any, idx: number) => {
                const num = Number(ep?.number ?? ep?.episode ?? idx + 1);
                if (!Number.isFinite(num)) return null;
                const id = String(ep?.id ?? '').trim();
                const safeId = id ? (id.includes('/') ? id : `${animeId}/${id}`) : `${animeId}/${num}`;
                const stream =
                  ep?.streamUrl ?? ep?.url ?? 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
                const fileName = `${safeTitle}_episode_${num}.mp4`;
                return {
                  id: safeId,
                  number: num,
                  title:
                    typeof ep?.title === 'string' && ep.title.trim()
                      ? ep.title
                      : `${bestQuery} - Episode ${num}`,
                  streamUrl: stream,
                  download: () => downloadToLocal(fileName, stream),
                } as Episode;
              })
              .filter((ep: Episode | null): ep is Episode => ep != null)
              .sort((a: Episode, b: Episode) => a.number - b.number);

            const maxEpisodes = anilistMatch?.episodeCount ?? null;
            if (maxEpisodes != null && maxEpisodes > 0 && mapped.length > maxEpisodes) {
              return mapped.filter((ep) => ep.number <= maxEpisodes);
            }
            return mapped;
          }
        }
      }
    } catch (e) {
      // engine not available or failed; try hidden WebView scraper
      try {
        const scraper = await import('@/lib/webviewScraperClient');
        for (const q of titleQueries) {
          const scraped = await scraper.scrapeEpisodesWithWebView(q);
          if (scraped && Array.isArray(scraped) && scraped.length > 0) {
            return scraped.map((ep: any) => ({
              id: ep.id,
              number: ep.number,
              title:
                typeof ep.title === 'string' && ep.title.trim()
                  ? ep.title
                  : `${q} - Episode ${ep.number}`,
              streamUrl: ep.streamUrl ?? 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8',
              download: () => downloadToLocal(`${q.replace(/[^a-z0-9]/gi,'_')}_episode_${ep.number}.mp4`, ep.streamUrl ?? 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
            } as Episode));
          }
        }
      } catch (e2) {
        // fall through to other methods below
      }
    }
  } catch (_) {
    // Extension attempt failed; continue to direct API
  }

  try {
    // 1) Search AnimePahe using english/romaji/native/title and pick highest confidence.
    let sessionId: string | null = null;
    let bestScore = 0;
    let bestQuery = searchQuery;

    for (const q of titleQueries) {
      const searchUrl = `https://animepahe.si/api?m=search&q=${encodeURIComponent(q)}`;
      const searchJson = await fetchJsonSafe(searchUrl);
      if (!searchJson?.data || !Array.isArray(searchJson.data) || searchJson.data.length === 0) {
        continue;
      }
      const data = searchJson.data as { title?: string; session?: string }[];
      for (const item of data) {
        const score = scoreMatch(String(item?.title ?? ''), titles);
        if (score > bestScore && item?.session) {
          bestScore = score;
          sessionId = String(item.session);
          bestQuery = q;
        }
      }
      if (bestScore >= 95) break;
    }

    // Refuse weak title matches that often produce another series.
    if (!sessionId || bestScore < 60) {
      for (const q of titleQueries) {
        const scraped = await scrapeAnimePaheEpisodes(q, titles, anilistMatch?.episodeCount ?? null);
        if (scraped.length > 0) return scraped;
      }
      return buildFallbackEpisodes(animeTitle, anilistMatch?.episodeCount);
    }

    // 3) First page of releases to get total pages
    const firstReleaseUrl = `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=1`;
    const firstReleaseJson = await fetchJsonSafe(firstReleaseUrl);
    const totalPages: number = firstReleaseJson?.last_page ?? 1;

    // 4) Fetch all pages (one by one to avoid overloading; catch per-page)
    const allEpisodesRaw: any[] = [];
    const emitPartial = (loadedPages: number, totalPages: number) => {
      if (typeof options?.onPartialEpisodes !== 'function') return;
      const demoStreamUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';
      let partial: Episode[] = allEpisodesRaw
        .map((ep) => {
          const epNumber = ep.episode as number;
          const epSession = ep.session as string;
          if (!Number.isFinite(epNumber) || !epSession) return null;
          const id = `${sessionId}/${epSession}`;
          const fileName = `${safeTitle}_episode_${epNumber}.mp4`;
          return {
            id,
            number: epNumber,
            title:
              typeof ep.title === 'string' && ep.title.trim()
                ? ep.title
                : `${bestQuery} - Episode ${epNumber}`,
            streamUrl: demoStreamUrl,
            download: () => downloadToLocal(fileName, demoStreamUrl),
          } as Episode;
        })
        .filter((ep: Episode | null): ep is Episode => ep != null)
        .sort((a, b) => a.number - b.number);

      const maxEpisodes = anilistMatch?.episodeCount ?? null;
      if (maxEpisodes != null && maxEpisodes > 0 && partial.length > maxEpisodes) {
        partial = partial.filter((ep) => ep.number <= maxEpisodes);
      }
      options.onPartialEpisodes(partial, loadedPages, totalPages);
    };

    for (let page = 1; page <= totalPages; page++) {
      const pageUrl = `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=${page}`;
      const pageData = await fetchJsonSafe(pageUrl);
      if (pageData?.data && Array.isArray(pageData.data)) {
        allEpisodesRaw.push(...pageData.data);
        emitPartial(page, totalPages);
      }
    }

    const demoStreamUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

    if (allEpisodesRaw.length === 0) {
      const scraped = await scrapeAnimePaheEpisodes(searchQuery, titles, anilistMatch?.episodeCount ?? null);
      if (scraped.length > 0) return scraped;
      return buildFallbackEpisodes(animeTitle, anilistMatch?.episodeCount);
    }

    let episodes: Episode[] = allEpisodesRaw
      .map((ep) => {
        const epNumber = ep.episode as number;
        const epSession = ep.session as string;
        const id = `${sessionId}/${epSession}`;
        const fileName = `${safeTitle}_episode_${epNumber}.mp4`;

        return {
          id,
          number: epNumber,
          title:
            typeof ep.title === 'string' && ep.title.trim()
              ? ep.title
              : `${bestQuery} - Episode ${epNumber}`,
          streamUrl: demoStreamUrl,
          download: () => downloadToLocal(fileName, demoStreamUrl),
        };
      })
      .sort((a, b) => a.number - b.number);

    // 5) Align to AniList episode count when provided
    const maxEpisodes = anilistMatch?.episodeCount ?? null;
    if (maxEpisodes != null && maxEpisodes > 0 && episodes.length > maxEpisodes) {
      episodes = episodes.filter((ep) => ep.number <= maxEpisodes);
    }

    return episodes;
  } catch (e) {
    console.warn('AnimePahe API failed, trying scraper then fallback.', e);
    try {
      for (const q of titleQueries) {
        const scraped = await scrapeAnimePaheEpisodes(q, titles, anilistMatch?.episodeCount ?? null);
        if (scraped.length > 0) return scraped;
      }
    } catch (_) {}
    return buildFallbackEpisodes(animeTitle, anilistMatch?.episodeCount);
  }
}
