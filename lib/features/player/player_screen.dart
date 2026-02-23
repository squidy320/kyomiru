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

    final VideoPlayerController c;
    if (widget.isLocal) {
      c = VideoPlayerController.file(File(url));
    } else {
      c = VideoPlayerController.networkUrl(Uri.parse(url),
          httpHeaders: widget.headers);
    }

    _controller = c;
    await c.initialize();

    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      await c.seekTo(Duration(milliseconds: saved.positionMs));
    }

    await c.play();

    _persistTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      final current = _controller;
      if (current == null || !current.value.isInitialized) return;
      final position = current.value.position.inMilliseconds;
      final duration = current.value.duration.inMilliseconds;
      if (duration <= 0) return;
      await store.write(
        mediaId: widget.mediaId,
        episode: widget.episodeNumber,
        positionMs: position,
        durationMs: duration,
      );
    });

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = _controller;
    final ready = c != null && c.value.isInitialized;

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
                  final controller = _controller;
                  if (controller == null || !controller.value.isInitialized) {
                    return;
                  }
                  final width = MediaQuery.of(context).size.width;
                  final current = controller.value.position;
                  final target = details.localPosition.dx < width / 2
                      ? current - const Duration(seconds: 10)
                      : current + const Duration(seconds: 10);
                  controller.seekTo(target);
                },
                child: Center(
                  child: ready
                      ? FittedBox(
                          fit: BoxFit.contain,
                          child: SizedBox(
                            width: c.value.size.width,
                            height: c.value.size.height,
                            child: VideoPlayer(c),
                          ),
                        )
                      : const Text('No playable source for this episode yet.',
                          style: TextStyle(color: Colors.white70)),
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
                    Text(widget.episodeTitle,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                    ValueListenableBuilder(
                      valueListenable: c,
                      builder: (context, VideoPlayerValue value, _) {
                        final duration = value.duration.inMilliseconds;
                        final position = value.position.inMilliseconds
                            .clamp(0, duration <= 0 ? 0 : duration);
                        final sliderMax =
                            duration <= 0 ? 1.0 : duration.toDouble();
                        return Column(
                          children: [
                            Slider(
                              value: position.toDouble(),
                              min: 0,
                              max: sliderMax,
                              onChanged: (v) =>
                                  c.seekTo(Duration(milliseconds: v.round())),
                            ),
                            Row(
                              children: [
                                IconButton(
                                  onPressed: () => c.seekTo(value.position -
                                      const Duration(seconds: 10)),
                                  icon: const Icon(Icons.replay_10,
                                      color: Colors.white),
                                ),
                                IconButton(
                                  onPressed: () =>
                                      value.isPlaying ? c.pause() : c.play(),
                                  icon: Icon(
                                      value.isPlaying
                                          ? Icons.pause
                                          : Icons.play_arrow,
                                      color: Colors.white),
                                ),
                                IconButton(
                                  onPressed: () => c.seekTo(value.position +
                                      const Duration(seconds: 10)),
                                  icon: const Icon(Icons.forward_10,
                                      color: Colors.white),
                                ),
                              ],
                            ),
                          ],
                        );
                      },
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
