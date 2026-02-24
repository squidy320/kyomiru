import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/sora_models.dart';

class SoraRuntime {
  SoraRuntime({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const _bases = <String>[
    'https://animepahe.si',
    'https://animepahe.ru',
    'https://animepahe.com',
  ];

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

    for (final base in _bases) {
      try {
        final response = await _withRetry(() => _dio.get(
              '$base/api',
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

        final results = list
            .whereType<Map<String, dynamic>>()
            .map((e) {
              final session = (e['session'] ?? '').toString();
              final animeId = (e['id'] ?? '').toString();
              return SoraAnimeMatch(
                title: (e['title'] ?? 'Unknown').toString(),
                image: (e['poster'] ?? '').toString(),
                href: '$base/anime/$session',
                session: session,
                animeId: animeId,
              );
            })
            .where((e) => e.session.isNotEmpty && e.animeId.isNotEmpty)
            .toList();

        if (results.isNotEmpty) return results;
      } catch (_) {
        // try next mirror
      }
    }

    return const [];
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

  Future<List<SoraEpisode>> getEpisodes(SoraAnimeMatch match) async {
    if (match.session.isEmpty || match.animeId.isEmpty) return const [];

    for (final base in _bases) {
      try {
        final first = await _withRetry(() => _dio.get(
              '$base/api',
              queryParameters: {
                'm': 'release',
                'id': match.animeId,
                'sort': 'episode_asc',
                'page': 1,
              },
              options: Options(
                headers: {'Accept': 'application/json'},
                sendTimeout: const Duration(seconds: 12),
                receiveTimeout: const Duration(seconds: 12),
              ),
            ));

        final data1 = first.data is Map<String, dynamic>
            ? first.data as Map<String, dynamic>
            : jsonDecode(first.data.toString()) as Map<String, dynamic>;

        final totalPages = (data1['last_page'] as num?)?.toInt() ?? 1;
        final allRows = <Map<String, dynamic>>[];
        allRows.addAll((data1['data'] as List? ?? const [])
            .whereType<Map<String, dynamic>>());

        for (var page = 2; page <= totalPages; page++) {
          try {
            final next = await _withRetry(() => _dio.get(
                  '$base/api',
                  queryParameters: {
                    'm': 'release',
                    'id': match.animeId,
                    'sort': 'episode_asc',
                    'page': page,
                  },
                  options: Options(
                    headers: {'Accept': 'application/json'},
                    sendTimeout: const Duration(seconds: 12),
                    receiveTimeout: const Duration(seconds: 12),
                  ),
                ));
            final d = next.data is Map<String, dynamic>
                ? next.data as Map<String, dynamic>
                : jsonDecode(next.data.toString()) as Map<String, dynamic>;
            allRows.addAll((d['data'] as List? ?? const [])
                .whereType<Map<String, dynamic>>());
          } catch (_) {
            // partial list is still useful
          }
        }

        final episodes = allRows
            .map((item) {
              final epSession = (item['session'] ?? '').toString();
              final number = (item['episode'] as num?)?.toInt() ?? 0;
              return SoraEpisode(
                number: number,
                session: epSession,
                playUrl: '$base/play/${match.session}/$epSession',
              );
            })
            .where((e) => e.number > 0 && e.session.isNotEmpty)
            .toList()
          ..sort((a, b) => a.number.compareTo(b.number));

        if (episodes.isNotEmpty) return episodes;
      } catch (_) {
        // try next mirror
      }
    }

    return const [];
  }

  Future<List<SoraSource>> getSourcesForEpisode(String playUrl) async {
    if (playUrl.isEmpty) return const [];

    final playCandidates = <String>{playUrl};
    try {
      final uri = Uri.parse(playUrl);
      if (uri.host.contains('animepahe')) {
        for (final base in _bases) {
          final b = Uri.parse(base);
          playCandidates.add(
            uri
                .replace(
                    scheme: b.scheme,
                    host: b.host,
                    port: b.hasPort ? b.port : null)
                .toString(),
          );
        }
      }
    } catch (_) {}

    for (final play in playCandidates) {
      try {
        final html = await _withRetry(() => _dio
            .get(
              play,
              options: Options(
                headers: {
                  'User-Agent': _ua,
                  'Referer': _inferReferer(play),
                },
                sendTimeout: const Duration(seconds: 15),
                receiveTimeout: const Duration(seconds: 15),
              ),
            )
            .then((r) => r.data.toString()));

        final candidates = <_Candidate>[];

        final buttonRegex = RegExp(r'<button[^>]*data-src="([^"]+)"[^>]*>',
            caseSensitive: false);
        for (final m in buttonRegex.allMatches(html)) {
          final tag = m.group(0) ?? '';
          final src = m.group(1) ?? '';
          if (src.isEmpty) continue;
          final resolution =
              _attr(tag, 'data-resolution') ?? _guessQuality(tag) ?? 'auto';
          final audio = (_attr(tag, 'data-audio') ?? 'jpn').toLowerCase();
          candidates.add(
            _Candidate(
              url: _resolveMaybeRelative(play, src),
              quality: resolution == 'auto' ? 'auto' : '${resolution}p',
              subOrDub: audio.contains('eng') ? 'dub' : 'sub',
            ),
          );
        }

        final kwikRegex =
            RegExp(r'"kwik"\s*:\s*"([^"]+)"', caseSensitive: false);
        for (final m in kwikRegex.allMatches(html)) {
          final url = m.group(1) ?? '';
          if (url.isEmpty) continue;
          candidates.add(_Candidate(
              url: _resolveMaybeRelative(play, url),
              quality: _guessQuality(url) ?? 'auto',
              subOrDub: 'sub'));
        }

        final m3u8Regex =
            RegExp(r'https:\/\/[^"\s]+\.m3u8[^"\s]*', caseSensitive: false);
        for (final m in m3u8Regex.allMatches(html)) {
          final raw = m.group(0) ?? '';
          if (raw.isEmpty) continue;
          final url = raw.replaceAll(r'\/', '/');
          candidates.add(_Candidate(
              url: url,
              quality: _guessQuality(url) ?? 'auto',
              subOrDub: 'sub'));
        }

        final dedup = <String, _Candidate>{};
        for (final c in candidates) {
          dedup[c.url] = c;
        }

        final out = <SoraSource>[];
        for (final c in dedup.values) {
          String? hls;
          final lower = c.url.toLowerCase();
          if (lower.contains('.m3u8')) {
            hls = c.url;
          } else if (lower.contains('kwik.') || lower.contains('/e/')) {
            hls = await _extractKwikHls(c.url);
          }
          if (hls == null || hls.isEmpty) continue;

          out.add(
            SoraSource(
              url: hls,
              quality: c.quality,
              subOrDub: c.subOrDub,
              format: 'm3u8',
              headers: {
                'Referer': _inferReferer(c.url),
                'Origin': _originFrom(hls) ?? 'https://kwik.cx',
                'User-Agent': _ua,
              },
            ),
          );
        }

        if (out.isNotEmpty) {
          out.sort((a, b) =>
              _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
          return out;
        }
      } catch (_) {
        // next mirror candidate
      }
    }

    return const [];
  }

  Future<String?> _extractKwikHls(String kwikUrl) async {
    final html = await _withRetry(() => _dio
        .get(
          kwikUrl,
          options: Options(
            headers: {
              'User-Agent': _ua,
              'Referer': _inferReferer(kwikUrl),
            },
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 15),
          ),
        )
        .then((r) => r.data.toString()));

    final direct =
        RegExp(r'https://[^"\s]+\.m3u8[^"\s]*').firstMatch(html)?.group(0);
    if (direct != null && direct.isNotEmpty) return direct;

    final scriptRegex =
        RegExp(r'<script[^>]*>([\s\S]*?)<\/script>', caseSensitive: false);
    for (final m in scriptRegex.allMatches(html)) {
      final script = m.group(1) ?? '';
      final fromConst = RegExp(r"const\s+source\s*=\s*'([^']+\.m3u8[^']*)'",
              caseSensitive: false)
          .firstMatch(script)
          ?.group(1);
      if (fromConst != null && fromConst.isNotEmpty) return fromConst;

      final fromFile =
          RegExp(r"file\s*:\s*'([^']+\.m3u8[^']*)'", caseSensitive: false)
              .firstMatch(script)
              ?.group(1);
      if (fromFile != null && fromFile.isNotEmpty) return fromFile;

      final unpacked =
          script.contains(".split('|')") ? _unpackPacker(script) : null;
      if (unpacked != null) {
        final inUnpacked = RegExp(r'https://[^"\s]+\.m3u8[^"\s]*')
            .firstMatch(unpacked)
            ?.group(0);
        if (inUnpacked != null && inUnpacked.isNotEmpty) return inUnpacked;
      }
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

    return payload.replaceAllMapped(RegExp(r'\b\w+\b'), (match) {
      final word = match.group(0)!;
      final idx = _unbase(word, radix);
      if (idx == null || idx < 0 || idx >= symtab.length) return word;
      return symtab[idx].isEmpty ? word : symtab[idx];
    });
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
      if (b.contains(a[i])) {
        same++;
      }
    }
    return (same * 1000) - maxLen;
  }

  int _qualityRank(String q) {
    final m = RegExp(r'(\d+)').firstMatch(q);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  String _resolveMaybeRelative(String base, String url) {
    final trimmed = url.trim();
    if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
      return trimmed;
    }
    if (trimmed.startsWith('//')) return 'https:$trimmed';
    try {
      return Uri.parse(base).resolve(trimmed).toString();
    } catch (_) {
      return trimmed;
    }
  }

  String _inferReferer(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}/';
    } catch (_) {
      return 'https://animepahe.si/';
    }
  }

  String? _originFrom(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}';
    } catch (_) {
      return null;
    }
  }

  String? _attr(String html, String name) {
    final m = RegExp('$name="([^"]+)"', caseSensitive: false).firstMatch(html);
    return m?.group(1);
  }

  String? _guessQuality(String text) {
    return RegExp(r'(360|480|720|1080)').firstMatch(text)?.group(1);
  }

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';
}

class _Candidate {
  const _Candidate(
      {required this.url, required this.quality, required this.subOrDub});

  final String url;
  final String quality;
  final String subOrDub;
}
