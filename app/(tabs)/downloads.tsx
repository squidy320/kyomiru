import { useRouter } from 'expo-router';
import React, { useEffect, useMemo, useState } from 'react';
import { Image, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import GlassSurface from '@/components/ui/glass-surface';

import { cancelDownload, clearFinishedDownloads, DownloadItem, subscribeDownloads } from '@/lib/soraDownloader';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';

export default function DownloadsScreen() {
  const router = useRouter();
  const [items, setItems] = useState<DownloadItem[]>([]);
  const [mode, setMode] = useState<'queue' | 'library'>('queue');

  useEffect(() => {
    return subscribeDownloads(setItems);
  }, []);

  const activeCount = useMemo(
    () => items.filter((item) => item.status === 'queued' || item.status === 'downloading').length,
    [items]
  );

  const libraryGroups = useMemo(() => {
    const completed = items.filter((item) => item.status === 'completed' && !!item.fileUri);
    const map = new Map<
      string,
      { key: string; title: string; cover?: string; anilistId?: number | null; episodes: DownloadItem[]; createdAt: number }
    >();

    for (const item of completed) {
      const title = String(item.animeTitle ?? 'Unknown');
      const anilist = Number(item.anilistId ?? 0);
      const key = Number.isFinite(anilist) && anilist > 0 ? `id:${anilist}` : `title:${title.trim().toLowerCase()}`;
      const existing = map.get(key);
      if (existing) {
        existing.episodes.push(item);
        if (!existing.cover && item.thumbnailUri) existing.cover = item.thumbnailUri;
        if (!existing.anilistId && anilist > 0) existing.anilistId = anilist;
        if (item.createdAt > existing.createdAt) existing.createdAt = item.createdAt;
      } else {
        map.set(key, {
          key,
          title,
          cover: item.thumbnailUri,
          anilistId: anilist > 0 ? anilist : null,
          episodes: [item],
          createdAt: item.createdAt,
        });
      }
    }

    return [...map.values()]
      .map((g) => ({ ...g, episodes: g.episodes.sort((a, b) => a.episodeNumber - b.episodeNumber) }))
      .sort((a, b) => b.createdAt - a.createdAt);
  }, [items]);

  const formatSpeed = (bytesPerSecond?: number) => {
    const speed = Number(bytesPerSecond ?? 0);
    if (!Number.isFinite(speed) || speed <= 0) return null;
    const kb = speed / 1024;
    if (kb < 1024) return `${kb.toFixed(0)} KB/s`;
    return `${(kb / 1024).toFixed(2)} MB/s`;
  };

  const formatSize = (bytes?: number) => {
    const value = Number(bytes ?? 0);
    if (!Number.isFinite(value) || value <= 0) return null;
    const kb = value / 1024;
    if (kb < 1024) return `${kb.toFixed(0)} KB`;
    const mb = kb / 1024;
    if (mb < 1024) return `${mb.toFixed(2)} MB`;
    return `${(mb / 1024).toFixed(2)} GB`;
  };

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Downloads</Text>
      <Text style={styles.subtitle}>{activeCount} active</Text>

      <GlassSurface style={[styles.modeSwitch, glassCardElevated]}>
        <TouchableOpacity
          style={[styles.modeButton, mode === 'queue' && styles.modeButtonActive]}
          onPress={() => setMode('queue')}
          activeOpacity={0.85}
        >
          <Text style={[styles.modeButtonText, mode === 'queue' && styles.modeButtonTextActive]}>Queue</Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.modeButton, mode === 'library' && styles.modeButtonActive]}
          onPress={() => setMode('library')}
          activeOpacity={0.85}
        >
          <Text style={[styles.modeButtonText, mode === 'library' && styles.modeButtonTextActive]}>Library</Text>
        </TouchableOpacity>
      </GlassSurface>

      {mode === 'queue' && (
        <>
          <TouchableOpacity
            style={[styles.clearButton, glassButton]}
            onPress={clearFinishedDownloads}
            activeOpacity={0.85}
          >
            <Text style={styles.clearText}>Clear Finished</Text>
          </TouchableOpacity>

          {items.length === 0 ? (
            <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
              <Text style={styles.empty}>No downloads yet.</Text>
            </GlassSurface>
          ) : (
            items.map((item) => {
              const pct = Math.round((item.progress ?? 0) * 100);
              const statusText =
                item.status === 'downloading'
                  ? `Downloading ${pct}%`
                  : item.status === 'queued'
                    ? 'Queued'
                    : item.status === 'completed'
                      ? 'Completed'
                      : item.status === 'failed'
                        ? `Failed${item.error ? `: ${item.error}` : ''}`
                        : item.status === 'cancelled'
                          ? 'Cancelled'
                          : item.status;
              return (
                <GlassSurface key={item.id} style={[styles.card, glassCardElevated, shadow]}>
                  <Text style={styles.itemTitle} numberOfLines={1}>
                    {item.animeTitle} - EP {item.episodeNumber}
                  </Text>
                  <Text style={styles.itemStatus}>{statusText}</Text>
                  {!!formatSize(item.totalSize) && (
                    <Text style={styles.itemMeta}>Size: {formatSize(item.totalSize)}</Text>
                  )}
                  {item.status === 'downloading' && !!formatSpeed(item.speedBytesPerSec) && (
                    <Text style={styles.itemSpeed}>Speed: {formatSpeed(item.speedBytesPerSec)}</Text>
                  )}
                  {!!item.fileUri && item.status === 'completed' && (
                    <Text style={styles.itemPath} numberOfLines={1}>{item.fileUri}</Text>
                  )}
                  {(item.status === 'queued' || item.status === 'downloading') && (
                    <TouchableOpacity
                      style={styles.cancelButton}
                      activeOpacity={0.85}
                      onPress={() => cancelDownload(item.id)}
                    >
                      <Text style={styles.cancelButtonText}>Cancel</Text>
                    </TouchableOpacity>
                  )}
                </GlassSurface>
              );
            })
          )}
        </>
      )}

      {mode === 'library' && (
        <>
          {libraryGroups.length === 0 ? (
            <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
              <Text style={styles.empty}>No completed downloads yet.</Text>
            </GlassSurface>
          ) : (
            libraryGroups.map((group) => (
              <TouchableOpacity
                key={group.key}
                style={[styles.libraryCard, glassCardElevated, shadow]}
                activeOpacity={0.85}
                onPress={() =>
                  router.push({
                    pathname: '/details/[id]',
                    params: {
                      id: String(group.anilistId && group.anilistId > 0 ? group.anilistId : 0),
                      title: group.title,
                      coverImage: group.cover ?? '',
                      downloadsOnly: '1',
                    },
                  })
                }
              >
                {group.cover ? <Image source={{ uri: group.cover }} style={styles.cover} /> : <View style={styles.coverPlaceholder} />}
                <View style={styles.libraryInfo}>
                  <Text style={styles.itemTitle} numberOfLines={2}>{group.title}</Text>
                  <Text style={styles.itemStatus}>
                    {group.episodes.length} downloaded episode{group.episodes.length === 1 ? '' : 's'}
                  </Text>
                  <Text style={styles.itemMeta} numberOfLines={1}>
                    Total size: {formatSize(group.episodes.reduce((sum, ep) => sum + Number(ep.totalSize ?? 0), 0)) ?? 'Unknown'}
                  </Text>
                  <Text style={styles.itemPath} numberOfLines={1}>
                    EP {group.episodes[0]?.episodeNumber} - EP {group.episodes[group.episodes.length - 1]?.episodeNumber}
                  </Text>
                </View>
              </TouchableOpacity>
            ))
          )}
        </>
      )}
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  content: {
    paddingHorizontal: 20,
    paddingTop: 70,
    paddingBottom: 120,
    gap: 12,
  },
  title: {
    color: colors.text,
    fontSize: 34,
    fontWeight: '900',
    letterSpacing: -0.8,
  },
  subtitle: {
    color: colors.textMuted,
    fontSize: 13,
    fontWeight: '600',
  },
  modeSwitch: {
    flexDirection: 'row',
    borderRadius: 14,
    padding: 4,
    borderWidth: 1,
    borderColor: colors.borderSoft,
  },
  modeButton: {
    flex: 1,
    borderRadius: 10,
    paddingVertical: 8,
    alignItems: 'center',
  },
  modeButtonActive: {
    backgroundColor: colors.surfaceSoft,
  },
  modeButtonText: {
    color: colors.textMuted,
    fontWeight: '700',
    fontSize: 12,
  },
  modeButtonTextActive: {
    color: colors.text,
  },
  clearButton: {
    alignSelf: 'flex-start',
    paddingHorizontal: 12,
    paddingVertical: 8,
  },
  clearText: {
    color: colors.text,
    fontWeight: '700',
    fontSize: 12,
  },
  card: {
    borderRadius: 16,
    padding: 14,
    gap: 6,
  },
  empty: {
    color: colors.textMuted,
    fontSize: 14,
  },
  itemTitle: {
    color: colors.text,
    fontWeight: '700',
    fontSize: 14,
  },
  itemStatus: {
    color: colors.textMuted,
    fontSize: 12,
    fontWeight: '600',
  },
  itemSpeed: {
    color: colors.accent,
    fontSize: 12,
    fontWeight: '700',
  },
  itemMeta: {
    color: colors.textDim,
    fontSize: 11,
    fontWeight: '600',
  },
  itemPath: {
    color: colors.textDim,
    fontSize: 11,
  },
  cancelButton: {
    alignSelf: 'flex-start',
    marginTop: 4,
    backgroundColor: '#3a1a1a',
    borderColor: '#7f1d1d',
    borderWidth: 1,
    borderRadius: 10,
    paddingHorizontal: 10,
    paddingVertical: 6,
  },
  cancelButtonText: {
    color: '#fca5a5',
    fontSize: 12,
    fontWeight: '700',
  },
  libraryCard: {
    borderRadius: 16,
    padding: 12,
    gap: 12,
    flexDirection: 'row',
    alignItems: 'center',
  },
  cover: {
    width: 68,
    height: 92,
    borderRadius: 10,
    backgroundColor: colors.surfaceSoft,
  },
  coverPlaceholder: {
    width: 68,
    height: 92,
    borderRadius: 10,
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
  },
  libraryInfo: {
    flex: 1,
    gap: 4,
  },
});




