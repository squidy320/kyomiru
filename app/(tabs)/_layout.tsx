import { Tabs, usePathname, useRouter } from 'expo-router';
import * as Network from 'expo-network';
import React from 'react';
import { Platform } from 'react-native';

import { HapticTab } from '@/components/haptic-tab';
import LiquidGlassView from '@/components/liquid-glass-view';
import { IconSymbol } from '@/components/ui/icon-symbol';
import { useAniListNotifications } from '@/lib/anilistNotifications';
import { useUIAppearance } from '@/lib/uiAppearance';
import { useThemePresetColors } from '@/lib/themePresets';

export default function TabLayout() {
  const router = useRouter();
  const pathname = usePathname();
  const launchOfflineCheckDone = React.useRef(false);

  React.useEffect(() => {
    if (launchOfflineCheckDone.current) return;
    launchOfflineCheckDone.current = true;

    const checkConnectivity = async () => {
      try {
        const state = await Network.getNetworkStateAsync();
        const offline = state.isConnected === false || state.isInternetReachable === false;
        if (offline && pathname !== '/downloads' && pathname !== '/(tabs)/downloads') {
          router.replace('/(tabs)/downloads');
        }
      } catch {
        // If network check fails, keep current tab.
      }
    };

    void checkConnectivity();
  }, [pathname, router]);
  const { compactTabBar, glassIntensity, liquidGlassActive } = useUIAppearance();
  const themed = useThemePresetColors();
  const { unreadDot } = useAniListNotifications();
  const isAndroid = Platform.OS === 'android';
  const tabBarHeight = compactTabBar ? (isAndroid ? 58 : 52) : (isAndroid ? 64 : 58);
  const tabBarBottom = compactTabBar ? (isAndroid ? 8 : 10) : (isAndroid ? 10 : 14);
  const tabBarInset = compactTabBar ? (isAndroid ? 18 : 34) : (isAndroid ? 16 : 28);
  const fallbackTabBarTint =
    glassIntensity === 'high'
      ? 'rgba(8,10,16,0.95)'
      : glassIntensity === 'low'
        ? 'rgba(10,12,18,0.84)'
        : 'rgba(8,10,16,0.90)';

  return (
    <Tabs
      screenOptions={{
        tabBarActiveTintColor: themed.accent,
        tabBarInactiveTintColor: 'rgba(255,255,255,0.86)',
        headerShown: false,
        lazy: true,
        freezeOnBlur: true,
        tabBarButton: HapticTab,
        tabBarShowLabel: true,
        tabBarLabelStyle: {
          fontSize: 10,
          fontWeight: '700',
          marginTop: 0,
          marginBottom: 1,
        },
        tabBarStyle: {
          position: 'absolute',
          left: tabBarInset,
          right: tabBarInset,
          bottom: tabBarBottom,
          height: tabBarHeight,
          paddingBottom: 2,
          paddingTop: 2,
          borderTopWidth: 0,
          elevation: 0,
          borderWidth: 1,
          borderColor: 'rgba(255,255,255,0.30)',
          borderRadius: 32,
          backgroundColor: liquidGlassActive ? 'transparent' : fallbackTabBarTint,
          shadowColor: '#000',
          shadowOpacity: 0.16,
          shadowRadius: 8,
          shadowOffset: { width: 0, height: 3 },
          overflow: isAndroid ? 'visible' : 'hidden',
        },
        tabBarBackground: () =>
          liquidGlassActive ? (
            <LiquidGlassView
              effect="regular"
              interactive={false}
              style={{
                flex: 1,
                borderRadius: 32,
                backgroundColor: 'transparent',
              }}
            />
          ) : null,
        tabBarItemStyle: {
          borderRadius: 26,
          justifyContent: 'center',
          alignItems: 'center',
          marginVertical: 2,
          marginHorizontal: 1,
        },
        tabBarActiveBackgroundColor: 'transparent',
        tabBarIconStyle: { marginTop: 0 },
      }}>
      <Tabs.Screen
        name="index"
        options={{
          title: 'Library',
          tabBarIcon: ({ color }) => <IconSymbol size={21} name="books.vertical.fill" color={color} />,
        }}
      />
      <Tabs.Screen
        name="discovery"
        options={{
          title: 'Discovery',
          tabBarIcon: ({ color }) => <IconSymbol size={21} name="sparkles" color={color} />,
        }}
      />
      <Tabs.Screen
        name="notifications"
        options={{
          title: 'Alerts',
          tabBarIcon: ({ color }) => <IconSymbol size={21} name="bell.fill" color={color} />,
          tabBarBadge: unreadDot ? ' ' : undefined,
          tabBarBadgeStyle: {
            backgroundColor: '#ff3b30',
            color: 'transparent',
            minWidth: 8,
            height: 8,
            borderRadius: 999,
            paddingHorizontal: 0,
            paddingVertical: 0,
            top: 4,
            right: -8,
          },
        }}
      />
      <Tabs.Screen
        name="downloads"
        options={{
          title: 'Downloads',
          tabBarIcon: ({ color }) => <IconSymbol size={21} name="arrow.down.circle.fill" color={color} />,
        }}
      />
      <Tabs.Screen
        name="settings"
        options={{
          title: 'Settings',
          tabBarIcon: ({ color }) => <IconSymbol size={21} name="gearshape.fill" color={color} />,
        }}
      />
    </Tabs>
  );
}



