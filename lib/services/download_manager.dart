import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
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
    );
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
  static const MethodChannel _mediaScanChannel =
      MethodChannel('kyomiru/media_scan');

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

  Future<void> _saveItem(DownloadItem item) async {
    final updated = {...state.items, item.key: item};
    state = DownloadState(items: updated);
    await _box.put(item.key, item.toJson());
  }

  Future<void> delete(int mediaId, int episode) async {
    final key = '$mediaId:$episode';
    final existing = state.items[key];
    if (existing?.localFilePath != null) {
      final f = File(existing!.localFilePath!);
      if (await f.exists()) {
        final parent = f.parent;
        if (await parent.exists()) {
          await parent.delete(recursive: true);
        }
      }
    }
    final token = _cancelTokens.remove(key);
    if (token != null && !token.isCancelled) {
      token.cancel('deleted');
    }
    await _box.delete(key);
    final updated = {...state.items}..remove(key);
    state = DownloadState(items: updated);
  }

  Future<String?> localManifestPath(int mediaId, int episode) async {
    final item = state.items['$mediaId:$episode'];
    final path = item?.localFilePath;
    if (path == null || path.isEmpty) return null;
    if (await File(path).exists()) return path;
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
      final file = File(path);
      if (await file.exists()) return file;
    }
    return null;
  }

  Future<File?> getLocalEpisodeByMedia(int mediaId, int episode) async {
    final item = state.items['$mediaId:$episode'];
    final path = item?.localFilePath;
    if (path == null || path.isEmpty) return null;
    final file = File(path);
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
      await _saveItem(DownloadItem(
        mediaId: mediaId,
        episode: episode,
        animeTitle: animeTitle,
        coverImageUrl: coverImageUrl,
        status: 'done',
        progress: 1,
        localFilePath: existingPath,
        sourceUrl: source.url,
        headers: source.headers,
      ));
      return;
    }

    final root = await _downloadsRoot();
    final animeDir = Directory('${root.path}/${_safe(animeTitle)}');
    if (!await animeDir.exists()) {
      await animeDir.create(recursive: true);
    }
    final epDir = Directory('${animeDir.path}/Episode $episode');
    if (!await epDir.exists()) {
      await epDir.create(recursive: true);
    }
    final manifestPath = '${epDir.path}/Episode $episode.m3u8';

    final token = CancelToken();
    _cancelTokens[key] = token;

    await _saveItem(DownloadItem(
      mediaId: mediaId,
      episode: episode,
      animeTitle: animeTitle,
      coverImageUrl: coverImageUrl,
      status: 'downloading',
      progress: 0,
      localFilePath: manifestPath,
      sourceUrl: source.url,
      headers: source.headers,
      resumable: true,
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

      final total = segmentLines.length + keyUris.length;
      var completed = 0;
      final rewritten = <String>[];
      final keyMap = <String, String>{};

      for (var i = 0; i < keyUris.length; i++) {
        final uri = resolved.url.resolve(keyUris[i]);
        final keyName = 'key_${i.toString().padLeft(2, '0')}.bin';
        final keyPath = '${epDir.path}/$keyName';
        await _dio.downloadUri(
          uri,
          keyPath,
          options: Options(headers: source.headers),
          cancelToken: token,
        );
        keyMap[keyUris[i]] = keyName;
        completed++;
        await _saveItem(
          state.items[key]!.copyWith(
            progress: total <= 0 ? 0 : completed / total,
            status: 'downloading',
          ),
        );
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
        final segPath = '${epDir.path}/$name';
        await _dio.downloadUri(
          segUri,
          segPath,
          options: Options(headers: source.headers),
          cancelToken: token,
        );
        rewritten.add(name);
        segIndex++;
        completed++;

        await _saveItem(
          state.items[key]!.copyWith(
            progress: total <= 0 ? 0 : completed / total,
            status: 'downloading',
          ),
        );
      }

      await File(manifestPath).writeAsString(rewritten.join('\n'));

      await _saveItem(
        state.items[key]!.copyWith(
          status: 'done',
          progress: 1,
          resumable: false,
          clearError: true,
        ),
      );
      await _scanOnAndroid(manifestPath);
    } catch (e, st) {
      final cancelled = e is DioException && e.type == DioExceptionType.cancel;
      AppLogger.e('Download', 'HLS download failed', error: e, stackTrace: st);
      await _saveItem(
        state.items[key]!.copyWith(
          status: cancelled ? 'cancelled' : 'error',
          resumable: true,
          error: e.toString(),
        ),
      );
    } finally {
      _cancelTokens.remove(key);
    }
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
    final dir = Directory('${base.path}/Kyomiru/AnimePahe');
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
