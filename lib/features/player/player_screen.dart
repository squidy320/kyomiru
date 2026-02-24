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

class _PlayerCandidate {
  const _PlayerCandidate({required this.url, required this.headers});

  final String url;
  final Map<String, String> headers;
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  VideoPlayerController? _controller;
  Timer? _persistTimer;
  bool _controlsVisible = true;
  bool _ready = false;
  bool _isPlaying = false;
  String? _initError;

  @override
  void initState() {
    super.initState();
    _init();
  }

  String _normalizeHlsUrl(String url) {
    return url
        .replaceAll('/stream/', '/hls/')
        .replaceAll('uwu.m3u8', 'owo.m3u8');
  }

  List<_PlayerCandidate> _buildCandidates(String url) {
    final out = <_PlayerCandidate>[];
    final seen = <String>{};

    void add(String u, Map<String, String> h) {
      if (u.trim().isEmpty) return;
      final key = '$u|${h.entries.map((e) => '${e.key}=${e.value}').join(';')}';
      if (seen.contains(key)) return;
      seen.add(key);
      out.add(_PlayerCandidate(url: u, headers: h));
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
    );
    try {
      await controller.initialize();
      return controller;
    } catch (e) {
      debugPrint('[Player] init failed for ${c.url}: $e');
      await controller.dispose();
      return null;
    }
  }

  Future<void> _init() async {
    final url = widget.sourceUrl;
    if (url == null || url.isEmpty) {
      if (mounted) {
        setState(() {
          _initError = 'Missing source URL.';
        });
      }
      return;
    }

    VideoPlayerController? controller;

    if (widget.isLocal) {
      final uri = Uri.parse(url);
      final file = uri.isScheme('file') ? File.fromUri(uri) : File(url);
      controller = VideoPlayerController.file(file);
      try {
        await controller.initialize();
      } catch (e) {
        debugPrint('[Player] local init failed for ${file.path}: $e');
        await controller.dispose();
        controller = null;
      }
    } else {
      final candidates = _buildCandidates(url);
      for (final c in candidates) {
        controller = await _createController(c);
        if (controller != null) break;
      }
    }

    if (controller == null) {
      if (mounted) {
        setState(() {
          _ready = false;
          _initError =
              'No playable source for this episode yet. Try another quality/source.';
        });
      }
      return;
    }

    _controller = controller;

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
        _isPlaying = controller!.value.isPlaying;
        _initError = null;
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
                      : Text(
                          _initError ?? 'Loading source...',
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.white70),
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
