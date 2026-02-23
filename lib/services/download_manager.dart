import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../models/sora_models.dart';

class DownloadItem {
  const DownloadItem({
    required this.mediaId,
    required this.episode,
    required this.animeTitle,
    required this.status,
    required this.progress,
    required this.localManifestPath,
    this.error,
  });

  final int mediaId;
  final int episode;
  final String animeTitle;
  final String status;
  final double progress;
  final String? localManifestPath;
  final String? error;

  String get key => '$mediaId:$episode';

  Map<String, dynamic> toJson() => {
        'mediaId': mediaId,
        'episode': episode,
        'animeTitle': animeTitle,
        'status': status,
        'progress': progress,
        'localManifestPath': localManifestPath,
        'error': error,
      };

  static DownloadItem fromJson(Map<dynamic, dynamic> map) {
    return DownloadItem(
      mediaId: (map['mediaId'] as num?)?.toInt() ?? 0,
      episode: (map['episode'] as num?)?.toInt() ?? 0,
      animeTitle: (map['animeTitle'] ?? '').toString(),
      status: (map['status'] ?? 'queued').toString(),
      progress: (map['progress'] as num?)?.toDouble() ?? 0,
      localManifestPath: map['localManifestPath']?.toString(),
      error: map['error']?.toString(),
    );
  }
}

class DownloadState {
  const DownloadState({required this.items});

  final Map<String, DownloadItem> items;

  DownloadItem? item(int mediaId, int episode) => items['$mediaId:$episode'];
}

class DownloadController extends StateNotifier<DownloadState> {
  DownloadController({Dio? dio, Box? box})
      : _dio = dio ?? Dio(),
        _box = box ?? Hive.box('downloads'),
        super(const DownloadState(items: {})) {
    _load();
  }

  final Dio _dio;
  final Box _box;
  final Map<String, CancelToken> _cancelTokens = {};

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
    if (existing?.localManifestPath != null) {
      final f = File(existing!.localManifestPath!);
      if (await f.exists()) {
        final dir = f.parent;
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      }
    }
    await _box.delete(key);
    final updated = {...state.items}..remove(key);
    state = DownloadState(items: updated);
  }

  Future<String?> localManifestPath(int mediaId, int episode) async {
    final item = state.items['$mediaId:$episode'];
    final path = item?.localManifestPath;
    if (path == null || path.isEmpty) return null;
    if (await File(path).exists()) return path;
    return null;
  }

  void cancel(int mediaId, int episode) {
    final key = '$mediaId:$episode';
    _cancelTokens[key]?.cancel('cancelled by user');
  }

  Future<void> downloadHlsEpisode({
    required int mediaId,
    required int episode,
    required String animeTitle,
    required SoraSource source,
  }) async {
    final key = '$mediaId:$episode';
    if (_cancelTokens.containsKey(key)) return;

    final existingPath = await localManifestPath(mediaId, episode);
    if (existingPath != null) {
      await _saveItem(DownloadItem(
        mediaId: mediaId,
        episode: episode,
        animeTitle: animeTitle,
        status: 'done',
        progress: 1,
        localManifestPath: existingPath,
      ));
      return;
    }

    final cancel = CancelToken();
    _cancelTokens[key] = cancel;

    await _saveItem(DownloadItem(
      mediaId: mediaId,
      episode: episode,
      animeTitle: animeTitle,
      status: 'downloading',
      progress: 0,
      localManifestPath: null,
    ));

    try {
      final root = await _downloadsRoot();
      final animeDir = Directory('${root.path}/${_safe(animeTitle)}');
      if (!await animeDir.exists()) await animeDir.create(recursive: true);
      final epDir = Directory('${animeDir.path}/Episode$episode');
      if (!await epDir.exists()) await epDir.create(recursive: true);

      final manifestResp = await _dio.get(
        source.url,
        options:
            Options(responseType: ResponseType.plain, headers: source.headers),
        cancelToken: cancel,
      );
      final manifestText = manifestResp.data.toString();
      final baseUri = Uri.parse(source.url);

      final lines = const LineSplitter().convert(manifestText);
      final segmentLines = <String>[];
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        segmentLines.add(trimmed);
      }

      if (segmentLines.isEmpty) {
        throw Exception('No HLS segments found.');
      }

      final rewritten = <String>[];
      var downloaded = 0;

      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) {
          rewritten.add(line);
          continue;
        }

        final segUri = Uri.parse(trimmed);
        final absolute = segUri.hasScheme ? segUri : baseUri.resolveUri(segUri);
        final fileName = _segmentFileName(
            downloaded,
            absolute.pathSegments.isEmpty
                ? 'seg.ts'
                : absolute.pathSegments.last);
        final segPath = '${epDir.path}/$fileName';

        await _dio.downloadUri(
          absolute,
          segPath,
          options: Options(headers: source.headers),
          cancelToken: cancel,
        );

        downloaded++;
        rewritten.add(fileName);

        await _saveItem(DownloadItem(
          mediaId: mediaId,
          episode: episode,
          animeTitle: animeTitle,
          status: 'downloading',
          progress: downloaded / segmentLines.length,
          localManifestPath: null,
        ));
      }

      final manifestPath = '${epDir.path}/Episode$episode.m3u8';
      await File(manifestPath).writeAsString(rewritten.join('\n'));

      // verification
      for (final line in rewritten) {
        if (line.startsWith('#') || line.trim().isEmpty) continue;
        final f = File('${epDir.path}/$line');
        if (!await f.exists()) {
          throw Exception('Download incomplete - segments missing');
        }
      }

      await _saveItem(DownloadItem(
        mediaId: mediaId,
        episode: episode,
        animeTitle: animeTitle,
        status: 'done',
        progress: 1,
        localManifestPath: manifestPath,
      ));
    } catch (e) {
      final cancelled = e is DioException && e.type == DioExceptionType.cancel;
      await _saveItem(DownloadItem(
        mediaId: mediaId,
        episode: episode,
        animeTitle: animeTitle,
        status: cancelled ? 'cancelled' : 'error',
        progress: 0,
        localManifestPath: null,
        error: e.toString(),
      ));
    } finally {
      _cancelTokens.remove(key);
    }
  }

  Future<Directory> _downloadsRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  String _safe(String value) {
    return value
        .replaceAll(RegExp(r'[^A-Za-z0-9 _-]'), '')
        .replaceAll('  ', ' ')
        .trim();
  }

  String _segmentFileName(int index, String original) {
    final cleaned = original.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    return '${index.toString().padLeft(4, '0')}_$cleaned';
  }
}

final downloadControllerProvider =
    StateNotifierProvider<DownloadController, DownloadState>(
  (ref) => DownloadController(),
);
