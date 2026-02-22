import React from 'react';
import { ScrollView, StyleSheet, Switch, Text, TouchableOpacity, View } from 'react-native';

import GlassSurface from '@/components/ui/glass-surface';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';
import { useUIAppearance } from '@/lib/uiAppearance';
import { useThemePresetColors } from '@/lib/themePresets';

export default function PlayerSettingsScreen() {
  const {
    playerFitMode,
    playerControlStyle,
    playerSkipSeconds,
    playerAutoHideSeconds,
    playerShowMeta,
    setPlayerFitMode,
    setPlayerControlStyle,
    setPlayerSkipSeconds,
    setPlayerAutoHideSeconds,
    setPlayerShowMeta,
  } = useUIAppearance();
  const themed = useThemePresetColors();

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Video Fit</Text>
        <Text style={styles.cardSub}>Contain preserves full frame. Cover fills the screen.</Text>
        <View style={styles.rowButtons}>
          <TouchableOpacity
            style={[styles.optionButton, glassButton, playerFitMode === 'contain' && styles.optionButtonActive]}
            onPress={() => setPlayerFitMode('contain')}
          >
            <Text style={styles.optionText}>Contain</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.optionButton, glassButton, playerFitMode === 'cover' && styles.optionButtonActive]}
            onPress={() => setPlayerFitMode('cover')}
          >
            <Text style={styles.optionText}>Cover</Text>
          </TouchableOpacity>
        </View>
      </GlassSurface>

      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Controls</Text>
        <Text style={styles.rowTitle}>Control Style</Text>
        <View style={styles.rowButtons}>
          <TouchableOpacity
            style={[styles.optionButton, glassButton, playerControlStyle === 'glass' && styles.optionButtonActive]}
            onPress={() => setPlayerControlStyle('glass')}
          >
            <Text style={styles.optionText}>Glass</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.optionButton, glassButton, playerControlStyle === 'solid' && styles.optionButtonActive]}
            onPress={() => setPlayerControlStyle('solid')}
          >
            <Text style={styles.optionText}>Solid</Text>
          </TouchableOpacity>
        </View>

        <Text style={[styles.rowTitle, { marginTop: 8 }]}>Skip Interval</Text>
        <View style={styles.rowButtons}>
          {([5, 10, 15, 30] as const).map((s) => (
            <TouchableOpacity
              key={s}
              style={[styles.optionButton, glassButton, playerSkipSeconds === s && styles.optionButtonActive]}
              onPress={() => setPlayerSkipSeconds(s)}
            >
              <Text style={styles.optionText}>{s}s</Text>
            </TouchableOpacity>
          ))}
        </View>

        <Text style={[styles.rowTitle, { marginTop: 8 }]}>Auto-hide Controls</Text>
        <View style={styles.rowButtons}>
          {([2, 3, 5, 8] as const).map((s) => (
            <TouchableOpacity
              key={s}
              style={[styles.optionButton, glassButton, playerAutoHideSeconds === s && styles.optionButtonActive]}
              onPress={() => setPlayerAutoHideSeconds(s)}
            >
              <Text style={styles.optionText}>{s}s</Text>
            </TouchableOpacity>
          ))}
        </View>

        <View style={[styles.row, { marginTop: 8 }]}>
          <View style={{ flex: 1 }}>
            <Text style={styles.rowTitle}>Show Episode Meta</Text>
            <Text style={styles.cardSub}>Show title and timeline overlay while controls are visible.</Text>
          </View>
          <Switch
            value={playerShowMeta}
            onValueChange={setPlayerShowMeta}
            trackColor={{ false: '#3a3a46', true: themed.accent }}
            thumbColor="#ffffff"
          />
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
  cardSub: { color: colors.textMuted, fontSize: 12, fontWeight: '600' },
  row: { flexDirection: 'row', gap: 12, justifyContent: 'space-between', alignItems: 'center' },
  rowTitle: { color: colors.text, fontSize: 13, fontWeight: '700' },
  rowButtons: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  optionButton: { paddingHorizontal: 12, paddingVertical: 8 },
  optionButtonActive: { borderColor: colors.accent, backgroundColor: 'rgba(139,92,246,0.18)' },
  optionText: { color: colors.text, fontSize: 11, fontWeight: '800' },
});
