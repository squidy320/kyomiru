import { colors, shadow } from '@/lib/theme';
import React from 'react';
import { ActivityIndicator, FlatList, Modal, StyleSheet, Text, TouchableOpacity, View } from 'react-native';
import LiquidGlassView from '@/components/liquid-glass-view';

type Source = {
  url: string;
  quality?: string;
  format?: string;
  subOrDub?: string;
  headers?: Record<string, string>;
};

type Props = {
  visible: boolean;
  onClose: () => void;
  sources: Source[];
  onSelect: (source: Source) => void;
  loading?: boolean;
  title?: string;
};

export default function StreamPicker({ visible, onClose, sources, onSelect, title, loading = false }: Props) {
  return (
    <Modal visible={visible} animationType="slide" transparent onRequestClose={onClose}>
      <View style={styles.backdrop}>
        <LiquidGlassView effect="regular" interactive style={[styles.sheet, shadow]}>
          <Text style={styles.header}>{title ?? 'Select Stream'}</Text>
          {loading ? (
            <View style={{ paddingVertical: 28, alignItems: 'center' }}>
              <ActivityIndicator color={colors.accent} />
            </View>
          ) : (
          <FlatList
            data={sources}
            keyExtractor={(item, idx) => item.url + idx}
            renderItem={({ item }) => (
              <TouchableOpacity style={styles.option} onPress={() => onSelect(item)}>
                <View style={styles.optionLeft}>
                  <Text style={styles.quality}>{item.quality ?? 'auto'}</Text>
                  <Text style={styles.meta}>{item.format ?? 'mp4'}</Text>
                </View>
                <Text style={styles.subdub}>{(item.subOrDub ?? 'sub').toUpperCase()}</Text>
              </TouchableOpacity>
            )}
            ItemSeparatorComponent={() => <View style={styles.sep} />}
          />
          )}
          <TouchableOpacity style={styles.closeButton} onPress={onClose}>
            <Text style={styles.closeText}>Cancel</Text>
          </TouchableOpacity>
        </LiquidGlassView>
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: { flex: 1, backgroundColor: 'rgba(0,0,0,0.6)', justifyContent: 'flex-end' },
  sheet: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: colors.borderSoft,
    padding: 16,
    borderTopLeftRadius: 20,
    borderTopRightRadius: 20,
    maxHeight: '60%',
  },
  header: { color: colors.text, fontSize: 18, fontWeight: '800', marginBottom: 12 },
  option: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 12,
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'space-between',
    paddingVertical: 12,
    paddingHorizontal: 12,
  },
  optionLeft: { flexDirection: 'row', gap: 8, alignItems: 'center' },
  quality: { color: colors.text, fontWeight: '800', fontSize: 16 },
  meta: { color: colors.textMuted, fontSize: 13, marginLeft: 8 },
  subdub: { color: colors.accent, fontWeight: '800' },
  sep: { height: 1, backgroundColor: colors.border, marginVertical: 4 },
  closeButton: {
    backgroundColor: 'transparent',
    borderWidth: 1,
    borderColor: colors.borderSoft,
    borderRadius: 12,
    marginTop: 8,
    alignItems: 'center',
    paddingVertical: 10,
  },
  closeText: { color: colors.textMuted },
});
