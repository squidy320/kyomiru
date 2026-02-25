import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../core/app_logger.dart';
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
  late final Player _player;
  late final VideoController _videoController;

  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<Duration>? _durationSub;

  Timer? _persistTimer;
  bool _controlsVisible = true;
  bool _ready = false;
  bool _isPlaying = false;
  String? _initError;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = Player();
    _videoController = VideoController(_player);

    _playingSub = _player.stream.playing.listen((playing) {
      if (!mounted) return;
      if (_isPlaying != playing) {
        setState(() => _isPlaying = playing);
      }
    });

    _positionSub = _player.stream.position.listen((p) {
      _position = p;
    });

    _durationSub = _player.stream.duration.listen((d) {
      _duration = d;
    });

    _init();
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

  Future<bool> _tryOpen(_PlayerCandidate candidate) async {
    try {
      await _player.open(
        Media(candidate.url, httpHeaders: candidate.headers),
        play: false,
      );
      return true;
    } catch (e, st) {
      AppLogger.w('Player', 'Init attempt failed for ${candidate.url}',
          error: e, stackTrace: st);
      return false;
    }
  }

  Future<void> _init() async {
    final rawUrl = widget.sourceUrl;
    final url = rawUrl == null ? null : _sanitizeUrl(rawUrl);
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

    bool opened = false;

    if (widget.isLocal) {
      final uri = Uri.parse(url);
      final fileUri = uri.isScheme('file') ? uri : Uri.file(url);
      opened = await _tryOpen(
          _PlayerCandidate(url: fileUri.toString(), headers: const {}));
      if (!opened) {
        AppLogger.w(
            'Player', 'Local source init failed for ${fileUri.toFilePath()}');
      }
    } else {
      final candidates = _buildCandidates(url);
      for (final c in candidates) {
        opened = await _tryOpen(c);
        if (opened) break;
      }
    }

    if (!opened) {
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

    AppLogger.i('Player',
        'Playback initialized for media ${widget.mediaId} ep ${widget.episodeNumber}');

    final store = ref.read(progressStoreProvider);
    final saved = store.read(widget.mediaId, widget.episodeNumber);
    if (saved != null && saved.positionMs > 0) {
      // Wait briefly to ensure duration has propagated.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final maxMs = _duration.inMilliseconds;
      if (maxMs > 0) {
        final seekMs = saved.positionMs.clamp(0, maxMs);
        await _player.seek(Duration(milliseconds: seekMs));
      }
    }

    await _player.play();

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

    if (mounted) {
      setState(() {
        _ready = true;
        _isPlaying = true;
        _initError = null;
      });
    }
  }

  Future<void> _seekRelative(Duration delta) async {
    final max = _duration;
    if (max <= Duration.zero) return;
    var target = _position + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > max) target = max;
    await _player.seek(target);
  }

  @override
  void dispose() {
    _persistTimer?.cancel();
    _playingSub?.cancel();
    _positionSub?.cancel();
    _durationSub?.cancel();
    unawaited(_player.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;

    final durationMs = ready ? _duration.inMilliseconds : 0;
    final positionMs = ready
        ? _position.inMilliseconds.clamp(0, durationMs <= 0 ? 0 : durationMs)
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
                      ? Video(
                          controller: _videoController,
                          fit: BoxFit.contain,
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
                        await _player.seek(Duration(milliseconds: v.round()));
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
                              await _player.pause();
                            } else {
                              await _player.play();
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
