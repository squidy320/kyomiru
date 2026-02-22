import React from 'react';
import { Alert, ScrollView, StyleSheet, Text, TouchableOpacity, View } from 'react-native';

import GlassSurface from '@/components/ui/glass-surface';
import { useAniListAuth } from '@/lib/anilistAuth';
import { colors, glassButton, glassCardElevated, shadow } from '@/lib/theme';

export default function AccountSettingsScreen() {
  const { clearAllAuthData, login, logout, accessToken } = useAniListAuth();
  const [clearingAuth, setClearingAuth] = React.useState(false);

  const onDeleteAllAuthData = React.useCallback(() => {
    Alert.alert(
      'Delete All Auth Data',
      'This will sign you out and clear saved AniList auth data on this device.',
      [
        { text: 'Cancel', style: 'cancel' },
        {
          text: 'Delete',
          style: 'destructive',
          onPress: async () => {
            if (clearingAuth) return;
            setClearingAuth(true);
            try {
              await clearAllAuthData();
              Alert.alert('Done', 'All saved auth data was deleted.');
            } catch (error: any) {
              Alert.alert('Failed', String(error?.message ?? error ?? 'Could not clear auth data.'));
            } finally {
              setClearingAuth(false);
            }
          },
        },
      ]
    );
  }, [clearAllAuthData, clearingAuth]);

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>AniList Account</Text>
        <Text style={styles.cardSub}>
          Status: {accessToken ? 'Connected' : 'Not connected'}
        </Text>
        <View style={styles.rowButtons}>
          <TouchableOpacity style={[styles.actionButton, glassButton]} onPress={login}>
            <Text style={styles.actionText}>Connect / Reconnect</Text>
          </TouchableOpacity>
          <TouchableOpacity style={[styles.actionButton, glassButton]} onPress={logout}>
            <Text style={styles.actionText}>Logout</Text>
          </TouchableOpacity>
        </View>
      </GlassSurface>

      <GlassSurface style={[styles.card, glassCardElevated, shadow]}>
        <Text style={styles.cardTitle}>Local Data</Text>
        <Text style={styles.cardSub}>This only clears auth data on this device.</Text>
        <TouchableOpacity
          style={[styles.deleteButton, glassButton, clearingAuth && { opacity: 0.6 }]}
          disabled={clearingAuth}
          onPress={onDeleteAllAuthData}
        >
          <Text style={styles.deleteText}>{clearingAuth ? 'Deleting...' : 'Delete All Auth Data'}</Text>
        </TouchableOpacity>
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
  rowButtons: { flexDirection: 'row', flexWrap: 'wrap', gap: 8 },
  actionButton: { paddingHorizontal: 12, paddingVertical: 8 },
  actionText: { color: colors.text, fontSize: 12, fontWeight: '700' },
  deleteButton: {
    alignSelf: 'flex-start',
    borderColor: '#8f1d24',
    backgroundColor: 'rgba(143,29,36,0.25)',
    paddingHorizontal: 12,
    paddingVertical: 10,
  },
  deleteText: { color: '#ffd7da', fontSize: 12, fontWeight: '800', letterSpacing: 0.2 },
});
