import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

import '../../core/app_logger.dart';
import '../../state/auth_state.dart';
import 'widgets/anime_player_mesh_background.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.mediaId,
    required this.episodeNumber,
    required this.episodeTitle,
    required this.sourceUrl,
    this.headers = const {},
    this.isLocal = false,
    this.backgroundImageUrl,
  });

  final int mediaId;
  final int episodeNumber;
  final String episodeTitle;
  final String? sourceUrl;
  final Map<String, String> headers;
  final bool isLocal;
  final String? backgroundImageUrl;

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
  VideoPlayerController? _controller;
  Timer? _persistTimer;
  Timer? _controlsHideTimer;

  bool _controlsVisible = true;
  bool _ready = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isScrubbing = false;
  bool _hasRecoveredFromError = false;
  bool _wasPlayingBeforeBackground = false;

  double _playbackSpeed = 1.0;
  double _speedBeforeHold = 1.0;
  String? _initError;
  String? _skipIndicator;
  double? _scrubValue;

  List<_PlayerCandidate> _candidates = const [];
  int _activeCandidateIndex = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _wasPlayingBeforeBackground = c.value.isPlaying;
      unawaited(_persistProgress());
      return;
    }

    if (state == AppLifecycleState.resumed && _wasPlayingBeforeBackground) {
      unawaited(c.play());
      _scheduleControlsAutoHide();
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
      if (normalized.trim().isEmpty) return;
      final key =
          '$normalized|${h.entries.map((e) => '${e.key}=${e.value}').join(';')}';
      if (seen.contains(key)) return;
      seen.add(key);
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

  Future<VideoPlayerController?> _createController(_PlayerCandidate c) async {
    final controller = VideoPlayerController.networkUrl(
      Uri.parse(c.url),
      httpHeaders: c.headers,
      videoPlayerOptions: VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );
    try {
      await controller.initialize();
      return controller;
    } catch (e, st) {
      AppLogger.w('Player', 'Init attempt failed for ${c.url}',
          error: e, stackTrace: st);
      await controller.dispose();
      return null;
    }
  }

  Future<VideoPlayerController?> _createLocalController(String rawUrl) async {
    final uri = Uri.parse(rawUrl);
    final file = uri.isScheme('file') ? File.fromUri(uri) : File(rawUrl);
    final controller = VideoPlayerController.file(
      file,
      videoPlayerOptions: VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );
    try {
      await controller.initialize();
      return controller;
    } catch (e, st) {
      AppLogger.w('Player', 'Local source init failed for ${file.path}',
          error: e, stackTrace: st);
      await controller.dispose();
      return null;
    }
  }

  Future<void> _attachController(VideoPlayerController next) async {
    final old = _controller;
    old?.removeListener(_onPlayerUpdate);
    _controller = next;
    next.addListener(_onPlayerUpdate);
    await old?.dispose();
  }

  Future<bool> _tryAttachCandidate(int index) async {
    if (index < 0 || index >= _candidates.length) return false;
    final c = _candidates[index];
    final controller = await _createController(c);
    if (controller == null) return false;
    _activeCandidateIndex = index;
    await _attachController(controller);
    return true;
  }

  Future<void> _init() async {
    final url =
        widget.sourceUrl == null ? null : _sanitizeUrl(widget.sourceUrl!);
    if (url == null || url.isEmpty) {
      AppLogger.w('Player',
          'Missing source URL for media ${widget.mediaId} ep ${widget.episodeNumber}');
      if (mounted) {
        setState(() {
          _initError = 'Missing source URL.';
        });
      }
      return;
    }

    bool attached = false;

    if (widget.isLocal) {
      final local = await _createLocalController(url);
      if (local != null) {
        attached = true;
        await _attachController(local);
      }
    } else {
      _candidates = _buildCandidates(url);
      for (var i = 0; i < _candidates.length; i++) {
        attached = await _tryAttachCandidate(i);
        if (attached) break;
      }
    }

    if (!attached) {
      AppLogger.e('Player',
          'All source init attempts failed for media ${widget.mediaId} ep ${widget.episodeNumber}',
          error: url);
      if (mounted) {
        setState(() {
          _ready = false;
          _initError =
              'No playable source for this episode yet. Try another quality/source.';
        });
      }
      return;
    }

    final c = _controller!;
    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      final maxMs = c.value.duration.inMilliseconds;
      if (maxMs > 0) {
        final seekMs = saved.positionMs.clamp(0, maxMs);
        await c.seekTo(Duration(milliseconds: seekMs));
      }
    }

    await c.setPlaybackSpeed(_playbackSpeed);
    await c.play();

    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _persistProgress();
    });

    AppLogger.i('Player',
        'Playback initialized for media ${widget.mediaId} ep ${widget.episodeNumber} candidate=$_activeCandidateIndex');

    if (mounted) {
      setState(() {
        _ready = true;
        _isPlaying = c.value.isPlaying;
        _isBuffering = c.value.isBuffering;
        _initError = null;
      });
      _scheduleControlsAutoHide();
    }
  }

  Future<void> _persistProgress() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final durationMs = c.value.duration.inMilliseconds;
    if (durationMs <= 0) return;

    await ref.read(progressStoreProvider).write(
          mediaId: widget.mediaId,
          episode: widget.episodeNumber,
          positionMs: c.value.position.inMilliseconds,
          durationMs: durationMs,
        );
  }

  void _onPlayerUpdate() {
    final c = _controller;
    if (c == null || !mounted || !c.value.isInitialized) return;

    final nextPlaying = c.value.isPlaying;
    final nextBuffering = c.value.isBuffering;

    if (_isPlaying != nextPlaying || _isBuffering != nextBuffering) {
      setState(() {
        _isPlaying = nextPlaying;
        _isBuffering = nextBuffering;
      });
    }

    if (c.value.hasError && !_hasRecoveredFromError && !widget.isLocal) {
      _hasRecoveredFromError = true;
      unawaited(_recoverFromPlaybackError());
    }
  }

  Future<void> _recoverFromPlaybackError() async {
    if (_activeCandidateIndex < 0) return;
    for (var i = _activeCandidateIndex + 1; i < _candidates.length; i++) {
      final savedPos = _controller?.value.position ?? Duration.zero;
      final attached = await _tryAttachCandidate(i);
      if (!attached) continue;
      final c = _controller;
      if (c == null) continue;
      if (savedPos > Duration.zero && c.value.duration > Duration.zero) {
        final target =
            savedPos > c.value.duration ? c.value.duration : savedPos;
        await c.seekTo(target);
      }
      await c.setPlaybackSpeed(_playbackSpeed);
      await c.play();
      AppLogger.w('Player', 'Recovered playback using candidate $i');
      if (mounted) {
        setState(() {
          _initError = null;
          _ready = true;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _initError = 'Playback failed. Try another source.';
      });
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    final target = c.value.position + delta;
    final max = c.value.duration;
    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (clamped > max) clamped = max;
    await c.seekTo(clamped);

    final seconds = delta.inSeconds.abs();
    final sign = delta.isNegative ? '-' : '+';
    _showSkipIndicator('$sign$seconds s');
    _scheduleControlsAutoHide();
  }

  void _showSkipIndicator(String text) {
    setState(() => _skipIndicator = text);
    Future<void>.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      setState(() => _skipIndicator = null);
    });
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) {
      _scheduleControlsAutoHide();
    } else {
      _controlsHideTimer?.cancel();
    }
  }

  void _scheduleControlsAutoHide() {
    _controlsHideTimer?.cancel();
    if (!_isPlaying) return;
    _controlsHideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  Future<void> _togglePlayPause() async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (c.value.isPlaying) {
      await c.pause();
      _controlsHideTimer?.cancel();
    } else {
      await c.play();
      _scheduleControlsAutoHide();
    }
  }

  Future<void> _setSpeed(double speed) async {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    await c.setPlaybackSpeed(speed);
    if (!mounted) return;
    setState(() => _playbackSpeed = speed);
  }

  Future<void> _cycleSpeed() async {
    const speeds = [0.75, 1.0, 1.25, 1.5, 2.0];
    final idx = speeds.indexWhere((s) => (s - _playbackSpeed).abs() < 0.01);
    final next = speeds[(idx + 1) % speeds.length];
    await _setSpeed(next);
    _showSkipIndicator(
        '${next.toStringAsFixed(next == next.roundToDouble() ? 0 : 2)}x');
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistTimer?.cancel();
    _controlsHideTimer?.cancel();
    _controller?.removeListener(_onPlayerUpdate);
    unawaited(_persistProgress());
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    final ready =
        controller != null && _ready && controller.value.isInitialized;

    final durationMs = ready ? controller.value.duration.inMilliseconds : 0;
    final positionMs = ready
        ? controller.value.position.inMilliseconds
            .clamp(0, durationMs <= 0 ? 0 : durationMs)
        : 0;
    final sliderMax = durationMs <= 0 ? 1.0 : durationMs.toDouble();

    final sliderValue = _isScrubbing
        ? (_scrubValue ?? positionMs.toDouble())
        : positionMs.toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: AnimePlayerMeshBackground(
                  backgroundImageUrl: widget.backgroundImageUrl,
                ),
              ),
            ),
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _toggleControls,
                onDoubleTapDown: (details) {
                  final width = MediaQuery.of(context).size.width;
                  if (details.localPosition.dx < width / 2) {
                    _seekRelative(const Duration(seconds: -10));
                  } else {
                    _seekRelative(const Duration(seconds: 10));
                  }
                },
                onLongPressStart: (_) async {
                  _speedBeforeHold = _playbackSpeed;
                  await _setSpeed(2.0);
                  _showSkipIndicator('2x');
                },
                onLongPressEnd: (_) async {
                  await _setSpeed(_speedBeforeHold);
                },
                child: Center(
                  child: ready
                      ? AspectRatio(
                          aspectRatio: controller.value.aspectRatio <= 0
                              ? (16 / 9)
                              : controller.value.aspectRatio,
                          child: Stack(
                            children: [
                              Positioned.fill(child: VideoPlayer(controller)),
                              if (_isBuffering)
                                const Positioned.fill(
                                  child: Center(
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2),
                                  ),
                                ),
                            ],
                          ),
                        )
                      : Text(
                          _initError ?? 'Loading source...',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
                        ),
                ),
              ),
            ),
            if (_skipIndicator != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _skipIndicator == null ? 0 : 1,
                      duration: const Duration(milliseconds: 140),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.5),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          _skipIndicator!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_controlsVisible)
              Positioned(
                top: 8,
                left: 8,
                child: IconButton.filledTonal(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ),
            if (_controlsVisible && ready)
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.episodeTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Slider(
                      value: sliderValue.clamp(0, sliderMax),
                      min: 0,
                      max: sliderMax,
                      onChangeStart: (v) {
                        _isScrubbing = true;
                        _scrubValue = v;
                      },
                      onChanged: (v) {
                        setState(() => _scrubValue = v);
                      },
                      onChangeEnd: (v) async {
                        _isScrubbing = false;
                        _scrubValue = null;
                        await controller
                            .seekTo(Duration(milliseconds: v.round()));
                        _scheduleControlsAutoHide();
                      },
                    ),
                    Row(
                      children: [
                        Text(
                          _formatDuration(Duration(milliseconds: positionMs)),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                        const Spacer(),
                        Text(
                          '-${_formatDuration(Duration(milliseconds: (durationMs - positionMs).clamp(0, durationMs)))}',
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 12),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        IconButton(
                          onPressed: () =>
                              _seekRelative(const Duration(seconds: -10)),
                          icon:
                              const Icon(Icons.replay_10, color: Colors.white),
                        ),
                        IconButton(
                          onPressed: _togglePlayPause,
                          icon: Icon(
                            _isPlaying ? Icons.pause : Icons.play_arrow,
                            color: Colors.white,
                          ),
                        ),
                        IconButton(
                          onPressed: () =>
                              _seekRelative(const Duration(seconds: 10)),
                          icon:
                              const Icon(Icons.forward_10, color: Colors.white),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: _cycleSpeed,
                          child: Text(
                            '${_playbackSpeed.toStringAsFixed(_playbackSpeed == _playbackSpeed.roundToDouble() ? 0 : 2)}x',
                            style: const TextStyle(color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
