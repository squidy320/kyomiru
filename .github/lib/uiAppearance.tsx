import * as SecureStore from 'expo-secure-store';
import React, { createContext, useContext, useEffect, useMemo, useState } from 'react';
import { AccessibilityInfo, Platform } from 'react-native';
import { isGlassEffectAPIAvailable, isLiquidGlassAvailable } from 'expo-glass-effect';

type GlassIntensity = 'low' | 'medium' | 'high';
type LiquidGlassMode = 'auto' | 'off';
type LibraryListOrganization = 'anilist' | 'alphabetical' | 'status-flow';
type LibrarySortType = 'recently-added' | 'rating' | 'title';
type StreamSelectionMode = 'auto' | 'ask-every-time';
type StreamQualityPreference = 'auto' | '1080p' | '720p' | '480p' | '360p';
type StreamLanguagePreference = 'sub' | 'dub' | 'any';
type ThemePreset = 'midnight' | 'ocean' | 'rose' | 'emerald' | 'sunset';
type PlayerFitMode = 'contain' | 'cover';
type PlayerControlStyle = 'glass' | 'solid';
type PlayerSkipSeconds = 5 | 10 | 15 | 30;
type PlayerAutoHideSeconds = 2 | 3 | 5 | 8;

type UIAppearanceSettings = {
  liquidGlassMode: LiquidGlassMode;
  glassIntensity: GlassIntensity;
  compactTabBar: boolean;
  touchOutline: boolean;
  libraryListOrganization: LibraryListOrganization;
  librarySortType: LibrarySortType;
  streamSelectionMode: StreamSelectionMode;
  defaultStreamQuality: StreamQualityPreference;
  defaultStreamLanguage: StreamLanguagePreference;
  themePreset: ThemePreset;
  oledMode: boolean;
  playerFitMode: PlayerFitMode;
  playerControlStyle: PlayerControlStyle;
  playerSkipSeconds: PlayerSkipSeconds;
  playerAutoHideSeconds: PlayerAutoHideSeconds;
  playerShowMeta: boolean;
};

type UIAppearanceContextValue = UIAppearanceSettings & {
  supportsLiquidGlass: boolean;
  isReduceTransparencyEnabled: boolean;
  liquidGlassActive: boolean;
  setLiquidGlassMode: (mode: LiquidGlassMode) => void;
  setGlassIntensity: (intensity: GlassIntensity) => void;
  setCompactTabBar: (value: boolean) => void;
  setTouchOutline: (value: boolean) => void;
  setLibraryListOrganization: (value: LibraryListOrganization) => void;
  setLibrarySortType: (value: LibrarySortType) => void;
  setStreamSelectionMode: (value: StreamSelectionMode) => void;
  setDefaultStreamQuality: (value: StreamQualityPreference) => void;
  setDefaultStreamLanguage: (value: StreamLanguagePreference) => void;
  setThemePreset: (value: ThemePreset) => void;
  setOledMode: (value: boolean) => void;
  setPlayerFitMode: (value: PlayerFitMode) => void;
  setPlayerControlStyle: (value: PlayerControlStyle) => void;
  setPlayerSkipSeconds: (value: PlayerSkipSeconds) => void;
  setPlayerAutoHideSeconds: (value: PlayerAutoHideSeconds) => void;
  setPlayerShowMeta: (value: boolean) => void;
  resetAppearanceSettings: () => void;
};

const STORAGE_KEY = 'ui_appearance_settings_v2';

const DEFAULTS: UIAppearanceSettings = {
  liquidGlassMode: 'auto',
  glassIntensity: 'medium',
  compactTabBar: true,
  touchOutline: true,
  libraryListOrganization: 'anilist',
  librarySortType: 'recently-added',
  streamSelectionMode: 'auto',
  defaultStreamQuality: 'auto',
  defaultStreamLanguage: 'sub',
  themePreset: 'midnight',
  oledMode: true,
  playerFitMode: 'contain',
  playerControlStyle: 'glass',
  playerSkipSeconds: 10,
  playerAutoHideSeconds: 3,
  playerShowMeta: true,
};

const UIAppearanceContext = createContext<UIAppearanceContextValue | null>(null);

export function UIAppearanceProvider({ children }: { children: React.ReactNode }) {
  const iosMajor =
    Platform.OS === 'ios'
      ? Number(String(Platform.Version).split('.')[0] ?? 0)
      : 0;
  const nativeLiquidGlassAvailable = (() => {
    if (Platform.OS !== 'ios') return false;
    try {
      return isLiquidGlassAvailable() || isGlassEffectAPIAvailable();
    } catch {
      return false;
    }
  })();
  const supportsLiquidGlass =
    Platform.OS === 'ios' && (nativeLiquidGlassAvailable || iosMajor >= 26);
  const [settings, setSettings] = useState<UIAppearanceSettings>(DEFAULTS);
  const [isReduceTransparencyEnabled, setIsReduceTransparencyEnabled] = useState(false);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const raw = await SecureStore.getItemAsync(STORAGE_KEY);
        if (!raw || cancelled) return;
        const parsed = JSON.parse(raw) as Partial<UIAppearanceSettings>;
        setSettings((prev) => ({
          liquidGlassMode:
            parsed.liquidGlassMode === 'off' || parsed.liquidGlassMode === 'auto'
              ? parsed.liquidGlassMode
              : prev.liquidGlassMode,
          glassIntensity:
            parsed.glassIntensity === 'low' ||
            parsed.glassIntensity === 'medium' ||
            parsed.glassIntensity === 'high'
              ? parsed.glassIntensity
              : prev.glassIntensity,
          compactTabBar:
            typeof parsed.compactTabBar === 'boolean' ? parsed.compactTabBar : prev.compactTabBar,
          touchOutline:
            typeof parsed.touchOutline === 'boolean' ? parsed.touchOutline : prev.touchOutline,
          libraryListOrganization:
            parsed.libraryListOrganization === 'anilist' ||
            parsed.libraryListOrganization === 'alphabetical' ||
            parsed.libraryListOrganization === 'status-flow'
              ? parsed.libraryListOrganization
              : prev.libraryListOrganization,
          librarySortType:
            parsed.librarySortType === 'recently-added' ||
            parsed.librarySortType === 'rating' ||
            parsed.librarySortType === 'title'
              ? parsed.librarySortType
              : prev.librarySortType,
          streamSelectionMode:
            parsed.streamSelectionMode === 'auto' ||
            parsed.streamSelectionMode === 'ask-every-time'
              ? parsed.streamSelectionMode
              : prev.streamSelectionMode,
          defaultStreamQuality:
            parsed.defaultStreamQuality === 'auto' ||
            parsed.defaultStreamQuality === '1080p' ||
            parsed.defaultStreamQuality === '720p' ||
            parsed.defaultStreamQuality === '480p' ||
            parsed.defaultStreamQuality === '360p'
              ? parsed.defaultStreamQuality
              : prev.defaultStreamQuality,
          defaultStreamLanguage:
            parsed.defaultStreamLanguage === 'sub' ||
            parsed.defaultStreamLanguage === 'dub' ||
            parsed.defaultStreamLanguage === 'any'
              ? parsed.defaultStreamLanguage
              : prev.defaultStreamLanguage,
          themePreset:
            parsed.themePreset === 'midnight' ||
            parsed.themePreset === 'ocean' ||
            parsed.themePreset === 'rose' ||
            parsed.themePreset === 'emerald' ||
            parsed.themePreset === 'sunset'
              ? parsed.themePreset
              : prev.themePreset,
          oledMode:
            typeof parsed.oledMode === 'boolean' ? parsed.oledMode : prev.oledMode,
          playerFitMode:
            parsed.playerFitMode === 'contain' || parsed.playerFitMode === 'cover'
              ? parsed.playerFitMode
              : prev.playerFitMode,
          playerControlStyle:
            parsed.playerControlStyle === 'glass' || parsed.playerControlStyle === 'solid'
              ? parsed.playerControlStyle
              : prev.playerControlStyle,
          playerSkipSeconds:
            parsed.playerSkipSeconds === 5 ||
            parsed.playerSkipSeconds === 10 ||
            parsed.playerSkipSeconds === 15 ||
            parsed.playerSkipSeconds === 30
              ? parsed.playerSkipSeconds
              : prev.playerSkipSeconds,
          playerAutoHideSeconds:
            parsed.playerAutoHideSeconds === 2 ||
            parsed.playerAutoHideSeconds === 3 ||
            parsed.playerAutoHideSeconds === 5 ||
            parsed.playerAutoHideSeconds === 8
              ? parsed.playerAutoHideSeconds
              : prev.playerAutoHideSeconds,
          playerShowMeta:
            typeof parsed.playerShowMeta === 'boolean'
              ? parsed.playerShowMeta
              : prev.playerShowMeta,
        }));
      } catch (e) {
        console.warn('Failed to load UI appearance settings', e);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    SecureStore.setItemAsync(STORAGE_KEY, JSON.stringify(settings)).catch((e) =>
      console.warn('Failed to persist UI appearance settings', e)
    );
  }, [settings]);

  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceTransparencyEnabled()
      .then((enabled) => {
        if (mounted) setIsReduceTransparencyEnabled(!!enabled);
      })
      .catch(() => {});
    const sub = AccessibilityInfo.addEventListener('reduceTransparencyChanged', (enabled) => {
      setIsReduceTransparencyEnabled(!!enabled);
    });
    return () => {
      mounted = false;
      sub.remove();
    };
  }, []);

  const liquidGlassActive =
    supportsLiquidGlass && !isReduceTransparencyEnabled && settings.liquidGlassMode !== 'off';

  const value = useMemo<UIAppearanceContextValue>(
    () => ({
      ...settings,
      supportsLiquidGlass,
      isReduceTransparencyEnabled,
      liquidGlassActive,
      setLiquidGlassMode: (liquidGlassMode) => setSettings((s) => ({ ...s, liquidGlassMode })),
      setGlassIntensity: (glassIntensity) => setSettings((s) => ({ ...s, glassIntensity })),
      setCompactTabBar: (compactTabBar) => setSettings((s) => ({ ...s, compactTabBar })),
      setTouchOutline: (touchOutline) => setSettings((s) => ({ ...s, touchOutline })),
      setLibraryListOrganization: (libraryListOrganization) =>
        setSettings((s) => ({ ...s, libraryListOrganization })),
      setLibrarySortType: (librarySortType) => setSettings((s) => ({ ...s, librarySortType })),
      setStreamSelectionMode: (streamSelectionMode) =>
        setSettings((s) => ({ ...s, streamSelectionMode })),
      setDefaultStreamQuality: (defaultStreamQuality) =>
        setSettings((s) => ({ ...s, defaultStreamQuality })),
      setDefaultStreamLanguage: (defaultStreamLanguage) =>
        setSettings((s) => ({ ...s, defaultStreamLanguage })),
      setThemePreset: (themePreset) => setSettings((s) => ({ ...s, themePreset })),
      setOledMode: (oledMode) => setSettings((s) => ({ ...s, oledMode })),
      setPlayerFitMode: (playerFitMode) => setSettings((s) => ({ ...s, playerFitMode })),
      setPlayerControlStyle: (playerControlStyle) =>
        setSettings((s) => ({ ...s, playerControlStyle })),
      setPlayerSkipSeconds: (playerSkipSeconds) =>
        setSettings((s) => ({ ...s, playerSkipSeconds })),
      setPlayerAutoHideSeconds: (playerAutoHideSeconds) =>
        setSettings((s) => ({ ...s, playerAutoHideSeconds })),
      setPlayerShowMeta: (playerShowMeta) =>
        setSettings((s) => ({ ...s, playerShowMeta })),
      resetAppearanceSettings: () => setSettings(DEFAULTS),
    }),
    [settings, supportsLiquidGlass, isReduceTransparencyEnabled, liquidGlassActive]
  );

  return <UIAppearanceContext.Provider value={value}>{children}</UIAppearanceContext.Provider>;
}

export function useUIAppearance() {
  const ctx = useContext(UIAppearanceContext);
  if (!ctx) {
    throw new Error('useUIAppearance must be used within UIAppearanceProvider');
  }
  return ctx;
}
