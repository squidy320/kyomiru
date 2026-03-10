import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:liquid_glass_renderer/liquid_glass_renderer.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_pip_mode/simple_pip.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';

import '../../core/app_logger.dart';
import '../../core/haptics.dart';
import '../../core/liquid_glass_preset.dart';
import '../../models/sora_models.dart';
import '../../services/download_manager.dart';
import '../../services/progress_store.dart';
import '../../state/app_settings_state.dart';
import '../../state/auth_state.dart';
import '../../state/episode_state.dart';
import '../../state/source_lock_state.dart';
import '../../state/tracking_state.dart';
import '../../state/watch_history_state.dart';

class PlayerSourceOption {
  const PlayerSourceOption({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;
}

class _TogglePlayIntent extends Intent {
  const _TogglePlayIntent();
}

class _SeekForwardIntent extends Intent {
  const _SeekForwardIntent();
}

class _SeekBackIntent extends Intent {
  const _SeekBackIntent();
}

class _ToggleFullscreenIntent extends Intent {
  const _ToggleFullscreenIntent();
}

class _ToggleMuteIntent extends Intent {
  const _ToggleMuteIntent();
}

class _EscapeIntent extends Intent {
  const _EscapeIntent();
}

class _SeekForwardSmallIntent extends Intent {
  const _SeekForwardSmallIntent();
}

class _SeekBackSmallIntent extends Intent {
  const _SeekBackSmallIntent();
}

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.mediaId,
    required this.episodeNumber,
    required this.episodeTitle,
    required this.sourceUrl,
    this.mediaTitle,
    this.headers = const {},
    this.isLocal = false,
    this.backgroundImageUrl,
    this.malId,
    this.fallbackSources = const [],
    this.resumePositionMs,
  });

  final int mediaId;
  final int episodeNumber;
  final String episodeTitle;
  final String? sourceUrl;
  final String? mediaTitle;
  final Map<String, String> headers;
  final bool isLocal;
  final String? backgroundImageUrl;
  final int? malId;
  final List<PlayerSourceOption> fallbackSources;
  final int? resumePositionMs;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerCandidate {
  const _PlayerCandidate({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final ProgressStore _progressStore;
  Player? _mediaKitPlayer;
  VideoController? _mediaKitVideoController;
  final SimplePip _simplePip = SimplePip();
  static const MethodChannel _iosPipChannel = MethodChannel('kyomiru/ios_pip');
  final bool _enablePip = !Platform.isIOS;

  Timer? _persistTimer;
  Timer? _uiPollTimer;
  Timer? _overlayHideTimer;

  bool _isInitializing = true;
  bool _overlayVisible = true;
  String? _initError;
  String _initStatusMessage = 'Establishing Secure Connection...';

  List<_PlayerCandidate> _candidates = const [];
  int _activeCandidateIndex = -1;

  double _currentSec = 0;
  double _durationSec = 0;
  bool _isDragging = false;
  double _dragValueSec = 0;
  bool _isHorizontalSeeking = false;
  double _horizontalSeekSec = 0;
  double _lastHorizontalSeekX = 0;
  bool _pipSupported = false;
  bool _autoTrackingSyncTriggered = false;
  bool _autoNextTriggered = false;
  bool _isHlsPlayback = false;
  bool _didEpisodeEndCleanup = false;
  DateTime? _lastLiveTrimAt;
  Offset _skipAnimationPosition = Offset.zero;
  bool _skipAnimationForward = true;
  bool _isLongPressSpeeding = false;
  double _selectedPlaybackSpeed = 1.0;
  String _selectedSubtitle = 'Sub';
  String _selectedQuality = 'Auto';
  List<SoraSource> _sourceCatalog = const [];
  bool _sourceCatalogLoading = false;
  bool _sourceSwitching = false;
  bool _isControlsLocked = false;
  BoxFit _videoFit = BoxFit.contain;
  bool _iosPipActive = false;
  bool _autoSmartSkipTriggered = false;
  bool _isVerticalAdjusting = false;
  bool _verticalAdjustBrightness = false;
  double _verticalStartValue = 1.0;
  double _virtualBrightness = 1.0;
  bool _isMediaKitPlaying = false;
  bool _wakelockEnabled = false;
  bool _desktopHoveringSurface = false;
  bool _manualNextInFlight = false;
  double _volumeLevel = 1.0;
  int _lastSurfaceWidth = 0;
  int _lastSurfaceHeight = 0;
  late final AnimationController _skipAnimationController;
  final BaseCacheManager _playbackCache = DefaultCacheManager();
  final Dio _hlsProbeDio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 10),
      sendTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ),
  );

  double? opStart;
  double? opEnd;

  bool get _isDesktopPlatform =>
      Platform.isWindows || Platform.isLinux || Platform.isMacOS;

  Future<void> _enterFullscreenPlayerMode() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    await SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  Future<void> _restoreSystemUiAndOrientation() async {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  @override
  void initState() {
    super.initState();
    if (_isDesktopPlatform) {
      _overlayVisible = false;
    }
    AppLogger.i('PlayerPiP', 'init platform=${Platform.operatingSystem}');
    final settings = ref.read(appSettingsProvider);
    _selectedQuality = settings.defaultQuality;
    _selectedSubtitle = settings.defaultAudio;
    unawaited(_enterFullscreenPlayerMode());
    _progressStore = ref.read(progressStoreProvider);
    _skipAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isIOS && _enablePip) {
      _iosPipChannel.setMethodCallHandler(_handleIosPipCallback);
    }
    _setWakelock(true);
    unawaited(_initPip());
    unawaited(_fetchAniSkipData());
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_mediaKitPlayer == null) return;
    final playing = _isMediaKitPlaying;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      if (_isLongPressSpeeding) {
        _isLongPressSpeeding = false;
        unawaited(_setPlaybackSpeed(_selectedPlaybackSpeed));
      }
      unawaited(_persistProgress());
      if (Platform.isAndroid && playing && !_iosPipActive) {
        AppLogger.i(
          'PlayerPiP',
          'auto-enter attempt state=$state platform=${Platform.operatingSystem}',
        );
        unawaited(togglePiP());
      }
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_enterFullscreenPlayerMode());
      _setWakelock(true);
    }
  }

  void _setWakelock(bool enabled) {
    if (_wakelockEnabled == enabled) return;
    _wakelockEnabled = enabled;
    if (enabled) {
      unawaited(WakelockPlus.enable());
    } else {
      unawaited(WakelockPlus.disable());
    }
  }

  Future<void> _initPip() async {
    if (!_enablePip) return;
    try {
      final supported =
          Platform.isAndroid ? await SimplePip.isPipAvailable : false;
      AppLogger.i(
        'PlayerPiP',
        'availability platform=${Platform.operatingSystem} supported=$supported',
      );
      if (!mounted) return;
      setState(() => _pipSupported = supported);
      if (supported && Platform.isAndroid) {
        unawaited(_simplePip.setAutoPipMode(
          seamlessResize: true,
          autoEnter: true,
        ));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _pipSupported = false);
      AppLogger.w(
        'PlayerPiP',
        'availability check failed platform=${Platform.operatingSystem}',
      );
    }
  }

  String _sanitizeUrl(String url) {
    return url
        .trim()
        .replaceAll(r'\/', '/')
        .replaceAll(r'\u002F', '/')
        .replaceAll('"', '')
        .replaceAll("'", '')
        .replaceAll(RegExp(r'\\+$'), '');
  }

  String _normalizeHlsUrl(String url) {
    return _sanitizeUrl(url)
        .replaceAll('/stream/', '/hls/')
        .replaceAll('uwu.m3u8', 'owo.m3u8');
  }

  List<_PlayerCandidate> _buildCandidates(
    String url,
    List<PlayerSourceOption> fallbackSources,
    Map<String, String> baseHeaders,
  ) {
    final out = <_PlayerCandidate>[];
    final seen = <String>{};

    void add(String u, Map<String, String> h) {
      final normalized = _sanitizeUrl(u);
      if (normalized.isEmpty) return;
      final key =
          '$normalized|${h.entries.map((e) => '${e.key}=${e.value}').join(';')}';
      if (!seen.add(key)) return;
      out.add(_PlayerCandidate(url: normalized, headers: h));
    }

    final normalized = _normalizeHlsUrl(url);
    add(url, baseHeaders);
    add(normalized, baseHeaders);
    add(url, const {});
    add(normalized, const {});

    for (final s in fallbackSources) {
      add(s.url, s.headers);
      add(_normalizeHlsUrl(s.url), s.headers);
      add(s.url, const {});
    }

    return out;
  }

  Future<void> _disposeControllers() async {
    final oldMediaKitPlayer = _mediaKitPlayer;
    _mediaKitPlayer = null;
    _mediaKitVideoController = null;
    await oldMediaKitPlayer?.pause();
    oldMediaKitPlayer?.dispose();
  }

  Future<bool> _bindMediaKitController(
    _PlayerCandidate candidate, {
    required bool isLocal,
    int? resumePositionMsOverride,
  }) async {
    try {
      await _disposeControllers();
      final lower = candidate.url.toLowerCase();
      final isHls = lower.contains('.m3u8');
      final isTs = lower.endsWith('.ts');
      final player = Player(
        configuration: PlayerConfiguration(
          logLevel: MPVLogLevel.warn,
          bufferSize: isHls ? 96 * 1024 * 1024 : 48 * 1024 * 1024,
          pitch: true,
        ),
      );
      final controller = VideoController(
        player,
        configuration: const VideoControllerConfiguration(
          // Keep defaults for compatibility; hardware acceleration stays on.
          enableHardwareAcceleration: true,
        ),
      );
      _mediaKitPlayer = player;
      _mediaKitVideoController = controller;
      _isHlsPlayback = isHls;
      _isMediaKitPlaying = false;

      if (mounted) {
        setState(() {
          _initStatusMessage = isHls
              ? 'Establishing Secure Connection...'
              : 'Initializing player...';
        });
      }

      final mediaUrl = isLocal
          ? Uri.file(candidate.url).toString()
          : _sanitizeUrl(candidate.url);

      if (isHls && !isLocal) {
        final warmupCancel = CancelToken();
        try {
          await _prewarmHls(
            candidate.url,
            candidate.headers,
            cancelToken: warmupCancel,
          ).timeout(const Duration(seconds: 7));
        } on TimeoutException {
          warmupCancel.cancel('hls prewarm timeout');
        }
      }

      await _tuneMpvRuntime(player, isHls: isHls);

      await player.open(
        Media(mediaUrl, httpHeaders: isLocal ? const {} : candidate.headers),
        play: false,
      );

      if (isTs) {
        if (mounted) {
          setState(
              () => _initStatusMessage = 'Scanning local stream metadata...');
        }
        await _primeMediaKitTsMetadata(player);
      }

      final saved = _progressStore.read(widget.mediaId, widget.episodeNumber);
      var initialPositionMs = resumePositionMsOverride ??
          widget.resumePositionMs ??
          saved?.positionMs ??
          0;
      if (saved != null && saved.percent >= 0.90) {
        initialPositionMs = 0;
      }
      if (saved != null && saved.positionMs > initialPositionMs) {
        initialPositionMs = saved.positionMs;
      }
      if (initialPositionMs <= 0 && widget.isLocal) {
        final downloadItem = ref
            .read(downloadControllerProvider)
            .item(widget.mediaId, widget.episodeNumber);
        final localRatio =
            (downloadItem != null && downloadItem.lastDurationMs > 0)
                ? (downloadItem.lastPositionMs / downloadItem.lastDurationMs)
                : 0.0;
        initialPositionMs =
            localRatio >= 0.90 ? 0 : (downloadItem?.lastPositionMs ?? 0);
      }
      if (initialPositionMs > 0) {
        await player.seek(Duration(milliseconds: initialPositionMs));
      }

      await player.setRate(_selectedPlaybackSpeed);
      await player.play();
      _isMediaKitPlaying = true;
      unawaited(WakelockPlus.enable());
      _persistTimer?.cancel();
      _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        unawaited(_persistProgress());
      });
      _startUiPoll();
      _scheduleOverlayAutoHide();
      return true;
    } catch (e, st) {
      AppLogger.w('Player', 'MediaKit init failed for ${candidate.url}',
          error: e, stackTrace: st);
      return false;
    }
  }

  Future<void> _seekAfterSourceSwitch(int positionMs) async {
    if (positionMs <= 0) return;
    final player = _mediaKitPlayer;
    if (player == null) return;
    final target = Duration(milliseconds: positionMs);
    for (var i = 0; i < 6; i++) {
      try {
        await player.seek(target);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 180));
      final now = player.state.position.inMilliseconds;
      if ((now - positionMs).abs() <= 1500) {
        break;
      }
    }
  }

  Future<void> _tuneMpvRuntime(Player player, {required bool isHls}) async {
    try {
      final native = player.platform as dynamic;
      Future<void> setProp(String key, String value) async {
        try {
          await native.setProperty(key, value);
        } catch (_) {}
      }

      await setProp('cache', 'yes');
      await setProp('network-timeout', '45');
      await setProp('demuxer-max-back-bytes', '67108864'); // 64 MB
      await setProp('demuxer-max-bytes', isHls ? '100663296' : '50331648');
      await setProp('demuxer-readahead-secs', isHls ? '35' : '12');
      await setProp('cache-secs', isHls ? '40' : '12');
      await setProp(
        'video-sync',
        Platform.isAndroid ? 'audio' : 'display-resample',
      );
      await setProp('interpolation', 'yes');
      await setProp('audio-pitch-correction', 'yes');
      if (Platform.isWindows) {
        await setProp('hwdec', 'auto-safe');
      } else if (Platform.isMacOS) {
        await setProp('hwdec', 'videotoolbox');
      } else {
        await setProp('hwdec', 'auto-safe');
      }
    } catch (_) {}
  }

  Future<void> _prewarmHls(
    String url,
    Map<String, String> headers, {
    CancelToken? cancelToken,
  }) async {
    try {
      final res = await _hlsProbeDio.headUri(
        Uri.parse(url),
        options: Options(
          headers: headers,
          validateStatus: (_) => true,
        ),
        cancelToken: cancelToken,
      );
      if ((res.statusCode ?? 500) < 400) return;
    } catch (_) {}

    final res = await _hlsProbeDio.getUri(
      Uri.parse(url),
      options: Options(
        headers: headers,
        responseType: ResponseType.plain,
        validateStatus: (_) => true,
      ),
      cancelToken: cancelToken,
    );
    if ((res.statusCode ?? 500) >= 400) {
      throw Exception('HLS pre-warm failed');
    }
  }

  Future<void> _primeMediaKitTsMetadata(Player player) async {
    try {
      if (player.state.duration.inMilliseconds > 0) return;
      await player.setVolume(0);
      await player.play();
      await Future<void>.delayed(const Duration(milliseconds: 900));
      await player.pause();
      await player.seek(Duration.zero);
      for (var i = 0; i < 6; i++) {
        if (player.state.duration.inMilliseconds > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      await player.setVolume(100);
    } catch (_) {}
  }

  Future<void> _fetchAniSkipData() async {
    if (widget.malId == null) return;
    final range = await ref.read(aniSkipServiceProvider).getOpeningRange(
          mediaId: widget.mediaId,
          episode: widget.episodeNumber,
          malId: widget.malId,
        );
    if (!mounted || range == null) return;
    setState(() {
      opStart = range.start;
      opEnd = range.end;
    });
  }

  void _startUiPoll() {
    _uiPollTimer?.cancel();
    _uiPollTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      final mk = _mediaKitPlayer;
      if (!mounted || mk == null) return;
      final state = mk.state;
      _isMediaKitPlaying = state.playing;
      _volumeLevel = (state.volume / 100.0).clamp(0.0, 1.0);
      if (_isMediaKitPlaying) {
        _setWakelock(true);
      }
      setState(() {
        _durationSec = state.duration.inMilliseconds <= 0
            ? 0
            : state.duration.inMilliseconds / 1000.0;
        _currentSec = state.position.inMilliseconds <= 0
            ? 0
            : state.position.inMilliseconds / 1000.0;
      });
      if (!_didEpisodeEndCleanup &&
          _durationSec > 0 &&
          (_currentSec / _durationSec) >= 0.99) {
        _didEpisodeEndCleanup = true;
        unawaited(_clearPlaybackCaches());
      }
      _trimLiveHlsSegments();
      unawaited(_maybeAutoUpdateTracking());
      if (ref.read(appSettingsProvider).smartSkipEnabled &&
          _hasActiveAniSkipWindow &&
          !_autoSmartSkipTriggered &&
          !_isDragging &&
          _isMediaKitPlaying) {
        _autoSmartSkipTriggered = true;
        unawaited(_skipIntro());
      } else if (!_hasActiveAniSkipWindow &&
          opStart != null &&
          _currentSec < (opStart! - 1.0)) {
        // Allow re-trigger if user manually seeks before intro.
        _autoSmartSkipTriggered = false;
      }
      if (ref.read(appSettingsProvider).autoPlayNextEpisode) {
        unawaited(_maybeAutoPlayNext());
      }
    });
  }

  int _qualityRank(String q) {
    final m = RegExp(r'(\d+)').firstMatch(q);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  String _audioKey(String value) {
    final v = value.trim().toLowerCase();
    if (v == 'any') return 'any';
    if (v.contains('dub') || v.contains('eng')) return 'dub';
    if (v.contains('sub') || v.contains('jpn') || v.contains('jp')) {
      return 'sub';
    }
    return 'sub';
  }

  String _prettyAudio(String value) {
    return _audioKey(value) == 'dub' ? 'Dub' : 'Sub';
  }

  String _prettyQuality(String value) {
    final v = value.trim();
    if (v.isEmpty) return 'Auto';
    if (v.toLowerCase() == 'auto') return 'Auto';
    final rank = _qualityRank(v);
    if (rank <= 0) return v;
    // AnimePahe sources may expose internal dimensions (e.g. 800/534/266).
    // Normalize them back to the canonical user-facing tiers.
    if (rank >= 780) return '1080p';
    if (rank >= 500) return '720p';
    return '360p';
  }

  SoraSource? _pickCatalogSource({
    required String desiredAudio,
    required String desiredQuality,
  }) {
    if (_sourceCatalog.isEmpty) return null;
    final ranked = [..._sourceCatalog]..sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    final wantedAudio = _audioKey(desiredAudio);
    final wantedQuality = desiredQuality.trim().toLowerCase();
    final wantedRank = _qualityRank(wantedQuality);

    List<SoraSource> pool = ranked;
    if (wantedAudio != 'any') {
      final byAudio =
          ranked.where((s) => _audioKey(s.subOrDub) == wantedAudio).toList();
      if (byAudio.isNotEmpty) pool = byAudio;
    }

    if (wantedQuality != 'auto') {
      final exact = pool.where((s) {
        final normalized = _prettyQuality(s.quality).toLowerCase();
        final sourceRaw = s.quality.toLowerCase();
        return normalized == wantedQuality ||
            sourceRaw.contains(wantedQuality) ||
            (wantedRank > 0 && _qualityRank(normalized) == wantedRank);
      }).toList();
      if (exact.isNotEmpty) return exact.first;
    }

    if (pool.isNotEmpty) return pool.first;
    return ranked.first;
  }

  String _resolvedAudioSelection() {
    if (_sourceCatalog.isEmpty) return _prettyAudio(_selectedSubtitle);
    final wanted = _audioKey(_selectedSubtitle);
    final available = _sourceCatalog.map((s) => _audioKey(s.subOrDub)).toSet();
    if (wanted == 'any') {
      if (available.contains('sub')) return 'Sub';
      if (available.contains('dub')) return 'Dub';
      return 'Sub';
    }
    if (available.contains(wanted)) return _prettyAudio(wanted);
    if (available.contains('sub')) return 'Sub';
    if (available.contains('dub')) return 'Dub';
    return 'Sub';
  }

  List<String> _qualityOptionsForAudio(String audio) {
    if (_sourceCatalog.isEmpty) {
      return <String>['Auto', '1080p', '720p', '360p'];
    }
    final audioKey = _audioKey(audio);
    var pool =
        _sourceCatalog.where((s) => _audioKey(s.subOrDub) == audioKey).toList();
    if (pool.isEmpty) {
      pool = [..._sourceCatalog];
    }
    final qualityValues =
        pool.map((s) => _prettyQuality(s.quality)).toSet().toList()
          ..sort((a, b) {
            if (a == 'Auto') return -1;
            if (b == 'Auto') return 1;
            return _qualityRank(b).compareTo(_qualityRank(a));
          });
    return qualityValues;
  }

  void _normalizeSelectionFromCatalog() {
    if (_sourceCatalog.isEmpty || !mounted) return;
    final target = _pickCatalogSource(
      desiredAudio: _resolvedAudioSelection(),
      desiredQuality: _selectedQuality,
    );
    if (target == null) return;
    final nextAudio = _prettyAudio(target.subOrDub);
    final nextQuality = _prettyQuality(target.quality);
    if (nextAudio == _selectedSubtitle && nextQuality == _selectedQuality) {
      return;
    }
    setState(() {
      _selectedSubtitle = nextAudio;
      _selectedQuality = nextQuality;
    });
  }

  SoraSource _pickSourceByLock(
    List<SoraSource> sources,
    AppSettings settings,
    SessionSourceLock? lock,
  ) {
    final sorted = [...sources]..sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));

    if (lock != null) {
      var pool = sorted
          .where(
            (s) => sourceProviderIdFromUrl(s.url) == lock.providerId,
          )
          .toList();
      if (pool.isEmpty) pool = sorted;
      final exact = pool.where((s) {
        final q = s.quality.toLowerCase();
        final a = _audioKey(s.subOrDub);
        return q.contains(lock.quality) && a == _audioKey(lock.audio);
      }).toList();
      if (exact.isNotEmpty) return exact.first;
      final qualityOnly = pool
          .where((s) => s.quality.toLowerCase().contains(lock.quality))
          .toList();
      if (qualityOnly.isNotEmpty) return qualityOnly.first;
      return pool.first;
    }

    var pool = sorted;
    final preferredAudio = _audioKey(settings.defaultAudio);
    final preferredQuality = settings.defaultQuality.toLowerCase();
    if (preferredAudio != 'any') {
      final audio =
          pool.where((s) => _audioKey(s.subOrDub) == preferredAudio).toList();
      if (audio.isNotEmpty) pool = audio;
    }
    if (preferredQuality != 'auto') {
      final quality = pool
          .where((s) => s.quality.toLowerCase().contains(preferredQuality))
          .toList();
      if (quality.isNotEmpty) return quality.first;
    }
    return pool.first;
  }

  Future<List<SoraSource>> _fetchCurrentEpisodeSources() async {
    final title = widget.mediaTitle?.trim();
    if (widget.isLocal || title == null || title.isEmpty) return const [];
    final episodeResult = await ref
        .read(
          episodeProvider(
            EpisodeQuery(mediaId: widget.mediaId, title: title),
          ).future,
        )
        .timeout(const Duration(seconds: 20));
    SoraEpisode? current;
    for (final ep in episodeResult.episodes) {
      if (ep.number == widget.episodeNumber) {
        current = ep;
        break;
      }
    }
    if (current == null) return const [];
    final sources = await ref
        .read(
          episodeSourcesProvider(
            EpisodeSourceQuery(
              playUrl: current.playUrl,
              anilistId: widget.mediaId,
              episodeNumber: widget.episodeNumber,
            ),
          ).future,
        )
        .timeout(const Duration(seconds: 45));
    return sources;
  }

  Future<void> _ensureSourceCatalog() async {
    if (_sourceCatalogLoading || _sourceCatalog.isNotEmpty || widget.isLocal) {
      return;
    }
    _sourceCatalogLoading = true;
    try {
      final sources = await _fetchCurrentEpisodeSources();
      if (!mounted) return;
      setState(() {
        _sourceCatalog = sources;
      });
      _normalizeSelectionFromCatalog();
    } catch (_) {
      // Keep existing playback if catalog loading fails.
    } finally {
      _sourceCatalogLoading = false;
    }
  }

  Future<void> _switchToSource(SoraSource target) async {
    if (_sourceSwitching || widget.isLocal) return;
    final currentMs = (_currentSec * 1000).round();
    final wasPlaying = _isMediaKitPlaying;
    setState(() => _sourceSwitching = true);
    try {
      final candidate = _PlayerCandidate(
        url: _sanitizeUrl(target.url),
        headers: target.headers,
      );
      final ok = await _bindMediaKitController(
        candidate,
        isLocal: false,
        resumePositionMsOverride: currentMs,
      );
      if (!ok || !mounted) return;

      _candidates = _buildCandidates(
        candidate.url,
        _sourceCatalog
            .map((s) => PlayerSourceOption(url: s.url, headers: s.headers))
            .toList(),
        target.headers,
      );
      var matchedIndex = _candidates.indexWhere(
        (c) =>
            c.url == candidate.url &&
            c.headers.toString() == target.headers.toString(),
      );
      if (matchedIndex < 0) {
        matchedIndex = _candidates.indexWhere((c) => c.url == candidate.url);
      }
      _activeCandidateIndex = matchedIndex < 0 ? 0 : matchedIndex;

      await _seekAfterSourceSwitch(currentMs);
      if (!wasPlaying) {
        await _mediaKitPlayer?.pause();
        _isMediaKitPlaying = false;
      }

      ref.read(sessionSourceLockProvider.notifier).lockFromSelection(
            sourceUrl: target.url,
            quality: target.quality,
            audio: target.subOrDub,
            format: target.format,
          );

      setState(() {
        _selectedQuality = _prettyQuality(target.quality);
        _selectedSubtitle = _prettyAudio(target.subOrDub);
      });
    } finally {
      if (mounted) setState(() => _sourceSwitching = false);
    }
  }

  Future<void> _maybeAutoPlayNext() async {
    if (_autoNextTriggered) return;
    if (_durationSec <= 0) return;
    if ((_durationSec - _currentSec) > 5) return;
    if (!mounted) return;
    final mediaTitle = widget.mediaTitle;
    if (mediaTitle == null || mediaTitle.trim().isEmpty) return;

    _autoNextTriggered = true;
    final nextEpisode = widget.episodeNumber + 1;
    await _openNextEpisode(nextEpisode);
  }

  Future<void> _playNextEpisodeManual() async {
    if (_manualNextInFlight) return;
    _manualNextInFlight = true;
    try {
      await _openNextEpisode(widget.episodeNumber + 1);
    } finally {
      _manualNextInFlight = false;
    }
  }

  Future<void> _openNextEpisode(int nextEpisode) async {
    final mediaTitle = widget.mediaTitle;
    if (mediaTitle == null || mediaTitle.trim().isEmpty) {
      _autoNextTriggered = false;
      return;
    }
    final downloader = ref.read(downloadControllerProvider.notifier);
    final localNext =
        await downloader.getLocalEpisodeByMedia(widget.mediaId, nextEpisode);

    if (!mounted) return;
    if (localNext != null) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            mediaId: widget.mediaId,
            episodeNumber: nextEpisode,
            episodeTitle: '${mediaTitle.trim()} - Episode $nextEpisode',
            sourceUrl: localNext.path,
            isLocal: true,
            backgroundImageUrl: widget.backgroundImageUrl,
            mediaTitle: mediaTitle,
            malId: widget.malId,
          ),
        ),
      );
      return;
    }

    try {
      final episodeResult = await ref.read(
        episodeProvider(
          EpisodeQuery(mediaId: widget.mediaId, title: mediaTitle),
        ).future,
      );
      SoraEpisode? next;
      for (final ep in episodeResult.episodes) {
        if (ep.number == nextEpisode) {
          next = ep;
          break;
        }
      }
      if (next == null || !mounted) return;
      final nextEp = next;

      final sources = await ref.read(
        episodeSourcesProvider(
          EpisodeSourceQuery(
            playUrl: nextEp.playUrl,
            anilistId: widget.mediaId,
            episodeNumber: nextEp.number,
          ),
        ).future,
      );
      if (sources.isEmpty || !mounted) return;
      final settings = ref.read(appSettingsProvider);
      final lock = ref.read(sessionSourceLockProvider);
      final selected = _pickSourceByLock(sources, settings, lock);
      ref.read(sessionSourceLockProvider.notifier).lockFromSelection(
            sourceUrl: selected.url,
            quality: selected.quality,
            audio: selected.subOrDub,
            format: selected.format,
          );
      final fallback = sources
          .map((s) => PlayerSourceOption(url: s.url, headers: s.headers))
          .toList();
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            mediaId: widget.mediaId,
            episodeNumber: nextEp.number,
            episodeTitle: '${mediaTitle.trim()} - Episode ${nextEp.number}',
            sourceUrl: selected.url,
            headers: selected.headers,
            backgroundImageUrl: widget.backgroundImageUrl,
            mediaTitle: mediaTitle,
            malId: widget.malId,
            fallbackSources: fallback,
          ),
        ),
      );
    } catch (_) {
      _autoNextTriggered = false;
    }
  }

  void _trimLiveHlsSegments() {
    if (!_isHlsPlayback) return;
    final now = DateTime.now();
    final last = _lastLiveTrimAt;
    if (last != null && now.difference(last) < const Duration(seconds: 20)) {
      return;
    }
    _lastLiveTrimAt = now;
    unawaited(_trimOldTempSegments());
  }

  Future<void> _trimOldTempSegments() async {
    try {
      final temp = await getTemporaryDirectory();
      if (!await temp.exists()) return;
      final deadline = DateTime.now().subtract(const Duration(seconds: 90));
      final entities = temp.listSync(recursive: true, followLinks: false);
      for (final e in entities) {
        if (e is! File) continue;
        final p = e.path.toLowerCase();
        if (!p.endsWith('.ts')) continue;
        try {
          final modified = await e.lastModified();
          if (modified.isBefore(deadline)) {
            await e.delete();
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _maybeAutoUpdateTracking() async {
    if (_autoTrackingSyncTriggered) return;
    if (_durationSec <= 0 || _currentSec <= 0) return;
    if (_currentSec / _durationSec < 0.90) return;

    _autoTrackingSyncTriggered = true;
    try {
      final target = AniListTrackingTarget(
        sourceMediaId: widget.mediaId,
        title: (widget.mediaTitle ?? '').trim().isEmpty
            ? 'Unknown'
            : widget.mediaTitle!.trim(),
        episodes: null,
      );
      final ok = await ref
          .read(aniListTrackingProvider(target).notifier)
          .autoAdvanceToEpisode(
            episodeNumber: widget.episodeNumber,
            mediaTitle: target.title,
          );
      if (!ok) {
        _autoTrackingSyncTriggered = false;
      }
    } catch (e, st) {
      _autoTrackingSyncTriggered = false;
      AppLogger.w(
        'Player',
        'Auto tracking transaction failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  void _scheduleOverlayAutoHide() {
    if (_isDesktopPlatform) return;
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      final isPlaying = _isMediaKitPlaying;
      if (isPlaying) {
        setState(() => _overlayVisible = false);
      }
    });
  }

  void _registerInteraction() {
    if (_isControlsLocked) return;
    if (!_overlayVisible) {
      setState(() => _overlayVisible = true);
    }
    _scheduleOverlayAutoHide();
  }

  void _handleSurfaceTap() {
    if (_isDesktopPlatform) return;
    if (_isControlsLocked) return;
    if (_overlayVisible) {
      setState(() => _overlayVisible = false);
      _overlayHideTimer?.cancel();
      return;
    }
    _registerInteraction();
  }

  Future<void> _clearTemporaryHlsCache() async {
    try {
      final temp = await getTemporaryDirectory();
      if (!await temp.exists()) return;
      final entities = temp.listSync(recursive: true, followLinks: false);
      for (final e in entities) {
        try {
          if (e is File) {
            final p = e.path.toLowerCase();
            if (p.endsWith('.m3u8') || p.endsWith('.ts') || p.contains('hls')) {
              await e.delete();
            }
          } else if (e is Directory) {
            final p = e.path.toLowerCase();
            if (p.contains('hls') || p.contains('video_player')) {
              await e.delete(recursive: true);
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<void> _clearPlaybackCaches() async {
    try {
      await _playbackCache.emptyCache();
    } catch (_) {}
    await _clearTemporaryHlsCache();
  }

  Future<void> _init() async {
    final downloader = ref.read(downloadControllerProvider.notifier);
    File? localFile;
    final title = widget.mediaTitle?.trim();
    if (title != null && title.isNotEmpty) {
      localFile = await downloader.getLocalEpisode(title, widget.episodeNumber);
    }
    localFile ??= await downloader.getLocalEpisodeByMedia(
        widget.mediaId, widget.episodeNumber);
    if (localFile != null) {
      final localCandidate =
          _PlayerCandidate(url: localFile.path, headers: const {});
      final boundMediaKit =
          await _bindMediaKitController(localCandidate, isLocal: true);
      if (boundMediaKit) {
        if (!mounted) return;
        setState(() {
          _isInitializing = false;
          _initError = null;
        });
        return;
      }
      // continue to network candidates if local open fails
    }

    String? url =
        widget.sourceUrl == null ? null : _sanitizeUrl(widget.sourceUrl!);
    Map<String, String> initialHeaders =
        Map<String, String>.from(widget.headers);

    if (!widget.isLocal) {
      try {
        final sources = await _fetchCurrentEpisodeSources();
        if (sources.isNotEmpty) {
          _sourceCatalog = sources;
          final settings = ref.read(appSettingsProvider);
          final lock = ref.read(sessionSourceLockProvider);
          final selected = _pickSourceByLock(sources, settings, lock);
          url = _sanitizeUrl(selected.url);
          initialHeaders = Map<String, String>.from(selected.headers);
          _selectedQuality = _prettyQuality(selected.quality);
          _selectedSubtitle = _prettyAudio(selected.subOrDub);
          ref.read(sessionSourceLockProvider.notifier).lockFromSelection(
                sourceUrl: selected.url,
                quality: selected.quality,
                audio: selected.subOrDub,
                format: selected.format,
              );
        }
      } catch (_) {
        // Keep fallback initial URL path when source catalog fetch fails.
      }
    }

    if (url == null || url.isEmpty) {
      setState(() {
        _isInitializing = false;
        _initError = 'Missing source URL.';
      });
      return;
    }

    _candidates = _buildCandidates(url, widget.fallbackSources, initialHeaders);
    var opened = false;
    for (var i = 0; i < _candidates.length; i++) {
      final ok = await _bindMediaKitController(
        _candidates[i],
        isLocal: widget.isLocal,
      );
      if (ok) {
        opened = true;
        _activeCandidateIndex = i;
        break;
      }
    }

    if (!opened) {
      AppLogger.e(
        'Player',
        'All source init attempts failed for media ${widget.mediaId} ep ${widget.episodeNumber}',
        error: url,
      );
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _initError =
            'No playable source for this episode yet. Try another quality/source.';
      });
      return;
    }

    AppLogger.i(
      'Player',
      'Playback initialized for media ${widget.mediaId} ep ${widget.episodeNumber} candidate=$_activeCandidateIndex/${_candidates.length}',
    );

    if (!mounted) return;
    setState(() {
      _isInitializing = false;
      _initError = null;
    });
    unawaited(_ensureSourceCatalog());
  }

  Future<void> _persistProgress() async {
    final mk = _mediaKitPlayer;
    if (mk == null) {
      return;
    }
    final state = mk.state;
    final durationMs = state.duration.inMilliseconds;
    final positionMs = state.position.inMilliseconds;
    if (durationMs <= 0 || positionMs < 0) return;

    await _progressStore.write(
      mediaId: widget.mediaId,
      episode: widget.episodeNumber,
      positionMs: positionMs,
      durationMs: durationMs,
    );
    await _syncContinueWatching(positionMs: positionMs, durationMs: durationMs);
    if (widget.isLocal) {
      await ref
          .read(downloadControllerProvider.notifier)
          .setLocalPlaybackPosition(
            widget.mediaId,
            widget.episodeNumber,
            positionMs: positionMs,
            durationMs: durationMs,
          );
    }
  }

  String? _activePlaybackUrl() {
    if (widget.isLocal) {
      final raw = widget.sourceUrl;
      if (raw == null || raw.trim().isEmpty) return null;
      return raw.trim();
    }
    if (_activeCandidateIndex >= 0 &&
        _activeCandidateIndex < _candidates.length) {
      final fromCandidate = _candidates[_activeCandidateIndex].url.trim();
      if (fromCandidate.isNotEmpty) return fromCandidate;
    }
    final raw = widget.sourceUrl;
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  Map<String, String> _activePlaybackHeaders() {
    if (widget.isLocal) return const {};
    if (_activeCandidateIndex >= 0 &&
        _activeCandidateIndex < _candidates.length) {
      return _candidates[_activeCandidateIndex].headers;
    }
    return widget.headers;
  }

  Future<void> _syncContinueWatching({
    required int positionMs,
    required int durationMs,
  }) async {
    if (durationMs <= 0) return;
    final ratio = (positionMs / durationMs).clamp(0.0, 1.0);
    final store = ref.read(watchHistoryStoreProvider);
    if (ratio >= 0.90) {
      await _progressStore.remove(widget.mediaId, widget.episodeNumber);
      if (widget.isLocal) {
        await ref
            .read(downloadControllerProvider.notifier)
            .setLocalPlaybackPosition(
              widget.mediaId,
              widget.episodeNumber,
              positionMs: 0,
              durationMs: durationMs,
            );
      }
      await store.remove(
        mediaId: widget.mediaId,
        episodeNumber: widget.episodeNumber,
      );
      return;
    }

    final activeUrl = _activePlaybackUrl();
    if (activeUrl == null || activeUrl.isEmpty) return;
    await store.upsert(
      mediaId: widget.mediaId,
      episodeNumber: widget.episodeNumber,
      mediaTitle: widget.mediaTitle ?? 'Media ${widget.mediaId}',
      episodeTitle: widget.episodeTitle,
      sourceUrl: activeUrl,
      lastPositionMs: positionMs,
      totalDurationMs: durationMs,
      isDownloaded: widget.isLocal,
      lastCompletedEpisode: ratio >= 0.85
          ? widget.episodeNumber
          : (widget.episodeNumber - 1).clamp(0, 99999),
      coverImageUrl: widget.backgroundImageUrl,
      headers: _activePlaybackHeaders(),
    );
  }

  Future<void> _seekByRatio(double ratio) async {
    final mk = _mediaKitPlayer;
    if (mk == null || _durationSec <= 0) return;
    final targetMs = (_durationSec * ratio.clamp(0.0, 1.0) * 1000).round();
    await mk.seek(Duration(milliseconds: targetMs));
  }

  Future<void> _seekToSeconds(double sec) async {
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    final clamped = _durationSec <= 0 ? 0.0 : sec.clamp(0.0, _durationSec);
    final target = Duration(milliseconds: (clamped * 1000).round());
    await mk.seek(target);
  }

  Future<void> _seekRelative(Duration delta) async {
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    Duration pos;
    Duration dur;
    final state = mk.state;
    pos = state.position;
    dur = state.duration;
    var target = pos + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    await mk.seek(target);
    _registerInteraction();
  }

  void _handleHorizontalSeekStart(DragStartDetails details) {
    if (_isControlsLocked) return;
    if (_mediaKitPlayer == null || _durationSec <= 0) {
      return;
    }
    _registerInteraction();
    setState(() {
      _isHorizontalSeeking = true;
      _horizontalSeekSec = _currentSec;
      _lastHorizontalSeekX = details.globalPosition.dx;
    });
  }

  void _handleHorizontalSeekUpdate(DragUpdateDetails details) {
    if (_isControlsLocked) return;
    if (!_isHorizontalSeeking || _durationSec <= 0) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    final deltaPx = details.globalPosition.dx - _lastHorizontalSeekX;
    _lastHorizontalSeekX = details.globalPosition.dx;
    final deltaSec = (deltaPx / width) * _durationSec;
    setState(() {
      _horizontalSeekSec =
          (_horizontalSeekSec + deltaSec).clamp(0.0, _durationSec);
    });
  }

  void _handleHorizontalSeekEnd() {
    if (_isControlsLocked) return;
    if (!_isHorizontalSeeking) return;
    final target = _horizontalSeekSec;
    setState(() => _isHorizontalSeeking = false);
    unawaited(_seekToSeconds(target));
    _registerInteraction();
  }

  void _handleDoubleTapSkip(TapDownDetails details) {
    if (_isControlsLocked) return;
    final width = MediaQuery.sizeOf(context).width;
    final isForward = details.localPosition.dx > width / 2;
    final skipSeconds = ref.read(appSettingsProvider).doubleTapSeekSeconds;
    HapticFeedback.lightImpact();
    setState(() {
      _skipAnimationPosition = details.localPosition;
      _skipAnimationForward = isForward;
    });
    _skipAnimationController.forward(from: 0);
    unawaited(
      _seekRelative(Duration(seconds: isForward ? skipSeconds : -skipSeconds)),
    );
  }

  Future<void> _enterPip() async {
    if (!_enablePip || !Platform.isAndroid || !_pipSupported) return;
    try {
      AppLogger.i('PlayerPiP', 'enter requested android');
      await _simplePip.enterPipMode(
        seamlessResize: true,
      );
      AppLogger.i('PlayerPiP', 'enter dispatched android');
    } catch (e, st) {
      AppLogger.w('PlayerPiP', 'enter failed', error: e, stackTrace: st);
    }
  }

  Future<void> _handleIosPipCallback(MethodCall call) async {
    if (!mounted) return;
    if (call.method == 'onPipError') {
      String message = 'unknown';
      final args = call.arguments;
      if (args is Map && args['message'] != null) {
        message = '${args['message']}';
      }
      AppLogger.w('PlayerPiP', 'ios native error: $message');
      return;
    }
    if (call.method != 'onPipStopped') return;
    _iosPipActive = false;
    final args = call.arguments;
    int positionMs = 0;
    if (args is Map) {
      final raw = args['positionMs'];
      if (raw is num) positionMs = raw.round();
    }
    AppLogger.i('PlayerPiP', 'ios pip stopped positionMs=$positionMs');
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    try {
      if (positionMs > 0) {
        await mk.seek(Duration(milliseconds: positionMs));
      }
      await _setPlaybackSpeed(_selectedPlaybackSpeed);
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed) {
        await mk.play();
        _isMediaKitPlaying = true;
        if (mounted) setState(() {});
        _registerInteraction();
      }
    } catch (e, st) {
      AppLogger.w('PlayerPiP', 'ios resume after pip failed',
          error: e, stackTrace: st);
    }
  }

  Future<void> togglePiP() async {
    await _enterPip();
  }

  Future<void> enterPictureInPictureMode() async {
    await _enterPip();
  }

  Future<void> _setPlaybackSpeed(
    double speed, {
    bool forceResync = true,
  }) async {
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    try {
      final target = speed.clamp(0.5, 2.0);
      final wasPlaying = _isMediaKitPlaying || mk.state.playing;

      if (!forceResync) {
        await mk.setRate(target);
        return;
      }

      final now = mk.state.position;
      await mk.setRate(target);

      // Re-seek once to re-anchor A/V clocks after speed changes.
      if (now > Duration.zero) {
        await mk.seek(now);
      }

      try {
        final native = mk.platform as dynamic;
        if (Platform.isAndroid && target != 1.0) {
          await native.setProperty('video-sync', 'audio');
          await native.setProperty('audio-sync', 'audio');
        }
        await native.setProperty('audio-delay', '0');
      } catch (_) {
        // Best-effort sync hint for MPV backends.
      }

      if (wasPlaying && !mk.state.playing) {
        await mk.play();
      }
    } catch (_) {}
  }

  Future<void> _setPreferredPlaybackSpeed(double speed) async {
    if (!mounted) return;
    setState(() => _selectedPlaybackSpeed = speed);
    await _setPlaybackSpeed(speed);
  }

  Future<void> _openSpeedMenu() async {
    final options = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
    final ui = ref.read(appSettingsProvider);
    final selected = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: LiquidGlass.withOwnLayer(
            settings: kyomiruLiquidGlassSettings(isOledBlack: ui.isOledBlack),
            shape: const LiquidRoundedSuperellipse(borderRadius: 18),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Playback Speed',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  ...options.map(
                    (speed) => ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                      title: Text(
                        '${speed.toStringAsFixed(speed % 1 == 0 ? 1 : 2)}x',
                      ),
                      trailing: _selectedPlaybackSpeed == speed
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => Navigator.of(context).pop(speed),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    if (selected == null) return;
    await _setPreferredPlaybackSpeed(selected);
    _registerInteraction();
  }

  Future<void> _openSubtitleMenu() async {
    await _ensureSourceCatalog();
    if (!mounted) return;
    final audioValues = _sourceCatalog
        .map((s) => _prettyAudio(s.subOrDub))
        .toSet()
        .toList()
      ..sort();
    final options = audioValues.isEmpty ? <String>['Sub'] : audioValues;
    if (!options.contains(_selectedSubtitle) && options.isNotEmpty) {
      setState(() => _selectedSubtitle = options.first);
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: _glassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Subtitles',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...options.map(
                  (o) => ListTile(
                    dense: true,
                    title: Text(o),
                    trailing: _selectedSubtitle == o
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(o),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final target = _pickCatalogSource(
      desiredAudio: selected,
      desiredQuality: _selectedQuality,
    );
    if (_sourceCatalog.isNotEmpty) {
      if (target != null) {
        await _switchToSource(target);
      }
    } else {
      setState(() => _selectedSubtitle = selected);
    }
    _registerInteraction();
  }

  Future<void> _openQualityMenu() async {
    await _ensureSourceCatalog();
    if (!mounted) return;
    final resolvedAudio = _resolvedAudioSelection();
    if (_selectedSubtitle != resolvedAudio) {
      setState(() => _selectedSubtitle = resolvedAudio);
    }
    final options = _qualityOptionsForAudio(resolvedAudio);
    if (!options.contains(_selectedQuality) && options.isNotEmpty) {
      setState(() => _selectedQuality = options.first);
    }
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: _glassPanel(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Quality',
                    style: TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                ...options.map(
                  (o) => ListTile(
                    dense: true,
                    title: Text(o),
                    trailing: _selectedQuality == o
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(context).pop(o),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selected == null || !mounted) return;
    final target = _pickCatalogSource(
      desiredAudio: _resolvedAudioSelection(),
      desiredQuality: selected,
    );
    if (target != null) {
      await _switchToSource(target);
    } else {
      setState(() => _selectedQuality = selected);
    }
    _registerInteraction();
  }

  Future<void> _toggleAspectFit() async {
    setState(() {
      _videoFit = _videoFit == BoxFit.contain ? BoxFit.cover : BoxFit.contain;
    });
    _registerInteraction();
  }

  void _toggleControlLock() {
    setState(() {
      _isControlsLocked = !_isControlsLocked;
      if (_isControlsLocked) _overlayVisible = false;
    });
    if (!_isControlsLocked) {
      _registerInteraction();
    }
  }

  bool get _hasActiveAniSkipWindow {
    if (!_hasValidIntroRange) return false;
    final start = opStart!;
    final end = opEnd!;
    return _currentSec >= start && _currentSec <= end;
  }

  String get _dynamicSkipLabel {
    return _hasActiveAniSkipWindow ? 'Skip Intro' : 'Skip 85s';
  }

  String _playerEpisodeLabel() {
    final explicit = widget.episodeTitle.trim();
    if (explicit.isNotEmpty) return explicit;
    final media = widget.mediaTitle?.trim();
    if (media != null && media.isNotEmpty) {
      return '$media - Episode ${widget.episodeNumber}';
    }
    return 'Episode ${widget.episodeNumber}';
  }

  Future<void> _handleDynamicSkip() async {
    if (_hasActiveAniSkipWindow) {
      await _skipIntro();
      return;
    }
    await _seekRelative(const Duration(seconds: 85));
  }

  Widget _glassPanel({required Widget child, double radius = 16}) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.20),
              width: 0.5,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _controlPillButton({
    required IconData icon,
    VoidCallback? onTap,
    String? label,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(999),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: label == null ? 10 : 12,
          vertical: 8,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
              color: Colors.white.withValues(alpha: 0.18), width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: Colors.white),
            if (label != null) ...[
              const SizedBox(width: 6),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _setDragFromDx(double dx, double width) {
    if (width <= 0 || _durationSec <= 0) return;
    final ratio = (dx / width).clamp(0.0, 1.0);
    setState(() {
      _dragValueSec = _durationSec * ratio;
    });
  }

  Widget _buildAppleProgressBar({
    required double currentSec,
    required double durationSec,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final played =
            durationSec <= 0 ? 0.0 : (currentSec / durationSec).clamp(0.0, 1.0);
        final hasSkip = _hasValidIntroRange && durationSec > 0;
        final skipStart =
            hasSkip ? (opStart! / durationSec).clamp(0.0, 1.0) : 0.0;
        final skipEnd = hasSkip ? (opEnd! / durationSec).clamp(0.0, 1.0) : 0.0;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            _registerInteraction();
            _setDragFromDx(details.localPosition.dx, width);
            final ratio = width <= 0
                ? 0.0
                : (details.localPosition.dx / width).clamp(0.0, 1.0);
            unawaited(_seekByRatio(ratio));
          },
          onHorizontalDragStart: (details) {
            _registerInteraction();
            setState(() {
              _isDragging = true;
              _dragValueSec = currentSec;
            });
            _setDragFromDx(details.localPosition.dx, width);
          },
          onHorizontalDragUpdate: (details) {
            _setDragFromDx(details.localPosition.dx, width);
          },
          onHorizontalDragEnd: (_) {
            final ratio = durationSec <= 0
                ? 0.0
                : (_dragValueSec / durationSec).clamp(0.0, 1.0);
            setState(() => _isDragging = false);
            unawaited(_seekByRatio(ratio));
            _registerInteraction();
          },
          onHorizontalDragCancel: () => setState(() => _isDragging = false),
          child: SizedBox(
            height: 22,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.24),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                if (hasSkip && skipEnd > skipStart)
                  Positioned(
                    left: width * skipStart,
                    child: Container(
                      width: width * (skipEnd - skipStart),
                      height: 4,
                      decoration: BoxDecoration(
                        color: const Color(0xFF60A5FA).withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                  ),
                Container(
                  width: width * played,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                Positioned(
                  left: (width * played).clamp(0.0, width) - 5,
                  child: Container(
                    width: 10,
                    height: 10,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _handleVerticalAdjustStart(DragStartDetails details) {
    if (_isControlsLocked) return;
    final width = MediaQuery.sizeOf(context).width;
    if (width <= 0) return;
    _isVerticalAdjusting = true;
    _verticalAdjustBrightness = details.localPosition.dx < (width / 2);
    _verticalStartValue = _verticalAdjustBrightness
        ? _virtualBrightness
        : (_mediaKitPlayer?.state.volume ?? 100) / 100.0;
  }

  void _handleVerticalAdjustUpdate(DragUpdateDetails details) {
    if (_isControlsLocked || !_isVerticalAdjusting) return;
    final height = MediaQuery.sizeOf(context).height;
    if (height <= 0) return;
    final delta = -(details.delta.dy / height) * 2.0;
    if (_verticalAdjustBrightness) {
      setState(() {
        _virtualBrightness = (_virtualBrightness + delta).clamp(0.2, 1.0);
      });
      return;
    }
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    final next =
        ((_verticalStartValue + delta).clamp(0.0, 1.0) * 100).roundToDouble();
    unawaited(mk.setVolume(next));
    _verticalStartValue = (next / 100.0);
  }

  void _handleVerticalAdjustEnd([DragEndDetails? _]) {
    _isVerticalAdjusting = false;
  }

  void _handleLongPressStart(LongPressStartDetails _) {
    setState(() => _isLongPressSpeeding = true);
    unawaited(_setPlaybackSpeed(2.0, forceResync: false));
  }

  void _handleLongPressEnd(LongPressEndDetails _) {
    setState(() => _isLongPressSpeeding = false);
    unawaited(_setPlaybackSpeed(_selectedPlaybackSpeed, forceResync: false));
  }

  Future<void> _togglePlayPause() async {
    final mk = _mediaKitPlayer;
    if (mk != null) {
      if (_isMediaKitPlaying) {
        await mk.pause();
        _isMediaKitPlaying = false;
        setState(() => _overlayVisible = true);
        _overlayHideTimer?.cancel();
      } else {
        await mk.play();
        _isMediaKitPlaying = true;
        _registerInteraction();
      }
    }
  }

  Future<void> _closePlayer() async {
    _overlayHideTimer?.cancel();
    _persistTimer?.cancel();
    _uiPollTimer?.cancel();
    try {
      await _persistProgress();
      await _mediaKitPlayer?.pause();
      await _disposeControllers();
    } catch (_) {}
    if (_isDesktopPlatform) {
      try {
        final fullscreen = await windowManager.isFullScreen();
        if (fullscreen) {
          await windowManager.setFullScreen(false);
        }
      } catch (_) {}
    }
    unawaited(_restoreSystemUiAndOrientation());
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) {
      navigator.pop();
    } else {
      navigator.maybePop();
    }
  }

  Widget _buildAdaptivePlayerSurface(BoxConstraints constraints) {
    final mediaKit = _mediaKitVideoController;
    if (mediaKit != null) {
      if (Platform.isWindows) {
        final width = constraints.maxWidth.floor();
        final height = constraints.maxHeight.floor();
        if (width > 0 &&
            height > 0 &&
            (width != _lastSurfaceWidth || height != _lastSurfaceHeight)) {
          _lastSurfaceWidth = width;
          _lastSurfaceHeight = height;
          unawaited(mediaKit.setSize(width: width, height: height));
        }
      }
      return Center(
        child: SizedBox(
          width: constraints.maxWidth,
          height: constraints.maxHeight,
          child: Video(
            controller: mediaKit,
            controls: NoVideoControls,
            fit: _videoFit,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Future<void> _skipIntro() async {
    final mk = _mediaKitPlayer;
    final end = opEnd;
    if (!_hasValidIntroRange || end == null || mk == null) {
      return;
    }
    HapticFeedback.lightImpact();
    final target = Duration(milliseconds: (end * 1000).round());
    await mk.seek(target);
    _registerInteraction();
  }

  bool get _hasValidIntroRange {
    final start = opStart;
    final end = opEnd;
    if (start == null || end == null) {
      return false;
    }
    if (!start.isFinite || !end.isFinite) {
      return false;
    }
    return end > start && end >= 5;
  }

  String _fmt(double sec) {
    if (!sec.isFinite || sec < 0) sec = 0;
    final d = Duration(milliseconds: (sec * 1000).round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistTimer?.cancel();
    _uiPollTimer?.cancel();
    _overlayHideTimer?.cancel();
    final mediaKit = _mediaKitPlayer;
    _mediaKitPlayer = null;
    _mediaKitVideoController = null;
    if (Platform.isIOS && _enablePip) {
      _iosPipChannel.setMethodCallHandler(null);
    }
    unawaited(_setPlaybackSpeed(_selectedPlaybackSpeed));
    unawaited(mediaKit?.pause());
    mediaKit?.dispose();
    _skipAnimationController.dispose();
    _setWakelock(false);
    unawaited(_clearPlaybackCaches());
    unawaited(_restoreSystemUiAndOrientation());
    super.dispose();
  }

  Future<void> _toggleMute() async {
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    final current = mk.state.volume;
    if (current <= 0.01) {
      await mk.setVolume(100);
      _volumeLevel = 1.0;
    } else {
      await mk.setVolume(0);
      _volumeLevel = 0.0;
    }
    if (mounted) setState(() {});
  }

  Future<void> _setVolumeLevel(double value) async {
    final mk = _mediaKitPlayer;
    if (mk == null) return;
    final clamped = value.clamp(0.0, 1.0);
    _volumeLevel = clamped;
    await mk.setVolume(clamped * 100.0);
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreenDesktop() async {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      final currentlyFullscreen = await windowManager.isFullScreen();
      await windowManager.setFullScreen(!currentlyFullscreen);
      return;
    }
    await _enterFullscreenPlayerMode();
  }

  @override
  Widget build(BuildContext context) {
    final usingMediaKit = _mediaKitVideoController != null;
    final showCustomProgress = usingMediaKit && _durationSec > 0;
    final uiCurrent = _isDragging ? _dragValueSec : _currentSec;
    final isPlaying = _isMediaKitPlaying;
    final viewPadding = MediaQuery.viewPaddingOf(context);
    final topInset = viewPadding.top;
    final bottomInset = viewPadding.bottom;
    final topHudOffset = topInset + 8;
    final bottomHudOffset = bottomInset + 12;

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.space): _TogglePlayIntent(),
        SingleActivator(LogicalKeyboardKey.arrowRight):
            _SeekForwardSmallIntent(),
        SingleActivator(LogicalKeyboardKey.arrowLeft): _SeekBackSmallIntent(),
        SingleActivator(LogicalKeyboardKey.keyL): _SeekForwardIntent(),
        SingleActivator(LogicalKeyboardKey.keyJ): _SeekBackIntent(),
        SingleActivator(LogicalKeyboardKey.keyF): _ToggleFullscreenIntent(),
        SingleActivator(LogicalKeyboardKey.f11): _ToggleFullscreenIntent(),
        SingleActivator(LogicalKeyboardKey.keyM): _ToggleMuteIntent(),
        SingleActivator(LogicalKeyboardKey.escape): _EscapeIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _SeekForwardSmallIntent: CallbackAction<_SeekForwardSmallIntent>(
            onInvoke: (_) {
              unawaited(_seekRelative(const Duration(seconds: 5)));
              return null;
            },
          ),
          _SeekBackSmallIntent: CallbackAction<_SeekBackSmallIntent>(
            onInvoke: (_) {
              unawaited(_seekRelative(const Duration(seconds: -5)));
              return null;
            },
          ),
          _TogglePlayIntent: CallbackAction<_TogglePlayIntent>(
            onInvoke: (_) {
              unawaited(_togglePlayPause());
              return null;
            },
          ),
          _SeekForwardIntent: CallbackAction<_SeekForwardIntent>(
            onInvoke: (_) {
              unawaited(_seekRelative(const Duration(seconds: 10)));
              return null;
            },
          ),
          _SeekBackIntent: CallbackAction<_SeekBackIntent>(
            onInvoke: (_) {
              unawaited(_seekRelative(const Duration(seconds: -10)));
              return null;
            },
          ),
          _ToggleFullscreenIntent: CallbackAction<_ToggleFullscreenIntent>(
            onInvoke: (_) {
              unawaited(_toggleFullscreenDesktop());
              return null;
            },
          ),
          _ToggleMuteIntent: CallbackAction<_ToggleMuteIntent>(
            onInvoke: (_) {
              unawaited(_toggleMute());
              return null;
            },
          ),
          _EscapeIntent: CallbackAction<_EscapeIntent>(
            onInvoke: (_) {
              unawaited(_closePlayer());
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: PopScope(
            canPop: true,
            onPopInvokedWithResult: (_, __) {
              if (mounted) {
                ref.invalidate(episodeProvider);
              }
            },
            child: Scaffold(
              extendBodyBehindAppBar: true,
              backgroundColor: Colors.black,
              body: Stack(
                children: [
                  const Positioned.fill(child: ColoredBox(color: Colors.black)),
                  if (_isInitializing)
                    Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(strokeWidth: 2),
                          const SizedBox(height: 12),
                          Text(
                            _initStatusMessage,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_initError != null)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _initError!,
                              style: const TextStyle(color: Colors.white70),
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 12),
                            FilledButton.tonal(
                              onPressed: () {
                                hapticTap();
                                setState(() {
                                  _isInitializing = true;
                                  _initError = null;
                                });
                                _init();
                              },
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      ),
                    )
                  else if (_mediaKitVideoController != null)
                    Positioned.fill(
                      child: MouseRegion(
                        onEnter: (_) {
                          if (!_isDesktopPlatform) return;
                          _desktopHoveringSurface = true;
                          if (!_overlayVisible && mounted) {
                            setState(() => _overlayVisible = true);
                          }
                        },
                        onExit: (_) {
                          if (!_isDesktopPlatform) return;
                          _desktopHoveringSurface = false;
                          if (mounted && !_isControlsLocked) {
                            setState(() => _overlayVisible = false);
                          }
                        },
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _isDesktopPlatform ? null : _handleSurfaceTap,
                          onDoubleTapDown:
                              _isDesktopPlatform ? null : _handleDoubleTapSkip,
                          onLongPressStart:
                              _isDesktopPlatform ? null : _handleLongPressStart,
                          onLongPressEnd:
                              _isDesktopPlatform ? null : _handleLongPressEnd,
                          onHorizontalDragStart: _isDesktopPlatform
                              ? null
                              : _handleHorizontalSeekStart,
                          onHorizontalDragUpdate: _isDesktopPlatform
                              ? null
                              : _handleHorizontalSeekUpdate,
                          onHorizontalDragEnd: _isDesktopPlatform
                              ? null
                              : (_) => _handleHorizontalSeekEnd(),
                          onHorizontalDragCancel: _isDesktopPlatform
                              ? null
                              : _handleHorizontalSeekEnd,
                          onVerticalDragStart: _isDesktopPlatform
                              ? null
                              : _handleVerticalAdjustStart,
                          onVerticalDragUpdate: _isDesktopPlatform
                              ? null
                              : _handleVerticalAdjustUpdate,
                          onVerticalDragEnd: _isDesktopPlatform
                              ? null
                              : _handleVerticalAdjustEnd,
                          onVerticalDragCancel: _isDesktopPlatform
                              ? null
                              : _handleVerticalAdjustEnd,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              return _buildAdaptivePlayerSurface(constraints);
                            },
                          ),
                        ),
                      ),
                    ),
                  AnimatedOpacity(
                    opacity: (_isDesktopPlatform
                            ? (_desktopHoveringSurface || _isControlsLocked)
                            : _overlayVisible)
                        ? 1
                        : 0,
                    duration: const Duration(milliseconds: 220),
                    child: IgnorePointer(
                      ignoring: !_overlayVisible || _isControlsLocked,
                      child: Stack(
                        children: [
                          Positioned(
                            top: topHudOffset,
                            left: 8,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Material(
                                  color: const Color(0xFA1E1E1E),
                                  borderRadius: BorderRadius.circular(999),
                                  child: InkWell(
                                    onTap: _closePlayer,
                                    borderRadius: BorderRadius.circular(999),
                                    child: const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: Icon(
                                        Icons.close_rounded,
                                        color: Colors.white,
                                        size: 24,
                                      ),
                                    ),
                                  ),
                                ),
                                if (_pipSupported) ...[
                                  const SizedBox(width: 8),
                                  Material(
                                    color: const Color(0xFA1E1E1E),
                                    borderRadius: BorderRadius.circular(999),
                                    child: InkWell(
                                      onTap: enterPictureInPictureMode,
                                      borderRadius: BorderRadius.circular(999),
                                      child: const Padding(
                                        padding: EdgeInsets.all(10),
                                        child: Icon(
                                          Icons.picture_in_picture_alt_rounded,
                                          color: Colors.white,
                                          size: 18,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (!_isDesktopPlatform)
                            Positioned.fill(
                              child: IgnorePointer(
                                ignoring: !_overlayVisible,
                                child: Center(
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Material(
                                        color: Colors.black
                                            .withValues(alpha: 0.45),
                                        shape: const CircleBorder(),
                                        child: InkWell(
                                          onTap: () {
                                            hapticTap();
                                            _togglePlayPause();
                                          },
                                          customBorder: const CircleBorder(),
                                          child: Padding(
                                            padding: const EdgeInsets.all(22),
                                            child: Icon(
                                              isPlaying
                                                  ? Icons.pause_rounded
                                                  : Icons.play_arrow_rounded,
                                              color: Colors.white,
                                              size: 44,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          Positioned(
                            left: 12,
                            right: 12,
                            bottom: bottomHudOffset,
                            child: showCustomProgress
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Align(
                                        alignment: Alignment.centerLeft,
                                        child: Text(
                                          _playerEpisodeLabel(),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            color: Colors.white
                                                .withValues(alpha: 0.88),
                                            fontSize: MediaQuery.sizeOf(context)
                                                        .width <
                                                    600
                                                ? 12
                                                : 13,
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(height: 6),
                                      LayoutBuilder(
                                        builder: (context, c) {
                                          final compact = c.maxWidth < 460;
                                          final veryNarrow = c.maxWidth < 390;
                                          final leftControls = <Widget>[
                                            _controlPillButton(
                                              icon: Icons.speed_rounded,
                                              label:
                                                  '${_selectedPlaybackSpeed.toStringAsFixed(_selectedPlaybackSpeed % 1 == 0 ? 1 : 2)}x',
                                              onTap: _openSpeedMenu,
                                            ),
                                            const SizedBox(width: 6),
                                            _controlPillButton(
                                              icon: Icons.subtitles_rounded,
                                              label: compact
                                                  ? null
                                                  : _selectedSubtitle,
                                              onTap: _openSubtitleMenu,
                                            ),
                                            const SizedBox(width: 6),
                                            _controlPillButton(
                                              icon: Icons.high_quality_rounded,
                                              label: compact
                                                  ? null
                                                  : _selectedQuality,
                                              onTap: _openQualityMenu,
                                            ),
                                          ];
                                          final rightControls = <Widget>[
                                            if (_isDesktopPlatform) ...[
                                              _controlPillButton(
                                                icon: isPlaying
                                                    ? Icons.pause_rounded
                                                    : Icons.play_arrow_rounded,
                                                label: isPlaying
                                                    ? 'Pause'
                                                    : 'Play',
                                                onTap: _togglePlayPause,
                                              ),
                                              const SizedBox(width: 6),
                                            ],
                                            if (_isDesktopPlatform) ...[
                                              _controlPillButton(
                                                icon: Icons.skip_next_rounded,
                                                label: 'Next',
                                                onTap: _playNextEpisodeManual,
                                              ),
                                              const SizedBox(width: 6),
                                            ],
                                            _controlPillButton(
                                              icon: Icons.skip_next_rounded,
                                              label: compact
                                                  ? (_hasActiveAniSkipWindow
                                                      ? 'Intro'
                                                      : '85s')
                                                  : _dynamicSkipLabel,
                                              onTap: _handleDynamicSkip,
                                            ),
                                            const SizedBox(width: 6),
                                            _controlPillButton(
                                              icon: Icons.aspect_ratio_rounded,
                                              label: compact
                                                  ? null
                                                  : (_videoFit == BoxFit.contain
                                                      ? 'Fit'
                                                      : 'Fill'),
                                              onTap: _toggleAspectFit,
                                            ),
                                            const SizedBox(width: 6),
                                            _controlPillButton(
                                              icon: _isControlsLocked
                                                  ? Icons.lock_rounded
                                                  : Icons.lock_open_rounded,
                                              onTap: _toggleControlLock,
                                            ),
                                          ];

                                          if (veryNarrow) {
                                            return SingleChildScrollView(
                                              scrollDirection: Axis.horizontal,
                                              child: Row(
                                                children: [
                                                  ...leftControls,
                                                  const SizedBox(width: 10),
                                                  ...rightControls,
                                                ],
                                              ),
                                            );
                                          }

                                          return Row(
                                            children: [
                                              ...leftControls,
                                              const Spacer(),
                                              if (_isDesktopPlatform) ...[
                                                const Icon(
                                                  Icons.volume_up_rounded,
                                                  color: Colors.white70,
                                                  size: 16,
                                                ),
                                                const SizedBox(width: 4),
                                                SizedBox(
                                                  width: 120,
                                                  child: SliderTheme(
                                                    data:
                                                        SliderTheme.of(context)
                                                            .copyWith(
                                                      thumbShape:
                                                          const RoundSliderThumbShape(
                                                              enabledThumbRadius:
                                                                  6),
                                                      overlayShape:
                                                          SliderComponentShape
                                                              .noOverlay,
                                                      trackHeight: 3,
                                                    ),
                                                    child: Slider(
                                                      value: _volumeLevel,
                                                      min: 0,
                                                      max: 1,
                                                      onChanged: (v) {
                                                        unawaited(
                                                          _setVolumeLevel(v),
                                                        );
                                                      },
                                                    ),
                                                  ),
                                                ),
                                                const SizedBox(width: 8),
                                              ],
                                              ...rightControls,
                                            ],
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 8),
                                      _buildAppleProgressBar(
                                        currentSec: uiCurrent,
                                        durationSec: _durationSec,
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 2),
                                        child: Row(
                                          children: [
                                            Text(
                                              _fmt(uiCurrent),
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12,
                                              ),
                                            ),
                                            const Spacer(),
                                            Text(
                                              '-${_fmt((_durationSec - uiCurrent).clamp(0, _durationSec))}',
                                              style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  )
                                : const SizedBox.shrink(),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_isControlsLocked)
                    Positioned(
                      top: topHudOffset,
                      left: 8,
                      child: _glassPanel(
                        radius: 999,
                        child: InkWell(
                          onTap: _toggleControlLock,
                          borderRadius: BorderRadius.circular(999),
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.lock_rounded,
                                    size: 16, color: Colors.white),
                                SizedBox(width: 6),
                                Text(
                                  'Locked',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_virtualBrightness < 0.99)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ColoredBox(
                          color: Colors.black.withValues(
                            alpha: (1 - _virtualBrightness).clamp(0.0, 0.65),
                          ),
                        ),
                      ),
                    ),
                  if (_isHorizontalSeeking)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFA1E1E1E),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.10),
                          ),
                        ),
                        child: Text(
                          '${_fmt(_horizontalSeekSec)} / ${_fmt(_durationSec)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: topInset + 14,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 160),
                        opacity: _isLongPressSpeeding ? 1 : 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 7,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFA1E1E1E),
                              borderRadius: BorderRadius.circular(999),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.10),
                              ),
                            ),
                            child: const Text(
                              '2x Speed',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: AnimatedBuilder(
                        animation: _skipAnimationController,
                        builder: (context, _) {
                          if (!_skipAnimationController.isAnimating) {
                            return const SizedBox.shrink();
                          }
                          final t = _skipAnimationController.value;
                          final rippleSize = 40 + (t * 110);
                          final iconOpacity = (1 - (t * 1.15)).clamp(0.0, 1.0);
                          final iconScale = 0.86 + (t * 0.35);

                          return Stack(
                            children: [
                              Positioned(
                                left: _skipAnimationPosition.dx -
                                    (rippleSize / 2),
                                top: _skipAnimationPosition.dy -
                                    (rippleSize / 2),
                                child: Container(
                                  width: rippleSize,
                                  height: rippleSize,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: Colors.white.withValues(
                                      alpha: 0.06 * (1 - t),
                                    ),
                                    border: Border.all(
                                      color: Colors.white.withValues(
                                        alpha: 0.40 * (1 - t),
                                      ),
                                      width: 1.2,
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.white.withValues(
                                          alpha: 0.22 * (1 - t),
                                        ),
                                        blurRadius: 22,
                                        spreadRadius: 1,
                                      ),
                                      BoxShadow(
                                        color: Colors.blueAccent.withValues(
                                          alpha: 0.16 * (1 - t),
                                        ),
                                        blurRadius: 36,
                                        spreadRadius: 2,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: _skipAnimationPosition.dx - 24,
                                top: _skipAnimationPosition.dy - 24,
                                child: Opacity(
                                  opacity: iconOpacity,
                                  child: Transform.scale(
                                    scale: iconScale,
                                    child: Container(
                                      width: 48,
                                      height: 48,
                                      decoration: BoxDecoration(
                                        color: Colors.black
                                            .withValues(alpha: 0.28),
                                        shape: BoxShape.circle,
                                        border: Border.all(
                                          color: Colors.white
                                              .withValues(alpha: 0.26),
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: Colors.white
                                                .withValues(alpha: 0.14),
                                            blurRadius: 14,
                                          ),
                                        ],
                                      ),
                                      child: Icon(
                                        _skipAnimationForward
                                            ? Icons.forward_10_rounded
                                            : Icons.replay_10_rounded,
                                        color: Colors.white,
                                        size: 22,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
