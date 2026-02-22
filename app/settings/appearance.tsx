import React from 'react';
import { ScrollView, StyleSheet, Switch, Text, TouchableOpacity, View } from 'react-native';

import GlassSurface from '@/components/ui/glass-surface';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';
import { useUIAppearance } from '@/lib/uiAppearance';
import { useThemePresetColors } from '@/lib/themePresets';

const PRESETS = [
  { key: 'midnight', label: 'Midnight' },
  { key: 'ocean', label: 'Ocean' },
  { key: 'rose', label: 'Rose' },
  { key: 'emerald', label: 'Emerald' },
  { key: 'sunset', label: 'Sunset' },
] as const;

export default function AppearanceSettingsScreen() {
  const {
    supportsLiquidGlass,
    isReduceTransparencyEnabled,
    liquidGlassMode,
    glassIntensity,
    compactTabBar,
    touchOutline,
    setLiquidGlassMode,
    setGlassIntensity,
    setCompactTabBar,
    setTouchOutline,
    themePreset,
    oledMode,
    setThemePreset,
    setOledMode,
    resetAppearanceSettings,
  } = useUIAppearance();
  const themed = useThemePresetColors();

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Theme</Text>
        <Text style={styles.cardSub}>Pick the accent and tone that matches your style.</Text>
        <View style={styles.paletteRow}>
          {PRESETS.map((item) => (
            <TouchableOpacity
              key={item.key}
              style={[styles.paletteButton, glassButton, themePreset === item.key && styles.paletteButtonActive]}
              onPress={() => setThemePreset(item.key)}
              activeOpacity={0.85}
            >
              <Text style={styles.paletteButtonText}>{item.label}</Text>
            </TouchableOpacity>
          ))}
        </View>
        <View style={[styles.preview, { borderColor: themed.accent }]}>
          <Text style={[styles.previewText, { color: themed.accent }]}>Accent preview</Text>
        </View>
      </GlassSurface>

      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Display</Text>
        <View style={styles.row}>
          <View style={styles.rowText}>
            <Text style={styles.rowTitle}>OLED Black Mode</Text>
            <Text style={styles.rowSub}>Use true black backgrounds for better contrast and battery.</Text>
          </View>
          <Switch
            value={oledMode}
            onValueChange={setOledMode}
            trackColor={{ false: '#3a3a46', true: themed.accent }}
            thumbColor="#ffffff"
          />
        </View>
        <View style={styles.row}>
          <View style={styles.rowText}>
            <Text style={styles.rowTitle}>Compact Bottom Bar</Text>
            <Text style={styles.rowSub}>Smaller tab bar with tighter spacing.</Text>
          </View>
          <Switch
            value={compactTabBar}
            onValueChange={setCompactTabBar}
            trackColor={{ false: '#3a3a46', true: themed.accent }}
            thumbColor="#ffffff"
          />
        </View>
        <View style={styles.row}>
          <View style={styles.rowText}>
            <Text style={styles.rowTitle}>Touch Outline</Text>
            <Text style={styles.rowSub}>Outline tab icons while pressing.</Text>
          </View>
          <Switch
            value={touchOutline}
            onValueChange={setTouchOutline}
            trackColor={{ false: '#3a3a46', true: themed.accent }}
            thumbColor="#ffffff"
          />
        </View>
      </GlassSurface>

      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Glass Effects</Text>
        <Text style={styles.cardSub}>
          Support: {supportsLiquidGlass ? 'Yes' : 'No'}{supportsLiquidGlass ? ` • Transparency: ${isReduceTransparencyEnabled ? 'Reduced' : 'Enabled'}` : ''}
        </Text>
        <View style={styles.rowButtons}>
          <TouchableOpacity
            style={[styles.optionButton, glassButton, liquidGlassMode === 'auto' && styles.optionButtonActive]}
            onPress={() => setLiquidGlassMode('auto')}
          >
            <Text style={styles.optionText}>Auto</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.optionButton, glassButton, liquidGlassMode === 'off' && styles.optionButtonActive]}
            onPress={() => setLiquidGlassMode('off')}
          >
            <Text style={styles.optionText}>Off</Text>
          </TouchableOpacity>
        </View>
        <Text style={[styles.rowTitle, { marginTop: 10 }]}>Glass Intensity</Text>
        <View style={styles.rowButtons}>
          {(['low', 'medium', 'high'] as const).map((level) => (
            <TouchableOpacity
              key={level}
              style={[styles.optionButton, glassButton, glassIntensity === level && styles.optionButtonActive]}
              onPress={() => setGlassIntensity(level)}
            >
              <Text style={styles.optionText}>{level.toUpperCase()}</Text>
            </TouchableOpacity>
          ))}
        </View>
      </GlassSurface>

      <TouchableOpacity style={[styles.resetButton, glassButton]} onPress={resetAppearanceSettings}>
        <Text style={styles.resetButtonText}>Reset All Customizations</Text>
      </TouchableOpacity>
    </ScrollView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: colors.background },
  content: { padding: 16, paddingBottom: 40, gap: 12 },
  card: { borderRadius: 16, padding: 14, gap: 10 },
  cardTitle: { color: colors.text, fontSize: 16, fontWeight: '800' },
  cardSub: { color: colors.textMuted, fontSize: 12, fontWeight: '600' },
  paletteRow: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  paletteButton: { paddingHorizontal: 12, paddingVertical: 8 },
  paletteButtonActive: { borderColor: colors.accent, backgroundColor: 'rgba(139,92,246,0.18)' },
  paletteButtonText: { color: colors.text, fontSize: 12, fontWeight: '700' },
  preview: {
    marginTop: 4,
    borderWidth: 1,
    borderRadius: 12,
    backgroundColor: 'rgba(255,255,255,0.04)',
    paddingVertical: 10,
    alignItems: 'center',
  },
  previewText: { fontWeight: '800', fontSize: 12 },
  row: { flexDirection: 'row', gap: 12, justifyContent: 'space-between', alignItems: 'center' },
  rowText: { flex: 1 },
  rowTitle: { color: colors.text, fontSize: 13, fontWeight: '700' },
  rowSub: { marginTop: 2, color: colors.textMuted, fontSize: 11 },
  rowButtons: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  optionButton: { paddingHorizontal: 12, paddingVertical: 8 },
  optionButtonActive: { borderColor: colors.accent, backgroundColor: 'rgba(139,92,246,0.18)' },
  optionText: { color: colors.text, fontSize: 11, fontWeight: '800' },
  resetButton: { alignSelf: 'flex-start', paddingHorizontal: 14, paddingVertical: 10 },
  resetButtonText: { color: '#ffd7da', fontWeight: '800', fontSize: 12 },
});
