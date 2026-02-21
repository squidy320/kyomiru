import {
  getDownloadedPathByAniListEpisode,
  getDownloadedPath,
  getDownloadedPathByMeta,
  listDownloadRegistry,
  removeDownloadedAssetById,
  startPrivateDownload,
} from '@/lib/DownloadManager';

export type DownloadStatus = 'queued' | 'downloading' | 'completed' | 'failed' | 'cancelled';

export type DownloadItem = {
  id: string;
  episodeId: string;
  anilistId?: number | null;
  animeTitle: string;
  episodeNumber: number;
  url: string;
  headers?: Record<string, string>;
  format?: string;
  fileName: string;
  thumbnailUri?: string;
  totalSize?: number;
  downloadedBytes?: number;
  speedBytesPerSec?: number;
  fileUri?: string;
  progress: number;
  status: DownloadStatus;
  error?: string;
  createdAt: number;
};

type EnqueueParams = {
  episodeId: string;
  anilistId?: number | null;
  animeTitle: string;
  episodeNumber: number;
  url: string;
  headers?: Record<string, string>;
  format?: string;
  fileName: string;
  thumbnailUri?: string;
};

type Listener = (items: DownloadItem[]) => void;

const listeners = new Set<Listener>();
let queue: DownloadItem[] = [];
let running = false;
let hydrated = false;
const cancelledItemIds = new Set<string>();

const emit = () => {
  const snapshot = [...queue].sort((a, b) => b.createdAt - a.createdAt);
  listeners.forEach((listener) => {
    try {
      listener(snapshot);
    } catch {}
  });
};

const updateItem = (id: string, patch: Partial<DownloadItem>) => {
  queue = queue.map((item) => (item.id === id ? { ...item, ...patch } : item));
  emit();
};

const isCancelledError = (err: unknown) => {
  const msg = String((err as any)?.message ?? err ?? '').toLowerCase();
  return msg.includes('cancelled') || msg.includes('canceled');
};

const hydrateFromRegistry = async () => {
  if (hydrated) return;
  hydrated = true;
  try {
    const rows = await listDownloadRegistry();
    const completed: DownloadItem[] = rows.map((row) => ({
      id: `${row.id}-completed`,
      episodeId: row.id,
      anilistId: row.anilistId ?? null,
      animeTitle: row.animeTitle,
      episodeNumber: row.episodeNumber,
      url: row.fileUri,
      fileName: row.fileUri.split('/').pop() ?? `${row.id}.mp4`,
      fileUri: row.fileUri,
      thumbnailUri: row.thumbnailUri ?? undefined,
      totalSize: row.totalSize,
      progress: 1,
      status: 'completed',
      createdAt: Date.now(),
    }));
    queue = [...completed, ...queue.filter((item) => item.status !== 'completed')];
    emit();
  } catch (e) {
    console.warn('[DownloadManager] Could not hydrate registry:', e);
  }
};

const runNext = async () => {
  if (running) return;
  const next = queue.find((item) => item.status === 'queued');
  if (!next) return;

  running = true;
  let lastBytes = 0;
  let lastAt = Date.now();
  updateItem(next.id, {
    status: 'downloading',
    progress: 0,
    error: undefined,
    downloadedBytes: 0,
    speedBytesPerSec: 0,
  });
  try {
    const saved = await startPrivateDownload({
      id: next.episodeId,
      anilistId: next.anilistId ?? null,
      animeTitle: next.animeTitle,
      episodeNumber: next.episodeNumber,
      url: next.url,
      format: next.format,
      fileName: next.fileName,
      headers: next.headers,
      thumbnailUri: next.thumbnailUri,
      shouldCancel: () => cancelledItemIds.has(next.id),
      onProgress: (progress, totalSize, downloadedBytes) => {
        if (cancelledItemIds.has(next.id)) return;
        const now = Date.now();
        const bytes = Math.max(0, Number(downloadedBytes ?? 0));
        const deltaBytes = Math.max(0, bytes - lastBytes);
        const deltaMs = Math.max(1, now - lastAt);
        const speedBytesPerSec = (deltaBytes * 1000) / deltaMs;
        lastBytes = bytes;
        lastAt = now;
        updateItem(next.id, {
          progress,
          totalSize: totalSize > 0 ? totalSize : next.totalSize,
          downloadedBytes: bytes > 0 ? bytes : next.downloadedBytes,
          speedBytesPerSec: Number.isFinite(speedBytesPerSec) ? speedBytesPerSec : 0,
        });
      },
    });

    if (cancelledItemIds.has(next.id)) {
      cancelledItemIds.delete(next.id);
      updateItem(next.id, {
        status: 'cancelled',
        error: undefined,
        speedBytesPerSec: 0,
      });
      return;
    }

    updateItem(next.id, {
      status: 'completed',
      progress: 1,
      speedBytesPerSec: 0,
      fileUri: saved.fileUri,
      totalSize: saved.totalSize,
      downloadedBytes: saved.totalSize,
      thumbnailUri: saved.thumbnailUri ?? undefined,
    });
  } catch (e: any) {
    if (cancelledItemIds.has(next.id) || isCancelledError(e)) {
      cancelledItemIds.delete(next.id);
      updateItem(next.id, {
        status: 'cancelled',
        error: undefined,
        speedBytesPerSec: 0,
      });
      return;
    }
    console.warn('[DownloadManager] Download failed:', {
      episodeId: next.episodeId,
      url: String(next.url ?? '').slice(0, 160),
      format: next.format ?? 'auto',
      error: e?.message ?? String(e),
    });
    updateItem(next.id, { status: 'failed', error: e?.message ?? 'Download failed', speedBytesPerSec: 0 });
  } finally {
    running = false;
    setTimeout(() => {
      void runNext();
    }, 0);
  }
};

export function subscribeDownloads(listener: Listener) {
  listeners.add(listener);
  listener([...queue]);
  void hydrateFromRegistry();
  return () => {
    listeners.delete(listener);
  };
}

export function getDownloads() {
  return [...queue];
}

export async function getDownloadedEpisodePath(episodeId: string) {
  return getDownloadedPath(episodeId);
}

export async function getDownloadedEpisodePathByMeta(animeTitle: string, episodeNumber: number) {
  return getDownloadedPathByMeta(animeTitle, episodeNumber);
}

export async function getDownloadedEpisodePathByAniListEpisode(anilistId: number, episodeNumber: number) {
  return getDownloadedPathByAniListEpisode(anilistId, episodeNumber);
}

export function enqueueDownload(params: EnqueueParams): DownloadItem {
  const duplicateActive = queue.find(
    (item) =>
      item.episodeId === params.episodeId &&
      (item.status === 'queued' || item.status === 'downloading')
  );
  if (duplicateActive) return duplicateActive;

  const existingCompletedIndex = queue.findIndex(
    (item) => item.episodeId === params.episodeId && item.status === 'completed'
  );

  const item: DownloadItem = {
    id: `${params.episodeId}-${Date.now()}`,
    episodeId: params.episodeId,
    anilistId: params.anilistId ?? null,
    animeTitle: params.animeTitle,
    episodeNumber: params.episodeNumber,
    url: params.url,
    headers: params.headers,
    format: params.format,
    fileName: params.fileName,
    thumbnailUri: params.thumbnailUri,
    progress: 0,
    status: 'queued',
    createdAt: Date.now(),
  };

  if (existingCompletedIndex >= 0) {
    queue[existingCompletedIndex] = item;
  } else {
    queue = [item, ...queue];
  }
  emit();
  void runNext();
  return item;
}

export function cancelDownload(downloadItemId: string) {
  const targetId = String(downloadItemId ?? '').trim();
  if (!targetId) return false;
  const item = queue.find((entry) => entry.id === targetId);
  if (!item) return false;
  if (item.status !== 'queued' && item.status !== 'downloading') return false;

  cancelledItemIds.add(item.id);
  updateItem(item.id, {
    status: 'cancelled',
    error: undefined,
    speedBytesPerSec: 0,
  });

  if (item.status === 'queued') {
    cancelledItemIds.delete(item.id);
    void runNext();
  }
  return true;
}

export async function clearFinishedDownloads() {
  const finished = queue.filter(
    (item) => item.status === 'completed' || item.status === 'failed' || item.status === 'cancelled'
  );
  queue = queue.filter(
    (item) => item.status !== 'completed' && item.status !== 'failed' && item.status !== 'cancelled'
  );
  emit();

  await Promise.all(
    finished
      .filter((item) => item.status === 'completed')
      .map((item) => removeDownloadedAssetById(item.episodeId).catch(() => undefined))
  );
}

export async function deleteDownloadedEpisode(
  episodeId: string,
  animeTitle?: string,
  episodeNumber?: number
) {
  const normalizedTitle = String(animeTitle ?? '').trim().toLowerCase();
  const targetNumber = Number(episodeNumber);

  const candidates = queue.filter((item) => {
    if (item.episodeId === episodeId) return true;
    if (
      item.status === 'completed' &&
      normalizedTitle &&
      Number.isFinite(targetNumber) &&
      item.episodeNumber === targetNumber &&
      String(item.animeTitle ?? '').trim().toLowerCase() === normalizedTitle
    ) {
      return true;
    }
    return false;
  });

  const completed = candidates.filter((item) => item.status === 'completed');
  await Promise.all(
    completed.map((item) => removeDownloadedAssetById(item.episodeId).catch(() => undefined))
  );

  if (candidates.length > 0) {
    const ids = new Set(candidates.map((item) => item.id));
    queue = queue.filter((item) => !ids.has(item.id));
    emit();
  }
}

