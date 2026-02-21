const express = require('express');
const cors = require('cors');
const fetch = require('node-fetch');

const app = express();
const PORT = process.env.PORT || 4000;

app.use(cors());
app.use(express.json());

async function fetchJson(url) {
  const res = await fetch(url, {
    headers: {
      'User-Agent':
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36',
      Accept: 'application/json,text/html;q=0.9',
    },
  });
  if (!res.ok) {
    throw new Error(`Request failed: ${res.status}`);
  }
  return res.json();
}

// Health check
app.get('/', (_req, res) => {
  res.json({ status: 'ok', message: 'animeapp backend running' });
});

// GET /episodes?title=Some+Anime
// Uses AnimePahe's public JSON API (same endpoints that the Sora source config uses)
// to resolve a title to a session id and then list all episodes.
app.get('/episodes', async (req, res) => {
  const title = (req.query.title || '').toString();
  if (!title) {
    return res.status(400).json({ error: 'Missing title query parameter.' });
  }

  try {
    // 1) Search AnimePahe (mirrors the "searchResults" Sora function)
    const searchUrl = `https://animepahe.si/api?m=search&q=${encodeURIComponent(title)}`;
    const searchJson = await fetchJson(searchUrl);

    if (!searchJson.data || !Array.isArray(searchJson.data) || searchJson.data.length === 0) {
      return res.json({ episodes: [] });
    }

    // For now just pick the first search result
    const first = searchJson.data[0];
    const sessionId = first.session;

    // 2) Fetch first page of releases to learn how many pages there are
    const firstReleaseUrl = `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=1`;
    const firstReleaseJson = await fetchJson(firstReleaseUrl);
    const totalPages = firstReleaseJson.last_page || 1;

    // 3) Fetch all pages in parallel (similar to extractEpisodes in the Sora script)
    const pagePromises = [];
    for (let page = 1; page <= totalPages; page++) {
      const pageUrl = `https://animepahe.si/api?m=release&id=${sessionId}&sort=episode_asc&page=${page}`;
      pagePromises.push(
        fetchJson(pageUrl).catch(() => ({
          data: [],
        }))
      );
    }

    const allPageJson = await Promise.all(pagePromises);
    const allEpisodesRaw = [];
    for (const p of allPageJson) {
      if (p && Array.isArray(p.data)) {
        allEpisodesRaw.push(...p.data);
      }
    }

    // 4) Transform into the shape the mobile app expects.
    // NOTE: We still return a demo HLS .m3u8 as the actual streamUrl because
    // extracting the Kwik .m3u8 requires the more advanced "networkFetch"
    // behavior from the Sora runtime, which is non-trivial to port.
    const demoStreamUrl = 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8';

    const episodes = allEpisodesRaw
      .map((ep) => ({
        id: ep.session,
        number: ep.episode,
        title: ep.title,
        // For later: you can add "playPageUrl" if you want to
        // implement full Kwik stream extraction.
        playPageUrl: `https://animepahe.si/play/${sessionId}/${ep.session}`,
        streamUrl: demoStreamUrl,
      }))
      .sort((a, b) => a.number - b.number);

    res.json({ episodes });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Failed to fetch episodes from AnimePahe' });
  }
});

// GET /kwik-m3u8?url=https://kwik-link-here
// Example endpoint that tries to extract a .m3u8 URL from a page.
// This is NOT guaranteed to work with any real site; treat it as a pattern.
app.get('/kwik-m3u8', async (req, res) => {
  const kwikUrl = (req.query.url || '').toString();
  if (!kwikUrl) {
    return res.status(400).json({ error: 'Missing url query parameter.' });
  }

  try {
    const response = await fetch(kwikUrl, {
      headers: {
        // Some hosts require a user-agent and referer; adjust as needed.
        'User-Agent':
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36',
      },
    });

    if (!response.ok) {
      return res.status(500).json({ error: 'Failed to fetch Kwik page.' });
    }

    const html = await response.text();
    const match = html.match(/https?:\/\/[^'"]+\.m3u8/);
    const m3u8 = match ? match[0] : null;

    if (!m3u8) {
      return res.status(404).json({ error: 'No m3u8 URL found on page.' });
    }

    res.json({ m3u8 });
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: 'Error while fetching Kwik page.' });
  }
});

app.listen(PORT, () => {
  console.log(`Backend listening on http://localhost:${PORT}`);
});

