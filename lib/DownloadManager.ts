import * as FileSystem from 'expo-file-system/legacy';
import * as SQLite from 'expo-sqlite';

export type DownloadRegistryRecord = {
  id: string;
  anilistId?: number | null;
  animeTitle: string;
  episodeNumber: number;
  fileUri: string;
  thumbnailUri?: string | null;
  totalSize: number;
};

type StartDownloadParams = {
  id: string;
  anilistId?: number | null;
  animeTitle: string;
  episodeNumber: number;
  url: string;
  format?: string;
  fileName: string;
  headers?: Record<string, string>;
  thumbnailUri?: string | null;
  onProgress?: (progress: number, totalSize: number, downloadedBytes: number) => void;
  shouldCancel?: () => boolean;
};

type ParsedHls = {
  playlistText: string;
  segmentUrls: string[];
  keyUrls: string[];
};

const DOWNLOAD_CANCELLED_ERROR = 'Download cancelled';
const DB_NAME = 'downloads.db';
const DOWNLOADS_DIR = `${(FileSystem as any).documentDirectory ?? ''}downloads/`;
const HLS_CONCURRENCY = 3;
const MAX_HLS_SEGMENTS = 3000;

let dbPromise: Promise<SQLite.SQLiteDatabase> | null = null;

const sanitizeFileName = (name: string) =>
  name
    .replace(/[<>:"/\\|?*\x00-\x1F]/g, '_')
    .replace(/\s+/g, '_')
    .replace(/_+/g, '_')
    .trim();

const sanitizeFolderName = (name: string) =>
  String(name ?? '')
    .replace(/[<>:"/\\|?*\x00-\x1F]/g, '_')
    .replace(/\s+/g, ' ')
    .trim();

const defaultUserAgent =
  'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';

async function getDb() {
  if (!dbPromise) {
    dbPromise = (async () => {
      const db = await SQLite.openDatabaseAsync(DB_NAME);
      await db.execAsync(`
        CREATE TABLE IF NOT EXISTS downloads (
          id TEXT PRIMARY KEY NOT NULL,
          anilistId INTEGER,
          animeTitle TEXT NOT NULL,
          episodeNumber INTEGER NOT NULL,
          fileUri TEXT NOT NULL,
          thumbnailUri TEXT,
          totalSize INTEGER NOT NULL DEFAULT 0
        );
      `);
      try {
        const cols = await db.getAllAsync<{ name: string }>('PRAGMA table_info(downloads);');
        const hasAnilistId = (cols ?? []).some((c) => String(c?.name ?? '').toLowerCase() === 'anilistid');
        if (!hasAnilistId) {
          await db.execAsync('ALTER TABLE downloads ADD COLUMN anilistId INTEGER;');
        }
      } catch {}
      return db;
    })();
  }
  return dbPromise;
}

async function ensurePrivateDownloadsDir() {
  if (!DOWNLOADS_DIR) throw new Error('No writable document directory available.');
  await FileSystem.makeDirectoryAsync(DOWNLOADS_DIR, { intermediates: true });
}

async function ensureDirectory(uri: string) {
  if (!uri) return;
  await FileSystem.makeDirectoryAsync(uri, { intermediates: true });
}

async function removeDownloadedPath(uri: string) {
  const normalized = String(uri ?? '').trim();
  if (!normalized) return;
  try {
    await FileSystem.deleteAsync(normalized, { idempotent: true });
  } catch {
    // Best-effort cleanup only.
  }
}

async function readFileHeadAsText(uri: string, bytes = 256) {
  try {
    return await FileSystem.readAsStringAsync(uri, {
      encoding: FileSystem.EncodingType.UTF8,
      position: 0,
      length: bytes,
    } as any);
  } catch {
    return '';
  }
}

function looksLikeHtmlPayload(head: string) {
  const sample = String(head ?? '').trim().toLowerCase();
  if (!sample) return false;
  return (
    sample.startsWith('<!doctype html') ||
    sample.startsWith('<html') ||
    sample.includes('<head') ||
    sample.includes('<body') ||
    sample.includes('</html>')
  );
}

function normalizeHeaders(input?: Record<string, string>) {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(input ?? {})) {
    if (!k) continue;
    const value = String(v ?? '').trim();
    if (!value) continue;
    out[k] = value;
  }

  const keyFor = (target: string) =>
    Object.keys(out).find((k) => k.toLowerCase() === target.toLowerCase());

  const refererKey = keyFor('referer');
  const referer = refererKey ? out[refererKey] : '';
  if (!refererKey && referer) out.Referer = referer;

  const originKey = keyFor('origin');
  if (!originKey && referer) {
    try {
      out.Origin = new URL(referer).origin;
    } catch {}
  }

  if (!keyFor('user-agent')) out['User-Agent'] = defaultUserAgent;
  if (!keyFor('accept')) out.Accept = '*/*';

  return out;
}

function isHlsLike(params: StartDownloadParams) {
  const byFormat = String(params.format ?? '').toLowerCase();
  const byUrl = String(params.url ?? '').toLowerCase();
  return byFormat === 'm3u8' || byFormat === 'hls' || byUrl.includes('.m3u8') || byUrl.includes('.ts');
}

function getExtensionFromUrl(url: string, fallback: string) {
  const clean = String(url ?? '').split('?')[0].split('#')[0];
  const idx = clean.lastIndexOf('.');
  if (idx <= 0 || idx >= clean.length - 1) return fallback;
  const ext = clean.slice(idx + 1).toLowerCase();
  if (!/^[a-z0-9]{1,8}$/i.test(ext)) return fallback;
  return ext;
}

function normalizeM3u8Line(line: string) {
  return String(line ?? '').trim();
}

async function fetchText(url: string, headers: Record<string, string>) {
  const res = await fetch(url, { headers });
  if (!res.ok) {
    throw new Error(`Failed to fetch playlist (HTTP ${res.status})`);
  }
  return await res.text();
}

function parseVariantCandidates(playlistText: string, entryUrl: string) {
  const lines = playlistText.split(/\r?\n/);
  const out: { url: string; bandwidth: number }[] = [];
  for (let i = 0; i < lines.length; i += 1) {
    const line = normalizeM3u8Line(lines[i]);
    if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
    const next = normalizeM3u8Line(lines[i + 1] ?? '');
    if (!next || next.startsWith('#')) continue;
    let resolved = '';
    try {
      resolved = new URL(next, entryUrl).toString();
    } catch {
      continue;
    }
    const bwMatch = line.match(/BANDWIDTH=(\d+)/i);
    out.push({ url: resolved, bandwidth: Number(bwMatch?.[1] ?? 0) });
  }
  return out;
}

async function resolveMediaPlaylist(entryUrl: string, headers: Record<string, string>) {
  const text = await fetchText(entryUrl, headers);
  if (!text || !/#EXTM3U/i.test(text)) {
    throw new Error('Invalid HLS playlist payload');
  }

  const variants = parseVariantCandidates(text, entryUrl);
  if (!variants.length) {
    return { mediaUrl: entryUrl, playlistText: text };
  }

  variants.sort((a, b) => b.bandwidth - a.bandwidth);
  for (const v of variants) {
    try {
      const variantText = await fetchText(v.url, headers);
      if (/#EXTINF/i.test(variantText)) {
        return { mediaUrl: v.url, playlistText: variantText };
      }
    } catch {
      // try next variant
    }
  }

  // fallback: first variant text (if none had EXTINF detection)
  const first = variants[0];
  return { mediaUrl: first.url, playlistText: await fetchText(first.url, headers) };
}

function parseHlsResources(playlistText: string, mediaUrl: string): ParsedHls {
  const lines = playlistText.split(/\r?\n/);
  const segmentUrls: string[] = [];
  const keyUrls: string[] = [];

  for (const lineRaw of lines) {
    const line = normalizeM3u8Line(lineRaw);
    if (!line) continue;

    if (line.startsWith('#EXT-X-KEY')) {
      const m = line.match(/URI="([^"]+)"/i);
      if (m?.[1]) {
        try {
          keyUrls.push(new URL(m[1], mediaUrl).toString());
        } catch {}
      }
      continue;
    }

    if (line.startsWith('#')) continue;

    try {
      segmentUrls.push(new URL(line, mediaUrl).toString());
    } catch {}
  }

  return {
    playlistText,
    segmentUrls,
    keyUrls,
  };
}

async function mapWithConcurrency<T>(
  values: T[],
  limit: number,
  worker: (value: T, index: number) => Promise<void>
) {
  if (!values.length) return;
  let cursor = 0;
  const runners = Array.from({ length: Math.max(1, Math.min(limit, values.length)) }, () =>
    (async () => {
      while (true) {
        const idx = cursor;
        cursor += 1;
        if (idx >= values.length) return;
        await worker(values[idx], idx);
      }
    })()
  );
  await Promise.all(runners);
}

async function downloadHlsToLocal(params: {
  entryUrl: string;
  headers: Record<string, string>;
  outputPlaylistUri: string;
  outputFolderUri: string;
  shouldCancel?: () => boolean;
  onProgress?: (progress: number, totalSize: number, downloadedBytes: number) => void;
}) {
  if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);

  const { mediaUrl, playlistText } = await resolveMediaPlaylist(params.entryUrl, params.headers);
  const parsed = parseHlsResources(playlistText, mediaUrl);

  if (!parsed.segmentUrls.length) {
    throw new Error('Download Incomplete - Segments Missing');
  }
  if (parsed.segmentUrls.length > MAX_HLS_SEGMENTS) {
    throw new Error(`Playlist has too many segments (${parsed.segmentUrls.length}).`);
  }

  await ensureDirectory(params.outputFolderUri);

  const resourceUrls = [...parsed.keyUrls, ...parsed.segmentUrls];
  const fileMap = new Map<string, string>();

  parsed.keyUrls.forEach((url, idx) => {
    const ext = getExtensionFromUrl(url, 'key');
    fileMap.set(url, `key_${idx + 1}.${ext}`);
  });
  parsed.segmentUrls.forEach((url, idx) => {
    const ext = getExtensionFromUrl(url, 'ts');
    fileMap.set(url, `segment_${idx + 1}.${ext}`);
  });

  let downloadedBytes = 0;
  let totalSize = 0;

  await mapWithConcurrency(resourceUrls, HLS_CONCURRENCY, async (resourceUrl) => {
    if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);

    const localName = fileMap.get(resourceUrl);
    if (!localName) return;
    const localUri = `${params.outputFolderUri}${localName}`;

    const resumable = FileSystem.createDownloadResumable(resourceUrl, localUri, {
      headers: params.headers,
    });

    const result = await resumable.downloadAsync();
    if (!result?.uri) {
      throw new Error(`Failed to download segment: ${resourceUrl}`);
    }

    const status = Number((result as any)?.status ?? 0);
    if (status >= 400) {
      throw new Error(`Segment HTTP ${status}: ${resourceUrl}`);
    }

    const info = await FileSystem.getInfoAsync(result.uri);
    const size = Number((info as any)?.size ?? 0);
    downloadedBytes += Math.max(0, size);
    totalSize = Math.max(totalSize, downloadedBytes);

    params.onProgress?.(
      Math.min(0.98, downloadedBytes / Math.max(1, totalSize)),
      totalSize,
      downloadedBytes
    );
  });

  if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);

  // Verify every resource exists before marking complete.
  for (const resourceUrl of resourceUrls) {
    const localName = fileMap.get(resourceUrl);
    const localUri = `${params.outputFolderUri}${localName}`;
    const info = await FileSystem.getInfoAsync(localUri);
    if (!(info as any)?.exists || Number((info as any)?.size ?? 0) <= 0) {
      throw new Error('Download Incomplete - Segments Missing');
    }
  }

  // Rewrite playlist with local relative paths.
  let rewritten = parsed.playlistText;
  for (const [remote, localName] of fileMap.entries()) {
    const escaped = remote.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    rewritten = rewritten.replace(new RegExp(escaped, 'g'), localName);

    try {
      const pathOnly = new URL(remote).pathname;
      const escapedPath = pathOnly.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      rewritten = rewritten.replace(new RegExp(escapedPath, 'g'), localName);
    } catch {}
  }

  const lines = rewritten.split(/\r?\n/).map((lineRaw) => {
    const line = normalizeM3u8Line(lineRaw);
    if (!line) return lineRaw;

    if (line.startsWith('#EXT-X-KEY')) {
      const keyMatch = line.match(/URI="([^"]+)"/i);
      if (keyMatch?.[1]) {
        try {
          const keyAbs = new URL(keyMatch[1], mediaUrl).toString();
          const keyLocal = fileMap.get(keyAbs);
          if (keyLocal) {
            return lineRaw.replace(keyMatch[1], keyLocal);
          }
        } catch {}
      }
      return lineRaw;
    }

    if (line.startsWith('#')) return lineRaw;

    try {
      const absolute = new URL(line, mediaUrl).toString();
      const mapped = fileMap.get(absolute);
      if (mapped) return mapped;
    } catch {}

    return lineRaw;
  });

  await FileSystem.writeAsStringAsync(params.outputPlaylistUri, lines.join('\n'), {
    encoding: FileSystem.EncodingType.UTF8,
  });

  const playlistInfo = await FileSystem.getInfoAsync(params.outputPlaylistUri);
  downloadedBytes += Number((playlistInfo as any)?.size ?? 0);
  totalSize = Math.max(totalSize, downloadedBytes);

  params.onProgress?.(1, totalSize, downloadedBytes);
  return {
    totalSize,
    downloadedBytes,
  };
}

export async function getFFmpegRuntimeStatus() {
  return {
    available: false,
    executionEnvironment: 'native-hls-local',
    appOwnership: 'n/a',
    reason: 'FFmpeg removed. Using native HLS local playlist + segments download.',
  };
}

export async function getDownloadedPath(episodeId: string): Promise<string | null> {
  const id = String(episodeId ?? '').trim();
  if (!id) return null;
  const db = await getDb();
  const row = await db.getFirstAsync<{ fileUri: string }>(
    'SELECT fileUri FROM downloads WHERE id = ? LIMIT 1;',
    [id]
  );
  const uri = String(row?.fileUri ?? '').trim();
  if (!uri) return null;

  const info = await FileSystem.getInfoAsync(uri);
  if ((info as any)?.exists) return uri;

  await db.runAsync('DELETE FROM downloads WHERE id = ?;', [id]);
  return null;
}

export async function getDownloadedPathByMeta(
  animeTitle: string,
  episodeNumber: number
): Promise<string | null> {
  const title = String(animeTitle ?? '').trim();
  const ep = Number(episodeNumber);
  if (!title || !Number.isFinite(ep) || ep <= 0) return null;

  const db = await getDb();
  const row = await db.getFirstAsync<{ id: string; fileUri: string }>(
    `SELECT id, fileUri
     FROM downloads
     WHERE episodeNumber = ? AND LOWER(TRIM(animeTitle)) = LOWER(TRIM(?))
     ORDER BY rowid DESC
     LIMIT 1;`,
    [Math.trunc(ep), title]
  );

  const uri = String(row?.fileUri ?? '').trim();
  if (!uri) return null;

  const info = await FileSystem.getInfoAsync(uri);
  if ((info as any)?.exists) return uri;

  const staleId = String(row?.id ?? '').trim();
  if (staleId) {
    await db.runAsync('DELETE FROM downloads WHERE id = ?;', [staleId]);
  }
  return null;
}

export async function getDownloadedPathByAniListEpisode(
  anilistId: number,
  episodeNumber: number
): Promise<string | null> {
  const aid = Number(anilistId);
  const ep = Number(episodeNumber);
  if (!Number.isFinite(aid) || aid <= 0 || !Number.isFinite(ep) || ep <= 0) return null;

  const db = await getDb();
  const row = await db.getFirstAsync<{ id: string; fileUri: string }>(
    `SELECT id, fileUri
     FROM downloads
     WHERE anilistId = ? AND episodeNumber = ?
     ORDER BY rowid DESC
     LIMIT 1;`,
    [Math.trunc(aid), Math.trunc(ep)]
  );

  const uri = String(row?.fileUri ?? '').trim();
  if (!uri) return null;

  const info = await FileSystem.getInfoAsync(uri);
  if ((info as any)?.exists) return uri;

  const staleId = String(row?.id ?? '').trim();
  if (staleId) {
    await db.runAsync('DELETE FROM downloads WHERE id = ?;', [staleId]);
  }
  return null;
}

export async function listDownloadRegistry(): Promise<DownloadRegistryRecord[]> {
  const db = await getDb();
  const rows = await db.getAllAsync<DownloadRegistryRecord>(
    'SELECT id, anilistId, animeTitle, episodeNumber, fileUri, thumbnailUri, totalSize FROM downloads ORDER BY animeTitle ASC, episodeNumber DESC;'
  );
  return rows ?? [];
}

export async function removeDownloadRegistryEntry(id: string) {
  const db = await getDb();
  await db.runAsync('DELETE FROM downloads WHERE id = ?;', [id]);
}

export async function removeDownloadedAssetById(id: string) {
  const db = await getDb();
  const row = await db.getFirstAsync<{ fileUri: string }>(
    'SELECT fileUri FROM downloads WHERE id = ? LIMIT 1;',
    [id]
  );
  await db.runAsync('DELETE FROM downloads WHERE id = ?;', [id]);
  const uri = String(row?.fileUri ?? '').trim();
  if (uri) {
    await removeDownloadedPath(uri);
  }
}

export async function startPrivateDownload(params: StartDownloadParams): Promise<DownloadRegistryRecord> {
  const id = String(params.id ?? '').trim();
  if (!id) throw new Error('Missing download id');
  if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);
  await ensurePrivateDownloadsDir();

  const headers = normalizeHeaders(params.headers);
  let latestProgress = 0;
  let latestTotalSize = 0;
  const isHlsDownload = isHlsLike(params);
  const sourceFormat = String(params.format ?? '').toLowerCase();
  const inferredExt = (() => {
    if (isHlsDownload) return '.m3u8';
    if (sourceFormat === 'webm') return '.webm';
    if (sourceFormat === 'mp4') return '.mp4';
    const u = String(params.url ?? '').toLowerCase();
    if (u.includes('.webm')) return '.webm';
    return '.mp4';
  })();
  const animeFolderName = sanitizeFolderName(String(params.animeTitle ?? '').trim() || 'Unknown Anime');
  const animeFolderUri = `${DOWNLOADS_DIR}${animeFolderName}/`;
  await ensureDirectory(animeFolderUri);
  const episodeBaseName = sanitizeFileName(`Episode${Math.max(1, Math.trunc(Number(params.episodeNumber) || 1))}`);
  const resolvedFileName = `${episodeBaseName}${inferredExt}`;
  const fileUri = `${animeFolderUri}${resolvedFileName}`;

  // Smart reuse: if user already moved/imported a matching episode file into this folder, use it directly.
  const existingPreferredMp4 = `${animeFolderUri}${episodeBaseName}.mp4`;
  const existingPreferredM3u8 = `${animeFolderUri}${episodeBaseName}.m3u8`;
  const existingCheckList = [existingPreferredMp4, existingPreferredM3u8, fileUri];
  for (const existingUri of existingCheckList) {
    const info = await FileSystem.getInfoAsync(existingUri);
    if ((info as any)?.exists && Number((info as any)?.size ?? 0) > 0) {
      const db = await getDb();
      await db.runAsync(
        `INSERT INTO downloads (id, anilistId, animeTitle, episodeNumber, fileUri, thumbnailUri, totalSize)
         VALUES (?, ?, ?, ?, ?, ?, ?)
         ON CONFLICT(id) DO UPDATE SET
           anilistId=excluded.anilistId,
           animeTitle=excluded.animeTitle,
           episodeNumber=excluded.episodeNumber,
           fileUri=excluded.fileUri,
           thumbnailUri=excluded.thumbnailUri,
           totalSize=excluded.totalSize;`,
        [
          id,
          params.anilistId ?? null,
          params.animeTitle,
          params.episodeNumber,
          existingUri,
          params.thumbnailUri ?? null,
          Number((info as any)?.size ?? 0),
        ]
      );
      params.onProgress?.(1, Number((info as any)?.size ?? 0), Number((info as any)?.size ?? 0));
      return {
        id,
        anilistId: params.anilistId ?? null,
        animeTitle: params.animeTitle,
        episodeNumber: params.episodeNumber,
        fileUri: existingUri,
        thumbnailUri: params.thumbnailUri ?? null,
        totalSize: Number((info as any)?.size ?? 0),
      };
    }
  }

  console.log('[DownloadManager] Starting private download:', {
    id,
    engine: isHlsDownload ? 'hls-local' : 'mp4-direct',
    format: params.format ?? 'auto',
    url: String(params.url ?? '').slice(0, 160),
    fileName: resolvedFileName,
  });

  let cancelRequested = false;
  let finalUri = fileUri;
  if (isHlsDownload) {
    const result = await downloadHlsToLocal({
      entryUrl: params.url,
      headers,
      outputPlaylistUri: fileUri,
      outputFolderUri: animeFolderUri,
      shouldCancel: params.shouldCancel,
      onProgress: params.onProgress,
    });
    latestTotalSize = result.totalSize;
    latestProgress = 1;
    finalUri = fileUri;
  } else {
    const resumable = FileSystem.createDownloadResumable(
      params.url,
      fileUri,
      { headers },
      (event: any) => {
        if (!cancelRequested && params.shouldCancel?.()) {
          cancelRequested = true;
          void resumable.pauseAsync().catch(() => undefined);
          return;
        }
        const total = Number(event?.totalBytesExpectedToWrite ?? 0);
        const written = Number(event?.totalBytesWritten ?? 0);
        latestTotalSize = total > 0 ? total : latestTotalSize;
        latestProgress = total > 0 ? Math.min(1, written / total) : 0;
        params.onProgress?.(latestProgress, latestTotalSize, written);
      }
    );

    if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);
    const result = await resumable.downloadAsync();
    if (cancelRequested || params.shouldCancel?.()) {
      throw new Error(DOWNLOAD_CANCELLED_ERROR);
    }
    if (!result?.uri) throw new Error('Download failed');
    const status = Number((result as any)?.status ?? 0);
    if (status >= 400) throw new Error(`HTTP ${status} while downloading file`);
    const head = await readFileHeadAsText(result.uri, 256);
    if (looksLikeHtmlPayload(head)) {
      throw new Error('Downloaded file appears to be an HTML error page');
    }
    latestProgress = 1;
    finalUri = result.uri;
  }

  const finalInfo = await FileSystem.getInfoAsync(finalUri);
  const finalSize = Number((finalInfo as any)?.size ?? latestTotalSize ?? 0);

  if (latestProgress < 1) {
    throw new Error('Download did not complete fully');
  }
  if (params.shouldCancel?.()) {
    throw new Error(DOWNLOAD_CANCELLED_ERROR);
  }

  const db = await getDb();
  const existingById = await db.getFirstAsync<{ fileUri: string }>(
    'SELECT fileUri FROM downloads WHERE id = ? LIMIT 1;',
    [id]
  );
  const duplicateRows = await db.getAllAsync<{ id: string; fileUri: string }>(
    `SELECT id, fileUri FROM downloads
     WHERE id <> ? AND episodeNumber = ? AND LOWER(TRIM(animeTitle)) = LOWER(TRIM(?));`,
    [id, params.episodeNumber, params.animeTitle]
  );
  for (const row of duplicateRows ?? []) {
    const dupId = String(row?.id ?? '').trim();
    const dupUri = String(row?.fileUri ?? '').trim();
    if (dupUri) await removeDownloadedPath(dupUri);
    if (dupId) await db.runAsync('DELETE FROM downloads WHERE id = ?;', [dupId]);
  }

  await db.runAsync(
    `INSERT INTO downloads (id, anilistId, animeTitle, episodeNumber, fileUri, thumbnailUri, totalSize)
     VALUES (?, ?, ?, ?, ?, ?, ?)
     ON CONFLICT(id) DO UPDATE SET
       anilistId=excluded.anilistId,
       animeTitle=excluded.animeTitle,
       episodeNumber=excluded.episodeNumber,
       fileUri=excluded.fileUri,
       thumbnailUri=excluded.thumbnailUri,
       totalSize=excluded.totalSize;`,
    [id, params.anilistId ?? null, params.animeTitle, params.episodeNumber, finalUri, params.thumbnailUri ?? null, finalSize]
  );

  const previousUri = String(existingById?.fileUri ?? '').trim();
  if (previousUri && previousUri !== finalUri) {
    await removeDownloadedPath(previousUri);
  }

  return {
    id,
    anilistId: params.anilistId ?? null,
    animeTitle: params.animeTitle,
    episodeNumber: params.episodeNumber,
    fileUri: finalUri,
    thumbnailUri: params.thumbnailUri ?? null,
    totalSize: finalSize,
  };
}

