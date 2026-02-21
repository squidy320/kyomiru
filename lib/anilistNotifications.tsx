import * as Notifications from 'expo-notifications';
import * as SecureStore from 'expo-secure-store';
import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import { AppState, AppStateStatus, Platform } from 'react-native';

import { fetchAniListNotifications } from '@/lib/anilist';
import { useAniListAuth } from '@/lib/anilistAuth';

type AniListNotificationsContextType = {
  unreadDot: boolean;
  unreadCount: number;
  clearUnreadDot: () => Promise<void>;
  refreshNotificationsStatus: () => Promise<void>;
};

const AniListNotificationsContext = createContext<AniListNotificationsContextType | undefined>(undefined);

const LAST_NOTIFIED_ID_KEY = 'anilist_last_notified_notification_id';
const LAST_SEEN_ID_KEY = 'anilist_last_seen_notification_id';
const POLL_INTERVAL_MS = 2 * 60 * 1000;

Notifications.setNotificationHandler({
  handleNotification: async () => ({
    shouldShowBanner: true,
    shouldShowList: true,
    shouldPlaySound: false,
    shouldSetBadge: false,
  }),
});

export function AniListNotificationsProvider({ children }: { children: React.ReactNode }) {
  const { accessToken } = useAniListAuth();
  const [unreadDot, setUnreadDot] = useState(false);
  const [unreadCount, setUnreadCount] = useState(0);
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);
  const pollingRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const checkingRef = useRef(false);

  const requestPermissionsIfNeeded = useCallback(async () => {
    try {
      const existing = await Notifications.getPermissionsAsync();
      if (!existing.granted) {
        await Notifications.requestPermissionsAsync();
      }
      if (Platform.OS === 'android') {
        await Notifications.setNotificationChannelAsync('anilist-airing', {
          name: 'AniList Airing',
          importance: Notifications.AndroidImportance.HIGH,
          vibrationPattern: [0, 200, 200, 200],
          lockscreenVisibility: Notifications.AndroidNotificationVisibility.PUBLIC,
        });
      }
    } catch {}
  }, []);

  const clearUnreadDot = useCallback(async () => {
    setUnreadDot(false);
    try {
      const lastNotified = Number(await SecureStore.getItemAsync(LAST_NOTIFIED_ID_KEY));
      if (Number.isFinite(lastNotified) && lastNotified > 0) {
        await SecureStore.setItemAsync(LAST_SEEN_ID_KEY, String(lastNotified));
      }
    } catch {}
  }, []);

  const refreshNotificationsStatus = useCallback(async () => {
    if (!accessToken || checkingRef.current || appStateRef.current !== 'active') return;
    checkingRef.current = true;
    try {
      const data = await fetchAniListNotifications(accessToken, 1, 20);
      setUnreadCount(Math.max(0, Number(data.unreadCount || 0)));

      const notifications = Array.isArray(data.notifications) ? data.notifications : [];
      const airing = notifications.filter((n) => String(n.type ?? '').toUpperCase() === 'AIRING');
      const latestId = airing.reduce((m, n) => Math.max(m, Number(n.id || 0)), 0);
      if (!Number.isFinite(latestId) || latestId <= 0) return;

      const lastNotified = Number(await SecureStore.getItemAsync(LAST_NOTIFIED_ID_KEY));
      const lastSeen = Number(await SecureStore.getItemAsync(LAST_SEEN_ID_KEY));

      // First run: establish baseline without spamming old alerts.
      if (!Number.isFinite(lastNotified) || lastNotified <= 0) {
        await SecureStore.setItemAsync(LAST_NOTIFIED_ID_KEY, String(latestId));
        await SecureStore.setItemAsync(LAST_SEEN_ID_KEY, String(latestId));
        setUnreadDot(false);
        return;
      }

      const newAiring = airing
        .filter((n) => Number(n.id || 0) > lastNotified)
        .sort((a, b) => Number(a.createdAt || 0) - Number(b.createdAt || 0));

      if (newAiring.length > 0) {
        await requestPermissionsIfNeeded();
        for (const notification of newAiring) {
          const animeTitle =
            notification.media?.title?.english ??
            notification.media?.title?.romaji ??
            notification.media?.title?.native ??
            'Anime';
          const ep = Number(notification.episode || 0);
          const body = ep > 0 ? `Episode ${ep} is out now.` : 'A new episode is out now.';
          await Notifications.scheduleNotificationAsync({
            content: {
              title: animeTitle,
              body,
              data: {
                type: 'anilist-airing',
                animeId: notification.media?.id ?? null,
                notificationId: notification.id,
              },
            },
            trigger: null,
          });
        }
        await SecureStore.setItemAsync(LAST_NOTIFIED_ID_KEY, String(latestId));
      }

      const effectiveLastSeen =
        Number.isFinite(lastSeen) && lastSeen > 0 ? lastSeen : Number(lastNotified || 0);
      setUnreadDot(latestId > effectiveLastSeen);
    } catch (error) {
      console.warn('[AniListNotifications] refresh failed:', error);
    } finally {
      checkingRef.current = false;
    }
  }, [accessToken, requestPermissionsIfNeeded]);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (state) => {
      appStateRef.current = state;
      if (state === 'active') {
        void refreshNotificationsStatus();
      }
    });
    return () => sub.remove();
  }, [refreshNotificationsStatus]);

  useEffect(() => {
    if (!accessToken) {
      setUnreadCount(0);
      setUnreadDot(false);
      if (pollingRef.current) clearInterval(pollingRef.current);
      pollingRef.current = null;
      return;
    }
    void refreshNotificationsStatus();
    if (pollingRef.current) clearInterval(pollingRef.current);
    pollingRef.current = setInterval(() => {
      void refreshNotificationsStatus();
    }, POLL_INTERVAL_MS);
    return () => {
      if (pollingRef.current) clearInterval(pollingRef.current);
      pollingRef.current = null;
    };
  }, [accessToken, refreshNotificationsStatus]);

  const value = useMemo(
    () => ({
      unreadDot,
      unreadCount,
      clearUnreadDot,
      refreshNotificationsStatus,
    }),
    [unreadDot, unreadCount, clearUnreadDot, refreshNotificationsStatus]
  );

  return (
    <AniListNotificationsContext.Provider value={value}>
      {children}
    </AniListNotificationsContext.Provider>
  );
}

export function useAniListNotifications() {
  const ctx = useContext(AniListNotificationsContext);
  if (!ctx) {
    throw new Error('useAniListNotifications must be used within AniListNotificationsProvider');
  }
  return ctx;
}

