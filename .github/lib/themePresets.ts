import { useMemo } from 'react';
import { useUIAppearance } from '@/lib/uiAppearance';

type ThemeColors = {
  accent: string;
  accentSoft: string;
  accentGradient: [string, string];
  background: string;
};

const PRESETS: Record<string, ThemeColors> = {
  midnight: {
    accent: '#8b5cf6',
    accentSoft: 'rgba(139,92,246,0.22)',
    accentGradient: ['#8b5cf6', '#a78bfa'],
    background: '#0a0a0f',
  },
  ocean: {
    accent: '#22d3ee',
    accentSoft: 'rgba(34,211,238,0.2)',
    accentGradient: ['#0ea5e9', '#22d3ee'],
    background: '#07111a',
  },
  rose: {
    accent: '#fb7185',
    accentSoft: 'rgba(251,113,133,0.2)',
    accentGradient: ['#f43f5e', '#fb7185'],
    background: '#12070c',
  },
  emerald: {
    accent: '#34d399',
    accentSoft: 'rgba(52,211,153,0.2)',
    accentGradient: ['#10b981', '#34d399'],
    background: '#07130f',
  },
  sunset: {
    accent: '#f59e0b',
    accentSoft: 'rgba(245,158,11,0.22)',
    accentGradient: ['#f97316', '#f59e0b'],
    background: '#130d07',
  },
};

export function useThemePresetColors() {
  const { themePreset, oledMode } = useUIAppearance();
  return useMemo(() => {
    const preset = PRESETS[themePreset] ?? PRESETS.midnight;
    return {
      ...preset,
      background: oledMode ? '#000000' : preset.background,
    };
  }, [themePreset, oledMode]);
}

