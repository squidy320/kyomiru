import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';

import '../core/app_logger.dart';
import 'android_http_bridge.dart';
import '../models/anilist_models.dart';

class SoraExtensionLoader {
  SoraExtensionLoader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const officialAnimePaheUrl =
      'https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.json';
  static const _fallbackAnimePaheManifest = <String, dynamic>{
    'id': 'animepahe',
    'name': 'AnimePahe',
    'getSources': true,
  };

  static const _mirrorUrls = <String>[
    officialAnimePaheUrl,
    'https://raw.githubusercontent.com/sources-anime/extensions/main/animepahe/animepahe.json',
  ];

  Future<SoraExtensionManifest> loadOfficialAnimePahe() async {
    Object? lastError;
    for (final url in _mirrorUrls) {
      try {
        final response = await _dio.get(url);
        final json = response.data is Map<String, dynamic>
            ? response.data as Map<String, dynamic>
            : jsonDecode(response.data.toString()) as Map<String, dynamic>;

        final manifest = SoraExtensionManifest.fromJson(json);
        if (manifest.id.isEmpty && (manifest.name ?? '').isEmpty) {
          throw Exception('Invalid Sora extension manifest.');
        }
        AppLogger.i('SoraExt', 'Loaded extension manifest from $url');
        return manifest;
      } catch (e, st) {
        lastError = e;
        AppLogger.w(
          'SoraExt',
          'Extension manifest load failed from $url',
          error: e,
          stackTrace: st,
        );
        if (Platform.isAndroid) {
          try {
            final bridged = await AndroidHttpBridge.request(
              url: url,
              method: 'GET',
              headers: const {
                'Accept': 'application/json',
              },
            );
            if (bridged != null && bridged.statusCode >= 200 && bridged.statusCode < 400) {
              final json = jsonDecode(bridged.body) as Map<String, dynamic>;
              final manifest = SoraExtensionManifest.fromJson(json);
              if (manifest.id.isNotEmpty || (manifest.name ?? '').isNotEmpty) {
                AppLogger.i(
                  'SoraExt',
                  'Loaded extension manifest from Android native HTTP bridge: $url',
                );
                return manifest;
              }
            }
          } catch (bridgeError, bridgeSt) {
            AppLogger.w(
              'SoraExt',
              'Android HTTP bridge failed for extension manifest $url',
              error: bridgeError,
              stackTrace: bridgeSt,
            );
          }
        }
        continue;
      }
    }

    // Last-resort fallback so app can proceed even when DNS blocks extension hosts.
    final fallback = SoraExtensionManifest.fromJson(_fallbackAnimePaheManifest);
    AppLogger.w(
      'SoraExt',
      'Using built-in AnimePahe extension manifest fallback',
      error: lastError ?? const SocketException('unknown'),
    );
    return fallback;
  }
}
