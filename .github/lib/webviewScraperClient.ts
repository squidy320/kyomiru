const g = globalThis as any;

export type SniffedDownloadLink = {
  url: string;
  headers?: Record<string, string>;
};

function ensure() {
  if (!g.__WEBVIEW_SCRAPER__ || typeof g.__WEBVIEW_SCRAPER__.request !== 'function') {
    throw new Error('HiddenWebViewScraper provider is not mounted');
  }
}

export async function scrapeEpisodesWithWebView(title: string): Promise<any[]> {
  ensure();
  return g.__WEBVIEW_SCRAPER__.request({ type: 'episodesByTitle', title });
}

export async function extractKwikWithWebView(playPageUrl: string): Promise<string | null> {
  ensure();
  return g.__WEBVIEW_SCRAPER__.request({ type: 'extractKwik', title: playPageUrl });
}

export async function fetchDownloadLinkWithWebView(
  playPageUrl: string,
  preferredQuality?: string
): Promise<SniffedDownloadLink | null> {
  ensure();
  return g.__WEBVIEW_SCRAPER__.request({
    type: 'fetchDownloadLink',
    title: playPageUrl,
    preferredQuality,
  });
}

export default { scrapeEpisodesWithWebView, extractKwikWithWebView, fetchDownloadLinkWithWebView };
