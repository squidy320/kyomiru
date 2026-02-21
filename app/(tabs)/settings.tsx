import MaterialIcons from '@expo/vector-icons/MaterialIcons';
import { useRouter } from 'expo-router';
import React from 'react';
import { ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';

import { colors, glassCardElevated, shadow } from '@/lib/theme';

const ITEMS = [
  { key: 'appearance', title: 'Appearance', subtitle: 'Themes, colors, and layout', icon: 'palette' },
  { key: 'player', title: 'Player', subtitle: 'Playback controls and behavior', icon: 'play-circle-outline' },
  { key: 'library', title: 'Library & Streams', subtitle: 'Sorting, quality, and language', icon: 'view-list' },
  { key: 'account', title: 'Account & Data', subtitle: 'Auth and cleanup controls', icon: 'manage-accounts' },
] as const;

export default function SettingsEntryScreen() {
  const router = useRouter();

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <Text style={styles.title}>Settings</Text>
      <Text style={styles.subtitle}>Customize Kyomiru exactly how you want.</Text>

      <View style={styles.list}>
        {ITEMS.map((item) => (
          <TouchableOpacity
            key={item.key}
            style={[styles.card, glassCardElevated, shadow]}
            activeOpacity={0.88}
            onPress={() => router.push(`/settings/${item.key}` as any)}
          >
            <View style={styles.iconWrap}>
              <MaterialIcons name={item.icon} size={20} color={colors.text} />
            </View>
            <View style={styles.textWrap}>
              <Text style={styles.cardTitle}>{item.title}</Text>
              <Text style={styles.cardSubtitle}>{item.subtitle}</Text>
            </View>
            <MaterialIcons name="chevron-right" size={22} color={colors.textMuted} />
          </TouchableOpacity>
        ))}
      </View>
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
    gap: 14,
  },
  title: {
    color: colors.text,
    fontSize: 34,
    fontWeight: '900',
    letterSpacing: -0.8,
  },
  subtitle: {
    color: colors.textMuted,
    fontSize: 14,
    fontWeight: '500',
  },
  list: {
    gap: 10,
    marginTop: 8,
  },
  card: {
    borderRadius: 16,
    padding: 14,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 12,
  },
  iconWrap: {
    width: 34,
    height: 34,
    borderRadius: 17,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  textWrap: {
    flex: 1,
  },
  cardTitle: {
    color: colors.text,
    fontSize: 14,
    fontWeight: '800',
  },
  cardSubtitle: {
    marginTop: 2,
    color: colors.textMuted,
    fontSize: 12,
    fontWeight: '600',
  },
});
