export function toRuntimeAnimePaheExtension(payload: any) {
  if (!payload || typeof payload !== 'object') return null;

  const directRuntimeCandidates = [
    payload,
    payload.extension,
    payload.source,
    ...(Array.isArray(payload.extensions) ? payload.extensions : []),
  ].filter(Boolean);

  const runnable = directRuntimeCandidates.find(
    (c: any) =>
      c &&
      (c.getSources || c.get_sources || c.sources || c.search || c.getEpisodes || c.episodes)
  );
  if (runnable) return runnable;

  const ensureTrailingSlash = (v: string) => (v.endsWith('/') ? v : `${v}/`);
  const baseUrl = ensureTrailingSlash(
    String(payload.baseUrl ?? payload.searchBaseUrl ?? 'https://animepahe.si/')
  );
  const searchUrlTemplate = String(
    payload.searchUrlTemplate ?? `${baseUrl}api?m=search&q=\${encodedKeyword}`
  );
  const releaseUrlTemplate = String(
    payload.releaseUrlTemplate ?? `${baseUrl}api?m=release&id=\${id}&sort=episode_asc&page=\${page}`
  );
  const playHrefTemplate = String(
    payload.playHrefTemplate ?? `${baseUrl}play/\${id}/\${session}`
  );

  return {
    id: String(payload.id ?? 'animepahe-luna-adapter'),
    name: String(payload.name ?? 'AnimePahe (Luna Adapter)'),
    version: String(payload.version ?? '1.0.0'),
    search: `async (query) => {
      const templateFill = (template, vars) => {
        let out = String(template ?? '');
        Object.keys(vars || {}).forEach((k) => {
          out = out.split('\${' + k + '}').join(String(vars[k] ?? ''));
        });
        return out;
      };
      const searchUrl = templateFill(${JSON.stringify(searchUrlTemplate)}, {
        encodedKeyword: encodeURIComponent(query),
        keyword: query,
        query,
      });
      const res = await fetch(searchUrl, { headers: { Accept: 'application/json' } });
      if (!res.ok) return [];
      const json = await res.json();
      const data = Array.isArray(json?.data) ? json.data : [];
      return data.map((d) => ({
        id: d.session,
        title: d.title,
        name: d.title,
        image: d.poster || d.snapshot || null,
      }));
    }`,
    getEpisodes: `async (animeId) => {
      const templateFill = (template, vars) => {
        let out = String(template ?? '');
        Object.keys(vars || {}).forEach((k) => {
          out = out.split('\${' + k + '}').join(String(vars[k] ?? ''));
        });
        return out;
      };
      const raw = String(animeId ?? '');
      const m = raw.match(/\\/anime\\/([^/]+)/);
      const id = m ? m[1] : raw;
      if (!id) return [];

      const firstUrl = templateFill(${JSON.stringify(releaseUrlTemplate)}, { id, page: 1, pageNum: 1 });
      const firstRes = await fetch(firstUrl, { headers: { Accept: 'application/json' } });
      if (!firstRes.ok) return [];
      const first = await firstRes.json();
      const pages = Number(first?.last_page ?? 1);
      const all = Array.isArray(first?.data) ? [...first.data] : [];

      for (let p = 2; p <= pages; p++) {
        try {
          const url = templateFill(${JSON.stringify(releaseUrlTemplate)}, { id, page: p, pageNum: p });
          const r = await fetch(url, { headers: { Accept: 'application/json' } });
          if (!r.ok) continue;
          const j = await r.json();
          if (Array.isArray(j?.data)) all.push(...j.data);
        } catch {}
      }

      return all.map((ep, idx) => ({
        id: id + '/' + String(ep?.session ?? idx + 1),
        number: Number(ep?.episode ?? idx + 1),
        title: ep?.title ?? undefined,
      })).filter((ep) => ep.id && Number.isFinite(ep.number)).sort((a, b) => a.number - b.number);
    }`,
    getSources: `async (episodeId) => {
      const templateFill = (template, vars) => {
        let out = String(template ?? '');
        Object.keys(vars || {}).forEach((k) => {
          out = out.split('\${' + k + '}').join(String(vars[k] ?? ''));
        });
        return out;
      };
      const findMedia = (text) => {
        if (!text) return null;
        const s = String(text);
        const m = s.match(/https?:\\/\\/[^\\s"'\\\\]+\\.(m3u8|mp4|mpd)(\\?[^\\s"'\\\\]*)?/i);
        return m?.[0] ?? null;
      };

      class Unbaser {
        constructor(base) {
          this.ALPHABET = {
            62: '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ',
            95: " !\\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\\\]^_\`abcdefghijklmnopqrstuvwxyz{|}~",
          };
          this.dictionary = {};
          this.base = base;
          if (36 < base && base < 62) this.ALPHABET[base] = this.ALPHABET[62].substr(0, base);
          if (2 <= base && base <= 36) {
            this.unbase = (value) => parseInt(value, base);
          } else {
            [...this.ALPHABET[base]].forEach((cipher, index) => {
              this.dictionary[cipher] = index;
            });
            this.unbase = this._dictunbaser.bind(this);
          }
        }
        _dictunbaser(value) {
          let ret = 0;
          [...value].reverse().forEach((cipher, index) => {
            ret += Math.pow(this.base, index) * this.dictionary[cipher];
          });
          return ret;
        }
      }

      const unpack = (source) => {
        const juicers = [
          /}\\('(.*)', *(\\d+|\\[\\]), *(\\d+), *'(.*)'\\.split\\('\\|'\\), *(\\d+), *(.*)\\)\\)/,
          /}\\('(.*)', *(\\d+|\\[\\]), *(\\d+), *'(.*)'\\.split\\('\\|'\\)/,
        ];
        let payload = '';
        let symtab = [];
        let radix = 10;
        let count = 0;
        for (const juicer of juicers) {
          const args = juicer.exec(source);
          if (!args) continue;
          payload = args[1];
          symtab = args[4].split('|');
          radix = parseInt(args[2], 10);
          count = parseInt(args[3], 10);
          break;
        }
        if (!payload || !symtab.length || count !== symtab.length) return null;
        const unbase = new Unbaser(radix);
        return payload.replace(/\\b\\w+\\b/g, (word) => {
          const idx = radix === 1 ? parseInt(word, 10) : unbase.unbase(word);
          return symtab[idx] || word;
        });
      };

      try {
        const raw = String(episodeId ?? '');
        if (!raw.includes('/')) return [];
        const parts = raw.split('/');
        const id = parts[0];
        const session = parts[1];
        const playPage = templateFill(${JSON.stringify(playHrefTemplate)}, { id, session, episodeSession: session });

        const pageHtml = await fetch(playPage, { headers: { Accept: 'text/html' } }).then((r) => r.text());
        const direct = findMedia(pageHtml);
        if (direct) {
          return [{ url: direct, quality: 'auto', format: direct.includes('.m3u8') ? 'm3u8' : direct.includes('.mpd') ? 'mpd' : 'mp4', subOrDub: 'sub' }];
        }

        const buttonMatches = pageHtml.match(/<button[^>]*data-src="([^"]*)"[^>]*>/g) || [];
        const streamPromises = buttonMatches.map(async (buttonHtml) => {
          const srcMatch = buttonHtml.match(/data-src="([^"]*)"/);
          const resMatch = buttonHtml.match(/data-resolution="([^"]*)"/);
          const audioMatch = buttonHtml.match(/data-audio="([^"]*)"/);
          if (!srcMatch || !srcMatch[1]) return null;

          const kwikUrl = srcMatch[1];
          if (!kwikUrl.includes('kwik')) return null;
          const resolution = resMatch ? String(resMatch[1]) : 'auto';
          const audio = audioMatch ? String(audioMatch[1]).toLowerCase() : 'jpn';

          try {
            const kwikHtml = await fetch(kwikUrl, { headers: { Referer: playPage, Accept: 'text/html' } }).then((r) => r.text());

            const directKwik = findMedia(kwikHtml);
            if (directKwik) {
              return {
                url: directKwik,
                quality: resolution === 'Unknown' ? 'auto' : resolution + 'p',
                format: directKwik.includes('.m3u8') ? 'm3u8' : directKwik.includes('.mpd') ? 'mpd' : 'mp4',
                subOrDub: audio === 'eng' ? 'dub' : 'sub',
                headers: {
                  Referer: kwikUrl,
                  Origin: (() => {
                    try { return new URL(kwikUrl).origin; } catch { return ''; }
                  })(),
                },
              };
            }

            const scripts = [...kwikHtml.matchAll(/<script[^>]*>([\\s\\S]*?)<\\/script>/gi)].map((m) => m[1] || '');
            for (const scriptContent of scripts) {
              let unpacked = null;
              if (scriptContent.includes('));eval(')) {
                const layers = scriptContent.split('));eval(');
                if (layers.length >= 2) unpacked = unpack(layers[layers.length - 1].slice(0, -1));
              } else if (scriptContent.includes('eval(function(p,a,c,k,e,d)')) {
                unpacked = unpack(scriptContent);
              }
              const blob = unpacked || scriptContent;
              const fromConst = blob.match(/const\\s+source\\s*=\\s*['"]([^'"]+)['"]/);
              const fromAny = findMedia(blob);
              const streamUrl = fromConst?.[1] || fromAny;
              if (streamUrl) {
                return {
                  url: streamUrl.replace(/\\\\+$/, ''),
                  quality: resolution === 'Unknown' ? 'auto' : resolution + 'p',
                  format: streamUrl.includes('.m3u8') ? 'm3u8' : streamUrl.includes('.mpd') ? 'mpd' : 'mp4',
                  subOrDub: audio === 'eng' ? 'dub' : 'sub',
                  headers: {
                    Referer: kwikUrl,
                    Origin: (() => {
                      try { return new URL(kwikUrl).origin; } catch { return ''; }
                    })(),
                  },
                };
              }
            }
          } catch {}
          return null;
        });

        const streams = (await Promise.all(streamPromises)).filter(Boolean);
        return streams;
      } catch {
        return [];
      }
    }`,
  };
}

export function createFallbackAnimePaheExtension() {
  return {
    id: 'animepahe-fallback',
    name: 'AnimePahe (Fallback)',
    version: '1.0.0',
    search: `async (query) => {
      const url = 'https://animepahe.si/api?m=search&q=' + encodeURIComponent(query);
      const res = await fetch(url);
      const data = await res.json();
      return Array.isArray(data?.data) ? data.data.map(d => ({ id: d.session, title: d.title, name: d.title })) : [];
    }`,
    getEpisodes: `async (animeId) => {
      const url = 'https://animepahe.si/api?m=release&id=' + animeId + '&sort=episode_asc&page=1';
      const res = await fetch(url);
      const data = await res.json();
      return Array.isArray(data?.data) ? data.data.map(ep => ({ id: ep.session, number: ep.episode, title: ep.title })) : [];
    }`,
    getSources: `async (episodeId) => {
      const asAbs = (base, value) => {
        try { return new URL(value, base).toString(); } catch { return null; }
      };
      const findMedia = (text) => {
        if (!text) return null;
        const m = String(text).match(/https?:\\/\\/[^\\s"'\\\\]+\\.(m3u8|mp4|mpd)(\\?[^\\s"'\\\\]*)?/i);
        return m?.[0] ?? null;
      };
      const collectCandidateLinks = (html, base) => {
        const out = [];
        const seen = new Set();
        const push = (u) => {
          if (!u || seen.has(u)) return;
          seen.add(u);
          out.push(u);
        };
        const kwikRe = /(data-src|src|href)=["']([^"']*kwik[^"']*)["']/gi;
        let m;
        while ((m = kwikRe.exec(html)) !== null) push(asAbs(base, m[2]));

        const genericRe = /(data-src|src|href)=["']([^"']+)["']/gi;
        while ((m = genericRe.exec(html)) !== null) {
          const raw = m[2] || '';
          if (!raw || raw.startsWith('javascript:') || raw.startsWith('data:')) continue;
          if (raw.includes('/play/') || raw.includes('/embed/') || raw.includes('/e/') || raw.includes('player')) {
            push(asAbs(base, raw));
          }
        }
        return out;
      };

      try {
        if (!episodeId || typeof episodeId !== 'string' || !episodeId.includes('/')) return [];
        const parts = episodeId.split('/');
        const playPage = 'https://animepahe.si/play/' + parts[0] + '/' + parts[1];

        const playHtml = await fetch(playPage, { headers: { Accept: 'text/html' } }).then(r => r.text());
        const direct = findMedia(playHtml);
        if (direct) return [{ url: direct, quality: 'auto', format: direct.includes('.m3u8') ? 'm3u8' : direct.includes('.mpd') ? 'mpd' : 'mp4', subOrDub: 'sub' }];

        const links = collectCandidateLinks(playHtml, playPage);
        for (const link of links) {
          try {
            const html = await fetch(link, { headers: { Accept: 'text/html' } }).then(r => r.text());
            const media = findMedia(html);
            if (media) {
              return [{ url: media, quality: 'auto', format: media.includes('.m3u8') ? 'm3u8' : media.includes('.mpd') ? 'mpd' : 'mp4', subOrDub: 'sub' }];
            }
          } catch {}
        }
        return [];
      } catch {
        return [];
      }
    }`,
  };
}
