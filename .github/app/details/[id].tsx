import { Stack, useLocalSearchParams, useRouter } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import * as FileSystem from 'expo-file-system/legacy';
import * as SecureStore from 'expo-secure-store';
import MaterialIcons from '@expo/vector-icons/MaterialIcons';
import React, { useEffect, useRef, useState } from 'react';
import Svg, { Circle } from 'react-native-svg';
import {
    ActivityIndicator,
    Alert,
    Image,
    ImageBackground,
    Platform,
    Share,
    ScrollView,
    StyleSheet,
    Text,
    TextInput,
    TouchableOpacity,
    useWindowDimensions,
    View,
} from 'react-native';

import StreamPicker from '@/components/StreamPicker';
import { VideoPlayer } from '@/components/VideoPlayer';
import {
  AniListMediaListEntry,
  AniListAnimeMetadata,
  AniListEpisodeMetaMap,
  AniListMediaStatus,
  deleteAniListEntry,
  fetchAniListCustomLists,
  fetchAniListEpisodeIntroRange,
  fetchAniListEpisodeMeta,
  fetchAnimeMetadataById,
  fetchAniListTrackingInfo,
  fetchAniListViewerProfile,
  fetchAnimeById,
  setAniListCustomLists,
  setAniListScore,
  setAniListStatus,
  updateAniListProgress,
} from '@/lib/anilist';
import { useAniListAuth } from '@/lib/anilistAuth';
import {
  clearAnimePaheManualMapping,
  getAnimePaheManualMapping,
  setAnimePaheManualMapping,
} from '@/lib/animePaheMapping';
import { Episode, fetchEpisodesForAnime } from '@/lib/animePahe';
import {
  fetchSourcesForEpisode,
  searchAnimePahe,
} from '@/lib/ScraperService';
import { colors, glassButton, glassCardElevated, glassInput, pill, shadow } from '@/lib/theme';
import { useUIAppearance } from '@/lib/uiAppearance';
import {
  DownloadItem,
  deleteDownloadedEpisode,
  enqueueDownload,
  getDownloadedEpisodePathByAniListEpisode,
  getDownloadedEpisodePath,
  getDownloadedEpisodePathByMeta,
  subscribeDownloads,
} from '@/lib/soraDownloader';

export default function DetailsScreen() {
  const router = useRouter();
  const params = useLocalSearchParams<{
    id: string;
    title?: string;
    coverImage?: string;
    averageScore?: string;
    soraId?: string;
    downloadsOnly?: string;
  }>();

  const anilistId = Number(params.id);
  const title = params.title ?? 'Details';
  const coverImage = params.coverImage;
  const averageScore = params.averageScore ? Number(params.averageScore) : undefined;
  const soraId =
    typeof params.soraId === 'string' &&
    params.soraId.trim() &&
    params.soraId !== 'null' &&
    params.soraId !== 'undefined'
      ? params.soraId
      : undefined;
  const downloadsOnly = String(params.downloadsOnly ?? '') === '1';

  const [episodes, setEpisodes] = useState<Episode[]>([]);
  const [loading, setLoading] = useState(true);
  const [selectedSource, setSelectedSource] = useState<{
    url: string;
    headers?: Record<string, string>;
    format?: string;
  } | null>(null);
  const [activeTab, setActiveTab] = useState<'watch' | 'anilist' | 'more'>('watch');
  const [resumeSeekSec, setResumeSeekSec] = useState(0);
  const [playbackOrigin, setPlaybackOrigin] = useState<'offline' | 'stream'>('stream');
  const [currentEpisode, setCurrentEpisode] = useState<Episode | null>(null);
  const [updatingProgress, setUpdatingProgress] = useState(false);
  const [pickerVisible, setPickerVisible] = useState(false);
  const [sources, setSources] = useState<any[]>([]);
  const [loadingSources, setLoadingSources] = useState(false);
  const [pickerMode, setPickerMode] = useState<'play' | 'download' | 'download-batch'>('play');
  const [pendingDownloadEpisode, setPendingDownloadEpisode] = useState<Episode | null>(null);
  const [pendingBatchEpisodes, setPendingBatchEpisodes] = useState<Episode[]>([]);
  const [batchQueueing, setBatchQueueing] = useState(false);
  const [trackingEntry, setTrackingEntry] = useState<AniListMediaListEntry | null>(null);
  const [animeTotalEpisodes, setAnimeTotalEpisodes] = useState<number | null>(null);
  const [animeAiringStatus, setAnimeAiringStatus] = useState<string | null>(null);
  const [animeMetadata, setAnimeMetadata] = useState<AniListAnimeMetadata | null>(null);
  const [viewerBanner, setViewerBanner] = useState<string | null>(null);
  const [viewerBannerLoaded, setViewerBannerLoaded] = useState(false);
  const [updatingList, setUpdatingList] = useState(false);
  const [scoreInput, setScoreInput] = useState('');
  const [availableCustomLists, setAvailableCustomLists] = useState<string[]>([]);
  const [canTrackAniList, setCanTrackAniList] = useState(true);
  const [manualSessionId, setManualSessionId] = useState<string | null>(null);
  const [manualSessionTitle, setManualSessionTitle] = useState<string | null>(null);
  const [mappingQuery, setMappingQuery] = useState('');
  const [mappingLoading, setMappingLoading] = useState(false);
  const [mappingResults, setMappingResults] = useState<{ id: string; title: string }[]>([]);
  const [playbackQueue, setPlaybackQueue] = useState<{ url: string; headers?: Record<string, string>; format?: string }[]>([]);
  const [downloadItems, setDownloadItems] = useState<DownloadItem[]>([]);
  const [episodeMetaMap, setEpisodeMetaMap] = useState<AniListEpisodeMetaMap>({});
  const [episodeIntroMap, setEpisodeIntroMap] = useState<Record<number, { startSec: number; endSec: number }>>({});
  const introFetchInFlightRef = useRef<Record<number, boolean>>({});
  const [episodeProgressMap, setEpisodeProgressMap] = useState<
    Record<number, { positionSec: number; durationSec: number; percent: number }>
  >({});
  const offlineFallbackAttemptedRef = useRef<string | null>(null);
  const playbackPositionSecRef = useRef(0);
  const mountedRef = useRef(true);
  const sourcesLoadingOpsRef = useRef(0);
  const playRequestIdRef = useRef(0);
  const downloadRequestIdRef = useRef(0);
  const batchDownloadRequestIdRef = useRef(0);
  const progressFileCacheRef = useRef<Record<string, string> | null>(null);
  const progressFileWriteQueueRef = useRef<Promise<void>>(Promise.resolve());
  const playbackErrorGuardRef = useRef({ lastAt: 0, handling: false });
  const { width: viewportWidth } = useWindowDimensions();

  const { accessToken, login } = useAniListAuth();
  const {
    defaultStreamQuality,
    defaultStreamLanguage,
    streamSelectionMode,
  } = useUIAppearance();
  const effectiveSoraId = manualSessionId ?? soraId;
  const trackingBackgroundUri = accessToken
    ? (viewerBannerLoaded ? viewerBanner ?? coverImage ?? null : null)
    : coverImage ?? null;
  const heroBannerUri =
    String(animeMetadata?.bannerImage ?? '').trim() ||
    String(trackingBackgroundUri ?? '').trim() ||
    String(coverImage ?? '').trim() ||
    null;
  const isTabletLayout = viewportWidth >= 768;
  const resolvedTotalEpisodes =
    animeTotalEpisodes ??
    (episodes.length > 0
      ? episodes.reduce((max, ep) => (ep.number > max ? ep.number : max), 0)
      : null);
  const strictIOSHlsOnly = Platform.OS === 'ios';
  const normalizeTitleKey = (value: string) => String(value ?? '').trim().toLowerCase();
  const titleKey = normalizeTitleKey(title);
  const completedDownloadItems = downloadItems.filter((item) => item.status === 'completed' && !!item.fileUri);
  const downloadedEpisodeIds = new Set(completedDownloadItems.map((item) => item.episodeId));
  const downloadedEpisodeNumbers = new Set(
    completedDownloadItems
      .filter((item) => normalizeTitleKey(item.animeTitle) === titleKey)
      .map((item) => item.episodeNumber)
  );
  const findEpisodeDownloadItem = (episode: Episode) =>
    downloadItems.find((item) => {
      if (item.episodeId === episode.id) return true;
      return (
        normalizeTitleKey(item.animeTitle) === titleKey &&
        item.episodeNumber === episode.number &&
        item.status === 'completed'
      );
    });
  const ensureFileUri = (localUri: string) => {
    const value = String(localUri ?? '').trim();
    if (!value) return value;
    return value.startsWith('file://') ? value : `file://${value}`;
  };
  const ensureExistingLocalUri = async (localUri: string, context: string) => {
    const normalized = ensureFileUri(localUri);
    if (!normalized) return null;
    try {
      const info = await FileSystem.getInfoAsync(normalized);
      if ((info as any)?.exists) return normalized;
      try {
        const docDir = (FileSystem as any).documentDirectory as string | undefined;
        if (docDir) {
          const entries = await FileSystem.readDirectoryAsync(docDir);
          if (__DEV__) console.log('[Details][Offline] documentDirectory entries:', { documentDirectory: docDir, entries });
        }
      } catch (dirError) {
        console.error('[Details][Offline] Failed to read documentDirectory:', dirError);
      }
      console.error('[Details][Offline] Local file missing, falling back to stream:', {
        context,
        requestedPath: localUri,
        normalizedPath: normalized,
      });
      return null;
    } catch (error) {
      console.error('[Details][Offline] Local file check failed, falling back to stream:', {
        context,
        requestedPath: localUri,
        normalizedPath: normalized,
        error,
      });
      return null;
    }
  };
  const canonicalizeHeaders = (headers?: Record<string, string>) => {
    if (!headers) return undefined;
    const out: Record<string, string> = {};
    const keyMap: Record<string, string> = {
      referer: 'Referer',
      origin: 'Origin',
      'user-agent': 'User-Agent',
      accept: 'Accept',
    };
    for (const [k, v] of Object.entries(headers)) {
      const value = String(v ?? '').trim();
      if (!value) continue;
      const lower = String(k ?? '').trim().toLowerCase();
      const finalKey = keyMap[lower] ?? String(k ?? '').trim();
      if (!finalKey) continue;
      out[finalKey] = value;
    }
    return Object.keys(out).length ? out : undefined;
  };
  const playbackSourceKey = (source?: {
    url?: string;
    headers?: Record<string, string>;
    format?: string;
  }) => {
    const url = String(source?.url ?? '').trim();
    const format = String(source?.format ?? '').toLowerCase();
    const headers = canonicalizeHeaders(source?.headers);
    const headerToken = headers
      ? Object.keys(headers)
          .sort((a, b) => a.localeCompare(b))
          .map((k) => `${k.toLowerCase()}:${String(headers[k] ?? '').trim()}`)
          .join('|')
      : '';
    return `${format}::${url}::${headerToken}`;
  };

  const progressNamespace = Number.isFinite(anilistId) && anilistId > 0
    ? `aid:${String(anilistId)}`
    : `title:${titleKey || 'na'}`;
  const progressFileUri = `${(FileSystem as any).documentDirectory ?? ''}watch_progress_v1.json`;

  const hashKeyPart = (value: string) => {
    const input = String(value ?? '');
    let hash = 2166136261;
    for (let i = 0; i < input.length; i += 1) {
      hash ^= input.charCodeAt(i);
      hash = Math.imul(hash, 16777619);
    }
    return Math.abs(hash >>> 0).toString(36);
  };

  const progressStorageKeys = (ep: Episode) => {
    const rawEpisodeId = String(ep?.id ?? '');
    const episodeIdHash = hashKeyPart(rawEpisodeId);
    const idKey = `watch_progress:${progressNamespace}:eid_h:${episodeIdHash}`;
    const legacyRawIdKey = `watch_progress:${progressNamespace}:eid:${rawEpisodeId}`;
    const numberKey = `watch_progress:${progressNamespace}:ep:${Math.max(
      1,
      Math.trunc(Number(ep?.number) || 1)
    )}`;
    return [numberKey, idKey, legacyRawIdKey] as const;
  };

  const enqueueProgressFileWrite = (task: () => Promise<void>) => {
    progressFileWriteQueueRef.current = progressFileWriteQueueRef.current
      .then(task, task)
      .then(
        () => undefined,
        () => undefined
      );
    return progressFileWriteQueueRef.current;
  };

  const ensureProgressFileCache = async (): Promise<Record<string, string>> => {
    if (progressFileCacheRef.current) return progressFileCacheRef.current;
    if (!progressFileUri.startsWith('file://')) {
      progressFileCacheRef.current = {};
      return progressFileCacheRef.current;
    }
    try {
      const info = await FileSystem.getInfoAsync(progressFileUri);
      if (!(info as any)?.exists) {
        progressFileCacheRef.current = {};
        return progressFileCacheRef.current;
      }
      const raw = await FileSystem.readAsStringAsync(progressFileUri);
      const parsed = raw ? JSON.parse(raw) : {};
      if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) {
        progressFileCacheRef.current = Object.fromEntries(
          Object.entries(parsed).map(([k, v]) => [String(k), String(v ?? '')])
        );
      } else {
        progressFileCacheRef.current = {};
      }
    } catch {
      progressFileCacheRef.current = {};
    }
    return progressFileCacheRef.current;
  };

  const getProgressFromFileByKeys = async (keys: string[]): Promise<string | null> => {
    const cache = await ensureProgressFileCache();
    for (const key of keys) {
      const value = String(cache?.[key] ?? '').trim();
      if (value) return value;
    }
    return null;
  };

  const writeProgressToFile = async (entries: Record<string, string | null>) => {
    if (!progressFileUri.startsWith('file://')) return;
    await enqueueProgressFileWrite(async () => {
      const cache = await ensureProgressFileCache();
      for (const [k, v] of Object.entries(entries)) {
        if (v == null || String(v).trim() === '') {
          delete cache[k];
        } else {
          cache[k] = String(v);
        }
      }
      try {
        await FileSystem.writeAsStringAsync(progressFileUri, JSON.stringify(cache));
      } catch {}
    });
  };

  const secureGet = async (key: string): Promise<string | null> => {
    try {
      return await SecureStore.getItemAsync(key);
    } catch {
      return null;
    }
  };

  const secureSet = async (key: string, value: string) => {
    try {
      await SecureStore.setItemAsync(key, value);
    } catch {}
  };

  const secureDelete = async (key: string) => {
    try {
      await SecureStore.deleteItemAsync(key);
    } catch {}
  };

  const parseStoredProgress = (raw: string | null): { positionSec: number; durationSec: number; percent: number } | null => {
    if (!raw) return null;
    const trimmed = String(raw).trim();
    if (!trimmed) return null;
    try {
      const parsed = JSON.parse(trimmed) as { position?: number; duration?: number };
      const position = Math.max(0, Math.floor(Number(parsed?.position ?? 0)));
      const duration = Math.max(0, Math.floor(Number(parsed?.duration ?? 0)));
      const percent =
        duration > 0 ? Math.min(100, Math.max(0, Math.floor((position / duration) * 100))) : 0;
      if (position <= 0) return null;
      return { positionSec: position, durationSec: duration, percent };
    } catch {
      const position = Math.max(0, Math.floor(Number(trimmed)));
      if (!Number.isFinite(position) || position <= 0) return null;
      return { positionSec: position, durationSec: 0, percent: 0 };
    }
  };

  const readEpisodeProgress = async (
    ep: Episode
  ): Promise<{ positionSec: number; durationSec: number; percent: number }> => {
    try {
      const [numberKey, idKey, legacyRawIdKey] = progressStorageKeys(ep);
      const fileRaw = await getProgressFromFileByKeys([numberKey, idKey, legacyRawIdKey]);
      const numberRaw = await secureGet(numberKey);
      const idRaw = await secureGet(idKey);
      const legacyRaw = await secureGet(legacyRawIdKey);
      return (
        parseStoredProgress(fileRaw) ??
        parseStoredProgress(numberRaw) ??
        parseStoredProgress(idRaw) ??
        parseStoredProgress(legacyRaw) ?? {
          positionSec: 0,
          durationSec: 0,
          percent: 0,
        }
      );
    } catch {
      return { positionSec: 0, durationSec: 0, percent: 0 };
    }
  };

  const readEpisodeProgressSec = async (ep: Episode): Promise<number> => {
    const entry = await readEpisodeProgress(ep);
    if (entry.durationSec > 0 && entry.positionSec / entry.durationSec >= 0.95) return 0;
    return entry.positionSec;
  };

  const saveEpisodeProgressSec = async (ep: Episode, positionSec: number, durationSec: number) => {
    try {
      const duration = Number(durationSec || 0);
      const position = Math.max(0, Math.floor(Number(positionSec || 0)));
      const nearEnd = duration > 0 && position / duration >= 0.95;
      const [numberKey, idKey, legacyRawIdKey] = progressStorageKeys(ep);
      if (position <= 5) return;
      if (nearEnd) {
        const completedPayload = JSON.stringify({
          position: Math.max(duration, position),
          duration: Math.max(duration, position),
        });
        await secureSet(numberKey, completedPayload);
        await secureSet(idKey, completedPayload);
        await secureDelete(legacyRawIdKey);
        await writeProgressToFile({
          [numberKey]: completedPayload,
          [idKey]: completedPayload,
          [legacyRawIdKey]: null,
        });
        return;
      }
      const payload = JSON.stringify({
        position,
        duration: Math.max(0, Math.floor(duration)),
      });
      await secureSet(numberKey, payload);
      await secureSet(idKey, payload);
      await secureDelete(legacyRawIdKey);
      await writeProgressToFile({
        [numberKey]: payload,
        [idKey]: payload,
        [legacyRawIdKey]: null,
      });
    } catch {}
  };

  const beginSourcesLoading = () => {
    sourcesLoadingOpsRef.current += 1;
    if (mountedRef.current) setLoadingSources(true);
  };

  const endSourcesLoading = () => {
    sourcesLoadingOpsRef.current = Math.max(0, sourcesLoadingOpsRef.current - 1);
    if (mountedRef.current && sourcesLoadingOpsRef.current === 0) {
      setLoadingSources(false);
    }
  };

  const resolveIOSCompatibleHlsSource = async (source: {
    url: string;
    headers?: Record<string, string>;
    format?: string;
  }) => {
    if (Platform.OS !== 'ios') return source;
    const url = String(source?.url ?? '').trim();
    const format = String(source?.format ?? '').toLowerCase();
    const isHls = format === 'm3u8' || format === 'hls' || url.toLowerCase().includes('.m3u8');
    if (!isHls || !url) return source;

    const abs = (base: string, value: string) => {
      try {
        return new URL(value, base).toString();
      } catch {
        return value;
      }
    };
    try {
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), 5000);
      const res = await fetch(url, {
        method: 'GET',
        headers: source.headers ?? {},
        signal: controller.signal,
      });
      clearTimeout(timer);
      if (!res.ok) return source;
      const text = await res.text();
      if (!text.includes('#EXTM3U')) return source;

      type Variant = { url: string; codecs: string; score: number };
      const variants: Variant[] = [];
      const lines = text.split(/\r?\n/);
      if (text.includes('#EXT-X-STREAM-INF')) {
        for (let i = 0; i < lines.length; i++) {
          const line = (lines[i] ?? '').trim();
          if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
          const attrs = line.slice('#EXT-X-STREAM-INF:'.length);
          const next = (lines[i + 1] ?? '').trim();
          if (!next || next.startsWith('#')) continue;
          const codecs = String(attrs.match(/CODECS="([^"]+)"/i)?.[1] ?? '').toLowerCase();

          let score = 0;
          if (codecs.includes('avc1')) score += 100;
          if (codecs.includes('mp4a')) score += 40;
          if (codecs.includes('hvc1') || codecs.includes('hev1') || codecs.includes('dvhe')) score -= 200;

          variants.push({
            url: abs(url, next),
            codecs,
            score,
          });
        }
      }

      let resolvedUrl = url;
      if (variants.length > 0) {
        variants.sort((a, b) => b.score - a.score);
        const best = variants[0];
        if (best?.url) {
          resolvedUrl = best.url;
        }
      }
      if (resolvedUrl !== url) {
        if (__DEV__) console.log(
          '[Details][Playback][iOS] Selected compatible HLS variant:',
          {
            codecs: variants[0]?.codecs,
            url: String(resolvedUrl).slice(0, 140),
          }
        );
      }

      if (resolvedUrl !== url) return { ...source, url: resolvedUrl, format: 'm3u8' };
      return source;
    } catch {
      return source;
    }
  };
  useEffect(() => {
    return () => {
      mountedRef.current = false;
      playRequestIdRef.current += 1;
      downloadRequestIdRef.current += 1;
    };
  }, []);
  useEffect(() => {
    return subscribeDownloads(setDownloadItems);
  }, []);
  useEffect(() => {
    let cancelled = false;
    (async () => {
      const saved = await getAnimePaheManualMapping(anilistId, title);
      if (cancelled) return;
      setManualSessionId(saved?.sessionId ?? null);
      setManualSessionTitle(saved?.animePaheTitle ?? null);
      setMappingQuery(saved?.animePaheTitle ?? title);
    })();
    return () => {
      cancelled = true;
    };
  }, [anilistId, title]);

  useEffect(() => {
    if (downloadsOnly) return;
    const loadEpisodes = async () => {
      if (!title) {
        setLoading(false);
        return;
      }
      setLoading(true);
      try {
        const [media, anilistEpisodeMeta, metadata] = await Promise.all([
          fetchAnimeById(anilistId),
          fetchAniListEpisodeMeta(anilistId).catch(() => ({} as AniListEpisodeMetaMap)),
          fetchAnimeMetadataById(anilistId).catch(() => null),
        ]);
        setEpisodeMetaMap(anilistEpisodeMeta ?? {});
        setAnimeMetadata(metadata);
        setCanTrackAniList(!!media && Number.isFinite(anilistId) && anilistId > 0);
        setAnimeAiringStatus(media?.status ?? null);
        const anilistMatch =
          media != null
            ? {
                episodeCount: media.episodes,
                titles: media.title,
                averageScore: averageScore ?? null,
                coverImage: coverImage ?? null,
              }
            : undefined;
        const mergeAniListTitles = (list: Episode[]) =>
          list.map((ep) => {
            const aniTitle = anilistEpisodeMeta?.[ep.number]?.title;
            if (aniTitle && aniTitle.trim()) {
              return { ...ep, title: aniTitle };
            }
            return ep;
          });
        // Fetch episodes from AnimePahe using anime title
        const list = await fetchEpisodesForAnime(title, anilistMatch, {
          animePaheSessionId: effectiveSoraId,
          onPartialEpisodes: (partial) => {
            const mergedPartial = mergeAniListTitles(partial);
            setEpisodes(mergedPartial);
          },
        });
        const merged = mergeAniListTitles(list);
        setEpisodes(merged);
        setEpisodeIntroMap({});
      } catch (e) {
        console.error(e);
        setCanTrackAniList(false);
      } finally {
        setLoading(false);
      }
    };

    loadEpisodes();
  }, [title, anilistId, averageScore, coverImage, effectiveSoraId, downloadsOnly]);

  useEffect(() => {
    if (!downloadsOnly) return;
    setEpisodeMetaMap({});
    const normalizedTitle = String(title ?? '').trim().toLowerCase();
    const completed = downloadItems
      .filter((item) => item.status === 'completed' && !!item.fileUri)
      .filter((item) => String(item.animeTitle ?? '').trim().toLowerCase() === normalizedTitle)
      .sort((a, b) => a.episodeNumber - b.episodeNumber);
    const localEpisodes: Episode[] = completed.map((item) => ({
      id: item.episodeId,
      number: item.episodeNumber,
      title: `${title} - Episode ${item.episodeNumber}`,
      streamUrl: item.fileUri,
    })) as Episode[];
    setEpisodes(localEpisodes);
    setLoading(false);
  }, [downloadsOnly, downloadItems, title]);

  // readEpisodeProgress is stable for this screen lifecycle; re-running on function identity changes is unnecessary.
  /* eslint-disable react-hooks/exhaustive-deps */
  useEffect(() => {
    let cancelled = false;
    const hydrateEpisodeProgress = async () => {
      if (!episodes.length) {
        if (!cancelled) setEpisodeProgressMap({});
        return;
      }
      const pairs = await Promise.all(
        episodes.map(async (ep) => ({ number: ep.number, progress: await readEpisodeProgress(ep) }))
      );
      if (cancelled) return;
      const next: Record<number, { positionSec: number; durationSec: number; percent: number }> = {};
      for (const pair of pairs) {
        next[pair.number] = pair.progress;
      }
      setEpisodeProgressMap(next);
    };
    void hydrateEpisodeProgress();
    return () => {
      cancelled = true;
    };
  }, [episodes, anilistId, titleKey]);
  /* eslint-enable react-hooks/exhaustive-deps */

  const handleSearchManualMapping = async () => {
    const q = (mappingQuery || title).trim();
    if (!q) return;
    try {
      setMappingLoading(true);
      const results = await searchAnimePahe(q);
      setMappingResults(
        (Array.isArray(results) ? results : [])
          .map((r: any) => ({
            id: String(r?.id ?? '').trim(),
            title: String(r?.title ?? r?.name ?? r?.id ?? '').trim(),
          }))
          .filter((r) => r.id && r.title)
      );
    } catch (e) {
      if (__DEV__) console.warn('Manual mapping search failed', e);
      setMappingResults([]);
      Alert.alert('AnimePahe', 'Could not search AnimePahe right now.');
    } finally {
      setMappingLoading(false);
    }
  };

  const handleSelectManualMapping = async (item: { id: string; title: string }) => {
    try {
      await setAnimePaheManualMapping({
        anilistId,
        title,
        sessionId: item.id,
        animePaheTitle: item.title,
      });
      setManualSessionId(item.id);
      setManualSessionTitle(item.title);
      setMappingResults([]);
      Alert.alert('AnimePahe', `Saved manual match: ${item.title}`);
    } catch (e) {
      if (__DEV__) console.warn('Manual mapping save failed', e);
      Alert.alert('AnimePahe', 'Could not save this mapping.');
    }
  };

  const handleClearManualMapping = async () => {
    try {
      await clearAnimePaheManualMapping(anilistId, title);
      setManualSessionId(null);
      setManualSessionTitle(null);
      setMappingResults([]);
      Alert.alert('AnimePahe', 'Manual mapping cleared.');
    } catch (e) {
      if (__DEV__) console.warn('Manual mapping clear failed', e);
      Alert.alert('AnimePahe', 'Could not clear mapping.');
    }
  };

  useEffect(() => {
    const loadViewerBanner = async () => {
      setViewerBannerLoaded(false);
      if (!accessToken) {
        setViewerBanner(null);
        setViewerBannerLoaded(true);
        return;
      }
      try {
        const viewer = await fetchAniListViewerProfile(accessToken);
        setViewerBanner(viewer?.bannerImage ?? null);
      } catch {
        setViewerBanner(null);
      } finally {
        setViewerBannerLoaded(true);
      }
    };
    loadViewerBanner();
  }, [accessToken]);

  useEffect(() => {
    const loadTracking = async () => {
      if (!accessToken || !anilistId) {
        setTrackingEntry(null);
        setAvailableCustomLists([]);
        return;
      }
      if (!canTrackAniList) {
        setTrackingEntry(null);
        setAvailableCustomLists([]);
        return;
      }
      try {
        const [data, customLists] = await Promise.all([
          fetchAniListTrackingInfo(anilistId, accessToken),
          fetchAniListCustomLists(accessToken),
        ]);
        setTrackingEntry(data.entry);
        if (data.episodes != null) setAnimeTotalEpisodes(data.episodes);
        setAvailableCustomLists(customLists);
        const raw = data.entry?.score;
        setScoreInput(typeof raw === 'number' ? raw.toFixed(1) : '');
      } catch (e) {
        if (__DEV__) console.warn('Failed to load AniList tracking info', e);
      }
    };
    loadTracking();
  }, [accessToken, anilistId, canTrackAniList]);

  const requestEpisodeIntroRange = (episodeNumber: number, episodeLengthSec?: number) => {
    if (!(Number.isFinite(anilistId) && anilistId > 0)) return;
    const ep = Math.max(1, Math.trunc(Number(episodeNumber) || 1));
    if (episodeIntroMap[ep]) return;
    if (introFetchInFlightRef.current[ep]) return;
    introFetchInFlightRef.current[ep] = true;
    void (async () => {
      const intro = await fetchAniListEpisodeIntroRange(anilistId, ep, episodeLengthSec).catch(() => null);
      introFetchInFlightRef.current[ep] = false;
      if (!intro || !mountedRef.current) return;
      setEpisodeIntroMap((prev) => (prev[ep] ? prev : { ...prev, [ep]: intro }));
    })();
  };

  // requestEpisodeIntroRange intentionally runs for episode/anilist changes only to avoid redundant intro fetch storms.
  /* eslint-disable react-hooks/exhaustive-deps */
  useEffect(() => {
    if (!(Number.isFinite(anilistId) && anilistId > 0)) return;
    if (!episodes.length) return;
    const top = [...episodes].sort((a, b) => a.number - b.number).slice(0, 12);
    for (const ep of top) {
      requestEpisodeIntroRange(ep.number);
    }
  }, [anilistId, episodes]);
  /* eslint-enable react-hooks/exhaustive-deps */

  const handlePlayEpisode = async (episode: Episode, options?: { skipOffline?: boolean }) => {
    const requestId = ++playRequestIdRef.current;
    const isRequestActive = () => mountedRef.current && playRequestIdRef.current === requestId;
    const savedResume = await readEpisodeProgressSec(episode);
    requestEpisodeIntroRange(episode.number);
    if (isRequestActive()) {
      playbackPositionSecRef.current = savedResume;
      setResumeSeekSec(savedResume);
    }
    const inferFormat = (url: string, format?: string): string => {
      const explicit = String(format ?? '').toLowerCase();
      if (explicit === 'm3u8' || explicit === 'hls') return 'm3u8';
      if (explicit === 'mpd' || explicit === 'dash') return 'mpd';
      if (explicit === 'mp4') return 'mp4';
      const u = String(url ?? '').toLowerCase();
      if (u.includes('.m3u8')) return 'm3u8';
      if (u.includes('.mpd')) return 'mpd';
      if (u.includes('.mp4')) return 'mp4';
      if (u.includes('kwik') || u.includes('animepahe')) return 'm3u8';
      return 'mp4';
    };

    const buildAnimePaheHeaders = (
      sourceUrl: string,
      episodeId: string,
      explicitReferer?: string
    ): Record<string, string> | undefined => {
      const rawUrl = String(sourceUrl ?? '').trim();
      if (!rawUrl) return undefined;
      const lower = rawUrl.toLowerCase();
      const isAnimePaheFlow =
        lower.includes('animepahe') ||
        lower.includes('kwik') ||
        lower.includes('owocdn.top') ||
        lower.includes('.m3u8') ||
        lower.includes('.mpd') ||
        lower.includes('.mp4');
      if (!isAnimePaheFlow) return undefined;

      const episodeParts = String(episodeId ?? '').split('/');
      const derivedPlayPage =
        episodeParts.length >= 2
          ? `https://animepahe.si/play/${episodeParts[0]}/${episodeParts[1]}`
          : undefined;
      const referer = explicitReferer || derivedPlayPage;

      const headers: Record<string, string> = {};
      if (referer) headers.Referer = referer;
      if (referer) {
        try {
          headers.Origin = new URL(referer).origin;
        } catch {}
      }
      headers['User-Agent'] =
        'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      headers.Accept = '*/*';
      return Object.keys(headers).length ? headers : undefined;
    };

    const mergePlaybackHeaders = (
      sourceUrl: string,
      episodeId: string,
      existing?: Record<string, string>,
      explicitReferer?: string
    ): Record<string, string> | undefined => {
      const inferred = buildAnimePaheHeaders(sourceUrl, episodeId, explicitReferer) ?? {};
      const merged = canonicalizeHeaders({ ...inferred, ...(existing ?? {}) });
      return merged;
    };
    const normalizeSourceForPlayback = (raw: any, episodeId: string, explicitReferer?: string) => {
      const url = String(
        typeof raw === 'string'
          ? raw
          : raw?.url ?? raw?.src ?? raw?.file ?? raw?.link ?? ''
      ).trim();
      if (!url) return null;
      const format = inferFormat(url, raw?.format);
      return {
        ...(typeof raw === 'object' && raw ? raw : {}),
        url,
        format,
        quality:
          typeof raw === 'object' && raw?.quality != null ? raw.quality : 'auto',
        subOrDub:
          typeof raw === 'object' && raw?.subOrDub != null ? raw.subOrDub : 'sub',
        headers:
          mergePlaybackHeaders(
            url,
            episodeId,
            typeof raw === 'object' ? raw?.headers : undefined,
            explicitReferer
          ),
      };
    };
    const normalizeQuality = (q: unknown) =>
      String(q ?? '')
        .toLowerCase()
        .replace(/\s+/g, '')
        .replace(/[^0-9a-z]/g, '');
    const normalizeLanguage = (lang: unknown) => {
      const v = String(lang ?? '').toLowerCase();
      if (v.includes('dub')) return 'dub';
      if (v.includes('sub')) return 'sub';
      return '';
    };
    const pickPreferredSource = (list: any[]) => {
      if (!Array.isArray(list) || list.length === 0) return null;
      const normalized = strictIOSHlsOnly
        ? list.filter((s) => {
            const f = String(s?.format ?? '').toLowerCase();
            return f === 'm3u8' || f === 'hls';
          })
        : Platform.OS === 'ios'
          ? list.filter((s) => String(s?.format ?? '').toLowerCase() !== 'mpd')
          : list;
      const formatRank = (s: any) => {
        const f = String(s?.format ?? '').toLowerCase();
        if (Platform.OS === 'ios') {
          if (f === 'm3u8' || f === 'hls') return 0;
          if (f === 'mp4') return 1;
          return 2;
        }
        return 0;
      };
      const candidates = (normalized.length > 0 ? normalized : list)
        .slice()
        .sort((a: any, b: any) => formatRank(a) - formatRank(b));
      if (streamSelectionMode === 'ask-every-time') return null;
      const qualityPref = normalizeQuality(defaultStreamQuality);
      const languagePref = defaultStreamLanguage;
      const hasLanguagePreference = languagePref !== 'any';
      const hasQualityPreference = qualityPref !== 'auto';
      const matchesLanguage = (source: any) =>
        !hasLanguagePreference || normalizeLanguage(source?.subOrDub) === languagePref;
      const matchesQuality = (source: any) => {
        if (!hasQualityPreference) return true;
        const q = normalizeQuality(source?.quality);
        if (!q) return false;
        if (q.includes(qualityPref)) return true;
        const prefNum = qualityPref.replace('p', '');
        return q.includes(prefNum);
      };
      // If no explicit preference is set, auto-play the first available source.
      if (!hasLanguagePreference && !hasQualityPreference) return candidates[0] ?? null;
      // If a preference is set but unavailable for this episode, return null to open picker.
      return candidates.find((s) => matchesLanguage(s) && matchesQuality(s)) ?? null;
    };
    const buildPlaybackQueue = (items: any[]) => {
      const out: { url: string; headers?: Record<string, string>; format?: string }[] = [];
      for (const item of items) {
        const base = { url: item.url, headers: item.headers, format: item.format };
        out.push(base);
        const lowerUrl = String(item?.url ?? '').toLowerCase();
        const hasHeaders = !!item?.headers && Object.keys(item.headers).length > 0;
        if (Platform.OS === 'ios' && lowerUrl.includes('owocdn.top') && hasHeaders) {
          out.push({ url: item.url, headers: undefined, format: item.format });
        }
      }
      return out;
    };

    const withTimeout = async <T,>(promise: Promise<T>, ms: number, label: string): Promise<T> => {
      return new Promise<T>((resolve, reject) => {
        const t = setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms);
        promise
          .then((v) => {
            clearTimeout(t);
            resolve(v);
          })
          .catch((e) => {
            clearTimeout(t);
            reject(e);
          });
      });
    };
    const verifySegmentsFromPlaylist = async (
      playlistUri: string,
      visited = new Set<string>()
    ): Promise<{ segmentCount: number; missingSegments: string[] }> => {
      const key = String(playlistUri ?? '').trim();
      if (!key || visited.has(key)) return { segmentCount: 0, missingSegments: [] };
      visited.add(key);
      const text = await FileSystem.readAsStringAsync(playlistUri);
      const refs = text
        .split(/\r?\n/)
        .map((line) => String(line ?? '').trim())
        .filter((line) => !!line && !line.startsWith('#'));
      let segmentCount = 0;
      const missingSegments: string[] = [];
      const docsDir = String((FileSystem as any).documentDirectory ?? '');
      for (const ref of refs) {
        const resolved = (() => {
          try {
            return new URL(ref, playlistUri).toString();
          } catch {
            return ref;
          }
        })();
        if (/\.m3u8(?:[\?#]|$)/i.test(ref)) {
          const nested = await verifySegmentsFromPlaylist(resolved, visited);
          segmentCount += nested.segmentCount;
          missingSegments.push(...nested.missingSegments);
          continue;
        }
        const isKnownMediaRef = /\.(ts|m4s|mp4|aac)(?:[\?#]|$)/i.test(ref);
        const isLikelySegmentRef =
          !ref.startsWith('http') &&
          !ref.startsWith('file://') &&
          !ref.startsWith('/') &&
          !ref.includes('://') &&
          !ref.includes('.m3u8');
        if (isKnownMediaRef || isLikelySegmentRef) {
          segmentCount += 1;
          const info = await FileSystem.getInfoAsync(resolved);
          const inDocuments = !docsDir || String(resolved).startsWith(docsDir);
          if (!(info as any)?.exists || !inDocuments) {
            missingSegments.push(resolved);
          }
        }
      }
      return { segmentCount, missingSegments };
    };
    const ensureOfflinePlayableAsset = async (localUri: string, context: string) => {
      const normalized = await ensureExistingLocalUri(localUri, `${context}:playlist`);
      if (!normalized) return null;
      if (!/\.m3u8(?:[\?#]|$)/i.test(String(normalized ?? ''))) return normalized;
      try {
        const verification = await verifySegmentsFromPlaylist(normalized);
        if (verification.segmentCount <= 0 || verification.missingSegments.length > 0) {
          throw new Error('Download Incomplete - Segments Missing');
        }
        return normalized;
      } catch (error: any) {
        const err = String(error?.message ?? '') === 'Download Incomplete - Segments Missing'
          ? error
          : new Error('Download Incomplete - Segments Missing');
        console.error('[Details][Offline] HLS preflight failed:', {
          context,
          playlist: normalized,
          error: err?.message ?? String(err),
        });
        throw err;
      }
    };
    const canUseLocalDownloadedPath = (path: string) => {
      const p = String(path ?? '').trim();
      if (!p) return false;
      if (!/^file:\/\//i.test(p) && !p.startsWith('/')) return false;
      return true;
    };
    const isIosLocalHls = (uri: string) =>
      Platform.OS === 'ios' && /^file:\/\//i.test(String(uri ?? '')) && /\.m3u8(?:[\?#]|$)/i.test(String(uri ?? ''));

    if (!options?.skipOffline) {
      const directLocalPath = String(episode.streamUrl ?? '').trim();
      if (canUseLocalDownloadedPath(directLocalPath)) {
        let localUri: string | null = null;
        try {
          localUri = await ensureOfflinePlayableAsset(directLocalPath, 'episode.streamUrl');
        } catch (error: any) {
          if (downloadsOnly) {
            Alert.alert('Offline File Missing', error?.message ?? 'Download Incomplete - Segments Missing');
            return;
          }
        }
        if (!localUri) {
          if (__DEV__) console.log('[Details][Offline] Falling back to online source resolution');
        } else {
        if (isIosLocalHls(localUri)) {
          if (downloadsOnly) {
            Alert.alert('Offline Unsupported', 'This download is HLS (.m3u8). On iOS, re-download as MP4 for offline playback.');
            return;
          }
          if (__DEV__) console.log('[Details][Offline] iOS local HLS skipped; falling back to stream');
        } else {
        const offlineFormat = localUri.toLowerCase().includes('.m3u8') ? 'm3u8' : 'mp4';
        const normalizedLocalPath = localUri;
        offlineFallbackAttemptedRef.current = null;
        setPlaybackOrigin('offline');
        setPickerMode('play');
        setPendingDownloadEpisode(null);
        setCurrentEpisode(episode);
        setPlaybackQueue([{ url: normalizedLocalPath, format: offlineFormat }]);
        setSelectedSource({ url: normalizedLocalPath, format: offlineFormat });
        return;
        }
        }
      }
      const matchedDownload = findEpisodeDownloadItem(episode);
      const matchedPath = String(matchedDownload?.fileUri ?? '').trim();
      if (canUseLocalDownloadedPath(matchedPath)) {
        let localUri: string | null = null;
        try {
          localUri = await ensureOfflinePlayableAsset(matchedPath, 'matched download item');
        } catch (error: any) {
          if (downloadsOnly) {
            Alert.alert('Offline File Missing', error?.message ?? 'Download Incomplete - Segments Missing');
            return;
          }
        }
        if (!localUri) {
          if (__DEV__) console.log('[Details][Offline] Falling back to online source resolution');
        } else {
        if (isIosLocalHls(localUri)) {
          if (downloadsOnly) {
            Alert.alert('Offline Unsupported', 'This download is HLS (.m3u8). On iOS, re-download as MP4 for offline playback.');
            return;
          }
          if (__DEV__) console.log('[Details][Offline] iOS local HLS skipped; falling back to stream');
        } else {
        const offlineFormat = localUri.toLowerCase().includes('.m3u8') ? 'm3u8' : 'mp4';
        const normalizedLocalPath = localUri;
        offlineFallbackAttemptedRef.current = null;
        setPlaybackOrigin('offline');
        setPickerMode('play');
        setPendingDownloadEpisode(null);
        setCurrentEpisode(episode);
        setPlaybackQueue([{ url: normalizedLocalPath, format: offlineFormat }]);
        setSelectedSource({ url: normalizedLocalPath, format: offlineFormat });
        return;
        }
        }
      }
      let downloadedPath = await getDownloadedEpisodePath(episode.id);
      if (!downloadedPath && Number.isFinite(anilistId) && anilistId > 0) {
        downloadedPath = await getDownloadedEpisodePathByAniListEpisode(anilistId, episode.number);
      }
      if (!downloadedPath) {
        downloadedPath = await getDownloadedEpisodePathByMeta(title, episode.number);
      }
      if (downloadedPath && canUseLocalDownloadedPath(downloadedPath)) {
        let localUri: string | null = null;
        try {
          localUri = await ensureOfflinePlayableAsset(downloadedPath, 'download registry lookup');
        } catch (error: any) {
          if (downloadsOnly) {
            Alert.alert('Offline File Missing', error?.message ?? 'Download Incomplete - Segments Missing');
            return;
          }
        }
        if (!localUri) {
          if (__DEV__) console.log('[Details][Offline] Falling back to online source resolution');
        } else {
        if (isIosLocalHls(localUri)) {
          if (downloadsOnly) {
            Alert.alert('Offline Unsupported', 'This download is HLS (.m3u8). On iOS, re-download as MP4 for offline playback.');
            return;
          }
          if (__DEV__) console.log('[Details][Offline] iOS local HLS skipped; falling back to stream');
        } else {
        const offlineFormat = localUri.toLowerCase().includes('.m3u8') ? 'm3u8' : 'mp4';
        const normalizedLocalPath = localUri;
        if (__DEV__) console.log('[Details][Offline] Using downloaded episode:', {
          episodeId: episode.id,
          episodeNumber: episode.number,
          path: normalizedLocalPath,
          format: offlineFormat,
        });
        offlineFallbackAttemptedRef.current = null;
        setPlaybackOrigin('offline');
        setPickerMode('play');
        setPendingDownloadEpisode(null);
        setCurrentEpisode(episode);
        setPlaybackQueue([{ url: normalizedLocalPath, format: offlineFormat }]);
        setSelectedSource({ url: normalizedLocalPath, format: offlineFormat });
        return;
        }
        }
      }
    }
    if (downloadsOnly) {
      console.error('[Details][Offline] downloadsOnly mode: local file not found, aborting remote playback');
      Alert.alert('Offline File Missing', 'This downloaded episode file is missing or invalid. Please re-download it.');
      return;
    }
    setPickerMode('play');
    setPendingDownloadEpisode(null);
    setCurrentEpisode(episode);
    setPlaybackOrigin('stream');
    // Fetch sources, then auto-pick preferred source when available.
    setPickerVisible(false);
    setSources([]);
    beginSourcesLoading();
    let settled = false;
    const fallback = [
      {
        url: episode.streamUrl,
        quality: 'auto',
        format: episode.streamUrl?.includes('.m3u8') ? 'm3u8' : 'mp4',
        subOrDub: 'sub',
      },
    ];
    const fallbackTimeout = setTimeout(() => {
      if (settled || !isRequestActive()) return;
      settled = true;
      setSources(fallback);
      setPickerVisible(true);
    }, 12000);
    try {
      // Fetch sources via Sora extension (through ScraperService)
      let list: any[] = [];
      try {
        if (__DEV__) console.log('[Details] Fetching sources for episode:', episode.id);
        list = await withTimeout(
          fetchSourcesForEpisode(episode.id, { title }),
          10000,
          'fetchSourcesForEpisode'
        );
        if (!isRequestActive()) return;
        if (__DEV__) console.log('[Details] Sources returned count:', Array.isArray(list) ? list.length : 0);
      } catch (e: any) {
        if (__DEV__) console.warn('[Details] Sora source fetch failed:', e);
        list = [];
      }
      
      // Fallback to the episode.streamUrl when still no sources found
      if (!list || list.length === 0) {
        list = fallback;
      }
      if (!isRequestActive()) return;
      list = list
        .map((item: any) => normalizeSourceForPlayback(item, episode.id))
        .filter((item: any) => !!item?.url);
      if (__DEV__) {
        if (__DEV__) console.log('[Details][Playback] Raw normalized sources count:', list.length);
      }
      let playableList =
        strictIOSHlsOnly
          ? list.filter((item: any) => {
              const f = String(item?.format ?? '').toLowerCase();
              return f === 'm3u8' || f === 'hls';
            })
          : Platform.OS === 'ios'
            ? list.filter((item: any) => String(item?.format ?? '').toLowerCase() !== 'mpd')
          : list;
      if (Platform.OS === 'ios') {
        const resolved: any[] = [];
        for (const item of playableList) {
          resolved.push(await resolveIOSCompatibleHlsSource(item));
          if (!isRequestActive()) return;
        }
        playableList = resolved;
      }
      if (__DEV__) {
        if (__DEV__) console.log('[Details][Playback] Playable sources count:', playableList.length);
      }
      if (!settled && isRequestActive()) {
        settled = true;
        if (strictIOSHlsOnly && playableList.length === 0) {
          setSources(list);
          setPickerVisible(true);
          Alert.alert(
            'No iOS-Compatible Stream',
            'Only HLS (.m3u8) streams are allowed on iOS right now. This episode has no compatible source.'
          );
          return;
        }
        const preferred = pickPreferredSource(playableList);
        const forcedFallbackPreferred =
          !preferred?.url && options?.skipOffline && playableList.length > 0 ? playableList[0] : null;
        const selectedPreferred = preferred?.url ? preferred : forcedFallbackPreferred;
        if (selectedPreferred?.url) {
          const queue = [
            selectedPreferred,
            ...playableList
              .filter((s: any) => String(s?.url ?? '') !== String(selectedPreferred?.url ?? ''))
              .sort((a: any, b: any) => {
                const fa = String(a?.format ?? '').toLowerCase();
                const fb = String(b?.format ?? '').toLowerCase();
                const ra = Platform.OS === 'ios'
                  ? (fa === 'm3u8' || fa === 'hls' ? 0 : fa === 'mp4' ? 1 : 2)
                  : 0;
                const rb = Platform.OS === 'ios'
                  ? (fb === 'm3u8' || fb === 'hls' ? 0 : fb === 'mp4' ? 1 : 2)
                  : 0;
                return ra - rb;
              }),
          ];
          setPlaybackQueue(buildPlaybackQueue(queue));
          if (__DEV__) console.log(
            '[Details][Playback] Auto-selected source:',
            {
              format: selectedPreferred?.format,
              quality: selectedPreferred?.quality,
              url: String(selectedPreferred?.url ?? '').slice(0, 120),
              forcedFallback: !!forcedFallbackPreferred,
            }
          );
          if (__DEV__) {
            if (__DEV__) console.log('[Details][Playback] Queue order count:', queue.length);
          }
          setSelectedSource({
            url: selectedPreferred.url,
            headers: selectedPreferred.headers,
            format: selectedPreferred.format,
          });
          setPlaybackOrigin(/^file:\/\//i.test(String(selectedPreferred?.url ?? '')) ? 'offline' : 'stream');
          setPickerVisible(false);
        } else {
          setSources(playableList.length > 0 ? playableList : list);
          setPickerVisible(true);
        }
      }
    } catch (e) {
      if (__DEV__) console.warn('Error loading sources', e);
      if (!settled && isRequestActive()) {
        settled = true;
        setSources(fallback);
        setPickerVisible(true);
      }
    } finally {
      clearTimeout(fallbackTimeout);
      if (!settled) settled = true;
      endSourcesLoading();
    }
  };

  const handleSelectSource = async (source: {
    url: string;
    headers?: Record<string, string>;
    format?: string;
    quality?: string;
    subOrDub?: string;
  }) => {
    setPickerVisible(false);
    if (pickerMode === 'download-batch' && pendingBatchEpisodes.length > 0) {
      const batch = [...pendingBatchEpisodes];
      setPendingBatchEpisodes([]);
      setPendingDownloadEpisode(null);
      setPickerMode('play');
      await queueBatchDownloads(batch, source);
      return;
    }
    if (pickerMode === 'download' && pendingDownloadEpisode) {
      enqueueEpisodeDownload(pendingDownloadEpisode, source);
      setPendingDownloadEpisode(null);
      setPickerMode('play');
      return;
    }
    if (!currentEpisode) return;
    const inferFormat = (url: string, format?: string): string => {
      const explicit = String(format ?? '').toLowerCase();
      if (explicit === 'm3u8' || explicit === 'hls') return 'm3u8';
      if (explicit === 'mpd' || explicit === 'dash') return 'mpd';
      if (explicit === 'mp4') return 'mp4';
      const u = String(url ?? '').toLowerCase();
      if (u.includes('.m3u8')) return 'm3u8';
      if (u.includes('.mpd')) return 'mpd';
      if (u.includes('.mp4')) return 'mp4';
      if (u.includes('kwik') || u.includes('animepahe')) return 'm3u8';
      return 'mp4';
    };
    const selectedFormat = inferFormat(source.url, source.format);
    if (strictIOSHlsOnly && selectedFormat !== 'm3u8') {
      Alert.alert('Unsupported Stream', 'On iOS this player currently accepts only HLS (.m3u8) sources.');
      setPickerVisible(true);
      return;
    }
    if (!strictIOSHlsOnly && Platform.OS === 'ios' && selectedFormat === 'mpd') {
      Alert.alert('Unsupported Stream', 'This stream format is not supported on iOS. Please pick another source.');
      setPickerVisible(true);
      return;
    }
    const lower = String(source.url ?? '').toLowerCase();
    const shouldInjectHeaders =
      lower.includes('animepahe') ||
      lower.includes('kwik') ||
      lower.includes('.m3u8') ||
      lower.includes('.mpd') ||
      lower.includes('.mp4');
    const episodeParts = String(currentEpisode.id ?? '').split('/');
    const derivedPlayPage =
      episodeParts.length >= 2
        ? `https://animepahe.si/play/${episodeParts[0]}/${episodeParts[1]}`
        : undefined;
    const existingHeaders = source.headers ?? {};
    const hasReferer = Object.keys(existingHeaders).some((k) => k.toLowerCase() === 'referer');
    const hasOrigin = Object.keys(existingHeaders).some((k) => k.toLowerCase() === 'origin');
    const mergedHeaders: Record<string, string> = { ...(canonicalizeHeaders(existingHeaders) ?? {}) };
    if (shouldInjectHeaders && derivedPlayPage && !hasReferer) {
      mergedHeaders.Referer = derivedPlayPage;
    }
    if (shouldInjectHeaders && derivedPlayPage && !hasOrigin) {
      try {
        mergedHeaders.Origin = new URL(derivedPlayPage).origin;
      } catch {}
    }
    if (shouldInjectHeaders) {
      const hasUserAgent = Object.keys(mergedHeaders).some((k) => k.toLowerCase() === 'user-agent');
      const hasAccept = Object.keys(mergedHeaders).some((k) => k.toLowerCase() === 'accept');
      if (!hasUserAgent) {
        mergedHeaders['User-Agent'] =
          'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
      }
      if (!hasAccept) {
        mergedHeaders.Accept = '*/*';
      }
    }

    const iosResolved = await resolveIOSCompatibleHlsSource({
      url: source.url,
      headers: Object.keys(mergedHeaders).length ? mergedHeaders : undefined,
      format: selectedFormat,
    });
    if (__DEV__) console.log(
      '[Details][Playback] Manually selected source:',
      { format: iosResolved.format ?? selectedFormat, url: String(iosResolved.url ?? '').slice(0, 120) }
    );
    setSelectedSource({
      url: iosResolved.url,
      headers: canonicalizeHeaders(iosResolved.headers ?? mergedHeaders),
      format: iosResolved.format ?? selectedFormat,
    });
    setPlaybackOrigin(/^file:\/\//i.test(String(iosResolved.url ?? '')) ? 'offline' : 'stream');
    const resolvedHeaders = canonicalizeHeaders(iosResolved.headers ?? mergedHeaders);
    const ordered = [
      {
        url: iosResolved.url,
        headers: resolvedHeaders,
        format: iosResolved.format ?? selectedFormat,
      },
      ...sources
        .filter((s: any) => String(s?.url ?? '') !== String(source.url ?? ''))
        .map((s: any) => ({ url: s.url, headers: s.headers, format: s.format })),
    ];
    const orderedQueue: { url: string; headers?: Record<string, string>; format?: string }[] = [];
    for (const s of ordered) {
      orderedQueue.push(s);
      const lowerUrl = String(s?.url ?? '').toLowerCase();
      const hasHeaders = !!s?.headers && Object.keys(s.headers).length > 0;
      if (Platform.OS === 'ios' && lowerUrl.includes('owocdn.top') && hasHeaders) {
        orderedQueue.push({ url: s.url, headers: undefined, format: s.format });
      }
    }
    setPlaybackQueue(orderedQueue);
    if (__DEV__) console.log(
      '[Details][Playback] Manual queue order:',
      orderedQueue.map((s: any) => ({ format: s?.format, url: String(s?.url ?? '').slice(0, 100), hasHeaders: !!s?.headers }))
    );
  };

  const handlePlaybackError = (message?: string) => {
    const now = Date.now();
    if (playbackErrorGuardRef.current.handling) return;
    if (now - playbackErrorGuardRef.current.lastAt < 800) return;
    playbackErrorGuardRef.current = { lastAt: now, handling: true };
    if (__DEV__) console.log('[Details][Playback] Player error:', message);
    if (downloadsOnly) {
      Alert.alert(
        'Offline Playback Failed',
        'Downloaded file failed to play in offline mode. Please delete and re-download this episode.'
      );
      playbackErrorGuardRef.current.handling = false;
      return;
    }
    const isLocalSelected = /^file:\/\//i.test(String(selectedSource?.url ?? ''));
    if (isLocalSelected && currentEpisode) {
      const key = String(currentEpisode.id ?? '');
      if (offlineFallbackAttemptedRef.current !== key) {
        offlineFallbackAttemptedRef.current = key;
        Alert.alert('Offline Playback Failed', 'Downloaded file failed to play. Switching to stream for this episode.');
        void handlePlayEpisode(currentEpisode, { skipOffline: true });
        playbackErrorGuardRef.current.handling = false;
        return;
      }
    }
    if (!selectedSource || playbackQueue.length === 0) {
      Alert.alert('Playback Error', message ?? 'Could not play this source.');
      playbackErrorGuardRef.current.handling = false;
      return;
    }
    const currentKey = playbackSourceKey(selectedSource);
    const currentIndex = playbackQueue.findIndex((s) => playbackSourceKey(s) === currentKey);
    const next = currentIndex >= 0 ? playbackQueue[currentIndex + 1] : undefined;
    if (next?.url) {
      const keepPosition = Math.max(0, Math.floor(Number(playbackPositionSecRef.current || 0)));
      if (keepPosition > 0) {
        setResumeSeekSec(keepPosition);
      }
      if (__DEV__) console.log(
        '[Details][Playback] Retrying next source:',
        {
          format: next?.format,
          url: String(next?.url ?? '').slice(0, 120),
          fromIndex: currentIndex,
          hasHeaders: !!next?.headers,
          resumeAtSec: keepPosition,
        }
      );
      setPlaybackOrigin(/^file:\/\//i.test(String(next?.url ?? '')) ? 'offline' : 'stream');
      setSelectedSource({
        url: next.url,
        headers: next.headers ? { ...next.headers } : undefined,
        format: next.format,
      });
      setTimeout(() => {
        playbackErrorGuardRef.current.handling = false;
      }, 250);
      return;
    }
    Alert.alert('Playback Error', message ?? 'No working stream found for this episode.');
    playbackErrorGuardRef.current.handling = false;
  };

  const closePlayerModal = () => {
    playRequestIdRef.current += 1;
    downloadRequestIdRef.current += 1;
    offlineFallbackAttemptedRef.current = null;
    setSelectedSource(null);
    setCurrentEpisode(null);
    playbackPositionSecRef.current = 0;
    playbackErrorGuardRef.current = { lastAt: 0, handling: false };
  };

  const handlePlaybackEnded = () => {
    // Keep offline and streaming behavior identical for tracking.
    void handleWatchedNearlyAll();
    const ep = currentEpisode;
    if (!ep) return;
    const sorted = [...episodes].sort((a, b) => a.number - b.number);
    const nextEpisode = sorted.find((item) => item.number > ep.number);
    if (!nextEpisode) return;
    Alert.alert(
      'Episode Finished',
      `Play Episode ${nextEpisode.number} now?`,
      [
        {
          text: 'Not now',
          style: 'cancel',
          onPress: () => {
            closePlayerModal();
          },
        },
        {
          text: 'Play next',
          onPress: () => {
            void handlePlayEpisode(nextEpisode);
          },
        },
      ]
    );
  };

  const sanitizeBaseName = (value: string) =>
    String(value ?? '')
      .replace(/[^a-z0-9\-_. ]/gi, '_')
      .replace(/\s+/g, ' ')
      .trim();

  const resolveDownloadSources = async (episode: Episode) => {
    const toSourceList = (raw: any): any[] => {
      if (!raw) return [];
      if (Array.isArray(raw)) return raw;
      if (typeof raw === 'string') return [{ url: raw }];
      if (raw && typeof raw === 'object') {
        if (Array.isArray(raw.sources)) return raw.sources;
        if (Array.isArray(raw.streams)) return raw.streams;
        if (Array.isArray(raw.files)) return raw.files;
        if (raw.url || raw.streamUrl || raw.src || raw.file || raw.link) return [raw];
      }
      return [];
    };

    const pullUrl = (item: any) =>
      String(item?.url ?? item?.streamUrl ?? item?.src ?? item?.file ?? item?.link ?? '').trim();

    const isDirectMediaUrl = (url: string) => {
      const lower = String(url ?? '').toLowerCase();
      return (
        lower.includes('.mp4') ||
        lower.includes('.m4v') ||
        lower.includes('.webm') ||
        lower.includes('.m3u8') ||
        lower.includes('.ts') ||
        lower.includes('.mpd')
      );
    };

    const inferFormat = (url: string, format?: string) => {
      const explicit = String(format ?? '').toLowerCase();
      if (explicit === 'm3u8' || explicit === 'hls') return 'm3u8';
      if (explicit === 'mp4') return 'mp4';
      if (explicit === 'webm') return 'webm';
      if (explicit === 'ts') return 'ts';
      if (explicit === 'mpd' || explicit === 'dash') return 'mpd';
      const lower = String(url ?? '').toLowerCase();
      if (lower.includes('.m3u8')) return 'm3u8';
      if (lower.includes('.mp4')) return 'mp4';
      if (lower.includes('.m4v')) return 'mp4';
      if (lower.includes('.webm')) return 'webm';
      if (lower.includes('.ts')) return 'ts';
      if (lower.includes('.mpd')) return 'mpd';
      return 'mp4';
    };

    const playPage = episode.id.includes('/')
      ? `https://animepahe.si/play/${episode.id.split('/')[0]}/${episode.id.split('/')[1]}`
      : undefined;

    let resolvedSources: any[] = [];
    try {
      const fetched = await Promise.race([
        fetchSourcesForEpisode(episode.id, { title }),
        new Promise<any[]>((_, reject) => setTimeout(() => reject(new Error('fetchSources timeout')), 12000)),
      ]);
      resolvedSources = toSourceList(fetched);
    } catch {
      resolvedSources = [];
    }

    if (resolvedSources.length === 0) {
      try {
        await new Promise((r) => setTimeout(r, 500));
        const retry = await Promise.race([
          fetchSourcesForEpisode(episode.id, { title }),
          new Promise<any[]>((_, reject) => setTimeout(() => reject(new Error('fetchSources timeout retry')), 12000)),
        ]);
        resolvedSources = toSourceList(retry);
      } catch {}
    }

    if (resolvedSources.length === 0) {
      const fromState = toSourceList(sources);
      if (fromState.length > 0) {
        resolvedSources = fromState;
      }
    }

    if (resolvedSources.length === 0 && episode.streamUrl) {
      resolvedSources = [{
        url: episode.streamUrl,
        format: episode.streamUrl.includes('.mpd')
          ? 'mpd'
          : episode.streamUrl.includes('.webm')
            ? 'webm'
            : episode.streamUrl.includes('.m3u8')
              ? 'm3u8'
              : 'mp4',
        quality: 'auto',
        subOrDub: 'sub',
      }];
    }

    const normalized = resolvedSources
      .map((item) => {
        const url = pullUrl(item);
        if (!url) return null;
        if (!isDirectMediaUrl(url)) return null;
        const format = inferFormat(url, item?.format);
        const headers: Record<string, string> = canonicalizeHeaders(item?.headers ?? {}) ?? {};
        if (!Object.keys(headers).some((k) => k.toLowerCase() === 'referer') && playPage) {
          headers.Referer = playPage;
        }
        if (!Object.keys(headers).some((k) => k.toLowerCase() === 'origin') && playPage) {
          try {
            headers.Origin = new URL(playPage).origin;
          } catch {}
        }
        if (!Object.keys(headers).some((k) => k.toLowerCase() === 'user-agent')) {
          headers['User-Agent'] =
            'Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1';
        }
        if (!Object.keys(headers).some((k) => k.toLowerCase() === 'accept')) {
          headers.Accept = '*/*';
        }
        return {
          url,
          format,
          headers: Object.keys(headers).length ? headers : undefined,
          quality: item?.quality ?? 'auto',
          subOrDub: item?.subOrDub ?? 'sub',
        };
      })
      .filter(Boolean) as {
        url: string;
        format: string;
        headers?: Record<string, string>;
        quality?: string;
        subOrDub?: string;
      }[];

    const downloadable = normalized.filter((s) => {
      const f = String(s.format ?? '').toLowerCase();
      return f === 'mp4' || f === 'webm' || f === 'm3u8' || f === 'hls' || f === 'ts';
    });
    if (downloadable.length > 0) return downloadable;

    return [];
  };

  const enqueueEpisodeDownload = (
    episode: Episode,
    source: { url: string; headers?: Record<string, string>; format?: string }
  ) => {
    const isDirectMediaUrl = (url: string) => {
      const lower = String(url ?? '').toLowerCase();
      return (
        lower.includes('.mp4') ||
        lower.includes('.m4v') ||
        lower.includes('.webm') ||
        lower.includes('.m3u8') ||
        lower.includes('.ts') ||
        lower.includes('.mpd')
      );
    };
    const inferFormat = (url: string, format?: string) => {
      const explicit = String(format ?? '').toLowerCase();
      if (explicit === 'mp4') return 'mp4';
      if (explicit === 'webm') return 'webm';
      if (explicit === 'm3u8' || explicit === 'hls') return 'm3u8';
      if (explicit === 'ts') return 'ts';
      if (explicit === 'mpd' || explicit === 'dash') return 'mpd';
      const lower = String(url ?? '').toLowerCase();
      if (lower.includes('.mp4')) return 'mp4';
      if (lower.includes('.m4v')) return 'mp4';
      if (lower.includes('.webm')) return 'webm';
      if (lower.includes('.m3u8')) return 'm3u8';
      if (lower.includes('.ts')) return 'ts';
      if (lower.includes('.mpd')) return 'mpd';
      return 'mp4';
    };
    if (!isDirectMediaUrl(source.url)) {
      Alert.alert('Download', 'Selected source is a web page, not a direct media file. Pick another source.');
      return;
    }
    const format = inferFormat(source.url, source.format);
    const downloadEngineLabel = format === 'mp4' ? 'mp4-direct' : format || 'unknown';
    if (__DEV__) console.log('[Details][Download] Selected engine:', {
      engine: downloadEngineLabel,
      episodeId: episode.id,
      episodeNumber: episode.number,
      format,
      url: String(source.url ?? '').slice(0, 140),
    });
    if (format === 'mpd') {
      Alert.alert('Download', 'DASH (.mpd) downloads are not supported yet. Pick another source.');
      return;
    }
    if (format !== 'mp4' && format !== 'webm' && format !== 'm3u8' && format !== 'ts') {
      Alert.alert('Download', 'Unsupported download format.');
      return;
    }
    const base = sanitizeBaseName(title || 'anime');
    const ext = format === 'webm' ? 'webm' : 'mp4';
    const fileName = `${base}_ep_${episode.number}.${ext}`;

    enqueueDownload({
      episodeId: episode.id,
      anilistId: Number.isFinite(anilistId) && anilistId > 0 ? anilistId : null,
      animeTitle: title,
      episodeNumber: episode.number,
      url: source.url,
      headers: source.headers,
      format,
      fileName,
      thumbnailUri: coverImage,
    });
  };

  const normalizeQuality = (q: unknown) =>
    String(q ?? '')
      .toLowerCase()
      .replace(/\s+/g, '')
      .replace(/[^0-9a-z]/g, '');
  const normalizeLanguage = (lang: unknown) => {
    const v = String(lang ?? '').toLowerCase();
    if (v.includes('dub')) return 'dub';
    if (v.includes('sub')) return 'sub';
    return '';
  };
  const filterDownloadableCandidates = (list: any[]) =>
    (Array.isArray(list) ? list : []).filter((s) => {
      const f = String(s?.format ?? '').toLowerCase();
      return f === 'mp4' || f === 'webm' || f === 'm3u8' || f === 'hls' || f === 'ts';
    });
  const pickDownloadBySettings = (candidates: any[]) => {
    const qualityPref = normalizeQuality(defaultStreamQuality);
    const languagePref = defaultStreamLanguage;
    const hasLanguagePreference = languagePref !== 'any';
    const hasQualityPreference = qualityPref !== 'auto';
    const matchesLanguage = (source: any) =>
      !hasLanguagePreference || normalizeLanguage(source?.subOrDub) === languagePref;
    const matchesQuality = (source: any) => {
      if (!hasQualityPreference) return true;
      const q = normalizeQuality(source?.quality);
      if (!q) return false;
      if (q.includes(qualityPref)) return true;
      const prefNum = qualityPref.replace('p', '');
      return q.includes(prefNum);
    };
    return (!hasLanguagePreference && !hasQualityPreference
      ? candidates[0]
      : candidates.find((s) => matchesLanguage(s) && matchesQuality(s)) ?? candidates[0]) as any;
  };
  const pickDownloadByTemplate = (candidates: any[], template: any) => {
    const templateQuality = normalizeQuality(template?.quality);
    const templateLanguage = normalizeLanguage(template?.subOrDub);
    const templateFormat = String(template?.format ?? '').toLowerCase();
    const exact = candidates.find((s) => {
      const sq = normalizeQuality(s?.quality);
      const sl = normalizeLanguage(s?.subOrDub);
      const sf = String(s?.format ?? '').toLowerCase();
      return (
        (!templateQuality || sq === templateQuality) &&
        (!templateLanguage || sl === templateLanguage) &&
        (!templateFormat || sf === templateFormat)
      );
    });
    if (exact) return exact;
    const byQualityAndLang = candidates.find((s) => {
      const sq = normalizeQuality(s?.quality);
      const sl = normalizeLanguage(s?.subOrDub);
      return (!templateQuality || sq === templateQuality) && (!templateLanguage || sl === templateLanguage);
    });
    if (byQualityAndLang) return byQualityAndLang;
    return candidates[0];
  };
  const queueBatchDownloads = async (
    episodeList: Episode[],
    templateSource?: { quality?: string; subOrDub?: string; format?: string }
  ) => {
    const ordered = [...episodeList].sort((a, b) => a.number - b.number);
    if (!ordered.length) return;
    const requestId = ++batchDownloadRequestIdRef.current;
    const isRequestActive = () => mountedRef.current && batchDownloadRequestIdRef.current === requestId;
    beginSourcesLoading();
    setBatchQueueing(true);
    let queued = 0;
    let skipped = 0;
    let failed = 0;
    try {
      for (const ep of ordered) {
        if (!isRequestActive()) return;
        const activeItem = downloadItems.find(
          (item) => item.episodeId === ep.id && (item.status === 'queued' || item.status === 'downloading')
        );
        if (activeItem || downloadedEpisodeIds.has(ep.id) || downloadedEpisodeNumbers.has(ep.number)) {
          skipped += 1;
          continue;
        }
        try {
          const list = await resolveDownloadSources(ep);
          if (!isRequestActive()) return;
          const candidates = filterDownloadableCandidates(list);
          if (!candidates.length) {
            failed += 1;
            continue;
          }
          const selected = templateSource
            ? pickDownloadByTemplate(candidates, templateSource)
            : streamSelectionMode === 'ask-every-time'
              ? candidates[0]
              : pickDownloadBySettings(candidates);
          if (!selected?.url) {
            failed += 1;
            continue;
          }
          enqueueEpisodeDownload(ep, selected);
          queued += 1;
        } catch {
          failed += 1;
        }
      }
    } finally {
      endSourcesLoading();
      setBatchQueueing(false);
    }
    if (!isRequestActive()) return;
    Alert.alert(
      'Batch Download',
      `Queued ${queued} episode${queued === 1 ? '' : 's'}.\nSkipped ${skipped}.\nFailed ${failed}.`
    );
  };
  const handleDownloadAllEpisodes = async () => {
    if (!episodes.length) return;
    const targets = [...episodes]
      .sort((a, b) => a.number - b.number)
      .filter((ep) => {
        const item = downloadItems.find((d) => d.episodeId === ep.id);
        if (item?.status === 'completed' || item?.status === 'queued' || item?.status === 'downloading') return false;
        if (downloadedEpisodeIds.has(ep.id) || downloadedEpisodeNumbers.has(ep.number)) return false;
        return true;
      });
    if (!targets.length) {
      Alert.alert('Batch Download', 'All available episodes are already downloaded or queued.');
      return;
    }
    if (streamSelectionMode !== 'ask-every-time') {
      await queueBatchDownloads(targets);
      return;
    }
    const firstEpisode = targets[0];
    beginSourcesLoading();
    try {
      const list = await resolveDownloadSources(firstEpisode);
      const candidates = filterDownloadableCandidates(list);
      if (!candidates.length) {
        Alert.alert('Batch Download', 'No downloadable source found for this series.');
        return;
      }
      setCurrentEpisode(firstEpisode);
      setPendingBatchEpisodes(targets);
      setPendingDownloadEpisode(null);
      setPickerMode('download-batch');
      setSources(candidates);
      setPickerVisible(true);
    } finally {
      endSourcesLoading();
    }
  };
  const handleDownloadEpisode = async (episode: Episode) => {
    const requestId = ++downloadRequestIdRef.current;
    const isRequestActive = () => mountedRef.current && downloadRequestIdRef.current === requestId;
    const current = downloadItems.find(
      (item) => item.episodeId === episode.id && (item.status === 'queued' || item.status === 'downloading')
    );
    if (current) return;

    beginSourcesLoading();
    try {
      const list = await resolveDownloadSources(episode);
      if (!isRequestActive()) return;
      if (!list.length) {
        Alert.alert('Download', 'No downloadable source found for this episode.');
        return;
      }
      const candidates = filterDownloadableCandidates(list);
      if (!candidates.length) {
        Alert.alert('Download', 'No downloadable source found for this episode.');
        return;
      }
      const preferred = streamSelectionMode === 'ask-every-time' ? null : pickDownloadBySettings(candidates);

      if (preferred?.url) {
        enqueueEpisodeDownload(episode, preferred);
        return;
      }

      setCurrentEpisode(episode);
      setPendingDownloadEpisode(episode);
      setPickerMode('download');
      setSources(candidates);
      setPickerVisible(true);
    } finally {
      endSourcesLoading();
    }
  };
  const handleDeleteDownloadedEpisode = (episode: Episode) => {
    const item = findEpisodeDownloadItem(episode);
    if (!item || item.status !== 'completed') return;
    Alert.alert(
      'Delete Download',
      `Remove Episode ${episode.number} from local storage?`,
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: () => {
            void deleteDownloadedEpisode(item.episodeId, title, episode.number);
          },
        },
      ]
    );
  };
  const handleWatchedNearlyAll = async () => {
    if (!currentEpisode) return;
    setEpisodeProgressMap((prev) => ({
      ...prev,
      [currentEpisode.number]: {
        positionSec: 1,
        durationSec: 1,
        percent: 100,
      },
    }));
    void saveEpisodeProgressSec(currentEpisode, Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
    if (!anilistId) return;
    if (!accessToken) {
      Alert.alert(
        'AniList',
        'To track your progress, please log in to AniList first.',
        [
          {
            text: 'Log in',
            onPress: () => login(),
          },
          { text: 'Cancel', style: 'cancel' },
        ]
      );
      return;
    }
    try {
      setUpdatingProgress(true);
      const isReleasing = animeAiringStatus === 'RELEASING';
      const nextStatus: AniListMediaStatus =
        !isReleasing && resolvedTotalEpisodes != null && currentEpisode.number >= resolvedTotalEpisodes
          ? 'COMPLETED'
          : 'CURRENT';
      await updateAniListProgress({
        mediaId: anilistId,
        progress: currentEpisode.number,
        status: nextStatus,
        accessToken,
      });
      setTrackingEntry((prev) => ({
        id: prev?.id ?? 0,
        progress: currentEpisode.number,
        status: nextStatus,
        score: prev?.score ?? null,
        customLists: prev?.customLists ?? [],
      }));
    } catch (e) {
      console.error(e);
      Alert.alert('AniList', 'Could not update your AniList progress.');
    } finally {
      setUpdatingProgress(false);
    }
  };

  const handleAddOneWatched = async () => {
    if (!accessToken || !anilistId) {
      login();
      return;
    }
    if (!canTrackAniList) {
      Alert.alert('AniList', 'This title is not linked to a valid AniList entry.');
      return;
    }
    const current = trackingEntry?.progress ?? 0;
    const next = resolvedTotalEpisodes != null ? Math.min(current + 1, resolvedTotalEpisodes) : current + 1;
    const isReleasing = animeAiringStatus === 'RELEASING';
    const nextStatus: AniListMediaStatus =
      !isReleasing && resolvedTotalEpisodes != null && next >= resolvedTotalEpisodes
        ? 'COMPLETED'
        : 'CURRENT';

    try {
      setUpdatingList(true);
      const res = await updateAniListProgress({
        mediaId: anilistId,
        progress: next,
        status: nextStatus,
        accessToken,
      });
      const entry = res?.data?.SaveMediaListEntry;
      setTrackingEntry((prev) => ({
        id: entry?.id ?? prev?.id ?? 0,
        progress: entry?.progress ?? next,
        status: entry?.status ?? nextStatus,
        score: prev?.score ?? null,
        customLists: prev?.customLists ?? [],
      }));
    } catch (e) {
      if (__DEV__) console.warn('AniList +1 progress failed', e);
      Alert.alert('AniList', 'Could not increment watched progress.');
    } finally {
      setUpdatingList(false);
    }
  };

  const handleSaveScore = async () => {
    if (!accessToken || !anilistId) {
      login();
      return;
    }
    if (!canTrackAniList) {
      Alert.alert('AniList', 'This title is not linked to a valid AniList entry.');
      return;
    }
    const parsed = Number.parseFloat(scoreInput);
    if (!Number.isFinite(parsed) || parsed < 0 || parsed > 10) {
      Alert.alert('AniList Score', 'Enter a score between 0.0 and 10.0 (decimals allowed).');
      return;
    }
    try {
      setUpdatingList(true);
      const res = await setAniListScore({ mediaId: anilistId, score: parsed, accessToken });
      const entry = res?.data?.SaveMediaListEntry;
      setTrackingEntry((prev) => ({
        id: entry?.id ?? prev?.id ?? 0,
        progress: entry?.progress ?? prev?.progress ?? 0,
        status: entry?.status ?? prev?.status ?? 'CURRENT',
        score: entry?.score ?? parsed,
        customLists: entry?.customLists ?? prev?.customLists ?? [],
      }));
      setScoreInput(parsed.toFixed(1));
    } catch (e) {
      if (__DEV__) console.warn('AniList score update failed', e);
      Alert.alert('AniList', 'Could not update score.');
    } finally {
      setUpdatingList(false);
    }
  };

  const handleToggleCustomList = async (listName: string) => {
    if (!accessToken || !anilistId) {
      login();
      return;
    }
    if (!canTrackAniList) {
      Alert.alert('AniList', 'This title is not linked to a valid AniList entry.');
      return;
    }
    const current = new Set(trackingEntry?.customLists ?? []);
    if (current.has(listName)) current.delete(listName);
    else current.add(listName);
    const next = [...current];
    try {
      setUpdatingList(true);
      const res = await setAniListCustomLists({
        mediaId: anilistId,
        customLists: next,
        accessToken,
      });
      const entry = res?.data?.SaveMediaListEntry;
      setTrackingEntry((prev) => ({
        id: entry?.id ?? prev?.id ?? 0,
        progress: entry?.progress ?? prev?.progress ?? 0,
        status: entry?.status ?? prev?.status ?? 'CURRENT',
        score: entry?.score ?? prev?.score ?? null,
        customLists: entry?.customLists ?? next,
      }));
    } catch (e) {
      if (__DEV__) console.warn('AniList custom list update failed', e);
      Alert.alert('AniList', 'Could not update custom lists.');
    } finally {
      setUpdatingList(false);
    }
  };

  const handleSetStatus = async (status: AniListMediaStatus) => {
    if (!accessToken || !anilistId) {
      login();
      return;
    }
    if (!canTrackAniList) {
      Alert.alert('AniList', 'This title is not linked to a valid AniList entry.');
      return;
    }
    try {
      setUpdatingList(true);
      const res = await setAniListStatus({ mediaId: anilistId, status, accessToken });
      const entry = res?.data?.SaveMediaListEntry;
      if (entry) {
        setTrackingEntry((prev) => ({
          id: entry.id ?? prev?.id ?? 0,
          progress: entry.progress ?? prev?.progress ?? 0,
          status: entry.status ?? status,
        }));
      }
    } catch (e) {
      if (__DEV__) console.warn('AniList status update failed', e);
      Alert.alert('AniList', 'Could not update list status.');
    } finally {
      setUpdatingList(false);
    }
  };

  const handleRemoveFromList = async () => {
    if (!accessToken || !trackingEntry?.id) return;
    try {
      setUpdatingList(true);
      await deleteAniListEntry(trackingEntry.id, accessToken);
      setTrackingEntry(null);
    } catch (e) {
      if (__DEV__) console.warn('AniList delete failed', e);
      Alert.alert('AniList', 'Could not remove this anime from your list.');
    } finally {
      setUpdatingList(false);
    }
  };

  const cleanDescription = (raw?: string | null): string => {
    if (!raw) return '';
    return raw
      .replace(/<br\s*\/?>/gi, '\n')
      .replace(/<\/?[^>]+(>|$)/g, '')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'")
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .trim();
  };

  const formatDate = (d?: { year?: number | null; month?: number | null; day?: number | null } | null): string | null => {
    if (!d?.year) return null;
    const y = d.year;
    const m = d.month ? String(d.month).padStart(2, '0') : null;
    const day = d.day ? String(d.day).padStart(2, '0') : null;
    return [y, m, day].filter(Boolean).join('-');
  };

  const relationLabel = (type?: string | null): string => {
    const key = String(type ?? '').toUpperCase();
    if (key === 'SEQUEL') return 'Sequel';
    if (key === 'PREQUEL') return 'Prequel';
    if (key === 'SOURCE') return 'Source';
    return key || 'Related';
  };

  const handleShareAniList = async () => {
    if (!Number.isFinite(anilistId) || anilistId <= 0) {
      Alert.alert('Share', 'This anime does not have a valid AniList link.');
      return;
    }
    const url = `https://anilist.co/anime/${anilistId}`;
    const name = String(title ?? '').trim() || 'Anime';
    try {
      await Share.share({
        title: name,
        message: `${name}\n${url}`,
        url,
      });
    } catch (error: any) {
      Alert.alert('Share', String(error?.message ?? 'Unable to share this link.'));
    }
  };

  return (
    <View style={styles.container}>
      <StatusBar style="light" />
      <Stack.Screen
        options={{
          title,
          headerTransparent: true,
          headerTintColor: colors.text,
        }}
      />

      <ScrollView contentContainerStyle={styles.scrollContent}>
        <View style={[styles.heroSection, isTabletLayout ? styles.heroSectionTablet : null]}>
          {heroBannerUri ? (
            <ImageBackground
              source={{ uri: heroBannerUri }}
              style={[styles.heroBannerBackground, isTabletLayout ? styles.heroBannerBackgroundTablet : null]}
              imageStyle={styles.heroBannerImage}
            >
              <View style={styles.heroBannerOverlay} />
            </ImageBackground>
          ) : null}
          {coverImage && (
            <View style={styles.coverContainer}>
              <Image source={{ uri: coverImage }} style={styles.cover} />
              <View style={styles.coverGradient} />
            </View>
          )}
          <View style={styles.heroContent}>
            {averageScore !== undefined && (
              <View style={[styles.badge, pill]}>
                <Text style={styles.badgeLabel}>Score</Text>
                <Text style={styles.badgeValue}>{averageScore}</Text>
              </View>
            )}
            <View style={styles.heroActionsRow}>
              <TouchableOpacity
                style={[styles.loginButton, glassCardElevated, shadow]}
                onPress={login}
                activeOpacity={0.85}
              >
                <Text style={styles.loginButtonText}>
                  {accessToken ? 'AniList Connected' : 'Connect AniList'}
                </Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.shareButton, glassButton]}
                onPress={handleShareAniList}
                activeOpacity={0.85}
              >
                <Text style={styles.shareButtonText}>Share AniList</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>

        <View style={styles.tabsRow}>
          {([
            { key: 'watch', label: 'Watch' },
            { key: 'anilist', label: 'AniList' },
            { key: 'more', label: 'More' },
          ] as const).map((tab) => (
            <TouchableOpacity
              key={tab.key}
              style={[styles.tabButton, glassButton, activeTab === tab.key ? styles.tabButtonActive : null]}
              onPress={() => setActiveTab(tab.key)}
              activeOpacity={0.86}
            >
              <Text style={styles.tabButtonText}>{tab.label}</Text>
            </TouchableOpacity>
          ))}
        </View>

        <View style={[styles.section, activeTab !== 'anilist' ? styles.hiddenSection : null]}>
          <Text style={styles.sectionTitle}>About</Text>
          <View style={[styles.aboutCard, glassCardElevated, shadow]}>
            <View style={styles.metaRow}>
              {!!animeMetadata?.format && (
                <View style={styles.metaChip}>
                  <Text style={styles.metaChipText}>{animeMetadata.format}</Text>
                </View>
              )}
              {!!animeMetadata?.status && (
                <View style={styles.metaChip}>
                  <Text style={styles.metaChipText}>{animeMetadata.status}</Text>
                </View>
              )}
              {!!animeMetadata?.source && (
                <View style={styles.metaChip}>
                  <Text style={styles.metaChipText}>Source: {animeMetadata.source}</Text>
                </View>
              )}
              {!!animeMetadata?.season && (
                <View style={styles.metaChip}>
                  <Text style={styles.metaChipText}>
                    {animeMetadata.season} {animeMetadata.seasonYear ?? ''}
                  </Text>
                </View>
              )}
              {animeMetadata?.episodes != null && (
                <View style={styles.metaChip}>
                  <Text style={styles.metaChipText}>EP {animeMetadata.episodes}</Text>
                </View>
              )}
            </View>

            {!!cleanDescription(animeMetadata?.description) && (
              <Text style={styles.aboutDescription}>{cleanDescription(animeMetadata?.description)}</Text>
            )}

            <View style={styles.infoGrid}>
              {!!formatDate(animeMetadata?.startDate) && (
                <Text style={styles.infoLine}>Started: {formatDate(animeMetadata?.startDate)}</Text>
              )}
              {!!formatDate(animeMetadata?.endDate) && (
                <Text style={styles.infoLine}>Ended: {formatDate(animeMetadata?.endDate)}</Text>
              )}
              {animeMetadata?.meanScore != null && (
                <Text style={styles.infoLine}>Mean Score: {animeMetadata.meanScore}</Text>
              )}
              {animeMetadata?.popularity != null && (
                <Text style={styles.infoLine}>Popularity: {animeMetadata.popularity}</Text>
              )}
              {animeMetadata?.favourites != null && (
                <Text style={styles.infoLine}>Favourites: {animeMetadata.favourites}</Text>
              )}
              {!!animeMetadata?.studios?.length && (
                <Text style={styles.infoLine}>Studios: {animeMetadata.studios.join(', ')}</Text>
              )}
              {!!animeMetadata?.genres?.length && (
                <Text style={styles.infoLine}>Genres: {animeMetadata.genres.join(', ')}</Text>
              )}
            </View>

            {!!animeMetadata?.relations?.length && (
              <>
                <Text style={styles.relationsLabel}>Relations</Text>
                <View style={styles.relationsWrap}>
                  {animeMetadata.relations.slice(0, 12).map((edge, idx) => {
                    const node = edge?.node;
                    if (!node?.id) return null;
                    const relTitle = node.title?.english ?? node.title?.romaji ?? node.title?.native ?? 'Unknown';
                    return (
                      <TouchableOpacity
                        key={`${node.id}-${idx}`}
                        style={[styles.relationCard, glassButton]}
                        activeOpacity={0.85}
                        onPress={() =>
                          router.push({
                            pathname: '/details/[id]',
                            params: {
                              id: String(node.id),
                              title: relTitle,
                              coverImage: node.coverImage?.large ?? '',
                              averageScore: node.averageScore ?? 'N/A',
                            },
                          })
                        }
                      >
                        <Text style={styles.relationType}>{relationLabel(edge.relationType)}</Text>
                        <Text style={styles.relationTitle} numberOfLines={2}>
                          {relTitle}
                        </Text>
                      </TouchableOpacity>
                    );
                  })}
                </View>
              </>
            )}
          </View>
        </View>

        <View style={[styles.section, activeTab !== 'watch' ? styles.hiddenSection : null]}>
          <Text style={styles.sectionTitle}>Match</Text>
          <View style={[styles.mappingCard, glassCardElevated, shadow]}>
            <View style={styles.mappingHeader}>
              <Text style={styles.mappingLabel}>AnimePahe</Text>
              <Text style={styles.mappingState}>{manualSessionId ? 'Manual' : 'Auto'}</Text>
            </View>
            <Text style={styles.mappingSelected} numberOfLines={1}>
              {manualSessionTitle ?? 'Using automatic matching'}
            </Text>
            <View style={styles.scoreRow}>
              <TextInput
                value={mappingQuery}
                onChangeText={setMappingQuery}
                placeholder="Find on AnimePahe"
                placeholderTextColor={colors.textDim}
                style={[styles.scoreInput, glassInput]}
              />
              <TouchableOpacity
                style={[styles.scoreSaveButton, glassButton]}
                onPress={handleSearchManualMapping}
                disabled={mappingLoading}
                activeOpacity={0.8}
              >
                <Text style={styles.scoreSaveText}>{mappingLoading ? '...' : 'Find'}</Text>
              </TouchableOpacity>
            </View>
            {mappingResults.length > 0 && (
              <View style={styles.mappingResults}>
                {mappingResults.slice(0, 5).map((item) => (
                  <TouchableOpacity
                    key={`${item.id}-${item.title}`}
                    style={styles.mappingResultRow}
                    onPress={() => handleSelectManualMapping(item)}
                    activeOpacity={0.8}
                  >
                    <Text style={styles.mappingResultTitle} numberOfLines={1}>
                      {item.title}
                    </Text>
                  </TouchableOpacity>
                ))}
              </View>
            )}
            {!!manualSessionId && (
              <TouchableOpacity
                style={styles.removeButton}
                onPress={handleClearManualMapping}
                activeOpacity={0.8}
              >
                <Text style={styles.removeButtonText}>Clear Manual Match</Text>
              </TouchableOpacity>
            )}
          </View>
        </View>

        <View style={[styles.section, activeTab !== 'anilist' ? styles.hiddenSection : null]}>
          <Text style={styles.sectionTitle}>Tracking</Text>
          <View style={[styles.trackingCard, glassCardElevated, shadow]}>
            {trackingBackgroundUri ? (
              <ImageBackground
                source={{ uri: trackingBackgroundUri }}
                style={styles.trackingBannerImage}
                imageStyle={styles.trackingBannerImageStyle}
              />
            ) : null}
            <View style={styles.trackingBannerOverlay} />
            <View style={styles.trackingContent}>
              <View style={styles.trackingSummaryRow}>
                <View style={styles.trackingChip}>
                  <Text style={styles.trackingChipText}>{trackingEntry?.status ?? 'NOT_ADDED'}</Text>
                </View>
                <View style={styles.trackingChip}>
                  <Text style={styles.trackingChipText}>
                    EP {trackingEntry?.progress ?? 0}{animeTotalEpisodes ? `/${animeTotalEpisodes}` : ''}
                  </Text>
                </View>
                <View style={styles.trackingChip}>
                  <Text style={styles.trackingChipText}>
                    Score {typeof trackingEntry?.score === 'number' ? trackingEntry.score.toFixed(1) : '-'}
                  </Text>
                </View>
              </View>
              {!canTrackAniList && (
                <Text style={styles.trackingWarning}>
                  Not linked to a valid AniList media id.
                </Text>
              )}
              <View style={styles.actionsRow}>
                <TouchableOpacity
                  style={[styles.quickProgressButton, glassButton]}
                  onPress={handleAddOneWatched}
                  disabled={updatingList || !canTrackAniList}
                  activeOpacity={0.8}
                >
                  <Text style={styles.quickProgressButtonText}>+1</Text>
                </TouchableOpacity>
                <TextInput
                  value={scoreInput}
                  onChangeText={setScoreInput}
                  placeholder="Score"
                  placeholderTextColor={colors.textDim}
                  keyboardType="decimal-pad"
                  style={[styles.scoreInput, glassInput]}
                />
                <TouchableOpacity
                  style={[styles.scoreSaveButton, glassButton]}
                  onPress={handleSaveScore}
                  disabled={updatingList || !canTrackAniList}
                  activeOpacity={0.8}
                >
                  <Text style={styles.scoreSaveText}>Save</Text>
                </TouchableOpacity>
              </View>
              <View style={styles.statusRow}>
                {(['CURRENT', 'PLANNING', 'COMPLETED', 'PAUSED', 'DROPPED'] as AniListMediaStatus[]).map((s) => (
                  <TouchableOpacity
                    key={s}
                    style={[
                      styles.statusButton,
                      glassButton,
                      trackingEntry?.status === s ? styles.statusButtonActive : null,
                    ]}
                    onPress={() => handleSetStatus(s)}
                    disabled={updatingList || !canTrackAniList}
                    activeOpacity={0.8}
                  >
                    <Text style={styles.statusButtonText}>{s}</Text>
                  </TouchableOpacity>
                ))}
              </View>
              {availableCustomLists.length > 0 && (
                <>
                  <Text style={styles.customListsLabel}>Lists</Text>
                  <View style={styles.statusRow}>
                    {availableCustomLists.map((name) => {
                      const active = (trackingEntry?.customLists ?? []).includes(name);
                      return (
                        <TouchableOpacity
                          key={name}
                          style={[styles.statusButton, glassButton, active ? styles.statusButtonActive : null]}
                          onPress={() => handleToggleCustomList(name)}
                          disabled={updatingList || !canTrackAniList}
                          activeOpacity={0.8}
                        >
                          <Text style={styles.statusButtonText}>{name}</Text>
                        </TouchableOpacity>
                      );
                    })}
                  </View>
                </>
              )}
              {!!trackingEntry?.id && (
                <TouchableOpacity
                  style={styles.removeButton}
                  onPress={handleRemoveFromList}
                  disabled={updatingList || !canTrackAniList}
                >
                  <Text style={styles.removeButtonText}>Remove</Text>
                </TouchableOpacity>
              )}
            </View>
          </View>
        </View>

        <View style={[styles.section, activeTab !== 'watch' ? styles.hiddenSection : null]}>
          <View style={styles.sectionHeaderRow}>
            <Text style={styles.sectionTitle}>Episodes</Text>
            {!downloadsOnly && episodes.length > 0 && (
              <TouchableOpacity
                style={[styles.sectionActionButton, glassButton]}
                onPress={() => {
                  void handleDownloadAllEpisodes();
                }}
                disabled={batchQueueing || loadingSources}
                activeOpacity={0.85}
              >
                <Text style={styles.sectionActionButtonText}>
                  {batchQueueing ? 'Queueing...' : 'Download All'}
                </Text>
              </TouchableOpacity>
            )}
          </View>
          {loading && (
            <View style={styles.center}>
              <ActivityIndicator color={colors.accent} />
            </View>
          )}
          {episodes.length === 0 && !loading && (
            <Text style={styles.mutedText}>No episodes available for this title.</Text>
          )}

          {episodes.map((ep) => {
            const progressPercent = Math.max(
              0,
              Math.min(100, Math.floor(episodeProgressMap?.[ep.number]?.percent ?? 0))
            );
            const progressSize = 42;
            const progressStroke = 4;
            const progressRadius = (progressSize - progressStroke) / 2;
            const progressCircumference = 2 * Math.PI * progressRadius;
            const progressOffset =
              progressCircumference * (1 - progressPercent / 100);
            const thumbUri = String(episodeMetaMap?.[ep.number]?.thumbnail || coverImage || '').trim();
            const item = findEpisodeDownloadItem(ep);
            const isQueued = item?.status === 'queued';
            const isDownloading = item?.status === 'downloading';
            const isFailed = item?.status === 'failed';
            const iconName = isQueued
              ? 'schedule'
              : isDownloading
              ? 'sync'
              : isFailed
              ? 'refresh'
              : 'file-download';

            return (
              <View key={ep.id} style={[styles.episodeRow, glassCardElevated, shadow]}>
                {thumbUri ? (
                  <Image source={{ uri: thumbUri }} style={styles.episodeThumb} resizeMode="cover" />
                ) : (
                  <View style={styles.episodeThumbPlaceholder} />
                )}
                <View style={styles.episodeInfo}>
                  <Text style={styles.episodeNumber}>EP {ep.number}</Text>
                  {(downloadedEpisodeIds.has(ep.id) || downloadedEpisodeNumbers.has(ep.number)) && (
                    <View style={styles.downloadedBadge}>
                      <Text style={styles.downloadedBadgeText}>Downloaded</Text>
                    </View>
                  )}
                  <Text style={styles.episodeTitle} numberOfLines={3}>
                    {(ep.title && ep.title.trim()) ? ep.title : `${title} - Episode ${ep.number}`}
                  </Text>
                </View>
                <View style={styles.episodeActions}>
                  <View style={styles.episodeProgressCircle}>
                    <Svg width={progressSize} height={progressSize} style={styles.episodeProgressSvg}>
                      <Circle
                        cx={progressSize / 2}
                        cy={progressSize / 2}
                        r={progressRadius}
                        stroke="rgba(255,255,255,0.26)"
                        strokeWidth={progressStroke}
                        fill="transparent"
                      />
                      <Circle
                        cx={progressSize / 2}
                        cy={progressSize / 2}
                        r={progressRadius}
                        stroke="#ffffff"
                        strokeWidth={progressStroke}
                        fill="transparent"
                        strokeLinecap="round"
                        strokeDasharray={`${progressCircumference} ${progressCircumference}`}
                        strokeDashoffset={progressOffset}
                        transform={`rotate(-90 ${progressSize / 2} ${progressSize / 2})`}
                      />
                    </Svg>
                    <Text style={styles.episodeProgressText}>{progressPercent}%</Text>
                  </View>
                  <View style={styles.episodeIconActions}>
                    <TouchableOpacity
                      style={[styles.iconButton, styles.playButton, glassButton]}
                      onPress={() => handlePlayEpisode(ep)}
                      activeOpacity={0.8}
                    >
                      <MaterialIcons name="play-arrow" size={20} color="#fff" />
                    </TouchableOpacity>
                    {item?.status === 'completed' ? (
                      <TouchableOpacity
                        style={[styles.iconButton, styles.deleteButton, glassButton]}
                        onPress={() => handleDeleteDownloadedEpisode(ep)}
                        activeOpacity={0.8}
                      >
                        <MaterialIcons name="delete-outline" size={20} color="#ff9f9f" />
                      </TouchableOpacity>
                    ) : (
                      <TouchableOpacity
                        style={[styles.iconButton, styles.downloadButton, glassButton]}
                        onPress={() => handleDownloadEpisode(ep)}
                        disabled={isQueued || isDownloading}
                        activeOpacity={0.8}
                      >
                        <MaterialIcons name={iconName as any} size={20} color={colors.text} />
                      </TouchableOpacity>
                    )}
                  </View>
                </View>
              </View>
            );
          })}
        </View>

        <View style={[styles.section, activeTab !== 'more' ? styles.hiddenSection : null]}>
          <Text style={styles.sectionTitle}>Relations</Text>
          <View style={[styles.aboutCard, glassCardElevated, shadow]}>
            {!!animeMetadata?.relations?.length ? (
              <View style={styles.relationsWrap}>
                {animeMetadata.relations.slice(0, 18).map((edge, idx) => {
                  const node = edge?.node;
                  if (!node?.id) return null;
                  const relTitle = node.title?.english ?? node.title?.romaji ?? node.title?.native ?? 'Unknown';
                  return (
                    <TouchableOpacity
                      key={`${node.id}-${idx}`}
                      style={[styles.relationCard, glassButton]}
                      activeOpacity={0.85}
                      onPress={() =>
                        router.push({
                          pathname: '/details/[id]',
                          params: {
                            id: String(node.id),
                            title: relTitle,
                            coverImage: node.coverImage?.large ?? '',
                            averageScore: node.averageScore ?? 'N/A',
                          },
                        })
                      }
                    >
                      <Text style={styles.relationType}>{relationLabel(edge.relationType)}</Text>
                      <Text style={styles.relationTitle} numberOfLines={2}>
                        {relTitle}
                      </Text>
                    </TouchableOpacity>
                  );
                })}
              </View>
            ) : (
              <Text style={styles.mutedText}>No related entries found for this title.</Text>
            )}
          </View>
        </View>
      </ScrollView>

      {selectedSource && currentEpisode && (
        <VideoPlayer
          visible={!!selectedSource}
          onClose={closePlayerModal}
          sourceUrl={selectedSource.url}
          sourceHeaders={selectedSource.headers}
          sourceFormat={selectedSource.format}
          introStartSec={episodeIntroMap[currentEpisode.number]?.startSec}
          introEndSec={episodeIntroMap[currentEpisode.number]?.endSec}
          title={`${title} - Episode ${currentEpisode.number} ${playbackOrigin === 'offline' ? '(Offline)' : '(Stream)'}`}
          resumePositionSec={resumeSeekSec}
          onProgressSave={(positionSec, durationSec) => {
            if (!currentEpisode) return;
            playbackPositionSecRef.current = Math.max(0, Math.floor(Number(positionSec || 0)));
            if (playbackPositionSecRef.current > 0) {
              setResumeSeekSec(playbackPositionSecRef.current);
            }
            const duration = Math.max(0, Math.floor(Number(durationSec || 0)));
            const position = Math.max(0, Math.floor(Number(positionSec || 0)));
            const percent =
              duration > 0 ? Math.min(100, Math.max(0, Math.floor((position / duration) * 100))) : 0;
            setEpisodeProgressMap((prev) => ({
              ...prev,
              [currentEpisode.number]: { positionSec: position, durationSec: duration, percent },
            }));
            if (duration > 0) {
              requestEpisodeIntroRange(currentEpisode.number, duration);
            }
            void saveEpisodeProgressSec(currentEpisode, positionSec, durationSec);
          }}
          onWatchedNearlyAll={handleWatchedNearlyAll}
          onPlaybackEnded={handlePlaybackEnded}
          onPlaybackError={handlePlaybackError}
          watchedThreshold={0.85}
          loadingOverlay={updatingProgress}
        />
      )}
      <StreamPicker
        visible={pickerVisible}
        onClose={() => {
          setPickerVisible(false);
          if (pickerMode === 'download') setPendingDownloadEpisode(null);
          if (pickerMode === 'download-batch') setPendingBatchEpisodes([]);
          setPickerMode('play');
        }}
        sources={sources}
        onSelect={handleSelectSource}
        loading={loadingSources}
        title={loadingSources ? 'Loading sources...' : `Streams - Episode ${currentEpisode?.number ?? ''}`}
      />

    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  scrollContent: {
    paddingTop: 100,
    paddingHorizontal: 20,
    paddingBottom: 40,
  },
  tabsRow: {
    flexDirection: 'row',
    gap: 8,
    marginBottom: 12,
  },
  tabButton: {
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  tabButtonActive: {
    borderColor: colors.accent,
    backgroundColor: 'rgba(126,203,255,0.20)',
  },
  tabButtonText: {
    color: colors.text,
    fontSize: 12,
    fontWeight: '700',
  },
  hiddenSection: {
    display: 'none',
  },
  heroSection: {
    position: 'relative',
    overflow: 'hidden',
    borderRadius: 26,
    paddingTop: 24,
    paddingBottom: 18,
    paddingHorizontal: 14,
    marginBottom: 32,
  },
  heroSectionTablet: {
    paddingTop: 36,
    paddingBottom: 24,
    paddingHorizontal: 24,
  },
  heroBannerBackground: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    height: 240,
  },
  heroBannerBackgroundTablet: {
    height: 320,
  },
  heroBannerImage: {
    resizeMode: 'cover',
  },
  heroBannerOverlay: {
    ...StyleSheet.absoluteFillObject,
    backgroundColor: 'rgba(4, 6, 14, 0.72)',
  },
  coverContainer: {
    position: 'relative',
    alignSelf: 'center',
    marginBottom: 20,
    zIndex: 2,
  },
  cover: {
    width: 140,
    height: 200,
    borderRadius: 24,
  },
  coverGradient: {
    position: 'absolute',
    bottom: 0,
    left: 0,
    right: 0,
    height: '30%',
    borderRadius: 24,
    backgroundColor: 'transparent',
  },
  heroContent: {
    alignItems: 'center',
    zIndex: 2,
  },
  heroActionsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  title: {
    color: colors.text,
    fontSize: 26,
    fontWeight: '900',
    textAlign: 'center',
    marginBottom: 16,
    letterSpacing: -0.5,
    lineHeight: 32,
  },
  badge: {
    alignSelf: 'center',
    paddingHorizontal: 14,
    paddingVertical: 8,
    marginBottom: 20,
  },
  badgeLabel: {
    color: colors.textMuted,
    fontSize: 11,
    textTransform: 'uppercase',
    letterSpacing: 1,
    fontWeight: '700',
    marginBottom: 2,
  },
  badgeValue: {
    color: colors.accent,
    fontWeight: '800',
    fontSize: 18,
  },
  loginButton: {
    paddingVertical: 12,
    paddingHorizontal: 24,
    borderRadius: 20,
    alignSelf: 'center',
  },
  loginButtonText: {
    color: colors.text,
    fontWeight: '700',
    fontSize: 14,
  },
  shareButton: {
    paddingVertical: 12,
    paddingHorizontal: 14,
    borderRadius: 20,
  },
  shareButtonText: {
    color: colors.text,
    fontWeight: '700',
    fontSize: 12,
  },
  section: {
    marginTop: 12,
  },
  aboutCard: {
    borderRadius: 16,
    padding: 12,
    marginBottom: 8,
  },
  metaRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
    marginBottom: 10,
  },
  metaChip: {
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  metaChipText: {
    color: colors.text,
    fontSize: 11,
    fontWeight: '700',
  },
  aboutDescription: {
    color: colors.textSecondary,
    fontSize: 13,
    lineHeight: 20,
    marginBottom: 10,
  },
  infoGrid: {
    gap: 6,
  },
  infoLine: {
    color: colors.textMuted,
    fontSize: 12,
    lineHeight: 17,
  },
  relationsLabel: {
    marginTop: 12,
    marginBottom: 8,
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
  },
  relationsWrap: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  relationCard: {
    width: '48%',
    borderRadius: 12,
    padding: 10,
  },
  relationType: {
    color: colors.accent,
    fontSize: 10,
    fontWeight: '800',
    textTransform: 'uppercase',
    marginBottom: 4,
    letterSpacing: 0.5,
  },
  relationTitle: {
    color: colors.text,
    fontSize: 12,
    lineHeight: 16,
    fontWeight: '700',
  },
  trackingCard: {
    borderRadius: 16,
    padding: 0,
    marginBottom: 8,
    overflow: 'hidden',
    position: 'relative',
  },
  trackingBannerImage: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    width: '100%',
    height: '100%',
  },
  trackingBannerImageStyle: {
    opacity: 0.95,
  },
  trackingBannerOverlay: {
    position: 'absolute',
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    backgroundColor: 'rgba(12, 16, 24, 0.78)',
  },
  trackingContent: {
    padding: 12,
    gap: 10,
  },
  trackingSummaryRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  trackingChip: {
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 999,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  trackingChipText: {
    color: colors.text,
    fontSize: 11,
    fontWeight: '700',
  },
  mappingCard: {
    borderRadius: 14,
    padding: 12,
    marginBottom: 8,
  },
  mappingHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
    marginBottom: 6,
  },
  mappingLabel: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
  },
  mappingState: {
    color: colors.accent,
    fontSize: 12,
    fontWeight: '700',
  },
  mappingSelected: {
    color: colors.textMuted,
    fontSize: 12,
    marginBottom: 10,
  },
  trackingText: {
    color: colors.text,
    fontSize: 13,
    marginBottom: 10,
  },
  trackingWarning: {
    color: '#ff9f7a',
    fontSize: 12,
    marginBottom: 10,
    lineHeight: 17,
  },
  statusRow: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 8,
  },
  statusButton: {
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 12,
    paddingHorizontal: 10,
    paddingVertical: 8,
  },
  statusButtonActive: {
    backgroundColor: colors.accent,
    borderColor: colors.accent,
  },
  statusButtonText: {
    color: '#fff',
    fontWeight: '700',
    fontSize: 11,
  },
  quickProgressButton: {
    backgroundColor: colors.surfaceSoft,
    borderRadius: 10,
    paddingHorizontal: 14,
    paddingVertical: 9,
  },
  quickProgressButtonText: {
    color: '#fff',
    fontWeight: '700',
    fontSize: 12,
  },
  actionsRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  scoreRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    marginBottom: 10,
  },
  scoreInput: {
    flex: 1,
    color: colors.text,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 7,
    fontSize: 12,
    backgroundColor: 'transparent',
  },
  scoreSaveButton: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  scoreSaveText: {
    color: colors.text,
    fontSize: 12,
    fontWeight: '700',
  },
  customListsLabel: {
    marginTop: 10,
    marginBottom: 6,
    color: colors.textMuted,
    fontSize: 12,
    fontWeight: '600',
  },
  removeButton: {
    marginTop: 12,
    alignSelf: 'flex-start',
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderRadius: 10,
    backgroundColor: 'rgba(255, 70, 70, 0.15)',
    borderWidth: 1,
    borderColor: 'rgba(255, 70, 70, 0.45)',
  },
  removeButtonText: {
    color: '#ff8a8a',
    fontWeight: '700',
    fontSize: 12,
  },
  mappingResults: {
    marginTop: 4,
    gap: 8,
  },
  mappingResultRow: {
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 7,
    backgroundColor: colors.surfaceSoft,
  },
  mappingResultTitle: {
    color: colors.text,
    fontSize: 12,
    fontWeight: '600',
  },
  sectionTitle: {
    color: colors.text,
    fontSize: 22,
    fontWeight: '800',
    marginBottom: 16,
    letterSpacing: -0.3,
  },
  sectionHeaderRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    gap: 10,
  },
  sectionActionButton: {
    paddingHorizontal: 12,
    paddingVertical: 8,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: colors.borderSoft,
    backgroundColor: colors.surfaceSoft,
    marginBottom: 12,
  },
  sectionActionButtonText: {
    color: colors.text,
    fontSize: 12,
    fontWeight: '700',
  },
  center: {
    alignItems: 'center',
    justifyContent: 'center',
    paddingVertical: 24,
  },
  mutedText: {
    color: colors.textMuted,
    fontSize: 15,
  },
  episodeRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingHorizontal: 10,
    paddingVertical: 10,
    borderRadius: 20,
    marginBottom: 12,
  },
  episodeThumb: {
    width: 92,
    height: 56,
    borderRadius: 10,
    marginRight: 8,
    backgroundColor: colors.surfaceSoft,
  },
  episodeThumbPlaceholder: {
    width: 92,
    height: 56,
    borderRadius: 10,
    marginRight: 8,
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
  },
  episodeInfo: {
    flex: 1,
    paddingRight: 12,
  },
  episodeNumber: {
    color: colors.accent,
    fontWeight: '800',
    fontSize: 12,
    marginBottom: 4,
    letterSpacing: 0.5,
  },
  episodeTitle: {
    color: colors.text,
    fontWeight: '600',
    fontSize: 16,
    lineHeight: 20,
  },
  downloadedBadge: {
    alignSelf: 'flex-start',
    marginBottom: 6,
    paddingHorizontal: 8,
    paddingVertical: 3,
    borderRadius: 999,
    backgroundColor: 'rgba(60, 190, 115, 0.2)',
    borderWidth: 1,
    borderColor: 'rgba(60, 190, 115, 0.55)',
  },
  downloadedBadgeText: {
    color: '#97f0b8',
    fontSize: 10,
    fontWeight: '800',
    letterSpacing: 0.4,
    textTransform: 'uppercase',
  },
  episodeActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  episodeProgressCircle: {
    width: 42,
    height: 42,
    borderRadius: 21,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255,255,255,0.03)',
  },
  episodeProgressSvg: {
    position: 'absolute',
    top: 0,
    left: 0,
  },
  episodeProgressText: {
    color: colors.text,
    fontSize: 10,
    fontWeight: '800',
  },
  episodeIconActions: {
    flexDirection: 'column',
    alignItems: 'center',
    gap: 6,
  },
  iconButton: {
    width: 38,
    height: 38,
    borderRadius: 19,
    alignItems: 'center',
    justifyContent: 'center',
  },
  smallButton: {
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderRadius: 16,
  },
  playButton: {
    backgroundColor: colors.surfaceSoft,
  },
  downloadButton: {
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
  },
  smallButtonText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '700',
  },
  downloadButtonText: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
  },
  deleteButton: {
    backgroundColor: 'rgba(255, 70, 70, 0.18)',
    borderWidth: 1,
    borderColor: 'rgba(255, 90, 90, 0.45)',
  },
  deleteButtonText: {
    color: '#ff9f9f',
    fontSize: 13,
    fontWeight: '700',
  },
});
















