import { Platform } from 'react-native';

const glassSurfaceColor = Platform.OS === 'ios' ? 'rgba(10,12,18,0.84)' : 'rgba(20,20,28,0.88)';
const glassElevatedColor = Platform.OS === 'ios' ? 'rgba(12,14,22,0.90)' : 'rgba(24,24,34,0.93)';
const glassSoftColor = Platform.OS === 'ios' ? 'rgba(16,18,28,0.80)' : 'rgba(28,28,40,0.86)';
const glassInputColor = Platform.OS === 'ios' ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.08)';
const glassTabBarColor = Platform.OS === 'ios' ? 'rgba(8,10,16,0.86)' : 'rgba(10,12,18,0.92)';

export const colors = {
  background: '#0a0a0f',
  backgroundSecondary: '#0f0f15',
  surface: glassSurfaceColor,
  surfaceSoft: glassSoftColor,
  surfaceElevated: glassElevatedColor,
  border: 'rgba(255,255,255,0.12)',
  borderSoft: 'rgba(255,255,255,0.08)',
  accent: '#8b5cf6',
  accentSoft: 'rgba(139,92,246,0.2)',
  accentGradient: ['#8b5cf6', '#a78bfa'],
  text: '#ffffff',
  textSecondary: '#e4e4e7',
  textMuted: '#a1a1aa',
  textDim: '#71717a',
  inputGlass: glassInputColor,
  tabBarGlass: glassTabBarColor,
};

export const glassCard = {
  backgroundColor: colors.surface,
  borderWidth: 1,
  borderColor: colors.border,
  borderRadius: 20,
};

export const glassCardElevated = {
  backgroundColor: colors.surfaceElevated,
  borderWidth: 1,
  borderColor: colors.border,
  borderRadius: 20,
};

export const glassButton = {
  backgroundColor: colors.surfaceSoft,
  borderWidth: 1,
  borderColor: colors.border,
  borderRadius: 14,
};

export const glassInput = {
  backgroundColor: colors.inputGlass,
  borderWidth: 1,
  borderColor: colors.borderSoft,
  borderRadius: 10,
};

export const tabBarGlass = {
  backgroundColor: colors.tabBarGlass,
  borderWidth: 1,
  borderColor: colors.border,
  borderRadius: 24,
};

export const shadow = {
  shadowColor: '#000',
  shadowOpacity: 0.4,
  shadowRadius: 20,
  shadowOffset: { width: 0, height: 8 },
  elevation: 10,
};

export const shadowLarge = {
  shadowColor: '#000',
  shadowOpacity: 0.5,
  shadowRadius: 30,
  shadowOffset: { width: 0, height: 12 },
  elevation: 15,
};

export const pill = {
  backgroundColor: colors.accentSoft,
  borderRadius: 999,
  borderWidth: 1,
  borderColor: 'rgba(139,92,246,0.4)',
};
