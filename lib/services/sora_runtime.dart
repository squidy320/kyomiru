import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/sora_models.dart';

class SoraRuntime {
  SoraRuntime({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _animePaheApi = 'https://animepahe.si/api';

  Future<T> _withRetry<T>(Future<T> Function() task, {int attempts = 3}) async {
    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      try {
        return await task();
      } catch (e) {
        lastError = e;
        await Future<void>.delayed(Duration(milliseconds: 250 * (i + 1)));
      }
    }
    throw lastError ?? Exception('Request failed');
  }

  Future<List<SoraAnimeMatch>> searchAnime(String query) async {
    if (query.trim().isEmpty) return const [];
    final response = await _withRetry(() => _dio.get(
          _animePaheApi,
          queryParameters: {'m': 'search', 'q': query.trim()},
          options: Options(
            headers: {'Accept': 'application/json'},
            sendTimeout: const Duration(seconds: 12),
            receiveTimeout: const Duration(seconds: 12),
          ),
        ));
    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : jsonDecode(response.data.toString()) as Map<String, dynamic>;
    final list = (data['data'] as List? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map((e) {
          final session = (e['session'] ?? '').toString();
          return SoraAnimeMatch(
            title: (e['title'] ?? 'Unknown').toString(),
            image: (e['poster'] ?? '').toString(),
            href: 'https://animepahe.si/anime/$session',
            session: session,
          );
        })
        .where((e) => e.session.isNotEmpty)
        .toList();
  }

  Future<SoraAnimeMatch?> autoMatchTitle(String title) async {
    final results = await searchAnime(title);
    if (results.isEmpty) return null;
    final normalizedTarget = _normalize(title);
    results.sort((a, b) {
      final sa = _score(_normalize(a.title), normalizedTarget);
      final sb = _score(_normalize(b.title), normalizedTarget);
      return sb.compareTo(sa);
    });
    return results.first;
  }

  Future<List<SoraEpisode>> getEpisodes(String animeSession) async {
    if (animeSession.isEmpty) return const [];

    Future<Map<String, dynamic>> fetchReleasePage(int page, {required bool sorted}) async {
      final response = await _withRetry(() => _dio.get(
            _animePaheApi,
            queryParameters: {
              'm': 'release',
              'id': animeSession,
              if (sorted) 'sort': 'episode_asc',
              'page': page,
            },
            options: Options(
              headers: {'Accept': 'application/json'},
              sendTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 12),
            ),
          ));
      return response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : jsonDecode(response.data.toString()) as Map<String, dynamic>;
    }

    List<SoraEpisode> mapEpisodes(List<Map<String, dynamic>> rows) {
      final items = rows
          .map((item) {
            final session = (item['session'] ?? '').toString();
            final number = (item['episode'] as num?)?.toInt() ?? 0;
            return SoraEpisode(
              number: number,
              session: session,
              playUrl: 'https://animepahe.si/play/$animeSession/$session',
            );
          })
          .where((e) => e.number > 0 && e.session.isNotEmpty)
          .toList();
      items.sort((a, b) => a.number.compareTo(b.number));
      return items;
    }

    Future<List<SoraEpisode>> fetchAll({required bool sorted}) async {
      final first = await fetchReleasePage(1, sorted: sorted);
      final totalPages = (first['last_page'] as num?)?.toInt() ?? 1;
      final allRows = <Map<String, dynamic>>[];
      allRows.addAll((first['data'] as List? ?? const []).whereType<Map<String, dynamic>>());

      for (var page = 2; page <= totalPages; page++) {
        try {
          final next = await fetchReleasePage(page, sorted: sorted);
          allRows.addAll((next['data'] as List? ?? const []).whereType<Map<String, dynamic>>());
        } catch (_) {
          // Keep partial pages instead of failing all episode loading.
        }
      }

      return mapEpisodes(allRows);
    }

    try {
      final sortedEpisodes = await fetchAll(sorted: true);
      if (sortedEpisodes.isNotEmpty) return sortedEpisodes;
    } catch (_) {
      // fall through
    }

    try {
      final unsortedEpisodes = await fetchAll(sorted: false);
      if (unsortedEpisodes.isNotEmpty) return unsortedEpisodes;
    } catch (_) {
      // fall through
    }

    return const [];
  }

  Future<List<SoraSource>> getSourcesForEpisode(String playUrl) async {
    if (playUrl.isEmpty) return const [];
    final html = await _withRetry(() => _dio
        .get(
          playUrl,
          options: Options(
            headers: {
              'User-Agent': _ua,
              'Referer': 'https://animepahe.si/',
            },
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        )
        .then((r) => r.data.toString()));

    final buttonRegex = RegExp(
      r'<button[^>]*data-src="([^"]+)"[^>]*>',
      caseSensitive: false,
    );
    final matches = buttonRegex.allMatches(html).toList();

    final out = <SoraSource>[];
    for (final m in matches) {
      final buttonHtml = m.group(0) ?? '';
      final src = m.group(1) ?? '';
      if (src.isEmpty) continue;

      final resolution = _attr(buttonHtml, 'data-resolution') ?? 'Unknown';
      final audio = (_attr(buttonHtml, 'data-audio') ?? 'jpn').toLowerCase();
      final quality = resolution == 'Unknown' ? 'auto' : '${resolution}p';
      final subOrDub = audio == 'eng' ? 'dub' : 'sub';

      String? hls;
      if (src.contains('.m3u8')) {
        hls = src;
      } else if (src.contains('kwik.cx') || src.contains('kwik.si')) {
        try {
          hls = await _extractKwikHls(src);
        } catch (_) {
          hls = null;
        }
      }

      if (hls == null || hls.isEmpty) continue;
      out.add(
        SoraSource(
          url: hls,
          quality: quality,
          subOrDub: subOrDub,
          format: 'm3u8',
          headers: const {
            'Referer': 'https://kwik.cx/',
            'Origin': 'https://kwik.cx',
          },
        ),
      );
    }

    final unique = <String, SoraSource>{};
    for (final s in out) {
      unique['${s.quality}_${s.subOrDub}_${s.url}'] = s;
    }
    return unique.values.toList();
  }

  Future<String?> _extractKwikHls(String kwikUrl) async {
    final html = await _withRetry(() => _dio
        .get(
          kwikUrl,
          options: Options(
            headers: {
              'User-Agent': _ua,
              'Referer': 'https://animepahe.si/',
            },
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        )
        .then((r) => r.data.toString()));

    final scripts = RegExp(
      r'<script>([\s\S]*?)<\/script>',
      caseSensitive: false,
    ).allMatches(html).toList();

    final direct = RegExp("https://[^\\s\"']+\\.m3u8[^\\s\"']*")
        .firstMatch(html)
        ?.group(0);
    if (direct != null) return direct;

    for (final s in scripts) {
      final script = s.group(1) ?? '';
      String? unpacked;

      if (script.contains('));eval(')) {
        final parts = script.split('));eval(');
        if (parts.length == 2) {
          final layer2 = parts[1].substring(0, parts[1].length - 1);
          unpacked = _unpackPacker(layer2);
        }
      } else if (script.contains(".split('|')")) {
        unpacked = _unpackPacker(script);
      }

      final source = unpacked ?? script;
      final m =
          RegExp("https://[^\\s\\\"']+\\.m3u8[^\\s\\\"']*").firstMatch(source);
      if (m != null) return m.group(0);

      final m2 = RegExp(
        "const\\s+source\\s*=\\s*['\\\"]([^'\\\"]+\\.m3u8[^'\\\"]*)['\\\"]",
      ).firstMatch(source);
      if (m2 != null) return m2.group(1);
    }

    return null;
  }

  String? _unpackPacker(String source) {
    final patterns = [
      RegExp(
        r"\}\('(.*)', *(\d+|\[\]), *(\d+), *'(.*)'\.split\('\|'\), *(\d+), *(.*)\)\)",
        dotAll: true,
      ),
      RegExp(
        r"\}\('(.*)', *(\d+|\[\]), *(\d+), *'(.*)'\.split\('\|'\)",
        dotAll: true,
      ),
    ];

    RegExpMatch? args;
    for (final p in patterns) {
      final m = p.firstMatch(source);
      if (m != null) {
        args = m;
        break;
      }
    }
    if (args == null) return null;

    final payload = args.group(1) ?? '';
    final radix = int.tryParse(args.group(2) ?? '') ?? 0;
    final count = int.tryParse(args.group(3) ?? '') ?? 0;
    final symtab = (args.group(4) ?? '').split('|');
    if (count != symtab.length || radix <= 0) return null;

    final out = payload.replaceAllMapped(RegExp(r'\b\w+\b'), (match) {
      final word = match.group(0)!;
      final idx = _unbase(word, radix);
      if (idx == null || idx < 0 || idx >= symtab.length) return word;
      return symtab[idx].isEmpty ? word : symtab[idx];
    });

    return out;
  }

  int? _unbase(String value, int base) {
    if (base >= 2 && base <= 36) return int.tryParse(value, radix: base);

    const alpha62 =
        '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
    const alpha95 =
        " !\"#\$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

    String alphabet;
    if (base == 62) {
      alphabet = alpha62;
    } else if (base == 95) {
      alphabet = alpha95;
    } else if (base > 36 && base < 62) {
      alphabet = alpha62.substring(0, base);
    } else {
      return null;
    }

    var result = 0;
    var power = 1;
    for (var i = value.length - 1; i >= 0; i--) {
      final idx = alphabet.indexOf(value[i]);
      if (idx < 0) return null;
      result += idx * power;
      power *= base;
    }
    return result;
  }

  String _normalize(String s) =>
      s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  int _score(String a, String b) {
    if (a == b) return 100000;
    if (a.contains(b) || b.contains(a)) {
      return 50000 - (a.length - b.length).abs();
    }
    final maxLen = a.length > b.length ? a.length : b.length;
    var same = 0;
    for (var i = 0; i < a.length; i++) {
      if (b.contains(a[i])) same++;
    }
    return (same * 1000) - maxLen;
  }

  String? _attr(String html, String name) {
    final m = RegExp('$name="([^"]+)"', caseSensitive: false).firstMatch(html);
    return m?.group(1);
  }

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';
}
