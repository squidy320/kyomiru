import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/anilist_models.dart';

class SoraExtensionLoader {
  SoraExtensionLoader({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const officialAnimePaheUrl =
      'https://git.luna-app.eu/50n50/sources/raw/branch/main/animepahe/animepahe.json';

  Future<SoraExtensionManifest> loadOfficialAnimePahe() async {
    final response = await _dio.get(officialAnimePaheUrl);
    final json = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : jsonDecode(response.data.toString()) as Map<String, dynamic>;

    final manifest = SoraExtensionManifest.fromJson(json);
    if (manifest.id.isEmpty && (manifest.name ?? '').isEmpty) {
      throw Exception('Invalid Sora extension manifest.');
    }
    return manifest;
  }
}
