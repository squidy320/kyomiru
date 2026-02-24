import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../state/auth_state.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.mediaId,
    required this.episodeNumber,
    required this.episodeTitle,
    required this.sourceUrl,
    this.headers = const {},
    this.isLocal = false,
  });

  final int mediaId;
  final int episodeNumber;
  final String episodeTitle;
  final String? sourceUrl;
  final Map<String, String> headers;
  final bool isLocal;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  Player? _player;
  VideoController? _videoController;
  Timer? _persistTimer;
  bool _controlsVisible = true;
  bool _ready = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _isPlaying = false;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playSub;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final url = widget.sourceUrl;
    if (url == null || url.isEmpty) {
      if (mounted) setState(() {});
      return;
    }

    final player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 64 * 1024 * 1024,
      ),
    );
    final videoController = VideoController(player);

    _player = player;
    _videoController = videoController;

    _posSub = player.stream.position.listen((p) {
      if (!mounted) return;
      setState(() => _position = p);
    });
    _durSub = player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() => _duration = d);
    });
    _playSub = player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _isPlaying = v);
    });

    await player.open(
      Media(
        url,
        httpHeaders: widget.isLocal ? null : widget.headers,
      ),
      play: false,
    );

    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      await player.seek(Duration(milliseconds: saved.positionMs));
    }

    await player.play();

    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final durationMs = _duration.inMilliseconds;
      if (durationMs <= 0) return;
      await store.write(
        mediaId: widget.mediaId,
        episode: widget.episodeNumber,
        positionMs: _position.inMilliseconds,
        durationMs: durationMs,
      );
    });

    if (mounted) setState(() => _ready = true);
  }

  Future<void> _seekRelative(Duration delta) async {
    final p = _player;
    if (p == null) return;
    final target = _position + delta;
    final max = _duration.inMilliseconds <= 0 ? null : _duration;
    Duration clamped = target;
    if (target < Duration.zero) clamped = Duration.zero;
    if (max != null && target > max) clamped = max;
    await p.seek(clamped);
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _posSub?.cancel();
    _durSub?.cancel();
    _playSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final ready = player != null && _videoController != null && _ready;

    final durationMs = _duration.inMilliseconds;
    final positionMs =
        _position.inMilliseconds.clamp(0, durationMs <= 0 ? 0 : durationMs);
    final sliderMax = durationMs <= 0 ? 1.0 : durationMs.toDouble();

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: () =>
                    setState(() => _controlsVisible = !_controlsVisible),
                onDoubleTapDown: (details) {
                  final width = MediaQuery.of(context).size.width;
                  if (details.localPosition.dx < width / 2) {
                    _seekRelative(const Duration(seconds: -10));
                  } else {
                    _seekRelative(const Duration(seconds: 10));
                  }
                },
                child: Center(
                  child: ready
                      ? FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: _videoController!.player.state.width
                                    ?.toDouble() ??
                                1280,
                            height: _videoController!.player.state.height
                                    ?.toDouble() ??
                                720,
                            child: Video(controller: _videoController!),
                          ),
                        )
                      : const Text(
                          'No playable source for this episode yet.',
                          style: TextStyle(color: Colors.white70),
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
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Slider(
                      value: positionMs.toDouble(),
                      min: 0,
                      max: sliderMax,
                      onChanged: (v) async {
                        await player.seek(Duration(milliseconds: v.round()));
                      },
                    ),
                    Row(
                      children: [
                        IconButton(
                          onPressed: () =>
                              _seekRelative(const Duration(seconds: -10)),
                          icon:
                              const Icon(Icons.replay_10, color: Colors.white),
                        ),
                        IconButton(
                          onPressed: () async {
                            if (_isPlaying) {
                              await player.pause();
                            } else {
                              await player.play();
                            }
                          },
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
