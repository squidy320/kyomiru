import * as FileSystem from 'expo-file-system/legacy';
import * as SQLite from 'expo-sqlite';
import Constants from 'expo-constants';

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

const DOWNLOAD_CANCELLED_ERROR = 'Download cancelled';
const DB_NAME = 'downloads.db';
const DOWNLOADS_DIR = `${(FileSystem as any).documentDirectory ?? ''}downloads/`;
const FFMPEG_UNAVAILABLE_MESSAGE =
  'FFmpeg is unavailable in this build. Rebuild a development client or production app after installing ffmpeg-kit-react-native.';

let dbPromise: Promise<SQLite.SQLiteDatabase> | null = null;
let ffmpegLoadAttempted = false;
let ffmpegLoadError: string | null = null;
let ffmpegKitCached: any | null = null;

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

function stripFileScheme(uri: string) {
  return String(uri ?? '').replace(/^file:\/\//i, '');
}

function buildHeaderBlob(headers: Record<string, string>) {
  const lines = Object.entries(headers)
    .filter(([k, v]) => String(k).trim() && String(v).trim())
    .map(([k, v]) => `${k}: ${v}`);
  if (!lines.length) return '';
  return `${lines.join('\r\n')}\r\n`;
}

async function loadFFmpegKit() {
  if (ffmpegLoadAttempted) return ffmpegKitCached;
  const executionEnvironment = String((Constants as any)?.executionEnvironment ?? '').toLowerCase();
  const isExpoGo =
    executionEnvironment === 'storeclient' ||
    String((Constants as any)?.appOwnership ?? '').toLowerCase() === 'expo';
  if (isExpoGo) {
    ffmpegLoadAttempted = true;
    ffmpegLoadError = 'Running in Expo Go (native FFmpeg modules are unavailable there).';
    ffmpegKitCached = null;
    return null;
  }
  try {
    const mod: any = require('ffmpeg-kit-react-native');
    const FFmpegKit = mod?.FFmpegKit ?? mod?.default?.FFmpegKit;
    if (!FFmpegKit || typeof FFmpegKit.executeAsync !== 'function') {
      ffmpegLoadAttempted = true;
      ffmpegLoadError = 'ffmpeg-kit-react-native module loaded, but FFmpegKit export is missing.';
      ffmpegKitCached = null;
      return null;
    }
    ffmpegLoadAttempted = true;
    ffmpegLoadError = null;
    ffmpegKitCached = FFmpegKit;
    return FFmpegKit;
  } catch (e: any) {
    ffmpegLoadAttempted = true;
    ffmpegLoadError = String(e?.message ?? e ?? 'Unknown FFmpeg load error');
    ffmpegKitCached = null;
    return null;
  }
}

export async function getFFmpegRuntimeStatus() {
  const executionEnvironment = String((Constants as any)?.executionEnvironment ?? '');
  const appOwnership = String((Constants as any)?.appOwnership ?? '');
  const ffmpeg = await loadFFmpegKit();
  return {
    available: !!ffmpeg,
    executionEnvironment,
    appOwnership,
    reason: ffmpeg ? null : ffmpegLoadError ?? FFMPEG_UNAVAILABLE_MESSAGE,
  };
}

async function buildLocalHlsPlaylist(
  entryUrl: string,
  headers: Record<string, string>,
  playlistUri: string
) {
  const res = await fetch(entryUrl, { headers });
  if (!res.ok) {
    throw new Error(`Failed to fetch playlist (HTTP ${res.status})`);
  }
  const text = await res.text();
  if (!text || !/#EXTM3U/i.test(text)) {
    throw new Error('Invalid HLS playlist payload');
  }
  const rewritten = text
    .split(/\r?\n/)
    .map((line) => {
      const raw = String(line ?? '');
      const trimmed = raw.trim();
      if (!trimmed || trimmed.startsWith('#')) return raw;
      try {
        return new URL(trimmed, entryUrl).toString();
      } catch {
        return trimmed;
      }
    })
    .join('\n');
  await FileSystem.writeAsStringAsync(playlistUri, rewritten, {
    encoding: FileSystem.EncodingType.UTF8,
  });
}

async function convertHlsToMp4WithFFmpeg(params: {
  entryUrl: string;
  playlistUri: string;
  outputUri: string;
  headers: Record<string, string>;
  shouldCancel?: () => boolean;
  onProgress?: (progress: number, totalSize: number, downloadedBytes: number) => void;
}) {
  const FFmpegKit = await loadFFmpegKit();
  if (!FFmpegKit) {
    const status = await getFFmpegRuntimeStatus();
    throw new Error(status.reason ?? FFMPEG_UNAVAILABLE_MESSAGE);
  }
  if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);

  await buildLocalHlsPlaylist(params.entryUrl, params.headers, params.playlistUri);

  const headerBlob = buildHeaderBlob(params.headers);
  const inPath = stripFileScheme(params.playlistUri);
  const outPath = stripFileScheme(params.outputUri);
  const cmd =
    `-y ` +
    `-allowed_extensions ALL ` +
    `-protocol_whitelist file,http,https,tcp,tls,crypto ` +
    (headerBlob ? `-headers "${headerBlob.replace(/"/g, '\\"')}" ` : '') +
    `-i "${inPath}" ` +
    `-c copy -bsf:a aac_adtstoasc "${outPath}"`;

  await new Promise<void>((resolve, reject) => {
    FFmpegKit.executeAsync(cmd, async (session: any) => {
      try {
        const rc = await session?.getReturnCode?.();
        const codeValue =
          typeof rc?.getValue === 'function' ? Number(rc.getValue()) : Number(String(rc ?? NaN));
        const isOk = Number.isFinite(codeValue) ? codeValue === 0 : !!rc?.isValueSuccess?.();
        if (!isOk) {
          const failLog = (await session?.getFailStackTrace?.()) || (await session?.getOutput?.()) || '';
          reject(new Error(`FFmpeg convert failed${failLog ? `: ${String(failLog).slice(0, 260)}` : ''}`));
          return;
        }
        resolve();
      } catch (e) {
        reject(e);
      }
    });
  });

  if (params.shouldCancel?.()) throw new Error(DOWNLOAD_CANCELLED_ERROR);
  const info = await FileSystem.getInfoAsync(params.outputUri);
  if (!(info as any)?.exists || Number((info as any)?.size ?? 0) <= 0) {
    throw new Error('FFmpeg finished but output MP4 is missing');
  }
  params.onProgress?.(1, Number((info as any)?.size ?? 0), Number((info as any)?.size ?? 0));
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
    if (isHlsDownload) return '.mp4';
    if (sourceFormat === 'webm') return '.webm';
    if (sourceFormat === 'mp4') return '.mp4';
    const u = String(params.url ?? '').toLowerCase();
    if (u.includes('.webm')) return '.webm';
    return '.mp4';
  })();
  const animeFolderName = sanitizeFolderName(String(params.animeTitle ?? '').trim() || 'Unknown Anime');
  const animeFolderUri = `${DOWNLOADS_DIR}${animeFolderName}/`;
  await ensureDirectory(animeFolderUri);
  const resolvedFileName = sanitizeFileName(`Episode${Math.max(1, Math.trunc(Number(params.episodeNumber) || 1))}${inferredExt}`);
  const fileUri = `${animeFolderUri}${resolvedFileName}`;
  const hlsPlaylistUri = `${animeFolderUri}${resolvedFileName.replace(/\.(mp4|m4v|webm)$/i, '')}.m3u8`;

  // Smart reuse: if user already moved/imported a matching episode file into this folder, use it directly.
  // Example: Documents/downloads/<Anime Name>/Episode2.mp4
  const existingPreferredMp4 = `${animeFolderUri}${sanitizeFileName(`Episode${Math.max(1, Math.trunc(Number(params.episodeNumber) || 1))}.mp4`)}`;
  const existingCheckList = [existingPreferredMp4, fileUri];
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
    engine: isHlsDownload ? 'hls-ffmpeg' : 'mp4-direct',
    format: params.format ?? 'auto',
    url: String(params.url ?? '').slice(0, 160),
    fileName: resolvedFileName,
  });

  let cancelRequested = false;
  let finalUri = fileUri;
  if (isHlsDownload) {
    await convertHlsToMp4WithFFmpeg({
      entryUrl: params.url,
      playlistUri: hlsPlaylistUri,
      outputUri: fileUri,
      headers,
      shouldCancel: params.shouldCancel,
      onProgress: params.onProgress,
    });
    latestProgress = 1;
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
