import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_logger.dart';
import '../../core/apple_material_overlay.dart';
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
  });

  final int mediaId;
  final int episodeNumber;
  final String episodeTitle;
  final String? sourceUrl;
  final String? mediaTitle;
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
  Player? _player;
  VideoController? _videoController;

  Timer? _persistTimer;
  Timer? _controlsHideTimer;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<String>? _errorSub;

  bool _controlsVisible = true;
  bool _ready = false;
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isScrubbing = false;
  bool _hasRecoveredFromError = false;
  bool _wasPlayingBeforeBackground = false;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

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
    final p = _player;
    if (p == null) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _wasPlayingBeforeBackground = _isPlaying;
      unawaited(_persistProgress());
      return;
    }

    if (state == AppLifecycleState.resumed && _wasPlayingBeforeBackground) {
      unawaited(p.play());
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

  Future<void> _attachPlayer(Player player) async {
    await _positionSub?.cancel();
    await _durationSub?.cancel();
    await _playingSub?.cancel();
    await _bufferingSub?.cancel();
    await _errorSub?.cancel();

    final old = _player;
    _player = player;
    _videoController = VideoController(player);

    _positionSub = player.stream.position.listen((v) {
      if (!mounted) return;
      setState(() => _position = v);
    });
    _durationSub = player.stream.duration.listen((v) {
      if (!mounted) return;
      setState(() => _duration = v);
    });
    _playingSub = player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _isPlaying = v);
    });
    _bufferingSub = player.stream.buffering.listen((v) {
      if (!mounted) return;
      setState(() => _isBuffering = v);
    });
    _errorSub = player.stream.error.listen((msg) {
      if (_hasRecoveredFromError || widget.isLocal) return;
      _hasRecoveredFromError = true;
      AppLogger.w('Player', 'media_kit stream error', error: msg);
      unawaited(_recoverFromPlaybackError());
    });

    await old?.dispose();
  }

  Future<Player?> _openCandidate(_PlayerCandidate c) async {
    final player = Player();
    try {
      final media = Media(c.url, httpHeaders: c.headers);
      await player.open(media, play: true);
      return player;
    } catch (e, st) {
      AppLogger.w('Player', 'Init attempt failed for ${c.url}',
          error: e, stackTrace: st);
      await player.dispose();
      return null;
    }
  }

  Future<Player?> _openLocal(String rawUrl) async {
    final player = Player();
    try {
      final uri = Uri.parse(rawUrl);
      final file = uri.isScheme('file') ? File.fromUri(uri) : File(rawUrl);
      await player.open(Media(file.path), play: true);
      return player;
    } catch (e, st) {
      AppLogger.w('Player', 'Local source init failed for $rawUrl',
          error: e, stackTrace: st);
      await player.dispose();
      return null;
    }
  }

  Future<bool> _tryAttachCandidate(int index) async {
    if (index < 0 || index >= _candidates.length) return false;
    final c = _candidates[index];
    final player = await _openCandidate(c);
    if (player == null) return false;
    _activeCandidateIndex = index;
    await _attachPlayer(player);
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
      final local = await _openLocal(url);
      if (local != null) {
        attached = true;
        await _attachPlayer(local);
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

    final p = _player!;
    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      final seekMs = saved.positionMs;
      await p.seek(Duration(milliseconds: seekMs));
    }

    await p.setRate(_playbackSpeed);
    await p.play();

    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      await _persistProgress();
    });

    AppLogger.i('Player',
        'Playback initialized for media ${widget.mediaId} ep ${widget.episodeNumber} candidate=$_activeCandidateIndex');

    if (mounted) {
      setState(() {
        _ready = true;
        _initError = null;
      });
      _scheduleControlsAutoHide();
    }
  }

  Future<void> _persistProgress() async {
    if (_duration.inMilliseconds <= 0) return;

    await ref.read(progressStoreProvider).write(
          mediaId: widget.mediaId,
          episode: widget.episodeNumber,
          positionMs: _position.inMilliseconds,
          durationMs: _duration.inMilliseconds,
        );
  }

  Future<void> _recoverFromPlaybackError() async {
    if (_activeCandidateIndex < 0) return;
    for (var i = _activeCandidateIndex + 1; i < _candidates.length; i++) {
      final savedPos = _position;
      final attached = await _tryAttachCandidate(i);
      if (!attached) continue;
      final p = _player;
      if (p == null) continue;
      if (savedPos > Duration.zero) {
        await p.seek(savedPos);
      }
      await p.setRate(_playbackSpeed);
      await p.play();
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
    final p = _player;
    if (p == null) return;
    final target = _position + delta;
    Duration clamped = target;
    if (clamped < Duration.zero) clamped = Duration.zero;
    if (_duration > Duration.zero && clamped > _duration) clamped = _duration;
    await p.seek(clamped);

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
  }

  Future<void> _togglePlayPause() async {
    final p = _player;
    if (p == null) return;
    if (_isPlaying) {
      await p.pause();
      _controlsHideTimer?.cancel();
    } else {
      await p.play();
      _scheduleControlsAutoHide();
    }
  }

  Future<void> _setSpeed(double speed) async {
    final p = _player;
    if (p == null) return;
    await p.setRate(speed);
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
    _positionSub?.cancel();
    _durationSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _errorSub?.cancel();
    unawaited(_persistProgress());
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _player != null && _ready;

    final durationMs = ready ? _duration.inMilliseconds : 0;
    final positionMs = ready
        ? _position.inMilliseconds.clamp(0, durationMs <= 0 ? 0 : durationMs)
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
            const Positioned.fill(
              child: ColoredBox(color: Colors.black),
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
                      ? Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: AspectRatio(
                                    aspectRatio: 16 / 9,
                                    child: Video(controller: _videoController!),
                                  ),
                                ),
                                if (_isBuffering)
                                  const Positioned.fill(
                                    child: Center(
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    ),
                                  ),
                              ],
                            ),
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
                      child: AppleMaterialOverlay(
                        borderRadius: BorderRadius.circular(999),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
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
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: _controlsVisible ? 1 : 0,
                duration: const Duration(milliseconds: 220),
                child: IgnorePointer(
                  ignoring: !_controlsVisible,
                  child: Stack(
                    children: [
                      Positioned(
                        top: 8,
                        left: 12,
                        child: _AppleCircleButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icons.close,
                        ),
                      ),
                      Positioned(
                        top: 8,
                        right: 12,
                        child: AppleMaterialOverlay(
                          borderRadius: BorderRadius.circular(999),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 14, vertical: 8),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.speed,
                                  size: 16, color: Colors.white),
                              const SizedBox(width: 6),
                              Text(
                                '${_playbackSpeed.toStringAsFixed(_playbackSpeed == _playbackSpeed.roundToDouble() ? 0 : 2)}x',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      Align(
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _AppleCircleButton(
                              onPressed: () =>
                                  _seekRelative(const Duration(seconds: -10)),
                              icon: Icons.replay_10_rounded,
                              size: 64,
                              iconSize: 32,
                            ),
                            const SizedBox(width: 20),
                            _AppleCircleButton(
                              onPressed: _togglePlayPause,
                              icon: _isPlaying
                                  ? Icons.pause_rounded
                                  : Icons.play_arrow_rounded,
                              size: 78,
                              iconSize: 42,
                            ),
                            const SizedBox(width: 20),
                            _AppleCircleButton(
                              onPressed: () =>
                                  _seekRelative(const Duration(seconds: 10)),
                              icon: Icons.forward_10_rounded,
                              size: 64,
                              iconSize: 32,
                            ),
                          ],
                        ),
                      ),
                      Positioned(
                        left: 10,
                        right: 10,
                        bottom: 10,
                        child: AppleMaterialOverlay(
                          borderRadius: BorderRadius.circular(22),
                          padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if ((widget.mediaTitle ?? '')
                                      .trim()
                                      .isNotEmpty)
                                    Text(
                                      widget.mediaTitle!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 16,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  Text(
                                    'Episode ${widget.episodeNumber}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  Text(
                                    widget.episodeTitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 6,
                                  thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 7),
                                  overlayShape: const RoundSliderOverlayShape(
                                      overlayRadius: 14),
                                ),
                                child: Slider(
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
                                    await _player!.seek(
                                        Duration(milliseconds: v.round()));
                                    _scheduleControlsAutoHide();
                                  },
                                ),
                              ),
                              Row(
                                children: [
                                  Text(
                                    _formatDuration(
                                        Duration(milliseconds: positionMs)),
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  ),
                                  const Spacer(),
                                  GestureDetector(
                                    onTap: _cycleSpeed,
                                    child: Text(
                                      '${_playbackSpeed.toStringAsFixed(_playbackSpeed == _playbackSpeed.roundToDouble() ? 0 : 2)}x',
                                      style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700),
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Text(
                                    '-${_formatDuration(Duration(milliseconds: (durationMs - positionMs).clamp(0, durationMs)))}',
                                    style: const TextStyle(
                                        color: Colors.white70, fontSize: 12),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AppleCircleButton extends StatelessWidget {
  const _AppleCircleButton({
    required this.onPressed,
    required this.icon,
    this.size = 54,
    this.iconSize = 28,
  });

  final VoidCallback onPressed;
  final IconData icon;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: AppleMaterialOverlay(
        borderRadius: BorderRadius.circular(999),
        padding: EdgeInsets.zero,
        child: IconButton(
          onPressed: onPressed,
          icon: Icon(icon, size: iconSize, color: Colors.white),
        ),
      ),
    );
  }
}
