import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_pip_mode/simple_pip.dart';
import 'package:video_player/video_player.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../../core/app_logger.dart';
import '../../core/haptics.dart';
import '../../services/download_manager.dart';
import '../../services/local_library_store.dart';
import '../../services/progress_store.dart';
import '../../state/auth_state.dart';
import '../../state/episode_state.dart';
import '../../state/library_source_state.dart';
import '../../state/tracking_state.dart';

class PlayerSourceOption {
  const PlayerSourceOption({required this.url, this.headers = const {}});

  final String url;
  final Map<String, String> headers;
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
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  final SimplePip _simplePip = SimplePip();

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
  bool _isHlsPlayback = false;
  bool _didEpisodeEndCleanup = false;
  DateTime? _lastLiveTrimAt;
  Offset _skipAnimationPosition = Offset.zero;
  bool _skipAnimationForward = true;
  late final AnimationController _skipAnimationController;
  HttpServer? _hlsProxyServer;
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

  @override
  void initState() {
    super.initState();
    _progressStore = ref.read(progressStoreProvider);
    _skipAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    WidgetsBinding.instance.addObserver(this);
    unawaited(WakelockPlus.enable());
    unawaited(_initPip());
    unawaited(_fetchAniSkipData());
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final chewie = _chewieController;
    if (chewie == null) return;

    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_persistProgress());
    }
  }

  Future<void> _initPip() async {
    if (!Platform.isAndroid) return;
    try {
      final supported = await SimplePip.isPipAvailable;
      if (!mounted) return;
      setState(() => _pipSupported = supported);
      if (supported) {
        unawaited(_simplePip.setAutoPipMode(
          seamlessResize: true,
          autoEnter: true,
        ));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _pipSupported = false);
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
    final baseHeaders = Map<String, String>.from(widget.headers);

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
    final oldChewie = _chewieController;
    final oldVideo = _videoController;
    _chewieController = null;
    _videoController = null;
    await oldChewie?.pause();
    oldChewie?.dispose();
    await oldVideo?.dispose();
  }

  Future<VideoPlayerController?> _createNetworkController(
      _PlayerCandidate c) async {
    final lower = c.url.toLowerCase();
    final isHls = lower.contains('.m3u8');
    final maxAttempts = isHls ? 2 : 3;
    for (var attempt = 0; attempt < maxAttempts; attempt++) {
      try {
        if (mounted) {
          setState(() {
            _initStatusMessage = isHls
                ? 'Establishing Secure Connection...'
                : 'Initializing player...';
          });
        }
        final playbackUrl =
            isHls ? await _startHlsProxy(c.url, c.headers) : c.url;
        final uri = Uri.parse(playbackUrl);
        final controller = VideoPlayerController.networkUrl(
          uri,
          formatHint: isHls ? VideoFormat.hls : null,
          httpHeaders: c.headers,
          videoPlayerOptions: VideoPlayerOptions(
            mixWithOthers: false,
            allowBackgroundPlayback: true,
          ),
        );
        if (isHls) {
          final warmupCancel = CancelToken();
          try {
            await Future.wait([
              _prewarmHls(c.url, c.headers, cancelToken: warmupCancel),
              controller.initialize(),
            ]).timeout(const Duration(seconds: 7));
          } on TimeoutException {
            warmupCancel.cancel('hls init timeout');
            await controller.dispose();
            await _stopHlsProxy();
            if (attempt == maxAttempts - 1) {
              return null;
            }
            await Future<void>.delayed(const Duration(seconds: 1));
            continue;
          }
        } else {
          await controller.initialize().timeout(const Duration(seconds: 7));
        }
        _isHlsPlayback = isHls;
        return controller;
      } catch (e, st) {
        AppLogger.w(
          'Player',
          'Init attempt ${attempt + 1} failed for ${c.url}',
          error: e,
          stackTrace: st,
        );
        if (attempt == maxAttempts - 1) {
          return null;
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
    return null;
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

  Future<String> _startHlsProxy(String sourceUrl, Map<String, String> headers) async {
    await _stopHlsProxy();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _hlsProxyServer = server;
    server.listen((request) async {
      final targetEncoded = request.uri.queryParameters['u'];
      if (targetEncoded == null || targetEncoded.isEmpty) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }
      final target = Uri.decodeComponent(targetEncoded);
      try {
        final response = await _hlsProbeDio.getUri(
          Uri.parse(target),
          options: Options(
            headers: headers,
            responseType: ResponseType.bytes,
            validateStatus: (_) => true,
          ),
        );
        final ct = response.headers.value('content-type') ?? '';
        request.response.statusCode = response.statusCode ?? 200;

        final isPlaylist = ct.contains('mpegurl') ||
            target.toLowerCase().contains('.m3u8');
        if (isPlaylist) {
          request.response.headers.contentType =
              ContentType.parse('application/vnd.apple.mpegurl');
          final raw = utf8.decode((response.data as List).cast<int>());
          final baseUri = Uri.parse(target);
          final rewritten = raw
              .split('\n')
              .map((line) {
                final t = line.trim();
                if (t.isEmpty || t.startsWith('#')) return line;
                final abs = baseUri.resolve(t).toString();
                return '/hls?u=${Uri.encodeComponent(abs)}';
              })
              .join('\n');
          request.response.write(rewritten);
        } else {
          if (ct.isNotEmpty) {
            request.response.headers.add('content-type', ct);
          }
          request.response.add((response.data as List).cast<int>());
        }
      } catch (_) {
        request.response.statusCode = 502;
      } finally {
        await request.response.close();
      }
    });
    return 'http://${server.address.host}:${server.port}/hls?u=${Uri.encodeComponent(sourceUrl)}';
  }

  Future<void> _stopHlsProxy() async {
    final server = _hlsProxyServer;
    _hlsProxyServer = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<VideoPlayerController?> _createLocalController(String rawUrl) async {
    try {
      final uri = Uri.tryParse(rawUrl);
      final file = (uri != null && uri.isScheme('file'))
          ? File.fromUri(uri)
          : File(rawUrl);
      final isHlsLocal = file.path.toLowerCase().endsWith('.m3u8');
      final controller = isHlsLocal
          ? VideoPlayerController.networkUrl(
              Uri.parse(await _startLocalHlsProxy(file)),
              formatHint: VideoFormat.hls,
              videoPlayerOptions: VideoPlayerOptions(
                mixWithOthers: false,
                allowBackgroundPlayback: true,
              ),
            )
          : VideoPlayerController.file(file);
      await controller.initialize().timeout(const Duration(seconds: 6));
      _isHlsPlayback = isHlsLocal;
      return controller;
    } catch (e, st) {
      AppLogger.w('Player', 'Local source init failed for $rawUrl',
          error: e, stackTrace: st);
      return null;
    }
  }

  Future<String> _startLocalHlsProxy(File manifest) async {
    await _stopHlsProxy();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _hlsProxyServer = server;
    server.listen((request) async {
      final targetEncoded = request.uri.queryParameters['f'];
      if (targetEncoded == null || targetEncoded.isEmpty) {
        request.response.statusCode = 400;
        await request.response.close();
        return;
      }

      final targetPath = Uri.decodeComponent(targetEncoded);
      final targetFile = File(targetPath);
      if (!await targetFile.exists()) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }

      final lower = targetFile.path.toLowerCase();
      try {
        if (lower.endsWith('.m3u8')) {
          request.response.headers.contentType =
              ContentType.parse('application/vnd.apple.mpegurl');
          final raw = await targetFile.readAsString();
          final baseUri = Uri.file(targetFile.path);
          final rewritten = raw.split('\n').map((line) {
            final t = line.trim();
            if (t.isEmpty || t.startsWith('#')) return line;
            if (t.startsWith('http://') || t.startsWith('https://')) {
              return line;
            }
            final absPath = baseUri.resolve(t).toFilePath();
            return '/lhls?f=${Uri.encodeComponent(absPath)}';
          }).join('\n');
          request.response.write(rewritten);
        } else {
          if (lower.endsWith('.ts')) {
            request.response.headers.add('content-type', 'video/mp2t');
          }
          request.response.add(await targetFile.readAsBytes());
        }
      } catch (_) {
        request.response.statusCode = 502;
      } finally {
        await request.response.close();
      }
    });
    return 'http://${server.address.host}:${server.port}/lhls?f=${Uri.encodeComponent(manifest.path)}';
  }

  Future<void> _fetchAniSkipData() async {
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
      final c = _videoController;
      if (!mounted || c == null) return;
      final v = c.value;
      if (!v.isInitialized) return;
      setState(() {
        _durationSec = v.duration.inMilliseconds <= 0
            ? 0
            : v.duration.inMilliseconds / 1000.0;
        _currentSec = v.position.inMilliseconds <= 0
            ? 0
            : v.position.inMilliseconds / 1000.0;
      });
      if (!_didEpisodeEndCleanup &&
          _durationSec > 0 &&
          (_currentSec / _durationSec) >= 0.99) {
        _didEpisodeEndCleanup = true;
        unawaited(_clearPlaybackCaches());
      }
      _trimLiveHlsSegments();
      unawaited(_maybeAutoUpdateTracking());
    });
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
    if (_currentSec / _durationSec < 0.85) return;

    final source = ref.read(librarySourceProvider);
    if (source == LibrarySource.local) {
      _autoTrackingSyncTriggered = true;
      try {
        final current =
            await ref.read(localLibraryStoreProvider).entryForMedia(widget.mediaId);
        final nextProgress = (current?.episodesWatched ?? 0) + 1;
        await ref.read(localLibraryStoreProvider).upsertByMediaId(
              widget.mediaId,
              title: widget.mediaTitle,
              status: current?.status ?? 'CURRENT',
              progress: nextProgress,
              score: current?.userScore ?? 0,
            );
        ref.invalidate(localLibraryEntriesProvider);
        ref.invalidate(mediaListProvider(widget.mediaId));
      } catch (e, st) {
        _autoTrackingSyncTriggered = false;
        AppLogger.w(
          'Player',
          'Auto local progress sync failed',
          error: e,
          stackTrace: st,
        );
      }
      return;
    }

    final auth = ref.read(authControllerProvider);
    final token = auth.token;
    if (token == null || token.isEmpty) return;

    _autoTrackingSyncTriggered = true;
    final client = ref.read(anilistClientProvider);
    try {
      final current = await client.trackingEntry(token, widget.mediaId);
      final nextProgress = (current?.progress ?? 0) + 1;
      await client.saveTrackingEntry(
        token: token,
        mediaId: widget.mediaId,
        status: current?.status ?? 'CURRENT',
        progress: nextProgress,
        score: current?.score ?? 0,
      );
      ref.invalidate(mediaListProvider(widget.mediaId));
    } catch (e, st) {
      _autoTrackingSyncTriggered = false;
      AppLogger.w(
        'Player',
        'Auto AniList progress sync failed',
        error: e,
        stackTrace: st,
      );
    }
  }

  void _scheduleOverlayAutoHide() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 2), () {
      final c = _videoController;
      if (!mounted || c == null) return;
      if (c.value.isPlaying) {
        setState(() => _overlayVisible = false);
      }
    });
  }

  void _registerInteraction() {
    if (!_overlayVisible) {
      setState(() => _overlayVisible = true);
    }
    _scheduleOverlayAutoHide();
  }

  void _handleSurfaceTap() {
    if (_overlayVisible) {
      setState(() => _overlayVisible = false);
      _overlayHideTimer?.cancel();
      return;
    }
    _registerInteraction();
  }

  Future<void> _bindController(VideoPlayerController controller) async {
    await _disposeControllers();

    final chewie = ChewieController(
      videoPlayerController: controller,
      autoInitialize: false,
      autoPlay: false,
      showControls: false,
      allowFullScreen: true,
      allowMuting: true,
      allowedScreenSleep: false,
      errorBuilder: (context, errorMessage) => Center(
        child: Text(
          errorMessage,
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );

    final saved = _progressStore.read(widget.mediaId, widget.episodeNumber);
    var initialPositionMs = saved?.positionMs ?? 0;
    if (initialPositionMs <= 0 && widget.isLocal) {
      final downloadItem =
          ref.read(downloadControllerProvider).item(widget.mediaId, widget.episodeNumber);
      initialPositionMs = downloadItem?.lastPositionMs ?? 0;
    }
    if (initialPositionMs > 0) {
      final seek = Duration(milliseconds: initialPositionMs);
      if (seek < controller.value.duration) {
        await controller.seekTo(seek);
      }
    }

    _videoController = controller;
    _chewieController = chewie;

    await controller.play();
    if (_isHlsPlayback) {
      unawaited(_ensureInitialBufferAhead());
    }

    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_persistProgress());
    });

    _startUiPoll();
    _scheduleOverlayAutoHide();
  }

  Future<void> _ensureInitialBufferAhead() async {
    final c = _videoController;
    if (c == null || !_isHlsPlayback) return;
    final deadline = DateTime.now().add(const Duration(seconds: 8));
    while (mounted && DateTime.now().isBefore(deadline)) {
      final v = c.value;
      if (!v.isInitialized) break;
      final pos = v.position;
      var bufferedAhead = Duration.zero;
      for (final r in v.buffered) {
        if (r.end <= pos) continue;
        final start = r.start > pos ? r.start : pos;
        final span = r.end - start;
        if (span > bufferedAhead) bufferedAhead = span;
      }
      if (bufferedAhead >= const Duration(seconds: 30)) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
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
            if (p.endsWith('.m3u8') ||
                p.endsWith('.ts') ||
                p.contains('hls')) {
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
    localFile ??=
        await downloader.getLocalEpisodeByMedia(widget.mediaId, widget.episodeNumber);
    if (localFile != null) {
      final localController = await _createLocalController(localFile.path);
      if (localController != null) {
        await _bindController(localController);
        if (!mounted) return;
        setState(() {
          _isInitializing = false;
          _initError = null;
        });
        return;
      }
    }

    final url =
        widget.sourceUrl == null ? null : _sanitizeUrl(widget.sourceUrl!);
    if (url == null || url.isEmpty) {
      setState(() {
        _isInitializing = false;
        _initError = 'Missing source URL.';
      });
      return;
    }

    VideoPlayerController? selected;

    if (widget.isLocal) {
      selected = await _createLocalController(url);
      if (selected == null && widget.fallbackSources.isNotEmpty) {
        _candidates = _buildCandidates(
          widget.fallbackSources.first.url,
          widget.fallbackSources,
        );
        for (var i = 0; i < _candidates.length; i++) {
          final controller = await _createNetworkController(_candidates[i]);
          if (controller != null) {
            selected = controller;
            _activeCandidateIndex = i;
            break;
          }
        }
      }
    } else {
      _candidates = _buildCandidates(url, widget.fallbackSources);
      for (var i = 0; i < _candidates.length; i++) {
        final controller = await _createNetworkController(_candidates[i]);
        if (controller != null) {
          selected = controller;
          _activeCandidateIndex = i;
          break;
        }
      }
    }

    if (selected == null) {
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

    await _bindController(selected);

    AppLogger.i(
      'Player',
      'Playback initialized for media ${widget.mediaId} ep ${widget.episodeNumber} candidate=$_activeCandidateIndex/${_candidates.length}',
    );

    if (!mounted) return;
    setState(() {
      _isInitializing = false;
      _initError = null;
    });
  }

  Future<void> _persistProgress() async {
    final controller = _videoController;
    if (controller == null) return;
    final value = controller.value;
    if (!value.isInitialized || value.duration.inMilliseconds <= 0) return;

    await _progressStore.write(
      mediaId: widget.mediaId,
      episode: widget.episodeNumber,
      positionMs: value.position.inMilliseconds,
      durationMs: value.duration.inMilliseconds,
    );
    if (widget.isLocal) {
      await ref.read(downloadControllerProvider.notifier).setLocalPlaybackPosition(
            widget.mediaId,
            widget.episodeNumber,
            positionMs: value.position.inMilliseconds,
            durationMs: value.duration.inMilliseconds,
          );
    }
  }

  Future<void> _seekByRatio(double ratio) async {
    final c = _videoController;
    if (c == null || _durationSec <= 0) return;
    final targetMs = (_durationSec * ratio.clamp(0.0, 1.0) * 1000).round();
    await c.seekTo(Duration(milliseconds: targetMs));
  }

  Future<void> _seekToSeconds(double sec) async {
    final c = _videoController;
    if (c == null) return;
    final clamped = _durationSec <= 0 ? 0.0 : sec.clamp(0.0, _durationSec);
    await c.seekTo(Duration(milliseconds: (clamped * 1000).round()));
  }

  Future<void> _seekRelative(Duration delta) async {
    final c = _videoController;
    if (c == null) return;
    final pos = c.value.position;
    final dur = c.value.duration;
    var target = pos + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (dur > Duration.zero && target > dur) target = dur;
    await c.seekTo(target);
    _registerInteraction();
  }

  void _handleHorizontalSeekStart(DragStartDetails details) {
    if (_videoController == null || _durationSec <= 0) return;
    _registerInteraction();
    setState(() {
      _isHorizontalSeeking = true;
      _horizontalSeekSec = _currentSec;
      _lastHorizontalSeekX = details.globalPosition.dx;
    });
  }

  void _handleHorizontalSeekUpdate(DragUpdateDetails details) {
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
    if (!_isHorizontalSeeking) return;
    final target = _horizontalSeekSec;
    setState(() => _isHorizontalSeeking = false);
    unawaited(_seekToSeconds(target));
    _registerInteraction();
  }

  void _handleDoubleTapSkip(TapDownDetails details) {
    final width = MediaQuery.sizeOf(context).width;
    final isForward = details.localPosition.dx > width / 2;
    HapticFeedback.lightImpact();
    setState(() {
      _skipAnimationPosition = details.localPosition;
      _skipAnimationForward = isForward;
    });
    _skipAnimationController.forward(from: 0);
    unawaited(
      _seekRelative(Duration(seconds: isForward ? 10 : -10)),
    );
  }

  Future<void> _enterPip() async {
    if (!Platform.isAndroid || !_pipSupported) return;
    try {
      await _simplePip.enterPipMode(
        seamlessResize: true,
      );
    } catch (_) {}
  }

  Future<void> _togglePlayPause() async {
    final c = _videoController;
    if (c == null) return;
    if (c.value.isPlaying) {
      await c.pause();
      setState(() => _overlayVisible = true);
      _overlayHideTimer?.cancel();
    } else {
      await c.play();
      _registerInteraction();
    }
  }

  bool get _isWithinOpeningRange {
    final s = opStart;
    final e = opEnd;
    if (s == null || e == null) return false;
    final current = _currentSec;
    return current >= s && current <= e;
  }

  Future<void> _skipIntro() async {
    final c = _videoController;
    final end = opEnd;
    if (c == null || end == null) return;
    HapticFeedback.lightImpact();
    await c.seekTo(Duration(milliseconds: (end * 1000).round()));
    _registerInteraction();
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
    final chewie = _chewieController;
    final video = _videoController;
    _chewieController = null;
    _videoController = null;
    if (chewie != null) {
      unawaited(chewie.pause());
      chewie.dispose();
    }
    if (video != null) {
      unawaited(video.pause());
      video.dispose();
    }
    _skipAnimationController.dispose();
    unawaited(WakelockPlus.disable());
    unawaited(_stopHlsProxy());
    unawaited(_clearPlaybackCaches());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showCustomProgress = _chewieController != null && _durationSec > 0;
    final uiCurrent = _isDragging ? _dragValueSec : _currentSec;
    final isPlaying = _videoController?.value.isPlaying ?? false;

    return PopScope(
      canPop: true,
      onPopInvokedWithResult: (_, __) {
        if (mounted) {
          ref.invalidate(episodeProvider);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
        child: Stack(
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
            else if (_chewieController != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _handleSurfaceTap,
                  onDoubleTapDown: _handleDoubleTapSkip,
                  onHorizontalDragStart: _handleHorizontalSeekStart,
                  onHorizontalDragUpdate: _handleHorizontalSeekUpdate,
                  onHorizontalDragEnd: (_) => _handleHorizontalSeekEnd(),
                  onHorizontalDragCancel: _handleHorizontalSeekEnd,
                  child: Chewie(controller: _chewieController!),
                ),
              ),
            AnimatedOpacity(
              opacity: _overlayVisible ? 1 : 0,
              duration: const Duration(milliseconds: 220),
              child: IgnorePointer(
                ignoring: !_overlayVisible,
                child: Stack(
                  children: [
                    if (_pipSupported)
                      Positioned(
                        top: 8,
                        right: 8,
                        child: Material(
                          color: const Color(0xFA1E1E1E),
                          borderRadius: BorderRadius.circular(999),
                          child: InkWell(
                            onTap: _enterPip,
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
                      ),
                    Align(
                      alignment: Alignment.center,
                      child: Container(
                        padding:
                            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFA1E1E1E),
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                              color: Colors.white.withValues(alpha: 0.10)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              style: IconButton.styleFrom(
                                backgroundColor: Colors.black45,
                                foregroundColor: Colors.white,
                              ),
                              onPressed: () {
                                hapticTap();
                                _togglePlayPause();
                              },
                              icon: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (showCustomProgress)
                      Positioned(
                        left: 12,
                        right: 12,
                        bottom: 18,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) {
                                final box =
                                    context.findRenderObject() as RenderBox?;
                                if (box == null) return;
                                final ratio =
                                    (details.localPosition.dx / box.size.width)
                                        .clamp(0.0, 1.0);
                                unawaited(_seekByRatio(ratio));
                                _registerInteraction();
                              },
                              onHorizontalDragStart: (_) {
                                _registerInteraction();
                                setState(() {
                                  _isDragging = true;
                                  _dragValueSec = uiCurrent;
                                });
                              },
                              onHorizontalDragUpdate: (details) {
                                final box =
                                    context.findRenderObject() as RenderBox?;
                                if (box == null || _durationSec <= 0) return;
                                final localDx = details.localPosition.dx;
                                final ratio =
                                    (localDx / box.size.width).clamp(0.0, 1.0);
                                setState(
                                    () => _dragValueSec = _durationSec * ratio);
                              },
                              onHorizontalDragEnd: (_) {
                                final ratio = _durationSec <= 0
                                    ? 0.0
                                    : _dragValueSec / _durationSec;
                                setState(() => _isDragging = false);
                                unawaited(_seekByRatio(ratio));
                                _registerInteraction();
                              },
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final width = constraints.maxWidth;
                                  final safeDuration =
                                      _durationSec <= 0 ? 1.0 : _durationSec;
                                  final playedRatio = (uiCurrent / safeDuration)
                                      .clamp(0.0, 1.0);
                                  final playedWidth = width * playedRatio;

                                  final start = opStart;
                                  final end = opEnd;
                                  final hasOpening = start != null &&
                                      end != null &&
                                      end > start;

                                  final openingLeft = hasOpening
                                      ? (start / safeDuration) * width
                                      : 0.0;
                                  final openingWidth = hasOpening
                                      ? ((end - start) / safeDuration) * width
                                      : 0.0;

                                  return SizedBox(
                                    height: 52,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          top: 26,
                                          child: Container(
                                            height: 6,
                                            decoration: BoxDecoration(
                                              color: Colors.white24,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                        ),
                                        if (hasOpening)
                                          Positioned(
                                            left: openingLeft.clamp(0.0, width),
                                            top: 26,
                                            child: Container(
                                              height: 6,
                                              width: openingWidth.clamp(
                                                  0.0, width),
                                              decoration: BoxDecoration(
                                                color: Colors.yellow
                                                    .withValues(alpha: 0.3),
                                                borderRadius:
                                                    BorderRadius.circular(8),
                                              ),
                                            ),
                                          ),
                                        Positioned(
                                          left: 0,
                                          top: 26,
                                          child: Container(
                                            height: 6,
                                            width: playedWidth,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: (playedWidth - 8).clamp(0.0,
                                              (width - 16).clamp(0.0, width)),
                                          top: 21,
                                          child: Container(
                                            width: 16,
                                            height: 16,
                                            decoration: const BoxDecoration(
                                              color: Colors.white,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                        ),
                                        Positioned(
                                          left: (playedWidth - 28).clamp(0.0,
                                              (width - 56).clamp(0.0, width)),
                                          top: 0,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 3),
                                            decoration: BoxDecoration(
                                              color: Colors.black87,
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              _fmt(uiCurrent),
                                              style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 10),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: Row(
                                children: [
                                  Text(
                                    _fmt(uiCurrent),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  ),
                                  const Spacer(),
                                  Text(
                                    '-${_fmt((_durationSec - uiCurrent).clamp(0, _durationSec))}',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    Positioned(
                      right: 12,
                      bottom: 74,
                      child: AnimatedOpacity(
                        duration: const Duration(milliseconds: 180),
                        opacity: _isWithinOpeningRange ? 1.0 : 0.0,
                        child: IgnorePointer(
                          ignoring: !_isWithinOpeningRange,
                          child: Material(
                            color: const Color(0xFA1E1E1E),
                            borderRadius: BorderRadius.circular(999),
                            child: InkWell(
                              onTap: _skipIntro,
                              borderRadius: BorderRadius.circular(999),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 14,
                                  vertical: 10,
                                ),
                                decoration: BoxDecoration(
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.10),
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.skip_next_rounded,
                                      color: Colors.white,
                                      size: 16,
                                    ),
                                    SizedBox(width: 6),
                                    Text(
                                      'Skip Intro',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
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
                          left: _skipAnimationPosition.dx - (rippleSize / 2),
                          top: _skipAnimationPosition.dy - (rippleSize / 2),
                          child: Container(
                            width: rippleSize,
                            height: rippleSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white.withValues(
                                  alpha: 0.35 * (1 - t),
                                ),
                                width: 1.2,
                              ),
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
                                  color: Colors.black.withValues(alpha: 0.45),
                                  shape: BoxShape.circle,
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.18),
                                  ),
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
    );
  }
}
