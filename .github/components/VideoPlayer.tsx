import MaterialIcons from '@expo/vector-icons/MaterialIcons';
import { useEventListener } from 'expo';
import { isPictureInPictureSupported, useVideoPlayer, VideoView } from 'expo-video';
import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator,
  Animated,
  AppState,
  AppStateStatus,
  Keyboard,
  Modal,
  Platform,
  Pressable,
  SafeAreaView,
  StyleSheet,
  Text,
  TouchableOpacity,
  useWindowDimensions,
  View,
} from 'react-native';
import { useSafeAreaInsets } from 'react-native-safe-area-context';
import LiquidGlassView from '@/components/liquid-glass-view';
import { useUIAppearance } from '@/lib/uiAppearance';

type Props = {
  visible: boolean;
  onClose: () => void;
  sourceUrl: string;
  sourceHeaders?: Record<string, string>;
  sourceFormat?: string;
  introStartSec?: number;
  introEndSec?: number;
  title: string;
  resumePositionSec?: number;
  onProgressSave?: (positionSec: number, durationSec: number) => void;
  onWatchedNearlyAll: () => void;
  onPlaybackError?: (message?: string) => void;
  watchedThreshold?: number;
  loadingOverlay?: boolean;
  onPlaybackEnded?: () => void;
};

const clamp = (v: number, min: number, max: number) => Math.max(min, Math.min(max, v));

const formatClock = (seconds: number) => {
  const safe = Math.max(0, Math.floor(Number.isFinite(seconds) ? seconds : 0));
  const h = Math.floor(safe / 3600);
  const m = Math.floor((safe % 3600) / 60);
  const s = safe % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
  return `${String(m).padStart(2, '0')}:${String(s).padStart(2, '0')}`;
};

export function VideoPlayer({
  visible,
  onClose,
  sourceUrl,
  sourceHeaders,
  sourceFormat,
  introStartSec,
  introEndSec,
  title,
  resumePositionSec,
  onProgressSave,
  onWatchedNearlyAll,
  onPlaybackError,
  watchedThreshold = 0.85,
  loadingOverlay,
  onPlaybackEnded,
}: Props) {
  const isAndroid = Platform.OS === 'android';
  const { width: viewportWidth, height: viewportHeight } = useWindowDimensions();
  const insets = useSafeAreaInsets();
  const {
    playerFitMode,
    playerSkipSeconds,
    playerAutoHideSeconds,
    playerShowMeta,
    playerControlStyle,
  } = useUIAppearance();
  const videoContentFit: 'contain' | 'cover' = playerFitMode;
  const [isReadyToPlay, setIsReadyToPlay] = useState(false);
  const [supportsPip, setSupportsPip] = useState(false);
  const [isPlaying, setIsPlaying] = useState(false);
  const [controlsVisible, setControlsVisible] = useState(true);
  const [isScrubbing, setIsScrubbing] = useState(false);
  const [scrubRatio, setScrubRatio] = useState(0);
  const [currentTimeSec, setCurrentTimeSec] = useState(0);
  const [durationSec, setDurationSec] = useState(0);
  const [barWidth, setBarWidth] = useState(1);
  const [gestureWidth, setGestureWidth] = useState(1);
  const [hasTriggeredProgress, setHasTriggeredProgress] = useState(false);
  const [selectedPlaybackRate, setSelectedPlaybackRate] = useState(1);
  const [isSpeedHold, setIsSpeedHold] = useState(false);
  const autoHideTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const streamStallTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const pendingSeekTargetRef = useRef<number | null>(null);
  const desiredResumeSeekRef = useRef<number | null>(null);
  const resumeExactSeekDoneRef = useRef(false);
  const resumeSeekRetryCountRef = useRef(0);
  const resumeSeekVerifyTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const resumeSeekRetryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seekFlushTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seekRecoveryTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const seekRecoveryUntilRef = useRef(0);
  const lastSeekAtRef = useRef(0);
  const rapidSeekBurstRef = useRef(0);
  const lastSeekBurstAtRef = useRef(0);
  const softRecoverAttemptsRef = useRef(0);
  const lastHardErrorAtRef = useRef(0);
  const didLongPressSpeedRef = useRef(false);
  const speedHoldTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const controlsOpacity = useRef(new Animated.Value(1)).current;
  const initialSeekAppliedRef = useRef(false);
  const lastProgressSaveSecRef = useRef(-1);
  const wasPlayingBeforeBackgroundRef = useRef(false);
  const appStateRef = useRef<AppStateStatus>(AppState.currentState);
  const lastTapAtRef = useRef(0);
  const lastTapRegionRef = useRef<'left' | 'center' | 'right' | null>(null);
  const singleTapTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastUiSyncAtRef = useRef(0);
  const lastDurationSyncRef = useRef(0);
  const wasPlayingBeforeScrubRef = useRef(false);
  const lastLiveScrubSeekAtRef = useRef(0);

  const normalizedSourceUrl = useMemo(() => {
    const raw = String(sourceUrl ?? '').trim();
    if (!raw) return raw;
    if (/^[a-z][a-z0-9+.-]*:\/\//i.test(raw)) return raw;
    if (raw.startsWith('/')) return `file://${raw}`;
    return raw;
  }, [sourceUrl]);

  const isLocalSource = /^file:\/\//i.test(normalizedSourceUrl);
  const isHlsSource =
    String(sourceFormat ?? '').toLowerCase() === 'm3u8' || normalizedSourceUrl.includes('.m3u8');
  const isLikelyProgressiveSource =
    !isHlsSource &&
    (String(sourceFormat ?? '').toLowerCase() === 'mp4' ||
      String(sourceFormat ?? '').toLowerCase() === 'm4v' ||
      normalizedSourceUrl.includes('.mp4') ||
      normalizedSourceUrl.includes('.m4v'));
  // expo-video cache does not support HLS (.m3u8), only enable for progressive sources.
  const shouldUseCaching = !isLocalSource && isLikelyProgressiveSource;
  const seekDebounceMs = 90;
  const seekRecoveryWindowMs = 20000;
  const seekTransientErrorGraceMs = 6000;

  const source =
    visible && sourceUrl
      ? (() => {
          const next: any = { uri: normalizedSourceUrl };
          const headers = sourceHeaders ?? {};
          if (!isLocalSource && Object.keys(headers).length > 0) {
            next.headers = headers;
          }
          if (shouldUseCaching) next.useCaching = true;
          next.contentType =
            isHlsSource
              ? 'hls'
              : String(sourceFormat ?? '').toLowerCase() === 'mpd' || normalizedSourceUrl.includes('.mpd')
                ? 'dash'
                : undefined;
          next.mimeType =
            isHlsSource
              ? 'application/x-mpegURL'
              : String(sourceFormat ?? '').toLowerCase() === 'mp4' || normalizedSourceUrl.includes('.mp4')
                ? 'video/mp4'
                : undefined;
          if (isLocalSource && isHlsSource) {
            const slash = normalizedSourceUrl.lastIndexOf('/');
            if (slash > 0) {
              next.basePath = normalizedSourceUrl.slice(0, slash + 1);
            }
          }
          return next;
        })()
      : null;

  const player = useVideoPlayer(source, (p) => {
    p.play();
    p.staysActiveInBackground = true;
    p.timeUpdateEventInterval = isAndroid ? 1 : 0.25;
    p.bufferOptions = {
      preferredForwardBufferDuration: isHlsSource ? 240 : 1800,
      waitsToMinimizeStalling: true,
      minBufferForPlayback: 0.5,
      maxBufferBytes: isHlsSource ? 128 * 1024 * 1024 : 512 * 1024 * 1024,
      prioritizeTimeOverSizeThreshold: true,
    } as any;
  });

  useEffect(() => {
    if (visible && sourceUrl) {
      Keyboard.dismiss();
      setHasTriggeredProgress(false);
      setControlsVisible(true);
      setCurrentTimeSec(0);
      setDurationSec(0);
      initialSeekAppliedRef.current = false;
      desiredResumeSeekRef.current = null;
      resumeExactSeekDoneRef.current = false;
      resumeSeekRetryCountRef.current = 0;
      if (resumeSeekVerifyTimerRef.current) {
        clearTimeout(resumeSeekVerifyTimerRef.current);
        resumeSeekVerifyTimerRef.current = null;
      }
      if (resumeSeekRetryTimerRef.current) {
        clearTimeout(resumeSeekRetryTimerRef.current);
        resumeSeekRetryTimerRef.current = null;
      }
      lastProgressSaveSecRef.current = -1;
    }
  }, [visible, sourceUrl]);

  const persistProgressNow = useCallback(() => {
    if (!onProgressSave) return;
    const d = Number(player.duration || durationSec || 0);
    const t = Number(player.currentTime || currentTimeSec || 0);
    if (!(d > 0) || t < 0) return;
    onProgressSave(Math.floor(t), d);
  }, [onProgressSave, player, durationSec, currentTimeSec]);

  useEffect(() => {
    const sub = AppState.addEventListener('change', (nextState) => {
      const prev = appStateRef.current;
      appStateRef.current = nextState;
      if (!visible) return;
      if (nextState !== 'active') {
        persistProgressNow();
        wasPlayingBeforeBackgroundRef.current = !!player.playing;
        return;
      }
      if (prev !== 'active') {
        Keyboard.dismiss();
        setControlsVisible(true);
        if (wasPlayingBeforeBackgroundRef.current && player.status !== 'error') {
          setTimeout(() => {
            try {
              player.play();
            } catch {}
          }, 180);
        }
      }
    });
    return () => sub.remove();
  }, [player, visible, persistProgressNow]);

  useEffect(() => {
    if (!visible || !sourceUrl) {
      setIsReadyToPlay(false);
      setIsPlaying(false);
      setSelectedPlaybackRate(1);
      setIsSpeedHold(false);
      return;
    }
    setIsReadyToPlay(false);
    setSelectedPlaybackRate(1);
    setIsSpeedHold(false);
  }, [visible, sourceUrl]);

  useEffect(() => {
    Animated.timing(controlsOpacity, {
      toValue: controlsVisible ? 1 : 0,
      duration: controlsVisible ? 180 : 150,
      useNativeDriver: true,
    }).start();
  }, [controlsVisible, controlsOpacity]);

  useEffect(() => {
    if (!visible) return;
    // Rotation can invalidate touch/layout metrics; refresh interaction surfaces.
    setControlsVisible(true);
    setGestureWidth(1);
    setBarWidth(1);
  }, [visible, viewportWidth, viewportHeight]);

  useEffect(() => {
    let mounted = true;
    (async () => {
      try {
        const supported = await isPictureInPictureSupported();
        if (mounted) setSupportsPip(!!supported);
      } catch {
        if (mounted) setSupportsPip(false);
      }
    })();
    return () => {
      mounted = false;
    };
  }, []);

  useEffect(() => {
    if (autoHideTimerRef.current) clearTimeout(autoHideTimerRef.current);
    if (!visible || !isPlaying || !controlsVisible || isScrubbing) return;
    autoHideTimerRef.current = setTimeout(() => {
      setControlsVisible(false);
    }, playerAutoHideSeconds * 1000);
    return () => {
      if (autoHideTimerRef.current) clearTimeout(autoHideTimerRef.current);
    };
  }, [visible, isPlaying, controlsVisible, currentTimeSec, isScrubbing, playerAutoHideSeconds]);

  useEffect(() => {
    return () => {
      if (streamStallTimerRef.current) clearTimeout(streamStallTimerRef.current);
      if (resumeSeekVerifyTimerRef.current) clearTimeout(resumeSeekVerifyTimerRef.current);
      if (resumeSeekRetryTimerRef.current) clearTimeout(resumeSeekRetryTimerRef.current);
      if (seekFlushTimerRef.current) clearTimeout(seekFlushTimerRef.current);
      if (seekRecoveryTimerRef.current) clearTimeout(seekRecoveryTimerRef.current);
      if (speedHoldTimerRef.current) clearTimeout(speedHoldTimerRef.current);
    };
  }, []);

  useEffect(() => {
    if (!visible || !sourceUrl) return;
    const isLocal = /^file:\/\//i.test(normalizedSourceUrl);
    if (!isLocal || isReadyToPlay) return;
    const timer = setTimeout(() => {
      if (!isReadyToPlay) {
        onPlaybackError?.('Offline playback timed out. Falling back to stream.');
      }
    }, 8000);
    return () => clearTimeout(timer);
  }, [visible, sourceUrl, normalizedSourceUrl, isReadyToPlay, onPlaybackError]);

  useEventListener(player, 'timeUpdate', () => {
    const duration = Number(player.duration || 0);
    const currentTime = Number(player.currentTime || 0);
    if (!visible) return;
    const now = Date.now();
    const uiSyncIntervalMs = 120;
    if (controlsVisible || isScrubbing || now - lastUiSyncAtRef.current >= uiSyncIntervalMs) {
      lastUiSyncAtRef.current = now;
      setCurrentTimeSec(currentTime);
    }
    if (Math.abs(duration - lastDurationSyncRef.current) >= 0.25) {
      lastDurationSyncRef.current = duration;
      setDurationSec(duration);
    }

    if (!hasTriggeredProgress && sourceUrl && duration > 0 && currentTime / duration >= watchedThreshold) {
      setHasTriggeredProgress(true);
      onWatchedNearlyAll();
    }

    if (!onProgressSave) return;
    if (!(duration > 0) || currentTime < 0) return;
    const whole = Math.floor(currentTime);
    if (whole - lastProgressSaveSecRef.current < 5) return;
    lastProgressSaveSecRef.current = whole;
    onProgressSave(whole, duration);
  });

  useEventListener(player, 'statusChange', (payload: any) => {
    if (!visible) return;
    const isLocal = /^file:\/\//i.test(String(normalizedSourceUrl ?? ''));
    if (payload?.status === 'readyToPlay') {
      setIsReadyToPlay(true);
      setIsPlaying(true);
      softRecoverAttemptsRef.current = 0;
      lastHardErrorAtRef.current = 0;
      rapidSeekBurstRef.current = 0;
      if (!initialSeekAppliedRef.current && Number(resumePositionSec || 0) > 0) {
        initialSeekAppliedRef.current = true;
        const resumeAt = Math.floor(Number(resumePositionSec || 0));
        setTimeout(() => {
          const d = Number(player.duration || 0);
          const capped = d > 15 ? clamp(resumeAt, 0, Math.max(0, d - 8)) : Math.max(0, resumeAt);
          if (!(capped > 0)) return;
          desiredResumeSeekRef.current = capped;
          try {
            player.currentTime = capped;
            player.play();
          } catch {}
          if (resumeSeekVerifyTimerRef.current) clearTimeout(resumeSeekVerifyTimerRef.current);
          resumeSeekVerifyTimerRef.current = setTimeout(() => {
            const current = Number(player.currentTime || 0);
            if (capped - current > 15) {
              try {
                player.currentTime = Math.max(0, capped - 20);
                player.play();
              } catch {}
            }
            desiredResumeSeekRef.current = null;
          }, 900);
        }, 180);
      }
      if (streamStallTimerRef.current) {
        clearTimeout(streamStallTimerRef.current);
        streamStallTimerRef.current = null;
      }
    }
    if (payload?.status === 'loading' && !isLocal) {
      if (streamStallTimerRef.current) clearTimeout(streamStallTimerRef.current);
      const msSinceSeek = Date.now() - lastSeekAtRef.current;
      const isWithinSeekRecovery = Date.now() < seekRecoveryUntilRef.current;
      const afterSeekGraceMs =
        isWithinSeekRecovery || (msSinceSeek >= 0 && msSinceSeek < 2500)
          ? 45000
          : isHlsSource
            ? 25000
            : 15000;
      streamStallTimerRef.current = setTimeout(() => {
        if (softRecoverAttemptsRef.current < 2) {
          softRecoverAttemptsRef.current += 1;
          try {
            const ct = Number(player.currentTime || 0);
            // Small nudge can unstick stalled HLS pipelines on iOS/Android.
            player.currentTime = Math.max(0, ct + 0.01);
            player.play();
          } catch {}
          return;
        }
        onPlaybackError?.('Stream stalled while loading. Trying next source.');
      }, afterSeekGraceMs);
    }
    if (payload?.status === 'error') {
      const isWithinSeekRecovery = Date.now() < seekRecoveryUntilRef.current;
      if (!isLocal && isWithinSeekRecovery) {
        if (streamStallTimerRef.current) {
          clearTimeout(streamStallTimerRef.current);
          streamStallTimerRef.current = null;
        }
        setTimeout(() => {
          try {
            const pending = pendingSeekTargetRef.current;
            const resumeTarget = desiredResumeSeekRef.current;
            if (pending != null && Number.isFinite(pending)) {
              player.currentTime = Math.max(0, Number(pending));
            } else if (resumeTarget != null && Number.isFinite(resumeTarget) && resumeTarget > 0) {
              player.currentTime = Math.max(0, Number(resumeTarget));
            } else {
              const ct = Number(player.currentTime || 0);
              player.currentTime = Math.max(0, ct + 0.03);
            }
            player.play();
          } catch {}
        }, 220);
        return;
      }
      const sinceSeekMs = Date.now() - lastSeekAtRef.current;
      if (!isLocal && sinceSeekMs >= 0 && (sinceSeekMs < seekTransientErrorGraceMs || rapidSeekBurstRef.current >= 3)) {
        try {
          const ct = Number(player.currentTime || 0);
          player.currentTime = Math.max(0, ct + 0.03);
          player.play();
        } catch {}
        return;
      }
      if (!isLocal && softRecoverAttemptsRef.current < 2) {
        softRecoverAttemptsRef.current += 1;
        setTimeout(() => {
          try {
            player.play();
          } catch {}
        }, 260);
        return;
      }
      const now = Date.now();
      if (!isLocal && Platform.OS === 'ios' && sinceSeekMs >= 0 && sinceSeekMs < 30000) {
        setTimeout(() => {
          try {
            const pending = pendingSeekTargetRef.current;
            const resumeTarget = desiredResumeSeekRef.current;
            if (pending != null && Number.isFinite(pending)) {
              player.currentTime = Math.max(0, Number(pending));
            } else if (resumeTarget != null && Number.isFinite(resumeTarget) && resumeTarget > 0) {
              player.currentTime = Math.max(0, Number(resumeTarget));
            } else {
              const ct = Number(player.currentTime || 0);
              player.currentTime = Math.max(0, ct + 0.03);
            }
            player.play();
          } catch {}
        }, 320);
        return;
      }
      // Suppress rapid duplicate hard errors to avoid thrashing source fallbacks.
      if (now - lastHardErrorAtRef.current < 1500) {
        setTimeout(() => {
          try {
            player.play();
          } catch {}
        }, 300);
        return;
      }
      lastHardErrorAtRef.current = now;
      if (streamStallTimerRef.current) {
        clearTimeout(streamStallTimerRef.current);
        streamStallTimerRef.current = null;
      }
      onPlaybackError?.(payload?.error?.message ?? 'Playback failed');
    }
  });

  useEventListener(player, 'playToEnd', () => {
    if (!visible) return;
    const d = Number(player.duration || 0);
    onProgressSave?.(d, d);
    onPlaybackEnded?.();
  });

  useEventListener(player, 'playingChange', (payload: any) => {
    if (!visible) return;
    setIsPlaying(!!payload?.isPlaying);
  });

  const duration = durationSec || 0;
  const current = currentTimeSec || 0;
  const progress = duration > 0 ? clamp(current / duration, 0, 1) : 0;
  const effectivePlaybackRate = isSpeedHold ? 2 : selectedPlaybackRate;
  const activeProgress = isScrubbing ? scrubRatio : progress;
  const displayCurrent = duration > 0 ? duration * activeProgress : current;
  const watchedPercent = Math.round(activeProgress * 100);
  const hasIntroRange =
    Number.isFinite(Number(introStartSec)) &&
    Number.isFinite(Number(introEndSec)) &&
    Number(introEndSec) > Number(introStartSec) &&
    duration > 0;
  const introStart = hasIntroRange ? clamp(Number(introStartSec || 0), 0, duration) : 0;
  const introEnd = hasIntroRange ? clamp(Number(introEndSec || 0), 0, duration) : 0;
  const introLeftPct = hasIntroRange ? (introStart / duration) * 100 : 0;
  const introWidthPct = hasIntroRange ? Math.max(0, ((introEnd - introStart) / duration) * 100) : 0;
  const currentForIntro = Number(player.currentTime || currentTimeSec || 0);
  const introActive = hasIntroRange && currentForIntro >= introStart && currentForIntro < introEnd;
  const titleParts = title.split(' - Episode ');
  const episodeLabel = titleParts.length > 1 ? `E${titleParts[1].split(' ')[0]}` : 'Episode';
  const animeTitle = titleParts[0] || title;

  const flushQueuedSeek = () => {
    const target = pendingSeekTargetRef.current;
    pendingSeekTargetRef.current = null;
    if (!(target != null) || !Number.isFinite(target)) return;
    const safeDuration = Number(player.duration || durationSec || 0);
    const bounded = safeDuration > 0 ? clamp(target, 0, safeDuration) : Math.max(0, target);
    try {
      player.currentTime = bounded;
    } catch {}
    desiredResumeSeekRef.current = null;
    resumeExactSeekDoneRef.current = false;
    const now = Date.now();
    if (now - lastSeekBurstAtRef.current < 1200) {
      rapidSeekBurstRef.current += 1;
    } else {
      rapidSeekBurstRef.current = 1;
    }
    lastSeekBurstAtRef.current = now;
    lastSeekAtRef.current = now;
    seekRecoveryUntilRef.current = now + seekRecoveryWindowMs;
    setCurrentTimeSec(bounded);
    setControlsVisible(true);
    if (seekRecoveryTimerRef.current) clearTimeout(seekRecoveryTimerRef.current);
    seekRecoveryTimerRef.current = setTimeout(() => {
      try {
        player.play();
      } catch {}
    }, 140);
  };

  const queueSeekTo = (targetSeconds: number) => {
    const safeDuration = Number(player.duration || durationSec || 0);
    const bounded = safeDuration > 0 ? clamp(targetSeconds, 0, safeDuration) : Math.max(0, targetSeconds);
    pendingSeekTargetRef.current = bounded;
    if (seekFlushTimerRef.current) clearTimeout(seekFlushTimerRef.current);
    // Debounce rapid repeated seeks so the player only resolves the latest target.
    seekFlushTimerRef.current = setTimeout(flushQueuedSeek, seekDebounceMs);
  };

  const seekBy = (seconds: number) => {
    const base = Number(
      pendingSeekTargetRef.current != null
        ? pendingSeekTargetRef.current
        : player.currentTime || currentTimeSec || 0
    );
    queueSeekTo(base + seconds);
    setControlsVisible(true);
  };

  const previewRatio = (ratio: number) => {
    const nextRatio = clamp(ratio, 0, 1);
    setScrubRatio(nextRatio);
    setControlsVisible(true);
  };

  const seekToRatio = (ratio: number) => {
    if (!duration) return;
    const nextRatio = clamp(ratio, 0, 1);
    setScrubRatio(nextRatio);
    queueSeekTo(nextRatio * duration);
    setControlsVisible(true);
  };

  const beginScrubbing = (locationX: number) => {
    wasPlayingBeforeScrubRef.current = !!isPlaying;
    lastLiveScrubSeekAtRef.current = 0;
    try {
      if (isPlaying) player.pause();
    } catch {}
    setIsScrubbing(true);
    previewRatio(locationX / barWidth);
  };

  const moveScrubbing = (locationX: number) => {
    const ratio = clamp(locationX / barWidth, 0, 1);
    previewRatio(ratio);
    if (!duration) return;
    const now = Date.now();
    if (now - lastLiveScrubSeekAtRef.current >= 120) {
      lastLiveScrubSeekAtRef.current = now;
      queueSeekTo(ratio * duration);
    }
  };

  const endScrubbing = (locationX: number) => {
    seekToRatio(locationX / barWidth);
    setIsScrubbing(false);
    if (wasPlayingBeforeScrubRef.current) {
      setTimeout(() => {
        try {
          player.play();
        } catch {}
      }, 120);
    }
  };

  const handleClosePlayer = () => {
    if (seekFlushTimerRef.current) {
      clearTimeout(seekFlushTimerRef.current);
      seekFlushTimerRef.current = null;
    }
    flushQueuedSeek();
    persistProgressNow();
    onClose();
  };

  const toggleControlsVisibility = () => {
    setControlsVisible((v) => !v);
  };

  const togglePlayPause = () => {
    try {
      if (isPlaying) player.pause();
      else player.play();
    } catch {}
  };
  const applyPlaybackRate = useCallback((rate: number) => {
    const safeRate = clamp(Number(rate || 1), 0.25, 3);
    try {
      (player as any).playbackRate = safeRate;
    } catch {}
    try {
      (player as any).rate = safeRate;
    } catch {}
  }, [player]);
  const cyclePlaybackRate = () => {
    const options = [1, 1.25, 1.5, 2];
    const currentIndex = options.findIndex((v) => Math.abs(v - selectedPlaybackRate) < 0.001);
    const next = options[(currentIndex + 1) % options.length];
    setSelectedPlaybackRate(next);
  };
  const handleSpeedPress = () => {
    if (didLongPressSpeedRef.current) {
      didLongPressSpeedRef.current = false;
      return;
    }
    cyclePlaybackRate();
  };
  const handleSpeedPressIn = () => {
    if (speedHoldTimerRef.current) clearTimeout(speedHoldTimerRef.current);
    didLongPressSpeedRef.current = false;
    speedHoldTimerRef.current = setTimeout(() => {
      didLongPressSpeedRef.current = true;
      setIsSpeedHold(true);
      setControlsVisible(true);
    }, 220);
  };
  const handleSpeedPressOut = () => {
    if (speedHoldTimerRef.current) {
      clearTimeout(speedHoldTimerRef.current);
      speedHoldTimerRef.current = null;
    }
    if (!didLongPressSpeedRef.current) {
      handleSpeedPress();
      return;
    }
    setIsSpeedHold(false);
    setTimeout(() => {
      didLongPressSpeedRef.current = false;
    }, 0);
  };

  const classifyTapRegion = (x: number): 'left' | 'center' | 'right' => {
    const w = Math.max(1, gestureWidth);
    if (x <= w * 0.33) return 'left';
    if (x >= w * 0.67) return 'right';
    return 'center';
  };
  const handleGestureTap = (x: number) => {
    const now = Date.now();
    const windowMs = 280;
    const region = classifyTapRegion(x);
    if (now - lastTapAtRef.current <= windowMs && lastTapRegionRef.current === region) {
      if (singleTapTimerRef.current) clearTimeout(singleTapTimerRef.current);
      singleTapTimerRef.current = null;
      lastTapAtRef.current = 0;
      lastTapRegionRef.current = null;
      if (region === 'left') {
        seekBy(-playerSkipSeconds);
      } else if (region === 'right') {
        seekBy(playerSkipSeconds);
      } else {
        togglePlayPause();
      }
      return;
    }

    lastTapAtRef.current = now;
    lastTapRegionRef.current = region;
    if (singleTapTimerRef.current) clearTimeout(singleTapTimerRef.current);
    singleTapTimerRef.current = setTimeout(() => {
      singleTapTimerRef.current = null;
      if (lastTapAtRef.current === now && lastTapRegionRef.current === region) {
        toggleControlsVisibility();
        lastTapAtRef.current = 0;
        lastTapRegionRef.current = null;
      }
    }, windowMs + 10);
  };

  useEffect(() => {
    return () => {
      if (singleTapTimerRef.current) clearTimeout(singleTapTimerRef.current);
      if (resumeSeekVerifyTimerRef.current) clearTimeout(resumeSeekVerifyTimerRef.current);
      if (resumeSeekRetryTimerRef.current) clearTimeout(resumeSeekRetryTimerRef.current);
      if (seekFlushTimerRef.current) clearTimeout(seekFlushTimerRef.current);
      if (seekRecoveryTimerRef.current) clearTimeout(seekRecoveryTimerRef.current);
      if (speedHoldTimerRef.current) clearTimeout(speedHoldTimerRef.current);
    };
  }, []);

  useEffect(() => {
    if (!visible) return;
    applyPlaybackRate(effectivePlaybackRate);
  }, [effectivePlaybackRate, visible, applyPlaybackRate]);

  const handleGestureLayerPress = (e: any) => {
    const x = Number(e?.nativeEvent?.locationX ?? 0);
    handleGestureTap(x);
  };

  return (
    <Modal
      visible={visible}
      animationType="fade"
      onRequestClose={handleClosePlayer}
      transparent={false}
      presentationStyle="fullScreen"
      statusBarTranslucent={false}
      supportedOrientations={['portrait', 'portrait-upside-down', 'landscape', 'landscape-left', 'landscape-right']}
    >
      <View style={styles.backdrop}>
        {isAndroid ? (
          <SafeAreaView style={styles.safe}>
            <View style={styles.playerContainer}>
              {source != null && (
                <VideoView
                  style={styles.video}
                  player={player}
                  nativeControls={isAndroid}
                  surfaceType={isAndroid ? 'surfaceView' : 'textureView'}
                  contentFit={videoContentFit}
                  allowsPictureInPicture={supportsPip}
                  startsPictureInPictureAutomatically={supportsPip && Platform.OS === 'ios'}
                  onFirstFrameRender={() => setIsReadyToPlay(true)}
                  useExoShutter={false}
                />
              )}

              {!isAndroid && (
                <Pressable
                  style={styles.gestureLayer}
                  pointerEvents="auto"
                  collapsable={false}
                  onLayout={(e) => setGestureWidth(Math.max(1, e.nativeEvent.layout.width))}
                  onPress={handleGestureLayerPress}
                />
              )}

              {!isAndroid && (
                <Animated.View
                  style={[styles.overlay, { opacity: controlsOpacity }]}
                  pointerEvents={controlsVisible ? 'box-none' : 'none'}
                >
                  <View style={[styles.topRightRow, { paddingTop: Math.max(6, insets.top) }]}>
                    <TouchableOpacity onPress={handleClosePlayer} style={styles.topCloseButton}>
                      <MaterialIcons name="close" size={22} color="#fff" />
                    </TouchableOpacity>
                  </View>

                  <View style={styles.centerControls}>
                    <LiquidGlassView enabled={playerControlStyle === 'glass'} effect="regular" style={[styles.centerButtonGlass, styles.centerMainButtonGlass]}>
                    <TouchableOpacity
                      style={[styles.centerButton, styles.centerMainButton, playerControlStyle === 'solid' ? styles.centerButtonSolid : null]}
                      onPress={togglePlayPause}
                    >
                      <MaterialIcons name={isPlaying ? 'pause' : 'play-arrow'} size={40} color="#fff" />
                    </TouchableOpacity>
                    </LiquidGlassView>
                  </View>

                  {playerShowMeta && <View style={styles.bottomBlock}>
                    <View style={styles.metaRow}>
                      <View style={styles.metaLeft}>
                        <Text style={styles.episodeText}>{episodeLabel}</Text>
                        <Text style={styles.titleText} numberOfLines={1}>
                          {animeTitle}
                        </Text>
                      </View>
                      <View style={styles.bottomRightActions}>
                        {introActive && (
                          <TouchableOpacity
                            onPress={() => queueSeekTo(introEnd + 0.15)}
                            style={[styles.bottomActionButton, styles.skipIntroButton]}
                            activeOpacity={0.9}
                          >
                            <Text style={[styles.bottomActionText, styles.skipIntroButtonText]}>Skip Intro</Text>
                          </TouchableOpacity>
                        )}
                        <TouchableOpacity
                          onPress={() => seekBy(85)}
                          style={styles.bottomActionButton}
                          activeOpacity={0.85}
                        >
                          <Text style={styles.bottomActionText}>Skip 85s</Text>
                        </TouchableOpacity>
                        <TouchableOpacity
                          onPressIn={handleSpeedPressIn}
                          onPressOut={handleSpeedPressOut}
                          style={styles.bottomActionButton}
                          activeOpacity={0.85}
                        >
                          <Text style={styles.bottomActionText}>{effectivePlaybackRate.toFixed(effectivePlaybackRate % 1 === 0 ? 0 : 2)}x</Text>
                        </TouchableOpacity>
                      </View>
                    </View>

                    <Pressable
                      style={styles.progressTrack}
                      onLayout={(e) => setBarWidth(Math.max(1, e.nativeEvent.layout.width))}
                      onPress={(e) => seekToRatio(e.nativeEvent.locationX / barWidth)}
                      onStartShouldSetResponder={() => true}
                      onMoveShouldSetResponder={() => true}
                      onResponderTerminationRequest={() => false}
                      onResponderGrant={(e) => {
                        beginScrubbing(e.nativeEvent.locationX);
                      }}
                      onResponderMove={(e) => {
                        moveScrubbing(e.nativeEvent.locationX);
                      }}
                      onResponderRelease={(e) => {
                        endScrubbing(e.nativeEvent.locationX);
                      }}
                      onResponderTerminate={() => {
                        setIsScrubbing(false);
                        if (wasPlayingBeforeScrubRef.current) {
                          setTimeout(() => {
                            try {
                              player.play();
                            } catch {}
                          }, 120);
                        }
                      }}
                    >
                      {hasIntroRange && (
                        <View
                          style={[
                            styles.introRangeHighlight,
                            { left: `${introLeftPct}%`, width: `${introWidthPct}%` },
                          ]}
                        />
                      )}
                      <View style={[styles.progressFill, { width: `${activeProgress * 100}%` }]} />
                    </Pressable>

                    <View style={styles.timeRow}>
                      <Text style={styles.timeText}>{formatClock(displayCurrent)}</Text>
                      <Text style={styles.timeSeparator}>|</Text>
                      <Text style={styles.timeText}>{watchedPercent}% watched</Text>
                    </View>

                  </View>}
                </Animated.View>
              )}

              {isAndroid && (
                <View style={styles.androidTopRow}>
                  <TouchableOpacity onPress={handleClosePlayer} style={styles.topCloseButton}>
                    <MaterialIcons name="arrow-back" size={22} color="#fff" />
                  </TouchableOpacity>
                </View>
              )}
            </View>

            {loadingOverlay && (
              <View style={styles.loadingOverlay}>
                <ActivityIndicator color="#8bb7ff" />
                <Text style={styles.loadingText}>Updating AniList...</Text>
              </View>
            )}
          </SafeAreaView>
        ) : (
          <View style={styles.safe}>
          <View style={styles.playerContainer}>
            {source != null && (
              <VideoView
                style={styles.video}
                player={player}
                nativeControls={isAndroid}
                surfaceType={isAndroid ? 'surfaceView' : 'textureView'}
                contentFit={videoContentFit}
                allowsPictureInPicture={supportsPip}
                startsPictureInPictureAutomatically={supportsPip && Platform.OS === 'ios'}
                onFirstFrameRender={() => setIsReadyToPlay(true)}
                useExoShutter={false}
              />
            )}

            {!isAndroid && (
              <Pressable
                style={styles.gestureLayer}
                pointerEvents="auto"
                collapsable={false}
                onLayout={(e) => setGestureWidth(Math.max(1, e.nativeEvent.layout.width))}
                onPress={handleGestureLayerPress}
              />
            )}

            {!isAndroid && (
              <Animated.View
                style={[styles.overlay, { opacity: controlsOpacity }]}
                pointerEvents={controlsVisible ? 'box-none' : 'none'}
              >
                <View style={[styles.topRightRow, { paddingTop: Math.max(6, insets.top) }]}>
                  <TouchableOpacity onPress={handleClosePlayer} style={styles.topCloseButton}>
                    <MaterialIcons name="close" size={22} color="#fff" />
                  </TouchableOpacity>
                </View>

                <View style={styles.centerControls}>
                  <LiquidGlassView enabled={playerControlStyle === 'glass'} effect="regular" style={[styles.centerButtonGlass, styles.centerMainButtonGlass]}>
                  <TouchableOpacity
                    style={[styles.centerButton, styles.centerMainButton, playerControlStyle === 'solid' ? styles.centerButtonSolid : null]}
                    onPress={togglePlayPause}
                  >
                    <MaterialIcons name={isPlaying ? 'pause' : 'play-arrow'} size={40} color="#fff" />
                  </TouchableOpacity>
                  </LiquidGlassView>
                </View>

                {playerShowMeta && <View style={styles.bottomBlock}>
                  <View style={styles.metaRow}>
                    <View style={styles.metaLeft}>
                      <Text style={styles.episodeText}>{episodeLabel}</Text>
                      <Text style={styles.titleText} numberOfLines={1}>
                        {animeTitle}
                      </Text>
                    </View>
                    <View style={styles.bottomRightActions}>
                      {introActive && (
                        <TouchableOpacity
                          onPress={() => queueSeekTo(introEnd + 0.15)}
                          style={[styles.bottomActionButton, styles.skipIntroButton]}
                          activeOpacity={0.9}
                        >
                          <Text style={[styles.bottomActionText, styles.skipIntroButtonText]}>Skip Intro</Text>
                        </TouchableOpacity>
                      )}
                      <TouchableOpacity
                        onPress={() => seekBy(85)}
                        style={styles.bottomActionButton}
                        activeOpacity={0.85}
                      >
                        <Text style={styles.bottomActionText}>Skip 85s</Text>
                      </TouchableOpacity>
                      <TouchableOpacity
                        onPressIn={handleSpeedPressIn}
                        onPressOut={handleSpeedPressOut}
                        style={styles.bottomActionButton}
                        activeOpacity={0.85}
                      >
                        <Text style={styles.bottomActionText}>{effectivePlaybackRate.toFixed(effectivePlaybackRate % 1 === 0 ? 0 : 2)}x</Text>
                      </TouchableOpacity>
                    </View>
                  </View>

                  <Pressable
                    style={styles.progressTrack}
                    onLayout={(e) => setBarWidth(Math.max(1, e.nativeEvent.layout.width))}
                    onPress={(e) => seekToRatio(e.nativeEvent.locationX / barWidth)}
                    onStartShouldSetResponder={() => true}
                    onMoveShouldSetResponder={() => true}
                    onResponderTerminationRequest={() => false}
                    onResponderGrant={(e) => {
                      beginScrubbing(e.nativeEvent.locationX);
                    }}
                    onResponderMove={(e) => {
                      moveScrubbing(e.nativeEvent.locationX);
                    }}
                    onResponderRelease={(e) => {
                      endScrubbing(e.nativeEvent.locationX);
                    }}
                    onResponderTerminate={() => {
                      setIsScrubbing(false);
                      if (wasPlayingBeforeScrubRef.current) {
                        setTimeout(() => {
                          try {
                            player.play();
                          } catch {}
                        }, 120);
                      }
                    }}
                  >
                    {hasIntroRange && (
                      <View
                        style={[
                          styles.introRangeHighlight,
                          { left: `${introLeftPct}%`, width: `${introWidthPct}%` },
                        ]}
                      />
                    )}
                    <View style={[styles.progressFill, { width: `${activeProgress * 100}%` }]} />
                  </Pressable>

                  <View style={styles.timeRow}>
                    <Text style={styles.timeText}>{formatClock(displayCurrent)}</Text>
                    <Text style={styles.timeSeparator}>|</Text>
                    <Text style={styles.timeText}>{watchedPercent}% watched</Text>
                  </View>

                </View>}
              </Animated.View>
            )}

            {isAndroid && (
              <View style={styles.androidTopRow}>
                <TouchableOpacity onPress={handleClosePlayer} style={styles.topCloseButton}>
                  <MaterialIcons name="arrow-back" size={22} color="#fff" />
                </TouchableOpacity>
              </View>
            )}
          </View>

          {loadingOverlay && (
            <View style={styles.loadingOverlay}>
              <ActivityIndicator color="#8bb7ff" />
              <Text style={styles.loadingText}>Updating AniList...</Text>
            </View>
          )}
          </View>
        )}
      </View>
    </Modal>
  );
}

const styles = StyleSheet.create({
  backdrop: {
    flex: 1,
    backgroundColor: '#000',
  },
  safe: {
    flex: 1,
    backgroundColor: '#000',
  },
  playerContainer: {
    flex: 1,
    backgroundColor: '#000',
  },
  video: {
    width: '100%',
    height: '100%',
  },
  overlay: {
    ...StyleSheet.absoluteFillObject,
    paddingHorizontal: 18,
    paddingTop: Platform.OS === 'android' ? 12 : 8,
    paddingBottom: 14,
    justifyContent: 'space-between',
    backgroundColor: 'rgba(0,0,0,0.14)',
    zIndex: 3,
  },
  gestureLayer: {
    ...StyleSheet.absoluteFillObject,
    zIndex: 2,
  },
  topRightRow: {
    flexDirection: 'row',
    alignItems: 'center',
    justifyContent: 'flex-end',
  },
  androidTopRow: {
    position: 'absolute',
    top: Platform.OS === 'android' ? 8 : 0,
    left: 10,
    zIndex: 20,
  },
  topCloseButton: {
    width: 40,
    height: 40,
    borderRadius: 20,
    alignItems: 'center',
    justifyContent: 'center',
    backgroundColor: 'rgba(26,28,33,0.7)',
  },
  centerControls: {
    position: 'absolute',
    top: '50%',
    left: 0,
    right: 0,
    transform: [{ translateY: -40 }],
    flexDirection: 'row',
    justifyContent: 'center',
    alignItems: 'center',
    gap: 16,
  },
  centerButtonGlass: {
    borderRadius: 34,
    overflow: 'hidden',
  },
  centerMainButtonGlass: {
    borderRadius: 40,
  },
  centerButton: {
    width: 68,
    height: 68,
    borderRadius: 34,
    backgroundColor: 'rgba(14,16,20,0.35)',
    alignItems: 'center',
    justifyContent: 'center',
  },
  centerButtonSolid: {
    backgroundColor: 'rgba(10,10,10,0.82)',
  },
  centerMainButton: {
    width: 80,
    height: 80,
    borderRadius: 40,
  },
  bottomBlock: {
    gap: 8,
  },
  metaRow: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'flex-end',
    gap: 12,
  },
  bottomRightActions: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
  },
  bottomActionButton: {
    borderRadius: 14,
    backgroundColor: 'rgba(20,22,28,0.72)',
    borderWidth: 1,
    borderColor: 'rgba(255,255,255,0.18)',
    paddingHorizontal: 10,
    paddingVertical: 7,
  },
  bottomActionText: {
    color: '#fff',
    fontSize: 12,
    fontWeight: '700',
  },
  skipIntroButton: {
    backgroundColor: 'rgba(245, 205, 70, 0.22)',
    borderColor: 'rgba(255, 220, 90, 0.75)',
  },
  skipIntroButtonText: {
    color: '#ffe07d',
  },
  metaLeft: {
    flex: 1,
  },
  episodeText: {
    color: '#b7bac0',
    fontWeight: '700',
    fontSize: 12,
    marginBottom: 4,
  },
  titleText: {
    color: '#fff',
    fontWeight: '800',
    fontSize: 18,
    lineHeight: 22,
    marginBottom: 0,
  },
  progressTrack: {
    width: '100%',
    height: 12,
    borderRadius: 999,
    backgroundColor: 'rgba(255,255,255,0.2)',
    overflow: 'hidden',
    justifyContent: 'center',
  },
  introRangeHighlight: {
    position: 'absolute',
    top: 0,
    bottom: 0,
    backgroundColor: 'rgba(255, 214, 76, 0.7)',
    borderRadius: 999,
  },
  progressFill: {
    height: '100%',
    borderRadius: 999,
    backgroundColor: '#fff',
  },
  timeRow: {
    flexDirection: 'row',
    justifyContent: 'flex-start',
    alignItems: 'center',
  },
  timeText: {
    color: '#d5d7db',
    fontSize: 13,
    fontWeight: '600',
  },
  timeSeparator: {
    marginHorizontal: 8,
    color: '#8f98a3',
    fontSize: 12,
    fontWeight: '700',
  },
  loadingOverlay: {
    position: 'absolute',
    left: 0,
    right: 0,
    bottom: 20,
    alignItems: 'center',
    justifyContent: 'center',
  },
  loadingText: {
    marginTop: 6,
    color: '#cfd6de',
    fontSize: 12,
  },
});
