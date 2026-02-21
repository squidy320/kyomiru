import { useFocusEffect } from '@react-navigation/native';
import { useRouter } from 'expo-router';
import React, { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  Image,
  ImageBackground,
  Modal,
  Pressable,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';

import {
  AniListAnime,
  AniListMediaListEntry,
  AniListLibraryData,
  fetchAniListLibraryData,
} from '@/lib/anilist';
import { useAniListAuth } from '@/lib/anilistAuth';
import { getAllAnimePaheManualMappings, normalizeAnimeTitleKey } from '@/lib/animePaheMapping';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';
import { useUIAppearance } from '@/lib/uiAppearance';

const CARD_GAP = 12;
const H_CARD = 238;
const ROW_CARD_WIDTH = 150;

type MergedAnime = AniListAnime & {
  soraId?: string | null;
};

export default function LibraryScreen() {
  const router = useRouter();
  const { accessToken, login, logout } = useAniListAuth();
  const { libraryListOrganization, librarySortType } = useUIAppearance();
  const [loading, setLoading] = useState(false);
  const [libraryData, setLibraryData] = useState<AniListLibraryData | null>(null);
  const [profileMenuVisible, setProfileMenuVisible] = useState(false);
  const [manualMappingByAniListId, setManualMappingByAniListId] = useState<Record<string, string>>({});
  const [manualMappingByTitle, setManualMappingByTitle] = useState<Record<string, string>>({});

  const loadManualMappings = useCallback(async () => {
    const store = await getAllAnimePaheManualMappings();
    const byId: Record<string, string> = {};
    const byTitle: Record<string, string> = {};
    for (const [k, v] of Object.entries(store.byAniListId ?? {})) {
      const sid = String(v?.sessionId ?? '').trim();
      if (sid) byId[k] = sid;
    }
    for (const [k, v] of Object.entries(store.byTitle ?? {})) {
      const sid = String(v?.sessionId ?? '').trim();
      if (sid) byTitle[k] = sid;
    }
    setManualMappingByAniListId(byId);
    setManualMappingByTitle(byTitle);
  }, []);

  const loadLibrary = useCallback(async () => {
    if (!accessToken) {
      setLibraryData(null);
      return;
    }
    setLoading(true);
    try {
      const data = await fetchAniListLibraryData(accessToken);
      setLibraryData(data);
    } catch (e) {
      console.error(e);
    } finally {
      setLoading(false);
    }
  }, [accessToken]);

  useEffect(() => {
    loadLibrary();
    loadManualMappings();
  }, [loadLibrary, loadManualMappings]);

  useFocusEffect(
    useCallback(() => {
      loadLibrary();
      loadManualMappings();
    }, [loadLibrary, loadManualMappings])
  );

  const getManualMappedSessionId = (item: MergedAnime): string | null => {
    const idKey = String(item.id ?? '');
    if (idKey && manualMappingByAniListId[idKey]) return manualMappingByAniListId[idKey];
    const titleCandidates = [item.title?.english, item.title?.romaji, item.title?.native]
      .map((s) => String(s ?? '').trim())
      .filter(Boolean);
    for (const t of titleCandidates) {
      const key = normalizeAnimeTitleKey(t);
      if (key && manualMappingByTitle[key]) return manualMappingByTitle[key];
    }
    return null;
  };

  const renderPosterCard = (item: MergedAnime, progressText?: string | null, unwatchedCount?: number) => {
    const displayTitle = item.title?.english ?? item.title?.romaji ?? item.title?.native ?? 'Unknown';
    const displayCover = item.coverImage?.large ?? 'https://via.placeholder.com/300x450?text=No+Cover';
    const displayScore = item.averageScore ?? null;
    const manualSoraId = getManualMappedSessionId(item);

    return (
      <TouchableOpacity
        key={String(item.id)}
        style={[styles.card, glassCardElevated, shadow]}
        activeOpacity={0.9}
        onPress={() =>
          router.push({
            pathname: '/details/[id]',
            params: {
              id: String(item.id),
              title: displayTitle,
              coverImage: displayCover,
              averageScore: displayScore ?? 'N/A',
              soraId: manualSoraId ?? item.soraId ?? null,
            },
          })
        }
      >
        <ImageBackground source={{ uri: displayCover }} style={styles.poster} imageStyle={styles.posterImage}>
          {Number(unwatchedCount ?? 0) > 0 && (
            <View style={styles.unwatchedBadge}>
              <Text style={styles.unwatchedBadgeText}>{unwatchedCount} new</Text>
            </View>
          )}
          <View style={styles.scoreBadge}>
            <Text style={styles.scoreText}>{displayScore ?? 'NR'}</Text>
          </View>
          <View style={styles.bottomOverlay}>
            <Text style={styles.cardTitle} numberOfLines={2}>
              {displayTitle}
            </Text>
            {!!progressText && (
              <Text style={styles.progressText} numberOfLines={1}>
                {progressText}
              </Text>
            )}
          </View>
        </ImageBackground>
      </TouchableOpacity>
    );
  };

  const getDisplayTitle = (item: MergedAnime | null): string => {
    return item?.title?.english ?? item?.title?.romaji ?? item?.title?.native ?? 'Unknown';
  };

  const sortEntries = useCallback(
    (entries: AniListMediaListEntry[]) => {
      const next = [...entries];
      next.sort((a, b) => {
        const mediaA = (a?.media ?? null) as MergedAnime | null;
        const mediaB = (b?.media ?? null) as MergedAnime | null;
        if (librarySortType === 'rating') {
          const scoreA = mediaA?.averageScore ?? -1;
          const scoreB = mediaB?.averageScore ?? -1;
          return scoreB - scoreA;
        }
        if (librarySortType === 'title') {
          const titleA = getDisplayTitle(mediaA);
          const titleB = getDisplayTitle(mediaB);
          return titleA.localeCompare(titleB);
        }
        const updatedA = Number(a?.updatedAt ?? 0);
        const updatedB = Number(b?.updatedAt ?? 0);
        if (updatedA !== updatedB) return updatedB - updatedA;
        return Number(b?.id ?? 0) - Number(a?.id ?? 0);
      });
      return next;
    },
    [librarySortType]
  );

  const getSectionRank = (name: string): number => {
    const key = String(name ?? '').trim().toUpperCase();
    const rank: Record<string, number> = {
      CURRENT: 0,
      WATCHING: 0,
      PLANNING: 1,
      COMPLETED: 2,
      PAUSED: 3,
      DROPPED: 4,
      REPEATING: 5,
    };
    return rank[key] ?? 99;
  };

  const displaySections = React.useMemo(() => {
    const base = (libraryData?.sections ?? []).map((s) => ({
      ...s,
      entries: sortEntries(s.entries ?? []),
    }));
    if (libraryListOrganization === 'alphabetical') {
      return [...base].sort((a, b) => a.name.localeCompare(b.name));
    }
    if (libraryListOrganization === 'status-flow') {
      return [...base].sort((a, b) => {
        const rankDiff = getSectionRank(a.name) - getSectionRank(b.name);
        if (rankDiff !== 0) return rankDiff;
        return a.name.localeCompare(b.name);
      });
    }
    return base;
  }, [libraryData?.sections, libraryListOrganization, sortEntries]);

  if (!accessToken) {
    return (
      <View style={styles.container}>
        <View style={styles.noAuthWrap}>
          <Text style={styles.pageTitle}>Library</Text>
          <Text style={styles.pageSub}>Sign in to sync your AniList library and tracking data.</Text>

          <View style={[styles.noAuthCard, glassCardElevated, shadow]}>
            <Text style={styles.noAuthTitle}>No account connected</Text>
            <Text style={styles.noAuthText}>
              Connect AniList to unlock personalized lists, progress sync, and account-based recommendations.
            </Text>

            <View style={styles.noAuthPoints}>
              <Text style={styles.noAuthPoint}>Sync Watching, Planning, and Completed lists</Text>
              <Text style={styles.noAuthPoint}>Track episodes and scores while you watch</Text>
              <Text style={styles.noAuthPoint}>Keep everything synced across devices</Text>
            </View>

            <View style={styles.noAuthActions}>
              <TouchableOpacity style={[styles.connectButton, glassButton]} onPress={login} activeOpacity={0.85}>
                <Text style={styles.connectButtonText}>Connect AniList</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.secondaryButton, glassButton]}
                onPress={() => router.push('/(tabs)/discovery')}
                activeOpacity={0.85}
              >
                <Text style={styles.secondaryButtonText}>Explore Discovery</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </View>
    );
  }

  const profileName = libraryData?.profile?.name ?? 'AniList User';
  const profileAvatar =
    libraryData?.profile?.avatar?.large ??
    libraryData?.profile?.avatar?.medium ??
    null;
  const profileInitial = profileName.trim().charAt(0).toUpperCase() || 'A';

  const handleRefresh = async () => {
    setProfileMenuVisible(false);
    await Promise.all([loadLibrary(), loadManualMappings()]);
  };

  const handleLogout = () => {
    setProfileMenuVisible(false);
    logout();
  };

  const handleSwitchAccount = async () => {
    setProfileMenuVisible(false);
    logout();
    setTimeout(() => {
      login();
    }, 120);
  };

  return (
    <View style={styles.container}>
      <FlatList
        style={styles.container}
        data={displaySections}
        keyExtractor={(item) => item.name}
      directionalLockEnabled={false}
      nestedScrollEnabled
      keyboardShouldPersistTaps="always"
        contentContainerStyle={styles.content}
        ListHeaderComponent={
          <View style={styles.header}>
            <View>
              <Text style={styles.pageTitle}>Library</Text>
              <Text style={styles.pageSub}>All your AniList collections</Text>
            </View>
            <TouchableOpacity
              style={styles.avatarButton}
              onPress={() => setProfileMenuVisible(true)}
              activeOpacity={0.9}
            >
              <View style={styles.avatarRing}>
                {profileAvatar ? (
                  <Image source={{ uri: profileAvatar }} style={styles.avatarImage} />
                ) : (
                  <View style={[styles.avatarFallback, glassButton]}>
                    <Text style={styles.avatarFallbackText}>{profileInitial}</Text>
                  </View>
                )}
              </View>
              <View style={styles.onlineDot} />
            </TouchableOpacity>
          </View>
        }
        ListEmptyComponent={
          loading ? (
            <View style={styles.center}>
              <ActivityIndicator color={colors.accent} />
            </View>
          ) : (
            <View style={styles.center}>
              <Text style={styles.pageSub}>No list data found.</Text>
            </View>
          )
        }
        renderItem={({ item: section }) => (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>
              {section.name} <Text style={styles.sectionCount}>({section.entries.length})</Text>
            </Text>
            <FlatList
              data={section.entries}
              horizontal
              keyExtractor={(e) => String(e.id)}
              directionalLockEnabled={false}
              nestedScrollEnabled
              keyboardShouldPersistTaps="always"
              showsHorizontalScrollIndicator={false}
              contentContainerStyle={styles.rowContent}
              ItemSeparatorComponent={() => <View style={styles.itemSeparator} />}
              renderItem={({ item }) => {
                const media = item.media as MergedAnime;
                if (!media) return null;
                const sectionKey = String(section.name ?? '').trim().toUpperCase();
                const showProgress = sectionKey === 'CURRENT' || sectionKey === 'WATCHING';
                const total = media?.episodes ?? null;
                const progress = showProgress
                  ? `Progress: ${item.progress ?? 0}${total ? ` / ${total}` : ''}`
                  : null;
                const tracked = Math.max(0, Number(item.progress ?? 0));
                const nextAiringEp = Number(media?.nextAiringEpisode?.episode ?? 0);
                const status = String(media?.status ?? '').toUpperCase();
                const isReleasing = status === 'RELEASING' || nextAiringEp > 0;
                // For currently releasing anime, only count episodes that have already aired.
                // Do not use media.episodes because it can represent the final planned total.
                const releasedEpisodes = isReleasing
                  ? (nextAiringEp > 1 ? nextAiringEp - 1 : tracked)
                  : 0;
                const unwatchedCount = isReleasing ? Math.max(0, releasedEpisodes - tracked) : 0;
                return <View style={styles.rowCard}>{renderPosterCard(media, progress, unwatchedCount)}</View>;
              }}
            />
          </View>
        )}
      />

      <Modal
        visible={profileMenuVisible}
        transparent
        animationType="fade"
        onRequestClose={() => setProfileMenuVisible(false)}
      >
        <View style={styles.menuBackdrop}>
          <Pressable style={StyleSheet.absoluteFill} onPress={() => setProfileMenuVisible(false)} />
          <View style={[styles.profileMenu, glassCardElevated, shadow]}>
            <View style={styles.menuHeader}>
              {profileAvatar ? (
                <Image source={{ uri: profileAvatar }} style={styles.menuAvatarImage} />
              ) : (
                <View style={[styles.menuAvatarFallback, glassButton]}>
                  <Text style={styles.avatarFallbackText}>{profileInitial}</Text>
                </View>
              )}
              <View style={styles.menuHeaderTextWrap}>
                <Text style={styles.menuName} numberOfLines={1}>
                  {profileName}
                </Text>
                <Text style={styles.menuSub}>AniList Account</Text>
              </View>
            </View>
            <TouchableOpacity style={[styles.menuAction, glassButton]} onPress={handleRefresh}>
              <Text style={styles.menuActionText}>Refresh Library</Text>
            </TouchableOpacity>
            <TouchableOpacity style={[styles.menuAction, glassButton]} onPress={handleSwitchAccount}>
              <Text style={styles.menuActionText}>Switch Account</Text>
            </TouchableOpacity>
            <TouchableOpacity style={[styles.menuAction, styles.menuDanger]} onPress={handleLogout}>
              <Text style={styles.menuDangerText}>Logout</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: colors.background,
  },
  content: {
    paddingHorizontal: 16,
    paddingTop: 56,
    paddingBottom: 100,
  },
  noAuthWrap: {
    paddingHorizontal: 16,
    paddingTop: 56,
    paddingBottom: 90,
  },
  header: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    marginBottom: 18,
  },
  pageTitle: {
    color: colors.text,
    fontSize: 34,
    fontWeight: '900',
    letterSpacing: -0.8,
  },
  pageSub: {
    marginTop: 6,
    color: colors.textMuted,
    fontSize: 14,
    fontWeight: '500',
  },
  connectButton: {
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  connectButtonText: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
  },
  avatarButton: {
    width: 42,
    height: 42,
    alignItems: 'center',
    justifyContent: 'center',
  },
  avatarRing: {
    width: 42,
    height: 42,
    borderRadius: 21,
    borderWidth: 1.5,
    borderColor: 'rgba(126,203,255,0.55)',
    overflow: 'hidden',
  },
  avatarImage: {
    width: '100%',
    height: '100%',
    borderRadius: 21,
  },
  avatarFallback: {
    width: '100%',
    height: '100%',
    alignItems: 'center',
    justifyContent: 'center',
    borderRadius: 21,
  },
  avatarFallbackText: {
    color: colors.text,
    fontWeight: '800',
    fontSize: 14,
  },
  onlineDot: {
    position: 'absolute',
    right: 1,
    bottom: 1,
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: '#45d97b',
    borderWidth: 1,
    borderColor: colors.background,
  },
  center: {
    paddingVertical: 30,
    alignItems: 'center',
    justifyContent: 'center',
  },
  noAuthCard: {
    marginTop: 18,
    borderRadius: 18,
    padding: 14,
  },
  noAuthTitle: {
    color: colors.text,
    fontSize: 18,
    fontWeight: '800',
  },
  noAuthText: {
    marginTop: 8,
    color: colors.textMuted,
    fontSize: 13,
    lineHeight: 18,
  },
  noAuthPoints: {
    marginTop: 12,
    gap: 8,
  },
  noAuthPoint: {
    color: colors.textSecondary,
    fontSize: 12,
    fontWeight: '600',
  },
  noAuthActions: {
    marginTop: 14,
    gap: 10,
  },
  secondaryButton: {
    paddingHorizontal: 16,
    paddingVertical: 10,
  },
  secondaryButtonText: {
    color: colors.textMuted,
    fontSize: 13,
    fontWeight: '700',
  },
  section: {
    marginTop: 10,
    marginBottom: 8,
  },
  sectionTitle: {
    color: colors.text,
    fontSize: 28,
    fontWeight: '900',
    letterSpacing: -0.6,
    marginBottom: 10,
  },
  sectionCount: {
    color: colors.textMuted,
    fontSize: 18,
    fontWeight: '700',
  },
  rowContent: {
    paddingRight: 16,
  },
  itemSeparator: {
    width: CARD_GAP,
  },
  rowCard: {
    width: ROW_CARD_WIDTH,
  },
  card: {
    width: '100%',
    borderRadius: 20,
    overflow: 'hidden',
    minHeight: H_CARD,
  },
  poster: {
    width: '100%',
    height: H_CARD,
  },
  posterImage: {
    borderRadius: 20,
  },
  scoreBadge: {
    position: 'absolute',
    top: 8,
    right: 8,
    zIndex: 2,
    borderRadius: 12,
    backgroundColor: 'rgba(16,16,16,0.78)',
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  scoreText: {
    color: '#fff',
    fontSize: 13,
    fontWeight: '800',
  },
  unwatchedBadge: {
    position: 'absolute',
    top: 8,
    left: 8,
    zIndex: 2,
    borderRadius: 12,
    backgroundColor: '#f43f5e',
    paddingHorizontal: 10,
    paddingVertical: 4,
  },
  unwatchedBadgeText: {
    color: '#fff',
    fontSize: 11,
    fontWeight: '800',
  },
  bottomOverlay: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 0,
    paddingHorizontal: 10,
    paddingVertical: 10,
    backgroundColor: 'rgba(0,0,0,0.56)',
  },
  cardTitle: {
    color: '#fff',
    fontSize: 13,
    lineHeight: 17,
    fontWeight: '700',
  },
  progressText: {
    marginTop: 4,
    color: 'rgba(255,255,255,0.9)',
    fontSize: 11,
    fontWeight: '600',
  },
  menuBackdrop: {
    flex: 1,
    backgroundColor: 'rgba(0,0,0,0.36)',
    paddingTop: 94,
    paddingHorizontal: 16,
  },
  profileMenu: {
    alignSelf: 'flex-end',
    width: 220,
    borderRadius: 16,
    padding: 10,
    gap: 8,
  },
  menuHeader: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    padding: 6,
    marginBottom: 2,
  },
  menuAvatarImage: {
    width: 30,
    height: 30,
    borderRadius: 15,
  },
  menuAvatarFallback: {
    width: 30,
    height: 30,
    borderRadius: 15,
    alignItems: 'center',
    justifyContent: 'center',
  },
  menuHeaderTextWrap: {
    flex: 1,
  },
  menuName: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
  },
  menuSub: {
    color: colors.textMuted,
    fontSize: 11,
    marginTop: 1,
  },
  menuAction: {
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  menuActionText: {
    color: colors.text,
    fontSize: 12,
    fontWeight: '700',
  },
  menuDanger: {
    borderWidth: 1,
    borderColor: 'rgba(255,120,120,0.45)',
    backgroundColor: 'rgba(255,90,90,0.15)',
    borderRadius: 14,
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  menuDangerText: {
    color: '#ff9b9b',
    fontSize: 12,
    fontWeight: '700',
  },
});
