import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:video_player/video_player.dart';

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
  VideoPlayerController? _controller;
  Timer? _persistTimer;
  bool _controlsVisible = true;
  bool _ready = false;
  bool _isPlaying = false;

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

    VideoPlayerController controller;
    if (widget.isLocal) {
      final uri = Uri.parse(url);
      final file = uri.isScheme('file') ? File.fromUri(uri) : File(url);
      controller = VideoPlayerController.file(file);
    } else {
      controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: widget.headers,
      );
    }

    _controller = controller;

    try {
      await controller.initialize();
    } catch (_) {
      if (mounted) setState(() => _ready = false);
      return;
    }

    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      final maxMs = controller.value.duration.inMilliseconds;
      if (maxMs > 0) {
        final seekMs = saved.positionMs.clamp(0, maxMs);
        await controller.seekTo(Duration(milliseconds: seekMs));
      }
    }

    controller.addListener(_onPlayerUpdate);
    await controller.play();

    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final c = _controller;
      if (c == null || !c.value.isInitialized) return;
      final durationMs = c.value.duration.inMilliseconds;
      if (durationMs <= 0) return;
      await store.write(
        mediaId: widget.mediaId,
        episode: widget.episodeNumber,
        positionMs: c.value.position.inMilliseconds,
        durationMs: durationMs,
      );
    });

    if (mounted) {
      setState(() {
        _ready = true;
        _isPlaying = controller.value.isPlaying;
      });
    }
  }

  void _onPlayerUpdate() {
    final c = _controller;
    if (c == null || !mounted) return;
    final playing = c.value.isPlaying;
    if (_isPlaying != playing) {
      setState(() => _isPlaying = playing);
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
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _controller?.removeListener(_onPlayerUpdate);
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
                      ? AspectRatio(
                          aspectRatio: controller.value.aspectRatio <= 0
                              ? (16 / 9)
                              : controller.value.aspectRatio,
                          child: VideoPlayer(controller),
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
                        await controller
                            .seekTo(Duration(milliseconds: v.round()));
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
                            if (controller.value.isPlaying) {
                              await controller.pause();
                            } else {
                              await controller.play();
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
