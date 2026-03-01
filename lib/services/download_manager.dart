import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:ffmpeg_kit_flutter_new/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new/return_code.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/app_logger.dart';
import '../models/sora_models.dart';

class DownloadItem {
  const DownloadItem({
    required this.mediaId,
    required this.episode,
    required this.animeTitle,
    this.coverImageUrl,
    required this.status,
    required this.progress,
    required this.localFilePath,
    required this.sourceUrl,
    required this.headers,
    this.taskId,
    this.resumable = false,
    this.error,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.speedBitsPerSecond = 0,
    this.lastPositionMs = 0,
    this.lastDurationMs = 0,
  });

  final int mediaId;
  final int episode;
  final String animeTitle;
  final String? coverImageUrl;
  final String status;
  final double progress;
  final String? localFilePath;
  final String sourceUrl;
  final Map<String, String> headers;
  final String? taskId;
  final bool resumable;
  final String? error;
  final int downloadedBytes;
  final int totalBytes;
  final double speedBitsPerSecond;
  final int lastPositionMs;
  final int lastDurationMs;

  String get key => '$mediaId:$episode';

  Map<String, dynamic> toJson() => {
        'mediaId': mediaId,
        'episode': episode,
        'animeTitle': animeTitle,
        'coverImageUrl': coverImageUrl,
        'status': status,
        'progress': progress,
        'localFilePath': localFilePath,
        'sourceUrl': sourceUrl,
        'headers': headers,
        'taskId': taskId,
        'resumable': resumable,
        'error': error,
        'downloadedBytes': downloadedBytes,
        'totalBytes': totalBytes,
        'speedBitsPerSecond': speedBitsPerSecond,
        'lastPositionMs': lastPositionMs,
        'lastDurationMs': lastDurationMs,
      };

  static DownloadItem fromJson(Map<dynamic, dynamic> map) {
    final headersRaw = map['headers'];
    final headers = <String, String>{};
    if (headersRaw is Map) {
      for (final e in headersRaw.entries) {
        headers[e.key.toString()] = e.value.toString();
      }
    }

    final localPath = map['localFilePath']?.toString() ??
        map['localManifestPath']?.toString();

    return DownloadItem(
      mediaId: (map['mediaId'] as num?)?.toInt() ?? 0,
      episode: (map['episode'] as num?)?.toInt() ?? 0,
      animeTitle: (map['animeTitle'] ?? '').toString(),
      coverImageUrl: map['coverImageUrl']?.toString(),
      status: (map['status'] ?? 'queued').toString(),
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
      localFilePath: localPath,
      sourceUrl: (map['sourceUrl'] ?? '').toString(),
      headers: headers,
      taskId: map['taskId']?.toString(),
      resumable: map['resumable'] == true,
      error: map['error']?.toString(),
      downloadedBytes: (map['downloadedBytes'] as num?)?.toInt() ?? 0,
      totalBytes: (map['totalBytes'] as num?)?.toInt() ?? 0,
      speedBitsPerSecond:
          (map['speedBitsPerSecond'] as num?)?.toDouble() ?? 0,
      lastPositionMs: (map['lastPositionMs'] as num?)?.toInt() ?? 0,
      lastDurationMs: (map['lastDurationMs'] as num?)?.toInt() ?? 0,
    );
  }

  DownloadItem copyWith({
    int? mediaId,
    int? episode,
    String? animeTitle,
    String? coverImageUrl,
    String? status,
    double? progress,
    String? localFilePath,
    String? sourceUrl,
    Map<String, String>? headers,
    String? taskId,
    bool? resumable,
    String? error,
    int? downloadedBytes,
    int? totalBytes,
    double? speedBitsPerSecond,
    int? lastPositionMs,
    int? lastDurationMs,
    bool clearError = false,
  }) {
    return DownloadItem(
      mediaId: mediaId ?? this.mediaId,
      episode: episode ?? this.episode,
      animeTitle: animeTitle ?? this.animeTitle,
      coverImageUrl: coverImageUrl ?? this.coverImageUrl,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      localFilePath: localFilePath ?? this.localFilePath,
      sourceUrl: sourceUrl ?? this.sourceUrl,
      headers: headers ?? this.headers,
      taskId: taskId ?? this.taskId,
      resumable: resumable ?? this.resumable,
      error: clearError ? null : (error ?? this.error),
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      speedBitsPerSecond: speedBitsPerSecond ?? this.speedBitsPerSecond,
      lastPositionMs: lastPositionMs ?? this.lastPositionMs,
      lastDurationMs: lastDurationMs ?? this.lastDurationMs,
    );
  }
}

class _SpeedSample {
  const _SpeedSample(this.timeMs, this.bytes);
  final int timeMs;
  final int bytes;
}

class _SpeedWindow {
  final List<_SpeedSample> _samples = <_SpeedSample>[];

  void addBytes(int bytes) {
    if (bytes <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    _samples.add(_SpeedSample(now, bytes));
    _trim(now);
  }

  double bitsPerSecond() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _trim(now);
    final bytes = _samples.fold<int>(0, (sum, e) => sum + e.bytes);
    return bytes * 8.0;
  }

  void _trim(int nowMs) {
    _samples.removeWhere((e) => nowMs - e.timeMs > 1000);
  }
}

class DownloadState {
  const DownloadState({required this.items});

  final Map<String, DownloadItem> items;

  DownloadItem? item(int mediaId, int episode) => items['$mediaId:$episode'];
}

class LocalEpisodeQuery {
  const LocalEpisodeQuery({
    required this.mediaId,
    required this.episode,
  });

  final int mediaId;
  final int episode;

  @override
  bool operator ==(Object other) {
    return other is LocalEpisodeQuery &&
        other.mediaId == mediaId &&
        other.episode == episode;
  }

  @override
  int get hashCode => Object.hash(mediaId, episode);
}

class _ResolvedPlaylist {
  const _ResolvedPlaylist({required this.url, required this.text});

  final Uri url;
  final String text;
}

class DownloadController extends StateNotifier<DownloadState> {
  DownloadController({Dio? dio, Box? box})
      : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 10),
                sendTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 10),
              ),
            ),
        _box = box ?? Hive.box('downloads'),
        super(const DownloadState(items: {})) {
    _load();
  }

  final Dio _dio;
  final Box _box;
  final Map<String, CancelToken> _cancelTokens = {};
  final Map<String, _SpeedWindow> _speedWindows = {};
  final Map<String, int> _lastUiEmitMs = {};
  final Map<String, int> _lastDiskPersistMs = {};
  static const int _uiUpdateIntervalMs = 280;
  static const int _diskPersistIntervalMs = 1200;
  static const MethodChannel _mediaScanChannel =
      MethodChannel('kyomiru/media_scan');

  String _escapeArg(String value) => '"${value.replaceAll('"', r'\"')}"';

  Future<bool> _convertHlsToMp4({
    required String inputManifestPath,
    required String outputMp4Path,
  }) async {
    final completer = Completer<bool>();
    final cmd =
        '-i ${_escapeArg(inputManifestPath)} -c copy ${_escapeArg(outputMp4Path)}';
    await FFmpegKit.executeAsync(cmd, (session) async {
      final code = await session.getReturnCode();
      completer.complete(ReturnCode.isSuccess(code));
    });
    return completer.future;
  }

  void _load() {
    final map = <String, DownloadItem>{};
    for (final k in _box.keys) {
      final raw = _box.get(k);
      if (raw is Map) {
        final item = DownloadItem.fromJson(raw);
        map[item.key] = item;
      }
    }
    state = DownloadState(items: map);
  }

  void _setItemInMemory(DownloadItem item) {
    final updated = {...state.items, item.key: item};
    state = DownloadState(items: updated);
  }

  Future<void> _saveItem(DownloadItem item) async {
    _setItemInMemory(item);
    _lastDiskPersistMs[item.key] = DateTime.now().millisecondsSinceEpoch;
    await _box.put(item.key, item.toJson());
  }

  Future<void> _emitDownloadUpdate(DownloadItem item, {bool force = false}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _lastUiEmitMs[item.key] ?? 0;
    if (!force && (now - last) < _uiUpdateIntervalMs) return;
    _lastUiEmitMs[item.key] = now;
    _setItemInMemory(item);

    final lastDisk = _lastDiskPersistMs[item.key] ?? 0;
    final shouldPersist = force ||
        item.status != 'downloading' ||
        (now - lastDisk) >= _diskPersistIntervalMs;
    if (!shouldPersist) return;

    _lastDiskPersistMs[item.key] = now;
    if (force) {
      await _box.put(item.key, item.toJson());
      return;
    }
    unawaited(_box.put(item.key, item.toJson()));
  }

  Future<void> delete(int mediaId, int episode) async {
    final key = '$mediaId:$episode';
    final existing = state.items[key];
    if (existing?.localFilePath != null) {
      final resolved = await _resolveStoredPath(existing!.localFilePath);
      if (resolved != null) {
        final f = File(resolved);
        if (await f.exists()) {
          final parent = f.parent;
          if (await parent.exists()) {
            await parent.delete(recursive: true);
          }
        }
      }
    }
    final token = _cancelTokens.remove(key);
    if (token != null && !token.isCancelled) {
      token.cancel('deleted');
    }
    _speedWindows.remove(key);
    _lastUiEmitMs.remove(key);
    _lastDiskPersistMs.remove(key);
    await _box.delete(key);
    final updated = {...state.items}..remove(key);
    state = DownloadState(items: updated);
  }

  Future<String?> localManifestPath(int mediaId, int episode) async {
    final item = state.items['$mediaId:$episode'];
    final path = item?.localFilePath;
    if (path == null || path.isEmpty) return null;
    final resolved = await _resolveStoredPath(path);
    if (resolved == null) return null;
    if (await File(resolved).exists()) return resolved;
    return null;
  }

  Future<File?> getLocalEpisode(String animeName, int episode) async {
    final safeTitle = _safe(animeName);
    for (final item in state.items.values) {
      if (_safe(item.animeTitle) != safeTitle || item.episode != episode) {
        continue;
      }
      final path = item.localFilePath;
      if (path == null || path.isEmpty) continue;
      final resolved = await _resolveStoredPath(path);
      if (resolved == null) continue;
      final file = File(resolved);
      if (await file.exists()) return file;
    }
    return null;
  }

  Future<File?> getLocalEpisodeByMedia(int mediaId, int episode) async {
    final item = state.items['$mediaId:$episode'];
    final path = item?.localFilePath;
    if (path == null || path.isEmpty) return null;
    final resolved = await _resolveStoredPath(path);
    if (resolved == null) return null;
    final file = File(resolved);
    if (await file.exists()) return file;
    return null;
  }

  Future<int> removeDownloadsForMedia(int mediaId) async {
    final targets = state.items.values
        .where((e) => e.mediaId == mediaId)
        .map((e) => e.episode)
        .toList();
    for (final ep in targets) {
      await delete(mediaId, ep);
    }
    return targets.length;
  }

  void cancel(int mediaId, int episode) {
    final key = '$mediaId:$episode';
    final token = _cancelTokens[key];
    token?.cancel('cancelled by user');
  }

  Future<void> setLocalPlaybackPosition(
    int mediaId,
    int episode, {
    required int positionMs,
    required int durationMs,
  }) async {
    final key = '$mediaId:$episode';
    final item = state.items[key];
    if (item == null) return;
    await _saveItem(
      item.copyWith(
        lastPositionMs: positionMs,
        lastDurationMs: durationMs,
      ),
    );
  }

  Future<void> resume(int mediaId, int episode) async {
    final item = state.items['$mediaId:$episode'];
    if (item == null) return;
    await downloadHlsEpisode(
      mediaId: item.mediaId,
      episode: item.episode,
      animeTitle: item.animeTitle,
      coverImageUrl: item.coverImageUrl,
      source: SoraSource(
        url: item.sourceUrl,
        quality: 'auto',
        subOrDub: 'sub',
        format: 'm3u8',
        headers: item.headers,
      ),
    );
  }

  Future<void> downloadHlsEpisode({
    required int mediaId,
    required int episode,
    required String animeTitle,
    String? coverImageUrl,
    required SoraSource source,
  }) async {
    final key = '$mediaId:$episode';
    if (_cancelTokens.containsKey(key)) {
      return;
    }

    final existingPath = await localManifestPath(mediaId, episode);
    if (existingPath != null) {
      final storedPath = await _toStoredRelativePath(existingPath);
      await _saveItem(DownloadItem(
        mediaId: mediaId,
        episode: episode,
        animeTitle: animeTitle,
        coverImageUrl: coverImageUrl,
        status: 'done',
        progress: 1,
        localFilePath: storedPath,
        sourceUrl: source.url,
        headers: source.headers,
      ));
      return;
    }

    final root = await _downloadsRoot();
    final safeTitle = _safe(animeTitle);
    final animeDir = Directory(p.join(root.path, safeTitle));
    if (!await animeDir.exists()) {
      await animeDir.create(recursive: true);
    }
    final epDir = Directory(p.join(animeDir.path, 'Episode $episode'));
    if (!await epDir.exists()) {
      await epDir.create(recursive: true);
    }
      final manifestRelativePath = p.join(
        safeTitle,
        'Episode $episode',
        'Episode $episode.m3u8',
      );
      final manifestPath = p.join(epDir.path, 'Episode $episode.m3u8');
      final mp4RelativePath = p.join(safeTitle, 'Episode $episode.mp4');
      final mp4Path = p.join(animeDir.path, 'Episode $episode.mp4');

    final token = CancelToken();
    _cancelTokens[key] = token;
    _speedWindows[key] = _SpeedWindow();

    await _saveItem(DownloadItem(
      mediaId: mediaId,
      episode: episode,
      animeTitle: animeTitle,
      coverImageUrl: coverImageUrl,
      status: 'downloading',
      progress: 0,
      localFilePath: manifestRelativePath,
      sourceUrl: source.url,
      headers: source.headers,
      resumable: true,
      downloadedBytes: 0,
      totalBytes: 0,
      speedBitsPerSecond: 0,
    ));

    try {
      final resolved = await _resolveMediaPlaylist(
        source.url,
        source.headers,
        token,
      );
      final lines = const LineSplitter().convert(resolved.text);

      final segmentLines = <String>[];
      final keyUris = <String>[];
      for (final line in lines) {
        final t = line.trim();
        if (t.isEmpty) continue;
        if (t.startsWith('#EXT-X-KEY') && t.contains('URI=')) {
          final m = RegExp(r'URI="([^"]+)"').firstMatch(t)?.group(1);
          if (m != null && m.isNotEmpty) keyUris.add(m);
        }
        if (!t.startsWith('#')) {
          segmentLines.add(t);
        }
      }

      final totalUnits = segmentLines.length + keyUris.length;
      var completed = 0;
      final rewritten = <String>[];
      final keyMap = <String, String>{};
      var downloadedBytes = 0;
      var knownTotalBytes = 0;

      for (var i = 0; i < keyUris.length; i++) {
        final uri = resolved.url.resolve(keyUris[i]);
        final keyName = 'key_${i.toString().padLeft(2, '0')}.bin';
        final keyPath = p.join(epDir.path, keyName);
        var lastReceived = 0;
        var currentTotal = 0;
        await _dio.downloadUri(
          uri,
          keyPath,
          options: Options(headers: source.headers),
          cancelToken: token,
          onReceiveProgress: (received, total) {
            final delta = received - lastReceived;
            if (delta > 0) {
              _speedWindows[key]?.addBytes(delta);
            }
            lastReceived = received;
            if (total > 0) currentTotal = total;
            final item = state.items[key];
            if (item == null) return;
            final unitProgress =
                total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
            final progress = totalUnits <= 0
                ? 0.0
                : ((completed + unitProgress) / totalUnits).clamp(0.0, 1.0);
            _emitDownloadUpdate(
              item.copyWith(
                status: 'downloading',
                progress: progress,
                downloadedBytes: downloadedBytes + received,
                totalBytes: knownTotalBytes + (currentTotal > 0 ? currentTotal : 0),
                speedBitsPerSecond: _speedWindows[key]?.bitsPerSecond() ?? 0,
              ),
            );
          },
        );
        final fileBytes = await File(keyPath).length();
        downloadedBytes += fileBytes;
        knownTotalBytes += currentTotal > 0 ? currentTotal : fileBytes;
        keyMap[keyUris[i]] = keyName;
        completed++;
        final item = state.items[key];
        if (item != null) {
          await _emitDownloadUpdate(
            item.copyWith(
              progress: totalUnits <= 0 ? 0 : completed / totalUnits,
              status: 'downloading',
              downloadedBytes: downloadedBytes,
              totalBytes: knownTotalBytes,
              speedBitsPerSecond: _speedWindows[key]?.bitsPerSecond() ?? 0,
            ),
            force: true,
          );
        }
      }

      var segIndex = 0;
      for (final line in lines) {
        final t = line.trim();
        if (t.startsWith('#EXT-X-KEY') && t.contains('URI=')) {
          var updated = line;
          for (final entry in keyMap.entries) {
            updated = updated.replaceAll('URI="${entry.key}"', 'URI="${entry.value}"');
          }
          rewritten.add(updated);
          continue;
        }
        if (t.isEmpty || t.startsWith('#')) {
          rewritten.add(line);
          continue;
        }

        final segUri = resolved.url.resolve(t);
        final ext = segUri.pathSegments.isEmpty
            ? 'ts'
            : (segUri.pathSegments.last.split('.').last);
        final name = 'seg_${segIndex.toString().padLeft(5, '0')}.$ext';
        final segPath = p.join(epDir.path, name);
        var lastReceived = 0;
        var currentTotal = 0;
        await _dio.downloadUri(
          segUri,
          segPath,
          options: Options(headers: source.headers),
          cancelToken: token,
          onReceiveProgress: (received, total) {
            final delta = received - lastReceived;
            if (delta > 0) {
              _speedWindows[key]?.addBytes(delta);
            }
            lastReceived = received;
            if (total > 0) currentTotal = total;
            final item = state.items[key];
            if (item == null) return;
            final unitProgress =
                total > 0 ? (received / total).clamp(0.0, 1.0) : 0.0;
            final progress = totalUnits <= 0
                ? 0.0
                : ((completed + unitProgress) / totalUnits).clamp(0.0, 1.0);
            _emitDownloadUpdate(
              item.copyWith(
                status: 'downloading',
                progress: progress,
                downloadedBytes: downloadedBytes + received,
                totalBytes: knownTotalBytes + (currentTotal > 0 ? currentTotal : 0),
                speedBitsPerSecond: _speedWindows[key]?.bitsPerSecond() ?? 0,
              ),
            );
          },
        );
        final fileBytes = await File(segPath).length();
        downloadedBytes += fileBytes;
        knownTotalBytes += currentTotal > 0 ? currentTotal : fileBytes;
        rewritten.add(name);
        segIndex++;
        completed++;

        final item = state.items[key];
        if (item != null) {
          await _emitDownloadUpdate(
            item.copyWith(
              progress: totalUnits <= 0 ? 0 : completed / totalUnits,
              status: 'downloading',
              downloadedBytes: downloadedBytes,
              totalBytes: knownTotalBytes,
              speedBitsPerSecond: _speedWindows[key]?.bitsPerSecond() ?? 0,
            ),
            force: true,
          );
        }
      }

      await File(manifestPath).writeAsString(rewritten.join('\n'));

      final finalizingItem = state.items[key];
      if (finalizingItem != null) {
        await _emitDownloadUpdate(
          finalizingItem.copyWith(
            status: 'finalizing',
            progress: 1,
            speedBitsPerSecond: 0,
            clearError: true,
          ),
          force: true,
        );
      }

      var finalizedToMp4 = false;
      try {
        finalizedToMp4 = await _convertHlsToMp4(
          inputManifestPath: manifestPath,
          outputMp4Path: mp4Path,
        );
      } catch (e, st) {
        AppLogger.w(
          'Download',
          'FFmpeg finalize failed for $key',
          error: e,
          stackTrace: st,
        );
      }

      if (finalizedToMp4 && await File(mp4Path).exists()) {
        try {
          if (await epDir.exists()) {
            await epDir.delete(recursive: true);
          }
        } catch (_) {}
        await _saveItem(
          state.items[key]!.copyWith(
            status: 'done',
            progress: 1,
            resumable: false,
            speedBitsPerSecond: 0,
            localFilePath: mp4RelativePath,
            clearError: true,
          ),
        );
        await _scanOnAndroid(mp4Path);
      } else {
        await _saveItem(
          state.items[key]!.copyWith(
            status: 'done',
            progress: 1,
            resumable: false,
            speedBitsPerSecond: 0,
            localFilePath: manifestRelativePath,
            error: 'Finalizing failed; using HLS file.',
          ),
        );
        await _scanOnAndroid(manifestPath);
      }
    } catch (e, st) {
      final cancelled = e is DioException && e.type == DioExceptionType.cancel;
      AppLogger.e('Download', 'HLS download failed', error: e, stackTrace: st);
      await _saveItem(
        state.items[key]!.copyWith(
          status: cancelled ? 'cancelled' : 'error',
          resumable: true,
          speedBitsPerSecond: 0,
          error: e.toString(),
        ),
      );
    } finally {
      _cancelTokens.remove(key);
      _speedWindows.remove(key);
    }
  }

  Future<String?> _resolveStoredPath(String? storedPath) async {
    if (storedPath == null) return null;
    var path = storedPath.trim();
    if (path.isEmpty) return null;

    final uri = Uri.tryParse(path);
    if (uri != null && uri.isScheme('file')) {
      path = uri.toFilePath();
    }
    path = path.replaceAll('\\', '/');

    final root = await _downloadsRoot();
    final rootPath = root.path.replaceAll('\\', '/');
    final docsPath = (await getApplicationDocumentsDirectory())
        .path
        .replaceAll('\\', '/');

    final isAbsoluteUnix = path.startsWith('/');
    final isAbsoluteWin = RegExp(r'^[A-Za-z]:/').hasMatch(path);
    if (isAbsoluteUnix || isAbsoluteWin) {
      if (await File(path).exists()) return path;

      if (Platform.isIOS) {
        final marker = '/Documents/Kyomiru/AnimePahe/';
        final markerIndex = path.lastIndexOf(marker);
        if (markerIndex >= 0) {
          final suffix = path.substring(markerIndex + '/Documents/'.length);
          final fixed = p.join(docsPath, suffix).replaceAll('\\', '/');
          if (await File(fixed).exists()) return fixed;
        }
      }
      return path;
    }

    var cleaned = path.startsWith('Kyomiru/')
        ? path.substring('Kyomiru/'.length)
        : path;
    if (cleaned.startsWith('AnimePahe/')) {
      cleaned = cleaned.substring('AnimePahe/'.length);
    }
    return p.join(rootPath, cleaned).replaceAll('\\', '/');
  }

  Future<String> _toStoredRelativePath(String absolutePath) async {
    final normalized = absolutePath.replaceAll('\\', '/');
    final root = await _downloadsRoot();
    final rootPath = root.path.replaceAll('\\', '/');
    if (normalized.startsWith('$rootPath/')) {
      return normalized.substring(rootPath.length + 1);
    }
    final marker = '/Kyomiru/AnimePahe/';
    final markerIndex = normalized.lastIndexOf(marker);
    if (markerIndex >= 0) {
      return normalized.substring(markerIndex + marker.length);
    }
    return normalized;
  }

  Future<_ResolvedPlaylist> _resolveMediaPlaylist(
    String sourceUrl,
    Map<String, String> headers,
    CancelToken cancelToken,
  ) async {
    final masterText = await _fetchText(sourceUrl, headers, cancelToken);
    final masterLines = const LineSplitter().convert(masterText);

    if (!masterText.contains('#EXT-X-STREAM-INF')) {
      return _ResolvedPlaylist(url: Uri.parse(sourceUrl), text: masterText);
    }

    String? bestVariant;
    var bestBandwidth = -1;
    for (var i = 0; i < masterLines.length; i++) {
      final line = masterLines[i].trim();
      if (!line.startsWith('#EXT-X-STREAM-INF')) continue;
      final bandwidth =
          int.tryParse(RegExp(r'BANDWIDTH=(\d+)').firstMatch(line)?.group(1) ?? '') ?? 0;
      for (var j = i + 1; j < masterLines.length; j++) {
        final cand = masterLines[j].trim();
        if (cand.isEmpty || cand.startsWith('#')) continue;
        if (bandwidth >= bestBandwidth) {
          bestBandwidth = bandwidth;
          bestVariant = cand;
        }
        break;
      }
    }

    if (bestVariant == null) {
      return _ResolvedPlaylist(url: Uri.parse(sourceUrl), text: masterText);
    }

    final variantUrl = Uri.parse(sourceUrl).resolve(bestVariant).toString();
    final variantText = await _fetchText(variantUrl, headers, cancelToken);
    return _ResolvedPlaylist(url: Uri.parse(variantUrl), text: variantText);
  }

  Future<String> _fetchText(
    String url,
    Map<String, String> headers,
    CancelToken cancelToken,
  ) async {
    final response = await _dio.get(
      url,
      options: Options(
        responseType: ResponseType.plain,
        headers: headers,
      ),
      cancelToken: cancelToken,
    );
    return response.data.toString();
  }

  Future<Directory> _downloadsRoot() async {
    late Directory base;
    if (Platform.isIOS) {
      base = await getApplicationDocumentsDirectory();
    } else if (Platform.isAndroid) {
      base =
          await getExternalStorageDirectory() ?? await getApplicationDocumentsDirectory();
    } else {
      base = await getApplicationDocumentsDirectory();
    }
    final dir = Directory(p.join(base.path, 'Kyomiru', 'AnimePahe'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  String _safe(String value) {
    return value
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .replaceAll('  ', ' ')
        .trim();
  }

  Future<void> _scanOnAndroid(String path) async {
    if (!Platform.isAndroid) return;
    try {
      await _mediaScanChannel.invokeMethod<void>('scanFile', {
        'path': path,
      });
    } catch (e, st) {
      AppLogger.w('Download', 'Media scan failed', error: e, stackTrace: st);
    }
  }
}

final downloadControllerProvider =
    StateNotifierProvider<DownloadController, DownloadState>(
  (ref) => DownloadController(),
);

final localEpisodeFileProvider =
    FutureProvider.family<File?, LocalEpisodeQuery>((ref, query) async {
  ref.watch(downloadControllerProvider);
  return ref
      .read(downloadControllerProvider.notifier)
      .getLocalEpisodeByMedia(query.mediaId, query.episode);
});
