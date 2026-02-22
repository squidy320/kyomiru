import { useRouter } from 'expo-router';
import React, { useEffect, useState } from 'react';
import {
  ActivityIndicator,
  FlatList,
  ImageBackground,
  Image,
  StyleSheet,
  Text,
  TextInput,
  TouchableOpacity,
  View,
} from 'react-native';

import GlassSurface from '@/components/ui/glass-surface';
import { AniListAnime, fetchDiscoveryAniListData, DiscoveryAniListData, searchAnime } from '@/lib/anilist';
import { colors, glassCardElevated, glassInput, shadow } from '@/lib/theme';

const CARD_GAP = 12;
const H_CARD = 238;
const ROW_CARD_WIDTH = 150;

export default function DiscoveryScreen() {
  const router = useRouter();
  const [loading, setLoading] = useState(false);
  const [data, setData] = useState<DiscoveryAniListData | null>(null);
  const [query, setQuery] = useState('');
  const [searchLoading, setSearchLoading] = useState(false);
  const [searchResults, setSearchResults] = useState<AniListAnime[]>([]);
  const [searchFocused, setSearchFocused] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);

  useEffect(() => {
    const load = async () => {
      setLoading(true);
      try {
        const res = await fetchDiscoveryAniListData();
        setData(res);
      } catch (e) {
        console.error(e);
      } finally {
        setLoading(false);
      }
    };
    load();
  }, []);

  useEffect(() => {
    const q = query.trim();
    if (!q) {
      setSearchResults([]);
      setSearchLoading(false);
      setSearchError(null);
      return;
    }
    let cancelled = false;
    const timer = setTimeout(async () => {
      setSearchLoading(true);
      setSearchError(null);
      try {
        const results = await searchAnime(q);
        if (!cancelled) {
          setSearchResults(results);
        }
      } catch {
        if (!cancelled) {
          setSearchResults([]);
          setSearchError('Search failed. Try again.');
        }
      } finally {
        if (!cancelled) {
          setSearchLoading(false);
        }
      }
    }, 300);
    return () => {
      cancelled = true;
      clearTimeout(timer);
    };
  }, [query]);

  const openDetails = (item: AniListAnime) => {
    const title = item.title?.english ?? item.title?.romaji ?? item.title?.native ?? 'Unknown';
    const cover = item.coverImage?.large ?? 'https://via.placeholder.com/300x450?text=No+Cover';
    const score = item.averageScore ?? null;
    router.push({
      pathname: '/details/[id]',
      params: {
        id: String(item.id),
        title,
        coverImage: cover,
        averageScore: score ?? 'N/A',
      },
    });
  };

  const sections = [
    { name: 'Trending', items: data?.trending ?? [] },
    { name: 'New Releases', items: data?.releasing ?? [] },
    { name: 'Hot Now', items: data?.popular ?? [] },
    { name: 'Top Rated', items: data?.topRated ?? [] },
  ].filter((s) => s.items.length > 0);

  const renderCard = (item: AniListAnime) => {
    const title = item.title?.english ?? item.title?.romaji ?? item.title?.native ?? 'Unknown';
    const cover = item.coverImage?.large ?? 'https://via.placeholder.com/300x450?text=No+Cover';
    const score = item.averageScore ?? null;

    return (
      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <TouchableOpacity style={styles.cardPressable} activeOpacity={0.9} onPress={() => openDetails(item)}>
          <ImageBackground source={{ uri: cover }} style={styles.poster} imageStyle={styles.posterImage}>
            <View style={styles.scoreBadge}>
              <Text style={styles.scoreText}>{score ?? 'NR'}</Text>
            </View>
            <View style={styles.bottomOverlay}>
              <Text style={styles.cardTitle} numberOfLines={2}>
                {title}
              </Text>
            </View>
          </ImageBackground>
        </TouchableOpacity>
      </GlassSurface>
    );
  };

  return (
    <FlatList
      style={styles.container}
      data={sections}
      keyExtractor={(item) => item.name}
      directionalLockEnabled={false}
      nestedScrollEnabled
      keyboardShouldPersistTaps="always"
      contentContainerStyle={styles.content}
      ListHeaderComponent={
        <View style={styles.header}>
          <Text style={styles.pageTitle}>Discovery</Text>
          <Text style={styles.pageSub}>Trending, new releases, and hot anime</Text>
          <TextInput
            value={query}
            onChangeText={setQuery}
            placeholder="Search anime..."
            placeholderTextColor={colors.textDim}
            style={[styles.searchInput, glassInput]}
            autoCapitalize="none"
            autoCorrect={false}
            clearButtonMode="while-editing"
            onFocus={() => setSearchFocused(true)}
            onBlur={() => setTimeout(() => setSearchFocused(false), 120)}
            returnKeyType="search"
          />
          {query.trim().length > 0 && (searchFocused || searchLoading || searchResults.length > 0) && (
            <GlassSurface style={[styles.suggestPanel, glassCardElevated, shadow]}>
              {searchLoading ? (
                <View style={styles.suggestLoadingRow}>
                  <ActivityIndicator color={colors.accent} />
                  <Text style={styles.suggestMuted}>Searching AniList...</Text>
                </View>
              ) : searchError ? (
                <Text style={styles.suggestMuted}>{searchError}</Text>
              ) : searchResults.length === 0 ? (
                <Text style={styles.suggestMuted}>No matches.</Text>
              ) : (
                searchResults.slice(0, 8).map((item) => {
                  const t = item.title?.english ?? item.title?.romaji ?? item.title?.native ?? 'Unknown';
                  const c = item.coverImage?.large ?? '';
                  return (
                    <TouchableOpacity
                      key={`suggest-${item.id}`}
                      style={styles.suggestRow}
                      activeOpacity={0.85}
                      onPress={() => openDetails(item)}
                    >
                      {c ? <Image source={{ uri: c }} style={styles.suggestThumb} /> : <View style={styles.suggestThumbPlaceholder} />}
                      <View style={styles.suggestInfo}>
                        <Text style={styles.suggestTitle} numberOfLines={1}>{t}</Text>
                        <Text style={styles.suggestMeta}>Score {item.averageScore ?? 'N/A'}</Text>
                      </View>
                    </TouchableOpacity>
                  );
                })
              )}
            </GlassSurface>
          )}
        </View>
      }
      ListEmptyComponent={
        <View style={styles.center}>
          {loading ? <ActivityIndicator color={colors.accent} /> : <Text style={styles.pageSub}>No data right now.</Text>}
        </View>
      }
      renderItem={({ item: section }) => (
        <View style={styles.section}>
          <Text style={styles.sectionTitle}>{section.name}</Text>
          <FlatList
            data={section.items}
            horizontal
            keyExtractor={(item) => String(item.id)}
            directionalLockEnabled={false}
            nestedScrollEnabled
            keyboardShouldPersistTaps="always"
            showsHorizontalScrollIndicator={false}
            contentContainerStyle={styles.rowContent}
            ItemSeparatorComponent={() => <View style={styles.itemSeparator} />}
            renderItem={({ item }) => <View style={styles.rowCard}>{renderCard(item)}</View>}
          />
        </View>
      )}
      ListFooterComponent={
        query.trim() && !searchFocused ? (
          <View style={styles.section}>
            <Text style={styles.sectionTitle}>Search Results</Text>
            {searchLoading ? (
              <View style={styles.center}>
                <ActivityIndicator color={colors.accent} />
              </View>
            ) : searchResults.length === 0 ? (
              <View style={styles.center}>
                <Text style={styles.pageSub}>No matches found.</Text>
              </View>
            ) : (
              <FlatList
                data={searchResults}
                horizontal
                keyExtractor={(item) => `search-${item.id}`}
                directionalLockEnabled={false}
                nestedScrollEnabled
                keyboardShouldPersistTaps="always"
                showsHorizontalScrollIndicator={false}
                contentContainerStyle={styles.rowContent}
                ItemSeparatorComponent={() => <View style={styles.itemSeparator} />}
                renderItem={({ item }) => <View style={styles.rowCard}>{renderCard(item)}</View>}
              />
            )}
          </View>
        ) : null
      }
    />
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
  header: {
    marginBottom: 16,
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
  searchInput: {
    marginTop: 12,
    borderRadius: 12,
    paddingHorizontal: 12,
    paddingVertical: 10,
    color: colors.text,
    fontSize: 14,
    fontWeight: '600',
  },
  suggestPanel: {
    marginTop: 8,
    borderRadius: 14,
    overflow: 'hidden',
    borderWidth: 1,
    borderColor: colors.borderSoft,
  },
  suggestLoadingRow: {
    paddingHorizontal: 12,
    paddingVertical: 12,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  suggestMuted: {
    paddingHorizontal: 12,
    paddingVertical: 12,
    color: colors.textMuted,
    fontSize: 13,
    fontWeight: '600',
  },
  suggestRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    paddingHorizontal: 10,
    paddingVertical: 8,
    borderTopWidth: 1,
    borderTopColor: colors.borderSoft,
  },
  suggestThumb: {
    width: 34,
    height: 48,
    borderRadius: 6,
  },
  suggestThumbPlaceholder: {
    width: 34,
    height: 48,
    borderRadius: 6,
    backgroundColor: colors.surfaceSoft,
    borderWidth: 1,
    borderColor: colors.borderSoft,
  },
  suggestInfo: {
    flex: 1,
  },
  suggestTitle: {
    color: colors.text,
    fontSize: 14,
    fontWeight: '700',
  },
  suggestMeta: {
    color: colors.textMuted,
    fontSize: 12,
    fontWeight: '600',
    marginTop: 2,
  },
  center: {
    paddingVertical: 30,
    alignItems: 'center',
    justifyContent: 'center',
  },
  section: {
    marginTop: 8,
    marginBottom: 8,
  },
  sectionTitle: {
    color: colors.text,
    fontSize: 28,
    fontWeight: '900',
    letterSpacing: -0.6,
    marginBottom: 10,
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
  cardPressable: {
    width: '100%',
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
});
