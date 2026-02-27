import 'dart:async';
import 'dart:io';

import 'package:chewie/chewie.dart';
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
  VideoPlayerController? _videoController;
  ChewieController? _chewieController;
  Timer? _persistTimer;

  bool _isInitializing = true;
  String? _initError;
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
    final chewie = _chewieController;
    if (chewie == null) return;

    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive) {
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
      final key = '$normalized|${h.entries.map((e) => '${e.key}=${e.value}').join(';')}';
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

  Future<VideoPlayerController?> _createNetworkController(_PlayerCandidate c) async {
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
      AppLogger.w('Player', 'Init attempt failed for ${c.url}', error: e, stackTrace: st);
      return null;
    }
  }

  Future<VideoPlayerController?> _createLocalController(String rawUrl) async {
    try {
      final uri = Uri.tryParse(rawUrl);
      final file = (uri != null && uri.isScheme('file')) ? File.fromUri(uri) : File(rawUrl);
      final controller = VideoPlayerController.file(file);
      await controller.initialize();
      return controller;
    } catch (e, st) {
      AppLogger.w('Player', 'Local source init failed for $rawUrl', error: e, stackTrace: st);
      return null;
    }
  }

  Future<void> _bindController(VideoPlayerController controller) async {
    await _disposeControllers();

    final chewie = ChewieController(
      videoPlayerController: controller,
      autoInitialize: false,
      autoPlay: false,
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
        _initError = 'No playable source for this episode yet. Try another quality/source.';
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _persistTimer?.cancel();
    unawaited(_persistProgress());
    unawaited(_disposeControllers());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                child: Chewie(controller: _chewieController!),
              ),
            Positioned(
              top: 12,
              left: 12,
              child: IconButton(
                style: IconButton.styleFrom(
                  backgroundColor: Colors.black54,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

