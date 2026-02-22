import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';

import GlassSurface from '@/components/ui/glass-surface';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';
import { useUIAppearance } from '@/lib/uiAppearance';

export default function LibrarySettingsScreen() {
  const {
    libraryListOrganization,
    librarySortType,
    streamSelectionMode,
    defaultStreamQuality,
    defaultStreamLanguage,
    setLibraryListOrganization,
    setLibrarySortType,
    setStreamSelectionMode,
    setDefaultStreamQuality,
    setDefaultStreamLanguage,
  } = useUIAppearance();

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Library Layout</Text>
        <View style={styles.rowButtons}>
          {([
            { key: 'anilist', label: 'AniList Order' },
            { key: 'alphabetical', label: 'Alphabetical' },
            { key: 'status-flow', label: 'Status Flow' },
          ] as const).map((item) => (
            <TouchableOpacity
              key={item.key}
              style={[styles.optionButton, glassButton, libraryListOrganization === item.key && styles.optionButtonActive]}
              onPress={() => setLibraryListOrganization(item.key)}
            >
              <Text style={styles.optionText}>{item.label}</Text>
            </TouchableOpacity>
          ))}
        </View>
      </GlassSurface>

      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Library Sorting</Text>
        <View style={styles.rowButtons}>
          {([
            { key: 'recently-added', label: 'Recently Added' },
            { key: 'rating', label: 'Rating' },
            { key: 'title', label: 'Title' },
          ] as const).map((item) => (
            <TouchableOpacity
              key={item.key}
              style={[styles.optionButton, glassButton, librarySortType === item.key && styles.optionButtonActive]}
              onPress={() => setLibrarySortType(item.key)}
            >
              <Text style={styles.optionText}>{item.label}</Text>
            </TouchableOpacity>
          ))}
        </View>
      </GlassSurface>

      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Stream Defaults</Text>
        <Text style={styles.rowTitle}>Selection Mode</Text>
        <View style={styles.rowButtons}>
          {([
            { key: 'auto', label: 'Auto Pick' },
            { key: 'ask-every-time', label: 'Ask Every Time' },
          ] as const).map((item) => (
            <TouchableOpacity
              key={item.key}
              style={[styles.optionButton, glassButton, streamSelectionMode === item.key && styles.optionButtonActive]}
              onPress={() => setStreamSelectionMode(item.key)}
            >
              <Text style={styles.optionText}>{item.label}</Text>
            </TouchableOpacity>
          ))}
        </View>

        <Text style={[styles.rowTitle, { marginTop: 8 }]}>Default Quality</Text>
        <View style={styles.rowButtons}>
          {(['auto', '1080p', '720p', '480p', '360p'] as const).map((q) => (
            <TouchableOpacity
              key={q}
              style={[styles.optionButton, glassButton, defaultStreamQuality === q && styles.optionButtonActive]}
              onPress={() => setDefaultStreamQuality(q)}
            >
              <Text style={styles.optionText}>{q.toUpperCase()}</Text>
            </TouchableOpacity>
          ))}
        </View>

        <Text style={[styles.rowTitle, { marginTop: 8 }]}>Default Language</Text>
        <View style={styles.rowButtons}>
          {(['sub', 'dub', 'any'] as const).map((lang) => (
            <TouchableOpacity
              key={lang}
              style={[styles.optionButton, glassButton, defaultStreamLanguage === lang && styles.optionButtonActive]}
              onPress={() => setDefaultStreamLanguage(lang)}
            >
              <Text style={styles.optionText}>{lang.toUpperCase()}</Text>
            </TouchableOpacity>
          ))}
        </View>
      </GlassSurface>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  content: { padding: 16, paddingBottom: 40, gap: 12 },
  card: { borderRadius: 16, padding: 14, gap: 10 },
  cardTitle: { color: colors.text, fontSize: 16, fontWeight: '800' },
  rowTitle: { color: colors.text, fontSize: 13, fontWeight: '700' },
  rowButtons: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  optionButton: { paddingHorizontal: 12, paddingVertical: 8 },
  optionButtonActive: { borderColor: colors.accent, backgroundColor: 'rgba(139,92,246,0.18)' },
  optionText: { color: colors.text, fontSize: 11, fontWeight: '800' },
});
