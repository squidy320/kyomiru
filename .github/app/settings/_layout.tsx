import { Stack } from 'expo-router';
import React from 'react';

import { colors } from '@/lib/theme';

export default function SettingsLayout() {
  return (
    <Stack
      screenOptions={{
        headerShown: true,
        headerStyle: { backgroundColor: colors.background },
        headerTintColor: colors.text,
        headerTitleStyle: { fontWeight: '800' },
        contentStyle: { backgroundColor: colors.background },
      }}
    >
      <Stack.Screen name="appearance" options={{ title: 'Appearance' }} />
      <Stack.Screen name="player" options={{ title: 'Player' }} />
      <Stack.Screen name="library" options={{ title: 'Library & Streams' }} />
      <Stack.Screen name="account" options={{ title: 'Account & Data' }} />
    </Stack>
  );
}

