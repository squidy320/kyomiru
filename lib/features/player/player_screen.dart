import 'dart:async';
import 'dart:io';

import 'package:chewie/chewie.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_logger.dart';
import '../../state/auth_state.dart';

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

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerCandidate {
  const _PlayerCandidate({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with WidgetsBindingObserver {
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;

  Timer? _persistTimer;
  Timer? _uiPollTimer;
  Timer? _overlayHideTimer;

  bool _isInitializing = true;
  bool _overlayVisible = true;
  String? _initError;

  List<_PlayerCandidate> _candidates = const [];
  int _activeCandidateIndex = -1;

  double _currentSec = 0;
  double _durationSec = 0;
  bool _isDragging = false;
  double _dragValueSec = 0;

  // AniSkip opening range (seconds)
  double? opStart;
  double? opEnd;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
      chewie.pause();
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

  List<_PlayerCandidate> _buildCandidates(String url) {
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
    try {
      final uri = Uri.parse(c.url);
      final controller = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: c.headers,
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: false,
          allowBackgroundPlayback: false,
        ),
      );
      await controller.initialize();
      return controller;
    } catch (e, st) {
      AppLogger.w('Player', 'Init attempt failed for ${c.url}',
          error: e, stackTrace: st);
      return null;
    }
  }

  Future<VideoPlayerController?> _createLocalController(String rawUrl) async {
    try {
      final uri = Uri.tryParse(rawUrl);
      final file =
          (uri != null && uri.isScheme('file')) ? File.fromUri(uri) : File(rawUrl);
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      return controller;
    } catch (e, st) {
      AppLogger.w('Player', 'Local source init failed for $rawUrl',
          error: e, stackTrace: st);
      return null;
    }
  }

  Future<void> _fetchAniSkipData() async {
    final malId = widget.malId;
    if (malId == null || malId <= 0) {
      AppLogger.w(
        'AniSkip',
        'Skipping fetch: missing MAL id for media=${widget.mediaId} ep=${widget.episodeNumber}',
      );
      return;
    }

    final url =
        'https://api.aniskip.com/v1/skip-times/$malId/${widget.episodeNumber}?types[]=op';

    try {
      final dio = Dio();
      AppLogger.i('AniSkip', 'Fetching OP timestamps url=$url');
      final res = await dio.get(
        url,
        options: Options(validateStatus: (_) => true),
      );
      AppLogger.i('AniSkip', 'Response status=${res.statusCode}');
      if ((res.statusCode ?? 0) >= 400) return;

      final data = res.data;
      if (data is! Map<String, dynamic>) return;
      final results = (data['results'] as List?) ?? const [];

      if (results.isEmpty) {
        AppLogger.w(
          'AniSkip',
          'No AniSkip results for media=${widget.mediaId} ep=${widget.episodeNumber}',
        );
      }

      for (final item in results) {
        if (item is! Map<String, dynamic>) continue;
        if ((item['skip_type'] ?? '').toString().toLowerCase() != 'op') {
          continue;
        }
        final interval = item['interval'];
        if (interval is! Map<String, dynamic>) continue;

        final start = (interval['start_time'] as num?)?.toDouble();
        final end = (interval['end_time'] as num?)?.toDouble();
        if (start == null || end == null || end <= start) continue;

        if (!mounted) return;
        setState(() {
          opStart = start;
          opEnd = end;
        });
        AppLogger.i(
          'AniSkip',
          'Loaded OP timestamps media=${widget.mediaId} ep=${widget.episodeNumber} start=$start end=$end',
        );
        return;
      }

      AppLogger.w(
        'AniSkip',
        'No OP range found in AniSkip results for media=${widget.mediaId} ep=${widget.episodeNumber}',
      );
    } catch (e, st) {
      AppLogger.w('AniSkip', 'Failed to fetch skip-times',
          error: e, stackTrace: st);
    }
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
    });
  }

  void _scheduleOverlayAutoHide() {
    _overlayHideTimer?.cancel();
    _overlayHideTimer = Timer(const Duration(seconds: 3), () {
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
      materialProgressColors: ChewieProgressColors(
        playedColor: Colors.white,
        handleColor: Colors.white,
        backgroundColor: Colors.white24,
        bufferedColor: Colors.white38,
      ),
      cupertinoProgressColors: ChewieProgressColors(
        playedColor: Colors.white,
        handleColor: Colors.white,
        backgroundColor: Colors.white24,
        bufferedColor: Colors.white38,
      ),
      errorBuilder: (context, errorMessage) => Center(
        child: Text(
          errorMessage,
          style: const TextStyle(color: Colors.white70),
          textAlign: TextAlign.center,
        ),
      ),
    );

    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      final seek = Duration(milliseconds: saved.positionMs);
      if (seek < controller.value.duration) {
        await controller.seekTo(seek);
      }
    }

    _videoController = controller;
    _chewieController = chewie;

    await controller.play();

    _persistTimer?.cancel();
    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_persistProgress());
    });

    _startUiPoll();
    _scheduleOverlayAutoHide();
  }

  Future<void> _init() async {
    final url = widget.sourceUrl == null ? null : _sanitizeUrl(widget.sourceUrl!);
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
    } else {
      _candidates = _buildCandidates(url);
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
      'Playback initialized for media ${widget.mediaId} ep ${widget.episodeNumber} candidate=$_activeCandidateIndex',
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

    await ref.read(progressStoreProvider).write(
          mediaId: widget.mediaId,
          episode: widget.episodeNumber,
          positionMs: value.position.inMilliseconds,
          durationMs: value.duration.inMilliseconds,
        );
  }

  Future<void> _seekByRatio(double ratio) async {
    final c = _videoController;
    if (c == null || _durationSec <= 0) return;
    final targetMs = (_durationSec * ratio.clamp(0.0, 1.0) * 1000).round();
    await c.seekTo(Duration(milliseconds: targetMs));
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
    final posSec = _videoController?.value.position.inMilliseconds.toDouble() ??
        (_currentSec * 1000);
    final current = posSec / 1000.0;
    return current >= s && current <= e;
  }

  Future<void> _skipIntro() async {
    final c = _videoController;
    final end = opEnd;
    if (c == null || end == null) return;
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
    _overlayHideTimer?.cancel();    unawaited(_disposeControllers());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final showCustomProgress = _chewieController != null && _durationSec > 0;
    final uiCurrent = _isDragging ? _dragValueSec : _currentSec;
    final isPlaying = _videoController?.value.isPlaying ?? false;

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            if (_isInitializing)
              const Center(child: CircularProgressIndicator(strokeWidth: 2))
            else if (_initError != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    _initError!,
                    style: const TextStyle(color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else if (_chewieController != null)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _handleSurfaceTap,
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
                    Positioned(
                      top: 8,
                      left: 8,
                      child: IconButton(
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.black54,
                          foregroundColor: Colors.white,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.arrow_back_rounded),
                      ),
                    ),
                    Align(
                      alignment: Alignment.center,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black38,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => _seekRelative(const Duration(seconds: -10)),
                            icon: const Icon(Icons.replay_10_rounded),
                          ),
                          const SizedBox(width: 14),
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black45,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: _togglePlayPause,
                            icon: Icon(
                              isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                            ),
                          ),
                          const SizedBox(width: 14),
                          IconButton(
                            style: IconButton.styleFrom(
                              backgroundColor: Colors.black38,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () => _seekRelative(const Duration(seconds: 10)),
                            icon: const Icon(Icons.forward_10_rounded),
                          ),
                        ],
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
                                final box = context.findRenderObject() as RenderBox?;
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
                                final box = context.findRenderObject() as RenderBox?;
                                if (box == null || _durationSec <= 0) return;
                                final localDx = details.localPosition.dx;
                                final ratio =
                                    (localDx / box.size.width).clamp(0.0, 1.0);
                                setState(() => _dragValueSec = _durationSec * ratio);
                              },
                              onHorizontalDragEnd: (_) {
                                final ratio =
                                    _durationSec <= 0 ? 0.0 : _dragValueSec / _durationSec;
                                setState(() => _isDragging = false);
                                unawaited(_seekByRatio(ratio));
                                _registerInteraction();
                              },
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final width = constraints.maxWidth;
                                  final safeDuration =
                                      _durationSec <= 0 ? 1.0 : _durationSec;
                                  final playedRatio =
                                      (uiCurrent / safeDuration).clamp(0.0, 1.0);
                                  final playedWidth = width * playedRatio;

                                  final start = opStart;
                                  final end = opEnd;
                                  final hasOpening =
                                      start != null && end != null && end > start;

                                  final openingLeft = hasOpening
                                      ? (start / safeDuration) * width
                                      : 0.0;
                                  final openingWidth = hasOpening
                                      ? ((end - start) / safeDuration) * width
                                      : 0.0;

                                  return SizedBox(
                                    height: 16,
                                    child: Stack(
                                      children: [
                                        Positioned(
                                          left: 0,
                                          right: 0,
                                          top: 5,
                                          child: Container(
                                            height: 6,
                                            decoration: BoxDecoration(
                                              color: Colors.white24,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                        if (hasOpening)
                                          Positioned(
                                            left: openingLeft.clamp(0.0, width),
                                            top: 5,
                                            child: Container(
                                              height: 6,
                                              width: openingWidth.clamp(0.0, width),
                                              decoration: BoxDecoration(
                                                color: Colors.yellow
                                                    .withValues(alpha: 0.3),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                            ),
                                          ),
                                        Positioned(
                                          left: 0,
                                          top: 5,
                                          child: Container(
                                            height: 6,
                                            width: playedWidth,
                                            decoration: BoxDecoration(
                                              color: Colors.white,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            ),
                            Row(
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
                          child: ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF1E1E1E),
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 14, vertical: 10),
                            ),
                            onPressed: _skipIntro,
                            icon: const Icon(Icons.skip_next_rounded),
                            label: const Text('Skip Intro'),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}




