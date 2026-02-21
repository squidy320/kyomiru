import { Stack } from 'expo-router';
import { StatusBar } from 'expo-status-bar';
import React from 'react';
import 'react-native-reanimated';

import { AniListAuthProvider } from '@/lib/anilistAuth';
import { AniListNotificationsProvider } from '@/lib/anilistNotifications';
import { getFFmpegRuntimeStatus } from '@/lib/DownloadManager';
import HiddenWebViewScraperProvider from '@/lib/HiddenWebViewScraper';
import { UIAppearanceProvider } from '@/lib/uiAppearance';
import { createFallbackAnimePaheExtension, toRuntimeAnimePaheExtension } from '@/services/animePaheLunaAdapter';
import ExtensionEngine from '@/services/ExtensionEngine.js';
import { colors } from '@/lib/theme';

export default function RootLayout() {
  React.useEffect(() => {
    (async () => {
      try {
        const status = await getFFmpegRuntimeStatus();
        console.log('[RootLayout] FFmpeg runtime status:', status);
      } catch (e) {
        console.warn('[RootLayout] FFmpeg runtime check failed:', e);
      }
    })();
  }, []);

  React.useEffect(() => {
    (async () => {
      try {
        const url = 'https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.json';
        console.log('[RootLayout] Fetching Sora extension from:', url);
        const controller = new AbortController();
        const timeout = setTimeout(() => controller.abort(), 10000);
        const res = await fetch(url, { signal: controller.signal });
        clearTimeout(timeout);
        if (!res.ok) throw new Error(`Failed to fetch official module: ${res.status}`);
        const json = await res.json();
        const runtimeExt = toRuntimeAnimePaheExtension(json);
        console.log(
          '[RootLayout] Sora extension fetched, id:',
          runtimeExt?.id,
          'has getSources:',
          !!(runtimeExt?.getSources || runtimeExt?.get_sources || runtimeExt?.sources)
        );
        if (!runtimeExt) {
          throw new Error('Fetched module is not a runnable Sora extension manifest');
        }

        ExtensionEngine.loadExtension(runtimeExt as any);
        console.log('[RootLayout] Loaded official AnimePahe Sora module successfully');
      } catch (e: any) {
        console.error('[RootLayout] Failed to load official Sora module:', e);
        console.log('[RootLayout] Loading fallback embedded extension');
        ExtensionEngine.loadExtension(createFallbackAnimePaheExtension() as any);
        console.log('[RootLayout] Loaded fallback extension');
      }
    })();
  }, []);

  return (
    <UIAppearanceProvider>
      <AniListAuthProvider>
        <AniListNotificationsProvider>
          <HiddenWebViewScraperProvider>
            <StatusBar style="light" backgroundColor={colors.background} />
            <Stack
              screenOptions={{
                headerStyle: { backgroundColor: 'transparent' },
                headerTintColor: colors.text,
                headerTitleStyle: { fontWeight: '700' },
                contentStyle: { backgroundColor: colors.background },
              }}
            >
              <Stack.Screen name="(tabs)" options={{ headerShown: false }} />
              <Stack.Screen name="details/[id]" options={{ headerBackTitle: 'Back' }} />
            </Stack>
          </HiddenWebViewScraperProvider>
        </AniListNotificationsProvider>
      </AniListAuthProvider>
    </UIAppearanceProvider>
  );
}
