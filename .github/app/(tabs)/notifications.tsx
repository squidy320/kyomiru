import React from 'react';
import { useFocusEffect } from '@react-navigation/native';
import {
  ActivityIndicator,
  FlatList,
  Image,
  RefreshControl,
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from 'react-native';

import { AniListNotification, fetchAniListNotifications } from '@/lib/anilist';
import { useAniListAuth } from '@/lib/anilistAuth';
import { useAniListNotifications } from '@/lib/anilistNotifications';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';

function titleFromMedia(notification: AniListNotification) {
  return (
    notification.media?.title?.english ??
    notification.media?.title?.romaji ??
    notification.media?.title?.native ??
    'Unknown Title'
  );
}

function toRelativeTime(tsSeconds: number) {
  const delta = Math.max(0, Math.floor(Date.now() / 1000) - Math.floor(tsSeconds || 0));
  if (delta < 60) return `${delta}s ago`;
  const min = Math.floor(delta / 60);
  if (min < 60) return `${min}m ago`;
  const hr = Math.floor(min / 60);
  if (hr < 24) return `${hr}h ago`;
  const day = Math.floor(hr / 24);
  return `${day}d ago`;
}

function summaryText(notification: AniListNotification) {
  const type = String(notification.type ?? '');
  if (type === 'AIRING') {
    const ep = Number(notification.episode ?? 0);
    const t = titleFromMedia(notification);
    return ep > 0 ? `${t} aired episode ${ep}` : `${t} has a new airing update`;
  }
  const user = String(notification.user?.name ?? '').trim();
  const context = String(notification.context ?? '').trim();
  if (user && context) return `${user} ${context}`;
  if (context) return context;
  if (user) return `${user} sent an update`;
  return type || 'Notification';
}

export default function NotificationsScreen() {
  const { accessToken, login } = useAniListAuth();
  const { clearUnreadDot, refreshNotificationsStatus } = useAniListNotifications();
  const [items, setItems] = React.useState<AniListNotification[]>([]);
  const [unreadCount, setUnreadCount] = React.useState(0);
  const [loading, setLoading] = React.useState(false);
  const [refreshing, setRefreshing] = React.useState(false);

  const load = React.useCallback(
    async (isRefresh = false) => {
      if (!accessToken) {
        setItems([]);
        setUnreadCount(0);
        return;
      }
      if (isRefresh) setRefreshing(true);
      else setLoading(true);
      try {
        const data = await fetchAniListNotifications(accessToken, 1, 40);
        setItems(data.notifications);
        setUnreadCount(data.unreadCount);
      } catch (e) {
        console.error('[Notifications] Failed to fetch AniList notifications:', e);
      } finally {
        setLoading(false);
        setRefreshing(false);
      }
    },
    [accessToken]
  );

  React.useEffect(() => {
    void load();
  }, [load]);

  useFocusEffect(
    React.useCallback(() => {
      void clearUnreadDot();
      void refreshNotificationsStatus();
      void load();
    }, [clearUnreadDot, refreshNotificationsStatus, load])
  );

  if (!accessToken) {
    return (
      <View style={styles.container}>
        <View style={styles.noAuthWrap}>
          <Text style={styles.title}>Notifications</Text>
          <Text style={styles.subtitle}>Sign in with AniList to see your account notifications.</Text>
          <TouchableOpacity style={[styles.connectBtn, glassButton]} onPress={login} activeOpacity={0.86}>
            <Text style={styles.connectBtnText}>Connect AniList</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      <FlatList
        data={items}
        keyExtractor={(item) => String(item.id)}
        contentContainerStyle={styles.content}
        refreshControl={<RefreshControl refreshing={refreshing} onRefresh={() => void load(true)} />}
        ListHeaderComponent={
          <View style={styles.header}>
            <View>
              <Text style={styles.title}>Notifications</Text>
              <Text style={styles.subtitle}>AniList unread: {unreadCount}</Text>
            </View>
          </View>
        }
        ListEmptyComponent={
          loading ? (
            <View style={styles.center}>
              <ActivityIndicator color={colors.accent} />
            </View>
          ) : (
            <View style={styles.center}>
              <Text style={styles.emptyText}>No notifications right now.</Text>
            </View>
          )
        }
        renderItem={({ item }) => {
          const cover = item.media?.coverImage?.large ?? item.user?.avatar?.large ?? null;
          return (
            <View style={[styles.card, glassCardElevated, shadow]}>
              {cover ? <Image source={{ uri: cover }} style={styles.thumb} /> : <View style={styles.thumbFallback} />}
              <View style={styles.cardBody}>
                <Text style={styles.cardText}>{summaryText(item)}</Text>
                <Text style={styles.cardMeta}>
                  {String(item.type || '').toLowerCase()} • {toRelativeTime(item.createdAt)}
                </Text>
              </View>
            </View>
          );
        }}
      />
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
    paddingBottom: 110,
    gap: 10,
  },
  header: {
    marginBottom: 8,
  },
  title: {
    color: colors.text,
    fontSize: 34,
    fontWeight: '900',
    letterSpacing: -0.8,
  },
  subtitle: {
    marginTop: 6,
    color: colors.textMuted,
    fontSize: 14,
    fontWeight: '500',
  },
  card: {
    borderRadius: 14,
    padding: 10,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
  },
  thumb: {
    width: 56,
    height: 56,
    borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  thumbFallback: {
    width: 56,
    height: 56,
    borderRadius: 10,
    backgroundColor: 'rgba(255,255,255,0.08)',
  },
  cardBody: {
    flex: 1,
  },
  cardText: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
    lineHeight: 18,
  },
  cardMeta: {
    marginTop: 4,
    color: colors.textMuted,
    fontSize: 11,
    fontWeight: '600',
  },
  center: {
    paddingVertical: 28,
    alignItems: 'center',
  },
  emptyText: {
    color: colors.textMuted,
    fontSize: 13,
    fontWeight: '600',
  },
  noAuthWrap: {
    paddingHorizontal: 16,
    paddingTop: 56,
    paddingBottom: 90,
    gap: 14,
  },
  connectBtn: {
    paddingHorizontal: 16,
    paddingVertical: 10,
    alignSelf: 'flex-start',
  },
  connectBtnText: {
    color: colors.text,
    fontSize: 13,
    fontWeight: '700',
  },
});
