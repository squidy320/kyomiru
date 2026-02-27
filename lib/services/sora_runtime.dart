import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/app_logger.dart';
import '../models/sora_models.dart';

class _RuntimeCacheEntry<T> {
  const _RuntimeCacheEntry({required this.value, required this.expiresAt});

  final T value;
  final DateTime expiresAt;

  bool get isFresh => DateTime.now().isBefore(expiresAt);
}

class SoraRuntime {
  SoraRuntime({Dio? dio}) : _dio = dio ?? Dio() {
    _dio.interceptors.add(InterceptorsWrapper(
      onError: (e, handler) {
        AppLogger.e('SoraRuntime', 'Module/network request failed',
            error: e.message);
        handler.next(e);
      },
    ));
  }

  final Dio _dio;
  static const Duration _cacheTtl = Duration(minutes: 30);
  final Set<String> _refreshing = <String>{};
  final Map<String, _RuntimeCacheEntry<List<SoraEpisode>>> _episodesCache = {};
  final Map<String, _RuntimeCacheEntry<List<SoraSource>>> _sourcesCache = {};

  static const _baseUrl = 'https://animepahe.si';
  static const _jormExtractUrl =
      'https://jormungandr.ofchaos.com/api/animepahe/extract';

  static String? _cookieHeader;

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

  void _refreshInBackground(String key, Future<void> Function() task) {
    if (_refreshing.contains(key)) return;
    _refreshing.add(key);
    unawaited(() async {
      try {
        await task();
      } catch (_) {
      } finally {
        _refreshing.remove(key);
      }
    }());
  }

  Map<String, String> _cookieMap(String? cookieHeader) {
    final out = <String, String>{};
    if (cookieHeader == null || cookieHeader.trim().isEmpty) return out;
    for (final part in cookieHeader.split(';')) {
      final p = part.trim();
      if (p.isEmpty || !p.contains('=')) continue;
      final idx = p.indexOf('=');
      final k = p.substring(0, idx).trim();
      final v = p.substring(idx + 1).trim();
      if (k.isEmpty || v.isEmpty) continue;
      out[k] = v;
    }
    return out;
  }

  void _mergeSetCookie(Headers headers) {
    final raw = headers['set-cookie'];
    if (raw == null || raw.isEmpty) return;

    final merged = _cookieMap(_cookieHeader);
    for (final cookieLine in raw) {
      final first = cookieLine.split(';').first.trim();
      if (!first.contains('=')) continue;
      final idx = first.indexOf('=');
      final k = first.substring(0, idx).trim();
      final v = first.substring(idx + 1).trim();
      if (k.isEmpty || v.isEmpty) continue;
      merged[k] = v;
    }

    if (merged.isEmpty) return;
    _cookieHeader = merged.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  bool _looksLikeDdosGuard(String body, int statusCode) {
    if (statusCode != 200) return true;
    final lower = body.toLowerCase();
    return lower.contains('ddos-guard') ||
        lower.contains('check.ddos-guard.net/check.js') ||
        lower.contains('just a moment');
  }

  Future<String?> _tryDdosBypass(String url) async {
    try {
      final origin = '${Uri.parse(url).scheme}://${Uri.parse(url).host}';

      final checkJs = await _dio.get(
        'https://check.ddos-guard.net/check.js',
        options: Options(
          headers: {'User-Agent': 'DDG-Bypass', 'Accept': '*/*'},
          validateStatus: (code) => (code ?? 500) < 500,
        ),
      );
      _mergeSetCookie(checkJs.headers);

      final jsBody = checkJs.data?.toString() ?? '';
      final imgPath = RegExp(r"new Image\(\)\.src\s*=\s*'([^']+)';")
          .firstMatch(jsBody)
          ?.group(1);
      if (imgPath != null && imgPath.isNotEmpty) {
        final step2 = await _dio.get(
          '$origin$imgPath',
          options: Options(
            headers: {
              'User-Agent': 'DDG-Bypass',
              if (_cookieHeader != null) 'Cookie': _cookieHeader!,
            },
            validateStatus: (code) => (code ?? 500) < 500,
          ),
        );
        _mergeSetCookie(step2.headers);
      }

      final finalRes = await _dio.get(
        url,
        options: Options(
          headers: {
            'User-Agent': _ua,
            'Accept': 'application/json,text/html,*/*',
            if (_cookieHeader != null) 'Cookie': _cookieHeader!,
          },
          validateStatus: (code) => (code ?? 500) < 500,
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
        ),
      );
      _mergeSetCookie(finalRes.headers);
      return finalRes.data?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<dynamic> _fetchJsonOrHtml(String url,
      {Map<String, String>? headers}) async {
    final response = await _withRetry(
      () => _dio.get(
        url,
        options: Options(
          headers: {
            'User-Agent': _ua,
            'Accept': 'application/json,text/html,*/*',
            if (_cookieHeader != null) 'Cookie': _cookieHeader!,
            if (headers != null) ...headers,
          },
          sendTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(seconds: 15),
          validateStatus: (code) => (code ?? 500) < 500,
        ),
      ),
    );

    _mergeSetCookie(response.headers);

    var bodyText = response.data?.toString() ?? '';
    final status = response.statusCode ?? 500;

    if (_looksLikeDdosGuard(bodyText, status)) {
      final bypassed = await _tryDdosBypass(url);
      if (bypassed != null && bypassed.isNotEmpty) {
        bodyText = bypassed;
      }
    }

    final contentType =
        response.headers.value('content-type')?.toLowerCase() ?? '';

    if (contentType.contains('application/json')) {
      try {
        if (response.data is Map<String, dynamic>) return response.data;
        return jsonDecode(bodyText);
      } catch (_) {}
    }

    final trimmed = bodyText.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return jsonDecode(bodyText);
      } catch (_) {}
    }

    return bodyText;
  }

  Future<List<SoraAnimeMatch>> searchAnime(String query) async {
    if (query.trim().isEmpty) return const [];
    final url =
        '$_baseUrl/api?m=search&q=${Uri.encodeQueryComponent(query.trim())}&page=1';
    final data = await _fetchJsonOrHtml(url);
    if (data is! Map<String, dynamic>) return const [];

    final list = (data['data'] as List? ?? const []);
    return list
        .whereType<Map<String, dynamic>>()
        .map((e) {
          final session = (e['session'] ?? '').toString();
          return SoraAnimeMatch(
            title: (e['title'] ?? 'Unknown').toString(),
            image: (e['poster'] ?? '').toString(),
            href: '$_baseUrl/anime/$session',
            session: session,
            animeId: session,
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

  Future<List<SoraEpisode>> getEpisodes(SoraAnimeMatch match) async {
    final session = match.session.trim();
    if (session.isEmpty) return const [];

    final cached = _episodesCache[session];
    if (cached != null) {
      if (cached.isFresh) return cached.value;
      _refreshInBackground('episodes:' + session, () async {
        _episodesCache.remove(session);
        await getEpisodes(match);
      });
      return cached.value;
    }

    Future<Map<String, dynamic>> fetchPage(int page) async {
      final data = await _fetchJsonOrHtml(
          '$_baseUrl/api?m=release&id=$session&sort=episode_asc&page=$page');
      if (data is! Map<String, dynamic>) {
        throw Exception('Invalid release response');
      }
      return data;
    }

    final first = await fetchPage(1);
    final totalPages = (first['last_page'] as num?)?.toInt() ?? 1;
    final rows = <Map<String, dynamic>>[];
    rows.addAll(
      (first['data'] as List? ?? const []).whereType<Map<String, dynamic>>(),
    );

    for (var page = 2; page <= totalPages; page++) {
      try {
        final next = await fetchPage(page);
        rows.addAll(
          (next['data'] as List? ?? const []).whereType<Map<String, dynamic>>(),
        );
      } catch (_) {}
    }

    final episodes = rows
        .map((ep) {
          final episode2 = (ep['episode2'] as num?)?.toInt() ?? 0;
          if (episode2 != 0) return null;
          final epSession = (ep['session'] ?? '').toString();
          final number = (ep['episode'] as num?)?.toInt() ?? 0;
          if (epSession.isEmpty || number <= 0) return null;
          return SoraEpisode(
            number: number,
            session: epSession,
            playUrl: '$_baseUrl/play/$session/$epSession',
          );
        })
        .whereType<SoraEpisode>()
        .toList()
      ..sort((a, b) => a.number.compareTo(b.number));

    _episodesCache[session] = _RuntimeCacheEntry<List<SoraEpisode>>(value: episodes, expiresAt: DateTime.now().add(_cacheTtl));
    return episodes;
  }

  Future<List<SoraSource>> getSourcesForEpisode(
    String playUrl, {
    int? anilistId,
    int? episodeNumber,
  }) async {
    if (playUrl.isEmpty) {
      AppLogger.w(
          'SoraRuntime', 'getSourcesForEpisode called with empty playUrl');
      return const [];
    }

    final uri = Uri.tryParse(playUrl);
    final segments = uri?.pathSegments ?? const <String>[];
    if (segments.length < 3) {
      AppLogger.w('SoraRuntime', 'Invalid playUrl: $playUrl');
      return const [];
    }
    final session = segments[segments.length - 2];
    final episodeSession = segments.last;
    final cacheKey = '$session/$episodeSession';
    final cached = _sourcesCache[cacheKey];
    if (cached != null) {
      if (cached.isFresh) return cached.value;
      _refreshInBackground('sources:' + cacheKey, () async {
        _sourcesCache.remove(cacheKey);
        await getSourcesForEpisode(
          playUrl,
          anilistId: anilistId,
          episodeNumber: episodeNumber,
        );
      });
      return cached.value;
    }

    final fromJorm = await _extractViaJorm(session, episodeSession,
        anilistId: anilistId, episodeNumber: episodeNumber);
    final jormClean = _dedupSources(fromJorm
        .where((s) => s.url.trim().isNotEmpty)
        .where(
            (s) => s.url.startsWith('http://') || s.url.startsWith('https://'))
        .toList());
    if (jormClean.isNotEmpty) {
      AppLogger.i('SoraRuntime',
          'Jorm extracted ${jormClean.length} source(s) for $session/$episodeSession');
      _sourcesCache[cacheKey] = _RuntimeCacheEntry<List<SoraSource>>(value: jormClean, expiresAt: DateTime.now().add(_cacheTtl));
      return jormClean;
    }

    final local = await _extractViaLocalFallback(session, episodeSession);
    final localClean = _dedupSources(local
        .where((s) => s.url.trim().isNotEmpty)
        .where(
            (s) => s.url.startsWith('http://') || s.url.startsWith('https://'))
        .toList());
    if (localClean.isNotEmpty) {
      AppLogger.i('SoraRuntime',
          'Local fallback extracted ${localClean.length} source(s) for $session/$episodeSession');
      _sourcesCache[cacheKey] = _RuntimeCacheEntry<List<SoraSource>>(value: localClean, expiresAt: DateTime.now().add(_cacheTtl));
      return localClean;
    }

    // Last-resort retry without AniList context for unstable extractors.
    if (anilistId != null || episodeNumber != null) {
      final retry = await _extractViaJorm(session, episodeSession);
      final retryClean = _dedupSources(retry
          .where((s) => s.url.trim().isNotEmpty)
          .where((s) =>
              s.url.startsWith('http://') || s.url.startsWith('https://'))
          .toList());
      if (retryClean.isNotEmpty) {
        _sourcesCache[cacheKey] = _RuntimeCacheEntry<List<SoraSource>>(value: retryClean, expiresAt: DateTime.now().add(_cacheTtl));
      }
      return retryClean;
    }

    AppLogger.w(
        'SoraRuntime', 'No sources extracted for $session/$episodeSession');
    return const [];
  }

  Future<List<SoraSource>> _extractViaJorm(
    String session,
    String episodeSession, {
    int? anilistId,
    int? episodeNumber,
  }) async {
    try {
      final response = await _withRetry(
        () => _dio.post(
          _jormExtractUrl,
          data: {
            'anilist_id': anilistId,
            'mal_id': null,
            'episode': episodeNumber,
            'dataset': {
              'session': session,
              'episodeSession': episodeSession,
            },
            'formatting': 'sora',
          },
          options: Options(
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              'User-Agent': _ua,
              if (_cookieHeader != null) 'Cookie': _cookieHeader!,
            },
            sendTimeout: const Duration(seconds: 15),
            receiveTimeout: const Duration(seconds: 20),
            validateStatus: (code) => (code ?? 500) < 500,
          ),
        ),
      );

      _mergeSetCookie(response.headers);
      if ((response.statusCode ?? 500) != 200) return const [];

      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : jsonDecode(response.data.toString()) as Map<String, dynamic>;

      dynamic streamsDyn = data['streams'];
      if ((streamsDyn is! List || streamsDyn.isEmpty) &&
          data['result'] is Map<String, dynamic>) {
        streamsDyn = (data['result'] as Map<String, dynamic>)['streams'];
      }
      final streams = streamsDyn is List ? streamsDyn : const [];
      if (streams.isEmpty) return const [];

      final out = <SoraSource>[];
      for (final item in streams.whereType<Map<String, dynamic>>()) {
        final streamUrl = _sanitizeStreamUrl(
          (item['streamUrl'] ?? item['stream_url'] ?? item['url'] ?? '')
              .toString(),
        );
        if (streamUrl.isEmpty || !streamUrl.contains('.m3u8')) continue;

        final title = (item['title'] ?? '').toString().toLowerCase();
        final qualityNum =
            RegExp(r'(360|480|720|1080)').firstMatch(title)?.group(1);
        final quality = qualityNum == null ? 'auto' : '${qualityNum}p';
        final subOrDub =
            title.contains('eng') || title.contains('dub') ? 'dub' : 'sub';

        out.add(
          SoraSource(
            url: streamUrl,
            quality: quality,
            subOrDub: subOrDub,
            format: 'm3u8',
            headers: {
              'Referer':
                  ((item['referer'] ?? item['Referer'])?.toString() ?? '')
                          .isNotEmpty
                      ? (item['referer'] ?? item['Referer']).toString()
                      : 'https://kwik.cx/',
              'Origin': _originFrom(streamUrl) ?? 'https://kwik.cx',
              'User-Agent': _ua,
              if (_cookieHeader != null) 'Cookie': _cookieHeader!,
            },
          ),
        );
      }

      out.sort(
          (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
      return _dedupSources(out);
    } catch (_) {
      return const [];
    }
  }

  Future<List<SoraSource>> _extractViaLocalFallback(
      String session, String episodeSession) async {
    final episodeUrl = '$_baseUrl/play/$session/$episodeSession';
    final html = await _fetchJsonOrHtml(episodeUrl);
    if (html is! String) return const [];

    final candidates = <_LocalSource>[];

    final tagRegex = RegExp(
      '''<(?:button|a)[^>]*(?:data-src|href)=["']([^"']+)["'][^>]*>''',
      caseSensitive: false,
    );
    for (final m in tagRegex.allMatches(html)) {
      final tag = m.group(0) ?? '';
      final raw = m.group(1) ?? '';
      if (raw.isEmpty) continue;
      final url = _resolveMaybeRelative(episodeUrl, raw);
      if (!(url.contains('kwik.') ||
          url.contains('/e/') ||
          url.contains('.m3u8'))) {
        continue;
      }
      final q = int.tryParse(_attr(tag, 'data-resolution') ?? '') ??
          (int.tryParse(
                  RegExp(r'(360|480|720|1080)').firstMatch(tag)?.group(1) ??
                      '') ??
              0);
      final a = (_attr(tag, 'data-audio') ?? 'jpn').toLowerCase();
      candidates.add(_LocalSource(kwik: url, resolution: q, audio: a));
    }

    final inlineKwikRegex =
        RegExp(r'https://kwik\.[^"\s]+/e/[^"\s]+', caseSensitive: false);
    for (final m in inlineKwikRegex.allMatches(html)) {
      final url = m.group(0) ?? '';
      if (url.isEmpty) continue;
      final q = int.tryParse(
              RegExp(r'(360|480|720|1080)').firstMatch(url)?.group(1) ?? '') ??
          0;
      candidates.add(_LocalSource(kwik: url, resolution: q, audio: 'jpn'));
    }

    final inlineM3u8Regex =
        RegExp(r'https://[^"\s]+\.m3u8[^"\s]*', caseSensitive: false);
    final out = <SoraSource>[];
    for (final m in inlineM3u8Regex.allMatches(html)) {
      final url = _sanitizeStreamUrl(m.group(0) ?? '');
      if (url.isEmpty) continue;
      final q = RegExp(r'(360|480|720|1080)').firstMatch(url)?.group(1);
      out.add(
        SoraSource(
          url: url,
          quality: q == null ? 'auto' : '${q}p',
          subOrDub: 'sub',
          format: 'm3u8',
          headers: {
            'Referer': episodeUrl,
            'Origin': _originFrom(url) ?? 'https://kwik.cx',
            'User-Agent': _ua,
            if (_cookieHeader != null) 'Cookie': _cookieHeader!,
          },
        ),
      );
    }

    final seen = <String>{};
    for (final c in candidates) {
      if (seen.contains(c.kwik)) continue;
      seen.add(c.kwik);
      String? hls;
      if (c.kwik.contains('.m3u8')) {
        hls = _sanitizeStreamUrl(c.kwik);
      } else {
        hls = await _extractKwikHls(c.kwik);
      }
      if (hls == null || hls.isEmpty) continue;

      out.add(
        SoraSource(
          url: hls,
          quality: c.resolution > 0 ? '${c.resolution}p' : 'auto',
          subOrDub: c.audio.contains('eng') ? 'dub' : 'sub',
          format: 'm3u8',
          headers: {
            'Referer': c.kwik,
            'Origin': _originFrom(hls) ?? 'https://kwik.cx',
            'User-Agent': _ua,
            if (_cookieHeader != null) 'Cookie': _cookieHeader!,
          },
        ),
      );
    }

    out.sort(
        (a, b) => _qualityRank(b.quality).compareTo(_qualityRank(a.quality)));
    return _dedupSources(out);
  }

  Future<String?> _extractKwikHls(String kwikUrl) async {
    try {
      final html = await _fetchJsonOrHtml(kwikUrl, headers: {
        'Referer': 'https://kwik.cx/',
      });
      if (html is! String) return null;

      var scriptSource = html;
      if (html.contains('eval(function(p,a,c,k,e,d)')) {
        final scriptMatch = RegExp(
          r'<script[^>]*>\s*(eval\(function\(p,a,c,k,e,d.*?\))\s*</script>',
          caseSensitive: false,
          dotAll: true,
        ).firstMatch(html)?.group(1);
        if (scriptMatch != null) {
          final unpacked = _unpackPacker(scriptMatch);
          if (unpacked != null && unpacked.isNotEmpty) scriptSource = unpacked;
        }
      }

      final normalizedScript = scriptSource.replaceAll("'", '"');
      String? sourceUrl =
          RegExp(r'source\s*=\s*"([^"]+)"', caseSensitive: false)
              .firstMatch(normalizedScript)
              ?.group(1);

      sourceUrl ??= RegExp(r'https://[^"\s]+\.m3u8[^"\s]*')
          .firstMatch(normalizedScript)
          ?.group(0);

      if (sourceUrl == null || sourceUrl.isEmpty) return null;

      return _sanitizeStreamUrl(sourceUrl)
          .replaceAll('/stream/', '/hls/')
          .replaceAll('uwu.m3u8', 'owo.m3u8');
    } catch (_) {
      return null;
    }
  }

  String _sanitizeStreamUrl(String url) {
    return url
        .trim()
        .replaceAll(r'\\/', '/')
        .replaceAll(r'\\u002F', '/')
        .replaceAll('\\"', '')
        .replaceAll("'", '')
        .replaceAll(RegExp(r'\\+$'), '');
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

  String? _attr(String html, String name) {
    final m = RegExp('$name=["\']([^"\']+)["\']', caseSensitive: false)
        .firstMatch(html);
    return m?.group(1);
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

  List<SoraSource> _dedupSources(List<SoraSource> sources) {
    final map = <String, SoraSource>{};
    for (final s in sources) {
      map['${s.url}_${s.quality}_${s.subOrDub}'] = s;
    }
    return map.values.toList();
  }

  int _qualityRank(String q) {
    final m = RegExp(r'(\d+)').firstMatch(q);
    return int.tryParse(m?.group(1) ?? '') ?? 0;
  }

  String? _originFrom(String url) {
    try {
      final uri = Uri.parse(url);
      return '${uri.scheme}://${uri.host}';
    } catch (_) {
      return null;
    }
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

  static const _ua =
      'Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1';
}

class _LocalSource {
  const _LocalSource({
    required this.kwik,
    required this.resolution,
    required this.audio,
  });

  final String kwik;
  final int resolution;
  final String audio;
}








