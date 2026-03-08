import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:hive/hive.dart';

import '../core/app_logger.dart';
import '../models/anilist_models.dart';

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;

  bool get isValid => DateTime.now().isBefore(expiresAt);
}

class AniListClient {
  AniListClient({Dio? dio, Box? mediaCacheBox})
      : _dio = dio ?? Dio(),
        _mediaCacheBox = mediaCacheBox {
    _dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final isGraphql = options.uri.toString().contains(graphqlEndpoint);
          final data = options.data;
          final queryText = data is Map<String, dynamic>
              ? (data['query']?.toString() ?? '')
              : '';
          final isMutation = queryText.contains('mutation');
          final authHeader =
              options.headers['Authorization']?.toString().trim() ?? '';
          final tokenFromExtra =
              options.extra['anilistToken']?.toString().trim() ?? '';

          if (isGraphql && isMutation) {
            if (authHeader.isEmpty && tokenFromExtra.isNotEmpty) {
              options.headers['Authorization'] = 'Bearer $tokenFromExtra';
            }
            final ensuredAuth =
                options.headers['Authorization']?.toString().trim() ?? '';
            if (ensuredAuth.isEmpty) {
              AppLogger.e('AniList', 'AniList Update Failed: No Token');
              handler.reject(
                DioException(
                  requestOptions: options,
                  error: 'AniList Update Failed: No Token',
                  type: DioExceptionType.badResponse,
                ),
              );
              return;
            }
            if (!ensuredAuth.startsWith('Bearer ')) {
              options.headers['Authorization'] = 'Bearer $ensuredAuth';
            }
          }
          handler.next(options);
        },
      ),
    );
  }

  final Dio _dio;
  final Box? _mediaCacheBox;

  static const authEndpoint = 'https://anilist.co/api/v2/oauth/authorize';
  static const graphqlEndpoint = 'https://graphql.anilist.co';
  static const tokenEndpoint = 'https://anilist.co/api/v2/oauth/token';

  final List<Future<void> Function()> _serialQueue = [];
  bool _serialRunning = false;
  DateTime _nextAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _anonymousCooldownUntil = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _staleTtl = Duration(minutes: 30);
  static const Duration _trackingTtl = Duration(minutes: 2);
  static const Duration _libraryTrackingTtl = Duration(minutes: 5);
  static const Duration _mediaTtl = Duration(hours: 24);
  final Set<String> _refreshing = <String>{};

  final Map<String, _CacheEntry<AniListUser>> _viewerCache = {};
  final Map<String, _CacheEntry<int>> _unreadCache = {};
  final Map<String, _CacheEntry<List<AniListLibraryEntry>>>
      _libraryCurrentCache = {};
  final Map<String, _CacheEntry<List<AniListLibrarySection>>>
      _librarySectionsCache = {};
  final Map<String, _CacheEntry<AniListEpisodeAvailability>>
      _episodeAvailabilityCache = {};
  final Map<String, _CacheEntry<List<AniListNotificationItem>>>
      _notificationsCache = {};
  final Map<String, _CacheEntry<AniListTrackingEntry?>> _trackingEntryCache =
      {};
  final Map<String, Future<AniListTrackingEntry?>> _inflightTrackingLoads = {};

  _CacheEntry<List<AniListMedia>>? _discoveryTrendingCache;
  _CacheEntry<List<AniListDiscoverySection>>? _discoverySectionsCache;
  final Map<int, _CacheEntry<AniListMedia>> _mediaDetailsMemoryCache = {};

  Future<T> _serialize<T>(Future<T> Function() task) {
    final completer = Completer<T>();
    _serialQueue.add(() async {
      try {
        final r = await task();
        if (!completer.isCompleted) completer.complete(r);
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      }
    });
    _drainSerialQueue();
    return completer.future;
  }

  void _drainSerialQueue() {
    if (_serialRunning) return;
    _serialRunning = true;
    unawaited(() async {
      try {
        while (_serialQueue.isNotEmpty) {
          final next = _serialQueue.removeAt(0);
          await next();
        }
      } finally {
        _serialRunning = false;
        if (_serialQueue.isNotEmpty) {
          _drainSerialQueue();
        }
      }
    }());
  }

  Future<void> _respectGate(Duration gate) async {
    final now = DateTime.now();
    if (now.isBefore(_nextAllowedAt)) {
      await Future<void>.delayed(_nextAllowedAt.difference(now));
    }
    _nextAllowedAt = DateTime.now().add(gate);
  }

  bool _isAnonymousNonEssential(String query, String? token) {
    final hasToken = token != null && token.isNotEmpty;
    if (hasToken) return false;
    final lower = query.toLowerCase();
    if (lower.contains('viewer')) return false;
    if (lower.contains('unreadnotificationcount')) return false;
    if (lower.contains('notifications')) return false;
    return true;
  }

  Box? _mediaBox() {
    if (_mediaCacheBox != null) return _mediaCacheBox;
    try {
      if (Hive.isBoxOpen('anilist_media_cache')) {
        return Hive.box('anilist_media_cache');
      }
    } catch (_) {}
    return null;
  }

  Box? _queryBox() {
    try {
      if (Hive.isBoxOpen('anilist_query_cache')) {
        return Hive.box('anilist_query_cache');
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic>? _readQueryCache(
    String key, {
    Duration? maxAge = _mediaTtl,
  }) {
    final raw = _queryBox()?.get(key);
    if (raw is! Map) return null;
    final cachedAtMs = (raw['cachedAtMs'] as num?)?.toInt() ?? 0;
    if (cachedAtMs <= 0) return null;
    if (maxAge != null) {
      final age = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(cachedAtMs));
      if (age > maxAge) return null;
    }
    final data = raw['data'];
    if (data is! Map) return null;
    return Map<String, dynamic>.from(data);
  }

  void _writeQueryCache(String key, Map<String, dynamic> data) {
    _queryBox()?.put(key, {
      'cachedAtMs': DateTime.now().millisecondsSinceEpoch,
      'data': data,
    });
  }

  void _cacheMediaMap(Map<String, dynamic> media) {
    final id = (media['id'] as num?)?.toInt();
    if (id == null || id <= 0) return;
    final cache = {
      'cachedAtMs': DateTime.now().millisecondsSinceEpoch,
      'data': media,
    };
    _mediaDetailsMemoryCache[id] = _CacheEntry<AniListMedia>(
      AniListMedia.fromJson(media),
      DateTime.now().add(_mediaTtl),
    );
    _mediaBox()?.put(id.toString(), cache);
  }

  void _cacheMediaList(Iterable<Map<String, dynamic>> medias) {
    for (final media in medias) {
      _cacheMediaMap(media);
    }
  }

  AniListMedia? _readMediaFromCache(int mediaId) {
    final mem = _mediaDetailsMemoryCache[mediaId];
    if (mem != null && mem.isValid) return mem.value;

    final raw = _mediaBox()?.get(mediaId.toString());
    if (raw is! Map) return null;
    final cachedAtMs = (raw['cachedAtMs'] as num?)?.toInt() ?? 0;
    if (cachedAtMs <= 0) return null;
    final age = DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(cachedAtMs));
    if (age > _mediaTtl) return null;

    final data = raw['data'];
    if (data is! Map) return null;
    final media = AniListMedia.fromJson(Map<String, dynamic>.from(data));
    _mediaDetailsMemoryCache[mediaId] =
        _CacheEntry<AniListMedia>(media, DateTime.now().add(_mediaTtl));
    return media;
  }

  bool _looksDetailedMedia(AniListMedia media) {
    final desc = (media.description ?? '').trim();
    return desc.isNotEmpty ||
        media.streamingEpisodes.isNotEmpty ||
        media.relations.isNotEmpty ||
        media.studios.isNotEmpty ||
        media.characters.isNotEmpty;
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

  void _patchTrackingCaches({
    required String token,
    required int mediaId,
    required String status,
    required int progress,
  }) {
    for (final entry in _libraryCurrentCache.entries.toList()) {
      if (!entry.key.startsWith('$token:')) continue;
      final current = entry.value;
      if (!current.isValid) continue;
      var changed = false;
      final patched = current.value.map((row) {
        if (row.media.id != mediaId) return row;
        changed = true;
        return AniListLibraryEntry(
          id: row.id,
          progress: progress,
          media: row.media,
        );
      }).toList();
      if (!changed) continue;
      _libraryCurrentCache[entry.key] = _CacheEntry<List<AniListLibraryEntry>>(
        patched,
        current.expiresAt,
      );
    }

    for (final entry in _librarySectionsCache.entries.toList()) {
      if (!entry.key.startsWith('$token:')) continue;
      final current = entry.value;
      if (!current.isValid) continue;
      var changed = false;
      final patchedSections = current.value.map((section) {
        final patchedItems = section.items.map((row) {
          if (row.media.id != mediaId) return row;
          changed = true;
          return AniListLibraryEntry(
            id: row.id,
            progress: progress,
            media: row.media,
          );
        }).toList();
        return AniListLibrarySection(title: section.title, items: patchedItems);
      }).toList();
      if (!changed) continue;

      // Move media between sections if status changed.
      AniListLibraryEntry? tracked;
      for (final section in patchedSections) {
        for (final item in section.items) {
          if (item.media.id == mediaId) {
            tracked = item;
            break;
          }
        }
        if (tracked != null) break;
      }
      if (tracked != null) {
        final normalizedStatus = status.toUpperCase();
        String targetTitle;
        switch (normalizedStatus) {
          case 'CURRENT':
          case 'REPEATING':
            targetTitle = 'Watching';
            break;
          case 'PLANNING':
            targetTitle = 'Planning';
            break;
          case 'COMPLETED':
            targetTitle = 'Completed';
            break;
          case 'PAUSED':
            targetTitle = 'Paused';
            break;
          case 'DROPPED':
            targetTitle = 'Dropped';
            break;
          default:
            targetTitle = 'Watching';
        }
        final withoutMedia = patchedSections
            .map(
              (section) => AniListLibrarySection(
                title: section.title,
                items: section.items
                    .where((item) => item.media.id != mediaId)
                    .toList(),
              ),
            )
            .toList();
        final targetIndex =
            withoutMedia.indexWhere((s) => s.title == targetTitle);
        if (targetIndex >= 0) {
          final target = withoutMedia[targetIndex];
          withoutMedia[targetIndex] = AniListLibrarySection(
            title: target.title,
            items: [...target.items, tracked],
          );
        } else {
          withoutMedia
              .add(AniListLibrarySection(title: targetTitle, items: [tracked]));
        }
        _librarySectionsCache[entry.key] =
            _CacheEntry<List<AniListLibrarySection>>(
          withoutMedia,
          current.expiresAt,
        );
      } else {
        _librarySectionsCache[entry.key] =
            _CacheEntry<List<AniListLibrarySection>>(
          patchedSections,
          current.expiresAt,
        );
      }
    }
  }

  void _pruneFromLibraryCaches(String token, int mediaId) {
    for (final entry in _libraryCurrentCache.entries.toList()) {
      if (!entry.key.startsWith('$token:')) continue;
      final current = entry.value;
      if (!current.isValid) continue;
      final patched = current.value
          .where((row) => row.media.id != mediaId)
          .toList(growable: false);
      _libraryCurrentCache[entry.key] = _CacheEntry<List<AniListLibraryEntry>>(
        patched,
        current.expiresAt,
      );
    }

    for (final entry in _librarySectionsCache.entries.toList()) {
      if (!entry.key.startsWith('$token:')) continue;
      final current = entry.value;
      if (!current.isValid) continue;
      final patchedSections = current.value
          .map(
            (section) => AniListLibrarySection(
              title: section.title,
              items: section.items
                  .where((item) => item.media.id != mediaId)
                  .toList(growable: false),
            ),
          )
          .where((section) => section.items.isNotEmpty)
          .toList(growable: false);
      _librarySectionsCache[entry.key] =
          _CacheEntry<List<AniListLibrarySection>>(
        patchedSections,
        current.expiresAt,
      );
    }
  }

  String buildAuthUrl({
    required String clientId,
    required String redirectUri,
    required String state,
    bool useCodeFlow = true,
  }) {
    final uri = Uri.parse(authEndpoint).replace(queryParameters: {
      'client_id': clientId,
      'response_type': useCodeFlow ? 'code' : 'token',
      'state': state,
      'redirect_uri': redirectUri,
    });
    final url = uri.toString();
    AppLogger.i(
      'AniList',
      'Built auth URL (flow=${useCodeFlow ? 'code' : 'token'}, redirect=$redirectUri)',
    );
    return url;
  }

  Future<String> exchangeCodeForToken({
    required String clientId,
    required String clientSecret,
    required String code,
    required String redirectUri,
  }) async {
    try {
      AppLogger.i('AniList', 'Starting code->token exchange');
      final response = await _dio.post(
        tokenEndpoint,
        data: {
          'grant_type': 'authorization_code',
          'client_id': clientId,
          'client_secret': clientSecret,
          'redirect_uri': redirectUri,
          'code': code,
        },
        options: Options(
          contentType: Headers.formUrlEncodedContentType,
          headers: const {'Accept': 'application/json'},
          validateStatus: (_) => true,
        ),
      );

      final status = response.statusCode ?? 0;
      final data = response.data is Map<String, dynamic>
          ? response.data as Map<String, dynamic>
          : jsonDecode(response.data.toString()) as Map<String, dynamic>;

      if (status >= 400) {
        AppLogger.e('AniList', 'Token exchange HTTP $status', error: data);
        throw Exception('AniList token exchange HTTP $status');
      }

      final token = (data['access_token'] ?? '').toString();
      if (token.isEmpty) {
        AppLogger.e('AniList', 'Token exchange returned empty access_token',
            error: data);
        throw Exception('AniList token exchange returned no access token.');
      }
      AppLogger.i('AniList', 'Token exchange succeeded');
      return token;
    } on DioException catch (e, st) {
      AppLogger.e('AniList', 'Token exchange DioException',
          error: {
            'statusCode': e.response?.statusCode,
            'response': e.response?.data,
            'message': e.message,
          },
          stackTrace: st);
      rethrow;
    } catch (e, st) {
      AppLogger.e('AniList', 'Token exchange failed', error: e, stackTrace: st);
      rethrow;
    }
  }

  static const _pornKeywords = <String>[
    'hentai',
    'porn',
    'pornography',
    'xxx',
    'rule34',
    'sex tape',
    'sex video',
    'nude',
  ];

  bool _isPorn(AniListMedia media) {
    if (media.isAdult) return true;
    final title = [media.title.english, media.title.romaji, media.title.native]
        .whereType<String>()
        .join(' ')
        .toLowerCase();
    if (_pornKeywords.any((k) => title.contains(k))) return true;
    final genres = media.genres.map((e) => e.toLowerCase()).toList();
    return genres
        .any((g) => g.contains('hentai') || g.contains('pornographic'));
  }

  List<AniListMedia> _sanitizeMediaList(List<AniListMedia> items) {
    return items.where((m) => !_isPorn(m)).toList();
  }

  Future<Map<String, dynamic>> _graphql({
    required String query,
    Map<String, dynamic>? variables,
    String? token,
  }) async {
    final operation = RegExp(r'\b(query|mutation)\s+([A-Za-z0-9_]+)')
            .firstMatch(query)
            ?.group(2) ??
        'anonymous';

    return _serialize(() async {
      final isAnonymous = token == null || token.isEmpty;
      final isMutation = query.toLowerCase().contains('mutation');
      if (isAnonymous && DateTime.now().isBefore(_anonymousCooldownUntil)) {
        AppLogger.w(
          'AniList',
          'GraphQL cooldown active op=$operation; returning empty payload',
        );
        return <String, dynamic>{};
      }
      var attempts = 0;
      while (true) {
        attempts++;
        final gate = _isAnonymousNonEssential(query, token)
            ? const Duration(milliseconds: 700)
            : const Duration(milliseconds: 300);
        await _respectGate(gate);
        try {
          AppLogger.d('AniList',
              'GraphQL request op=$operation hasToken=${token != null && token.isNotEmpty}');

          final response = await _dio.post(
            graphqlEndpoint,
            data: {
              'query': query,
              'variables': variables ?? <String, dynamic>{},
            },
            options: Options(
              headers: {
                if (token != null && token.isNotEmpty)
                  'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
                'Accept': 'application/json',
              },
              extra: {
                if (token != null && token.isNotEmpty) 'anilistToken': token,
              },
              validateStatus: (_) => true,
            ),
          );

          final status = response.statusCode ?? 0;
          final body = response.data is Map<String, dynamic>
              ? response.data as Map<String, dynamic>
              : jsonDecode(response.data.toString()) as Map<String, dynamic>;

          if (status == 429 && isMutation) {
            const delayMs = 8000;
            _nextAllowedAt =
                DateTime.now().add(const Duration(milliseconds: delayMs));
            AppLogger.w(
              'AniList',
              'GraphQL 429 op=$operation on mutation; failing fast and cooling down ${delayMs}ms',
            );
            throw Exception('AniList GraphQL HTTP 429 (mutation cooldown)');
          }

          if (status == 429 && attempts < 4) {
            final delayMs = 1200 * attempts;
            _nextAllowedAt =
                DateTime.now().add(Duration(milliseconds: delayMs));
            if (isAnonymous) {
              _anonymousCooldownUntil = DateTime.now().add(
                const Duration(seconds: 45),
              );
            }
            AppLogger.w('AniList',
                'GraphQL 429 op=$operation; backing off ${delayMs}ms');
            continue;
          }

          if (status >= 400) {
            if (status == 429 && isAnonymous) {
              _anonymousCooldownUntil = DateTime.now().add(
                const Duration(seconds: 45),
              );
              AppLogger.w(
                'AniList',
                'GraphQL 429 op=$operation in anonymous mode; returning empty payload',
              );
              return <String, dynamic>{};
            }
            AppLogger.e('AniList', 'GraphQL HTTP $status op=$operation',
                error: {
                  'variables': variables,
                  'body': body,
                });
            throw Exception('AniList GraphQL HTTP $status');
          }

          if (body['errors'] is List && (body['errors'] as List).isNotEmpty) {
            final first = (body['errors'] as List).first;
            final message = first is Map ? (first['message'] ?? first) : first;
            AppLogger.e('AniList', 'GraphQL logical error op=$operation',
                error: {
                  'message': message,
                  'variables': variables,
                });
            throw Exception('AniList GraphQL error: $message');
          }

          return (body['data'] as Map<String, dynamic>? ?? <String, dynamic>{});
        } on DioException catch (e, st) {
          AppLogger.e('AniList', 'GraphQL DioException op=$operation',
              error: {
                'statusCode': e.response?.statusCode,
                'response': e.response?.data,
                'message': e.message,
              },
              stackTrace: st);
          rethrow;
        } catch (e, st) {
          AppLogger.e('AniList', 'GraphQL request failed op=$operation',
              error: e, stackTrace: st);
          rethrow;
        }
      }
    });
  }

  Future<AniListUser> me(String token, {bool force = false}) async {
    final cached = _viewerCache[token];
    if (!force && cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('me:$token', () async {
        final fresh = await _fetchMe(token);
        _viewerCache[token] = _CacheEntry<AniListUser>(
          fresh,
          DateTime.now().add(_staleTtl),
        );
      });
      return cached.value;
    }

    return _fetchMe(token);
  }

  Future<AniListUser> _fetchMe(String token) async {
    const q = r'''
      query {
        Viewer {
          id
          name
          avatar { large }
          bannerImage
          mediaListOptions { scoreFormat }
        }
      }
    ''';
    final data = await _graphql(query: q, token: token);
    final user = AniListUser.fromJson(
      (data['Viewer'] as Map<String, dynamic>? ?? const {}),
    );
    _viewerCache[token] = _CacheEntry<AniListUser>(
      user,
      DateTime.now().add(_staleTtl),
    );
    return user;
  }

  Future<int> unreadNotificationCount(String token,
      {bool force = false}) async {
    final cached = _unreadCache[token];
    if (!force && cached != null && cached.isValid) return cached.value;

    const q = r'''
      query {
        Viewer { unreadNotificationCount }
      }
    ''';
    final data = await _graphql(query: q, token: token);
    final value =
        (data['Viewer']?['unreadNotificationCount'] as num?)?.toInt() ?? 0;
    _unreadCache[token] = _CacheEntry<int>(
      value,
      DateTime.now().add(const Duration(seconds: 30)),
    );
    return value;
  }

  void clearUnreadCache(String token) {
    _unreadCache.remove(token);
  }

  Future<void> markNotificationsRead(String token) async {
    // AniList schema variants may not expose NotificationReset.
    // Use local reset to avoid hard failures and repeated 400 logs.
    clearUnreadCache(token);
    _notificationsCache.remove(token);
    AppLogger.i('AniList', 'Marked notifications as read (local cache reset)');
  }

  Future<List<AniListLibraryEntry>> libraryCurrent(
    String token, {
    int? userId,
    bool force = false,
  }) async {
    final uid = userId ?? (await me(token)).id;
    final cacheKey = '$token:$uid';
    final persistedKey = 'libraryCurrent:$cacheKey';
    final cached = _libraryCurrentCache[cacheKey];
    if (!force && cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('libraryCurrent:$cacheKey', () async {
        _libraryCurrentCache.remove(cacheKey);
        final fresh = await libraryCurrent(token, userId: uid);
        _libraryCurrentCache[cacheKey] = _CacheEntry<List<AniListLibraryEntry>>(
            fresh, DateTime.now().add(_libraryTrackingTtl));
      });
      return cached.value;
    }
    if (force) {
      _libraryCurrentCache.remove(cacheKey);
    }
    final persisted = _readQueryCache(
      persistedKey,
      maxAge: _libraryTrackingTtl,
    );
    if (!force && persisted != null) {
      final rows = (persisted['items'] as List? ?? const [])
          .whereType<Map>()
          .map(
              (e) => AniListLibraryEntry.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _libraryCurrentCache[cacheKey] = _CacheEntry<List<AniListLibraryEntry>>(
        rows,
        DateTime.now().add(_libraryTrackingTtl),
      );
      return rows;
    }
    const q = r'''
      query ($userId: Int) {
        MediaListCollection(
          userId: $userId,
          type: ANIME,
          status_in: [CURRENT, REPEATING]
        ) {
          lists {
            entries {
              id
              progress
              media {
                id
                idMal
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
                isAdult
                genres
              }
            }
          }
        }
      }
    ''';

    final data = await _graphql(
      query: q,
      token: token,
      variables: {'userId': uid},
    );
    final lists = (data['MediaListCollection']?['lists'] as List? ?? const []);
    final out = <AniListLibraryEntry>[];
    for (final list in lists) {
      final entries =
          (list is Map<String, dynamic> ? list['entries'] : null) as List? ??
              const [];
      for (final entry in entries) {
        if (entry is Map<String, dynamic>) {
          final media = entry['media'];
          if (media is Map<String, dynamic>) {
            _cacheMediaMap(media);
          }
          out.add(AniListLibraryEntry.fromJson(entry));
        }
      }
    }
    _libraryCurrentCache[cacheKey] = _CacheEntry<List<AniListLibraryEntry>>(
        out, DateTime.now().add(_libraryTrackingTtl));
    _writeQueryCache(
      persistedKey,
      {
        'items': out
            .map((e) => {
                  'id': e.id,
                  'progress': e.progress,
                  'media': {
                    'id': e.media.id,
                    'idMal': e.media.idMal,
                    'episodes': e.media.episodes,
                    'averageScore': e.media.averageScore,
                    'title': {
                      'romaji': e.media.title.romaji,
                      'english': e.media.title.english,
                      'native': e.media.title.native,
                    },
                    'coverImage': {
                      'large': e.media.cover.large,
                      'extraLarge': e.media.cover.extraLarge,
                    },
                    'siteUrl': e.media.siteUrl,
                    'bannerImage': e.media.bannerImage,
                    'status': e.media.status,
                    'isAdult': e.media.isAdult,
                    'genres': e.media.genres,
                  },
                })
            .toList(),
      },
    );
    return out;
  }

  Future<List<AniListLibrarySection>> librarySections(
    String token, {
    int? userId,
    bool force = false,
  }) async {
    final uid = userId ?? (await me(token)).id;
    final cacheKey = '$token:$uid';
    final persistedKey = 'librarySections:$cacheKey';
    final cached = _librarySectionsCache[cacheKey];
    if (!force && cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('librarySections:$cacheKey', () async {
        _librarySectionsCache.remove(cacheKey);
        final fresh = await librarySections(token, userId: uid);
        _librarySectionsCache[cacheKey] =
            _CacheEntry<List<AniListLibrarySection>>(
                fresh, DateTime.now().add(_libraryTrackingTtl));
      });
      return cached.value;
    }
    if (force) {
      _librarySectionsCache.remove(cacheKey);
    }
    final persisted = _readQueryCache(
      persistedKey,
      maxAge: _libraryTrackingTtl,
    );
    if (!force && persisted != null) {
      final sections = (persisted['sections'] as List? ?? const [])
          .whereType<Map>()
          .map((e) {
        final map = Map<String, dynamic>.from(e);
        final title = (map['title'] ?? 'List').toString();
        final items = (map['items'] as List? ?? const [])
            .whereType<Map>()
            .map((row) =>
                AniListLibraryEntry.fromJson(Map<String, dynamic>.from(row)))
            .toList();
        return AniListLibrarySection(title: title, items: items);
      }).toList();
      _librarySectionsCache[cacheKey] =
          _CacheEntry<List<AniListLibrarySection>>(
        sections,
        DateTime.now().add(_libraryTrackingTtl),
      );
      return sections;
    }
    const q = r'''
      query ($userId: Int) {
        MediaListCollection(
          userId: $userId,
          type: ANIME,
          status_in: [CURRENT, PLANNING, COMPLETED]
        ) {
          lists {
            name
            entries {
              id
              progress
              media {
                id
                idMal
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
                isAdult
                genres
              }
            }
          }
        }
      }
    ''';

    try {
      final data = await _graphql(
        query: q,
        token: token,
        variables: {'userId': uid},
      );
      final lists =
          (data['MediaListCollection']?['lists'] as List? ?? const []);
      final out = <AniListLibrarySection>[];

      for (final list in lists) {
        if (list is! Map<String, dynamic>) continue;
        final name = (list['name'] ?? 'List').toString();
        final entries = (list['entries'] as List? ?? const []);
        for (final entry in entries.whereType<Map<String, dynamic>>()) {
          final media = entry['media'];
          if (media is Map<String, dynamic>) {
            _cacheMediaMap(media);
          }
        }
        final items = entries
            .whereType<Map<String, dynamic>>()
            .map(AniListLibraryEntry.fromJson)
            .toList();
        if (items.isEmpty) continue;
        out.add(AniListLibrarySection(title: name, items: items));
      }

      out.sort((a, b) {
        int order(String s) {
          final l = s.toLowerCase();
          if (l.contains('current') || l.contains('watching')) return 0;
          if (l.contains('planning') || l.contains('plan')) return 1;
          if (l.contains('completed')) return 2;
          return 99;
        }

        return order(a.title).compareTo(order(b.title));
      });

      _librarySectionsCache[cacheKey] =
          _CacheEntry<List<AniListLibrarySection>>(
              out, DateTime.now().add(_libraryTrackingTtl));
      _writeQueryCache(
        persistedKey,
        {
          'sections': out
              .map((s) => {
                    'title': s.title,
                    'items': s.items
                        .map((e) => {
                              'id': e.id,
                              'progress': e.progress,
                              'media': {
                                'id': e.media.id,
                                'idMal': e.media.idMal,
                                'episodes': e.media.episodes,
                                'averageScore': e.media.averageScore,
                                'title': {
                                  'romaji': e.media.title.romaji,
                                  'english': e.media.title.english,
                                  'native': e.media.title.native,
                                },
                                'coverImage': {
                                  'large': e.media.cover.large,
                                  'extraLarge': e.media.cover.extraLarge,
                                },
                                'siteUrl': e.media.siteUrl,
                                'bannerImage': e.media.bannerImage,
                                'status': e.media.status,
                                'isAdult': e.media.isAdult,
                                'genres': e.media.genres,
                              },
                            })
                        .toList(),
                  })
              .toList(),
        },
      );
      return out;
    } catch (e, st) {
      AppLogger.w('AniList',
          'librarySections failed, falling back to current list only',
          error: e, stackTrace: st);
      final current = await libraryCurrent(token, userId: uid);
      if (current.isEmpty) return const [];
      final fallback = [
        AniListLibrarySection(title: 'Watching', items: current)
      ];
      _librarySectionsCache[cacheKey] =
          _CacheEntry<List<AniListLibrarySection>>(
              fallback, DateTime.now().add(_libraryTrackingTtl));
      return fallback;
    }
  }

  Future<List<AniListMedia>> discoveryTrending() async {
    final cached = _discoveryTrendingCache;
    if (cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('discoveryTrending', () async {
        _discoveryTrendingCache = null;
        await discoveryTrending();
      });
      return cached.value;
    }
    final persisted = _readQueryCache('discoveryTrending');
    if (persisted != null) {
      final rows = (persisted['items'] as List? ?? const [])
          .whereType<Map>()
          .map((e) => AniListMedia.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      _discoveryTrendingCache = _CacheEntry<List<AniListMedia>>(
        rows,
        DateTime.now().add(_staleTtl),
      );
      return rows;
    }

    const q = r'''
      query {
        Page(page: 1, perPage: 24) {
          media(type: ANIME, sort: TRENDING_DESC) {
            id
            idMal
            episodes
            averageScore
            title { romaji english native }
            coverImage { large extraLarge }
            siteUrl
            bannerImage
            status
            isAdult
            genres
          }
        }
      }
    ''';

    Map<String, dynamic> data;
    try {
      data = await _graphql(query: q);
    } catch (_) {
      final stale = _readQueryCache('discoveryTrending', maxAge: null);
      if (stale != null) {
        final rows = (stale['items'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => AniListMedia.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        if (rows.isNotEmpty) return rows;
      }
      rethrow;
    }
    final media = (data['Page']?['media'] as List? ?? const []);
    final out = _sanitizeMediaList(media
        .whereType<Map<String, dynamic>>()
        .map(AniListMedia.fromJson)
        .toList());
    _cacheMediaList(media.whereType<Map<String, dynamic>>());

    _discoveryTrendingCache = _CacheEntry<List<AniListMedia>>(
      out,
      DateTime.now().add(_staleTtl),
    );
    _writeQueryCache(
      'discoveryTrending',
      {
        'items': media.whereType<Map<String, dynamic>>().toList(),
      },
    );

    return out;
  }

  Future<List<AniListDiscoverySection>> discoverySections() async {
    final cached = _discoverySectionsCache;
    if (cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('discoverySections', () async {
        _discoverySectionsCache = null;
        await discoverySections();
      });
      return cached.value;
    }
    final persisted = _readQueryCache('discoverySections');
    if (persisted != null) {
      final sections = (persisted['sections'] as List? ?? const [])
          .whereType<Map>()
          .map((e) {
        final map = Map<String, dynamic>.from(e);
        final title = (map['title'] ?? 'Section').toString();
        final items = (map['items'] as List? ?? const [])
            .whereType<Map>()
            .map((row) => AniListMedia.fromJson(Map<String, dynamic>.from(row)))
            .toList();
        return AniListDiscoverySection(title: title, items: items);
      }).toList();
      _discoverySectionsCache = _CacheEntry<List<AniListDiscoverySection>>(
        sections,
        DateTime.now().add(_staleTtl),
      );
      return sections;
    }

    final now = DateTime.now();
    final currentSeason = _season(now.month);
    final currentYear = now.year;

    const q = r'''
      query ($currentSeason: MediaSeason, $currentYear: Int) {
        topRated: Page(page: 1, perPage: 20) {
          media(type: ANIME, sort: SCORE_DESC) {
            id
            idMal
            episodes
            averageScore
            title { romaji english native }
            coverImage { large extraLarge }
            siteUrl
            bannerImage
            status
            isAdult
            genres
          }
        }
        newReleases: Page(page: 1, perPage: 20) {
          media(type: ANIME, season: $currentSeason, seasonYear: $currentYear, sort: START_DATE_DESC) {
            id
            idMal
            episodes
            averageScore
            title { romaji english native }
            coverImage { large extraLarge }
            siteUrl
            bannerImage
            status
            isAdult
            genres
          }
        }
        hotNow: Page(page: 1, perPage: 20) {
          media(type: ANIME, sort: POPULARITY_DESC) {
            id
            idMal
            episodes
            averageScore
            title { romaji english native }
            coverImage { large extraLarge }
            siteUrl
            bannerImage
            status
            isAdult
            genres
          }
        }
      }
    ''';

    Map<String, dynamic> data;
    try {
      data = await _graphql(query: q, variables: {
        'currentSeason': currentSeason,
        'currentYear': currentYear,
      });
    } catch (_) {
      final stale = _readQueryCache('discoverySections', maxAge: null);
      if (stale != null) {
        final sections =
            (stale['sections'] as List? ?? const []).whereType<Map>().map((e) {
          final map = Map<String, dynamic>.from(e);
          final title = (map['title'] ?? 'Section').toString();
          final items = (map['items'] as List? ?? const [])
              .whereType<Map>()
              .map((row) =>
                  AniListMedia.fromJson(Map<String, dynamic>.from(row)))
              .toList();
          return AniListDiscoverySection(title: title, items: items);
        }).toList();
        if (sections.isNotEmpty) return sections;
      }
      rethrow;
    }

    List<AniListMedia> listFrom(String key) {
      final raw = (data[key]?['media'] as List? ?? const []);
      _cacheMediaList(raw.whereType<Map<String, dynamic>>());
      return _sanitizeMediaList(raw
          .whereType<Map<String, dynamic>>()
          .map(AniListMedia.fromJson)
          .toList());
    }

    final out = [
      AniListDiscoverySection(title: 'Top Rated', items: listFrom('topRated')),
      AniListDiscoverySection(
          title: 'New Releases', items: listFrom('newReleases')),
      AniListDiscoverySection(title: 'Hot Now', items: listFrom('hotNow')),
    ];

    _discoverySectionsCache = _CacheEntry<List<AniListDiscoverySection>>(
      out,
      DateTime.now().add(_staleTtl),
    );
    _writeQueryCache(
      'discoverySections',
      {
        'sections': [
          {
            'title': 'Top Rated',
            'items': (data['topRated']?['media'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList(),
          },
          {
            'title': 'New Releases',
            'items': (data['newReleases']?['media'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList(),
          },
          {
            'title': 'Hot Now',
            'items': (data['hotNow']?['media'] as List? ?? const [])
                .whereType<Map<String, dynamic>>()
                .toList(),
          },
        ],
      },
    );

    return out;
  }

  Future<List<AniListMedia>> searchAnime(String query) async {
    if (query.trim().isEmpty) return const [];
    const q = r'''
      query ($search: String) {
        Page(page: 1, perPage: 20) {
          media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
            id
            idMal
            episodes
            averageScore
            title { romaji english native }
            coverImage { large extraLarge }
            siteUrl
            bannerImage
            status
            isAdult
            genres
          }
        }
      }
    ''';
    final data = await _graphql(query: q, variables: {'search': query});
    final media = (data['Page']?['media'] as List? ?? const []);
    _cacheMediaList(media.whereType<Map<String, dynamic>>());
    return _sanitizeMediaList(media
        .whereType<Map<String, dynamic>>()
        .map(AniListMedia.fromJson)
        .toList());
  }

  Future<AniListMedia> mediaDetails(int mediaId) async {
    final cached = _readMediaFromCache(mediaId);
    if (cached != null && _looksDetailedMedia(cached)) return cached;
    const q = r'''
      query ($id: Int) {
        Media(id: $id, type: ANIME) {
          id
          type
          idMal
          episodes
          averageScore
          title { romaji english native }
          coverImage { large extraLarge }
          siteUrl
          bannerImage
          status
            isAdult
            genres
          description(asHtml: false)
          streamingEpisodes {
            title
            thumbnail
            url
            site
          }
          studios {
            nodes {
              name
            }
          }
          characters(page: 1, perPage: 12, sort: [ROLE, RELEVANCE]) {
            edges {
              node {
                name { full }
                image { large }
              }
              voiceActors(language: JAPANESE, sort: [RELEVANCE, ID]) {
                name { full }
                image { large }
                languageV2
              }
            }
          }
          relations {
            edges {
              relationType
              node {
                id
                type
                idMal
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
                isAdult
                genres
              }
            }
          }
        }
      }
    ''';
    try {
      final data = await _graphql(query: q, variables: {'id': mediaId});
      final media = data['Media'] as Map<String, dynamic>?;
      if (media == null) {
        if (cached != null) return cached;
        throw Exception('Anime not found.');
      }
      _cacheMediaMap(media);
      return AniListMedia.fromJson(media);
    } catch (_) {
      if (cached != null) return cached;
      rethrow;
    }
  }

  Future<List<AniListNotificationItem>> notifications(String token) async {
    final cached = _notificationsCache[token];
    if (cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('notifications:$token', () async {
        _notificationsCache.remove(token);
        await notifications(token);
      });
      return cached.value;
    }
    const qPrimary = r'''
      query NotificationsPrimary {
        Page(page: 1, perPage: 50) {
          notifications {
            __typename
            ... on AiringNotification {
              id
              type
              createdAt
              episode
              contexts
              media {
                id
                idMal
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
                isAdult
                genres
              }
            }
            ... on ActivityLikeNotification {
              id
              type
              createdAt
              user {
                name
                avatar { large }
              }
            }
            ... on ActivityReplyNotification {
              id
              type
              createdAt
              user {
                name
                avatar { large }
              }
            }
            ... on ActivityReplyLikeNotification {
              id
              type
              createdAt
              user {
                name
                avatar { large }
              }
            }
            ... on FollowingNotification {
              id
              type
              createdAt
              user {
                name
                avatar { large }
              }
            }
          }
        }
      }
    ''';

    const qFallback = r'''
      query NotificationsFallback {
        Page(page: 1, perPage: 40) {
          notifications {
            ... on AiringNotification {
              id
              type
              createdAt
              episode
              contexts
              media {
                id
                idMal
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
                isAdult
                genres
              }
            }
          }
        }
      }
    ''';

    try {
      final data = await _graphql(query: qPrimary, token: token);
      final raw = (data['Page']?['notifications'] as List? ?? const []);
      final out = raw
          .whereType<Map<String, dynamic>>()
          .map(AniListNotificationItem.fromJson)
          .where((n) => n.id != 0)
          .toList();
      AppLogger.i('AniList', 'notifications loaded count=${out.length}');
      _notificationsCache[token] = _CacheEntry<List<AniListNotificationItem>>(
          out, DateTime.now().add(_staleTtl));
      return out;
    } catch (e, st) {
      AppLogger.w(
        'AniList',
        'notifications primary query failed, trying fallback',
        error: e,
        stackTrace: st,
      );
      try {
        final data = await _graphql(query: qFallback, token: token);
        final raw = (data['Page']?['notifications'] as List? ?? const []);
        final out = raw
            .whereType<Map<String, dynamic>>()
            .map(AniListNotificationItem.fromJson)
            .where((n) => n.id != 0)
            .toList();
        AppLogger.i(
          'AniList',
          'notifications fallback loaded count=${out.length}',
        );
        _notificationsCache[token] = _CacheEntry<List<AniListNotificationItem>>(
            out, DateTime.now().add(_staleTtl));
        return out;
      } catch (e2, st2) {
        AppLogger.w(
          'AniList',
          'notifications query failed, returning empty list',
          error: e2,
          stackTrace: st2,
        );
        return const [];
      }
    }
  }

  Future<AniListTrackingEntry?> trackingEntry(String token, int mediaId,
      {bool force = false}) async {
    final key = '$token:$mediaId';
    final cached = _trackingEntryCache[key];
    AppLogger.d(
      'AniListTracking',
      'trackingEntry request mediaId=$mediaId force=$force hasMemCache=${cached != null} valid=${cached?.isValid ?? false}',
    );
    if (!force) {
      if (cached != null && cached.isValid) {
        AppLogger.d(
          'AniListTracking',
          'trackingEntry resolved from memory cache mediaId=$mediaId status=${cached.value?.status ?? 'null'} progress=${cached.value?.progress ?? -1}',
        );
        return cached.value;
      }
      if (cached != null) {
        AppLogger.d(
          'AniListTracking',
          'trackingEntry stale memory cache hit mediaId=$mediaId; scheduling background refresh',
        );
        _refreshInBackground('tracking:$key', () async {
          await trackingEntry(token, mediaId, force: true);
        });
        return cached.value;
      }
    }
    final inflight = _inflightTrackingLoads[key];
    if (inflight != null) {
      if (!force) {
        AppLogger.d(
          'AniListTracking',
          'trackingEntry joining inflight request mediaId=$mediaId',
        );
        return inflight;
      }
      AppLogger.d(
        'AniListTracking',
        'trackingEntry bypassing inflight request because force=true mediaId=$mediaId',
      );
    }
    final loadFuture = _loadTrackingEntryNetwork(
      key: key,
      token: token,
      mediaId: mediaId,
      cached: cached,
    );
    _inflightTrackingLoads[key] = loadFuture;
    try {
      return await loadFuture;
    } finally {
      if (identical(_inflightTrackingLoads[key], loadFuture)) {
        _inflightTrackingLoads.remove(key);
      }
    }
  }

  Future<AniListTrackingEntry?> _loadTrackingEntryNetwork({
    required String key,
    required String token,
    required int mediaId,
    required _CacheEntry<AniListTrackingEntry?>? cached,
  }) async {
    bool is429(Object error) => error.toString().contains('429');

    AniListTrackingEntry? fallbackFromCaches() {
      if (cached != null) {
        AppLogger.w(
          'AniListTracking',
          'trackingEntry using memory fallback mediaId=$mediaId status=${cached.value?.status ?? 'null'} progress=${cached.value?.progress ?? -1}',
        );
        return cached.value;
      }
      return null;
    }

    final viewerId = (await me(token)).id;
    const q = r'''
      query TrackingEntry($mediaId: Int, $userId: Int) {
        MediaList(mediaId: $mediaId, type: ANIME, userId: $userId) {
          id
          status
          progress
          score
        }
      }
    ''';
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        AppLogger.d(
          'AniListTracking',
          'trackingEntry network attempt=$attempt mediaId=$mediaId',
        );
        final data = await _graphql(
          query: q,
          token: token,
          variables: {
            'mediaId': mediaId,
            'userId': viewerId,
          },
        );
        final raw = data['MediaList'];
        final entry = raw is! Map<String, dynamic>
            ? null
            : AniListTrackingEntry.fromJson(raw);
        _trackingEntryCache[key] = _CacheEntry<AniListTrackingEntry?>(
          entry,
          DateTime.now().add(_trackingTtl),
        );
        AppLogger.i(
          'AniListTracking',
          'trackingEntry network success mediaId=$mediaId userId=$viewerId status=${entry?.status ?? 'null'} progress=${entry?.progress ?? -1} score=${entry?.score ?? -1}',
        );
        return entry;
      } catch (e, st) {
        AppLogger.w(
          'AniListTracking',
          'trackingEntry network failure attempt=$attempt mediaId=$mediaId',
          error: e,
          stackTrace: st,
        );
        if (is429(e)) {
          final fallback = fallbackFromCaches();
          if (fallback != null) return fallback;
          if (attempt >= 1) break;
        }
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 250 * attempt),
          );
          continue;
        }
      }
    }
    final fallback = fallbackFromCaches();
    if (fallback != null) return fallback;
    AppLogger.w(
      'AniListTracking',
      'trackingEntry resolved null mediaId=$mediaId (no cache and network failed)',
    );
    return null;
  }

  Future<AniListTrackingEntry> saveTrackingEntry({
    required String token,
    required int mediaId,
    required String status,
    required int progress,
    required double score,
    int? entryId,
  }) async {
    AppLogger.i(
      'AniListTracking',
      'saveTrackingEntry request mediaId=$mediaId entryId=${entryId ?? -1} status=$status progress=$progress score=$score',
    );
    final hasEntryId = entryId != null && entryId > 0;
    const qUpdate = r'''
      mutation UpdateMediaListEntryMutation(
        $id: Int!,
        $status: MediaListStatus!,
        $progress: Int!,
        $score: Float!
      ) {
        SaveMediaListEntry(
          id: $id,
          status: $status,
          progress: $progress,
          score: $score
        ) {
          id
          status
          progress
          score
        }
      }
    ''';
    const qCreate = r'''
      mutation SaveMediaListEntryMutation(
        $mediaId: Int!,
        $status: MediaListStatus!,
        $progress: Int!,
        $score: Float!
      ) {
        SaveMediaListEntry(
          mediaId: $mediaId,
          status: $status,
          progress: $progress,
          score: $score
        ) {
          id
          status
          progress
          score
        }
      }
    ''';
    Future<Map<String, dynamic>> runMutation({
      required bool useEntryId,
    }) {
      return _graphql(
        query: useEntryId ? qUpdate : qCreate,
        token: token,
        variables: useEntryId
            ? {
                'id': entryId,
                'status': status,
                'progress': progress,
                'score': score,
              }
            : {
                'mediaId': mediaId,
                'status': status,
                'progress': progress,
                'score': score,
              },
      );
    }

    Map<String, dynamic> data;
    try {
      data = await runMutation(useEntryId: hasEntryId);
    } catch (e, st) {
      final isUnauthorized = e.toString().contains('HTTP 401');
      if (hasEntryId && isUnauthorized) {
        AppLogger.w(
          'AniListTracking',
          'saveTrackingEntry id-based update unauthorized; retrying with mediaId mediaId=$mediaId entryId=$entryId',
          error: e,
          stackTrace: st,
        );
        data = await runMutation(useEntryId: false);
      } else {
        rethrow;
      }
    }
    final saved = AniListTrackingEntry.fromJson(
      (data['SaveMediaListEntry'] as Map<String, dynamic>? ?? const {}),
    );
    _trackingEntryCache['$token:$mediaId'] = _CacheEntry<AniListTrackingEntry?>(
        saved, DateTime.now().add(_trackingTtl));
    _patchTrackingCaches(
      token: token,
      mediaId: mediaId,
      status: saved.status,
      progress: saved.progress,
    );
    AppLogger.i(
      'AniListTracking',
      'saveTrackingEntry success mediaId=$mediaId status=${saved.status} progress=${saved.progress} score=${saved.score}',
    );
    return saved;
  }

  Future<bool> deleteTrackingEntry({
    required String token,
    required int mediaId,
  }) async {
    AppLogger.i('AniListTracking', 'deleteTrackingEntry request mediaId=$mediaId');
    final existing = await trackingEntry(token, mediaId);
    if (existing == null || existing.id <= 0) return true;
    const q = r'''
      mutation ($id: Int!) {
        DeleteMediaListEntry(id: $id) {
          deleted
        }
      }
    ''';
    final data = await _graphql(
      query: q,
      token: token,
      variables: {'id': existing.id},
    );
    final deleted = data['DeleteMediaListEntry']?['deleted'] == true;
    if (deleted) {
      _trackingEntryCache['$token:$mediaId'] =
          _CacheEntry<AniListTrackingEntry?>(
              null, DateTime.now().add(_trackingTtl));
      _pruneFromLibraryCaches(token, mediaId);
    }
    AppLogger.i(
      'AniListTracking',
      'deleteTrackingEntry result mediaId=$mediaId deleted=$deleted',
    );
    return deleted;
  }

  void clearRuntimeCaches() {
    _viewerCache.clear();
    _unreadCache.clear();
    _libraryCurrentCache.clear();
    _librarySectionsCache.clear();
    _episodeAvailabilityCache.clear();
    _notificationsCache.clear();
    _trackingEntryCache.clear();
    _discoveryTrendingCache = null;
    _discoverySectionsCache = null;
    _mediaDetailsMemoryCache.clear();
  }

  Future<AniListEpisodeAvailability?> episodeAvailability(
    String token,
    int mediaId,
  ) async {
    final key = '$token:$mediaId';
    final cached = _episodeAvailabilityCache[key];
    if (cached != null && cached.isValid) {
      return cached.value;
    }

    const q = r'''
      query ($mediaId: Int!) {
        Media(id: $mediaId, type: ANIME) {
          id
          status
          episodes
          nextAiringEpisode { episode }
        }
      }
    ''';

    final data = await _graphql(
      query: q,
      token: token,
      variables: {'mediaId': mediaId},
    );
    final media = data['Media'];
    if (media is! Map<String, dynamic>) return null;
    final result = AniListEpisodeAvailability(
      mediaId: (media['id'] as num?)?.toInt() ?? mediaId,
      status: (media['status'] ?? '').toString(),
      episodes: (media['episodes'] as num?)?.toInt(),
      nextAiringEpisode: (media['nextAiringEpisode']
          as Map<String, dynamic>?)?['episode'] as int?,
    );
    _episodeAvailabilityCache[key] = _CacheEntry<AniListEpisodeAvailability>(
      result,
      DateTime.now().add(_staleTtl),
    );
    return result;
  }

  String _season(int month) {
    if (month <= 2 || month == 12) return 'WINTER';
    if (month <= 5) return 'SPRING';
    if (month <= 8) return 'SUMMER';
    return 'FALL';
  }

  List<AniListLibrarySection> cachedLibrarySections(String token) {
    final fromMemory = _librarySectionsCache.entries
        .where((e) => e.key.startsWith('$token:'))
        .map((e) => e.value.value)
        .where((sections) => sections.isNotEmpty)
        .toList();
    if (fromMemory.isNotEmpty) {
      return fromMemory.first;
    }

    final box = _queryBox();
    if (box == null) return const [];
    final prefix = 'librarySections:$token:';
    Map<String, dynamic>? newest;
    var newestAtMs = -1;
    for (final key in box.keys) {
      final keyStr = key.toString();
      if (!keyStr.startsWith(prefix)) continue;
      final raw = box.get(keyStr);
      if (raw is! Map) continue;
      final cachedAtMs = (raw['cachedAtMs'] as num?)?.toInt() ?? 0;
      if (cachedAtMs <= newestAtMs) continue;
      final data = raw['data'];
      if (data is! Map) continue;
      newest = Map<String, dynamic>.from(data);
      newestAtMs = cachedAtMs;
    }
    if (newest == null) return const [];
    final sections = _parseLibrarySections(newest);
    if (sections.isNotEmpty) {
      _librarySectionsCache['$token:cached_snapshot'] =
          _CacheEntry<List<AniListLibrarySection>>(
        sections,
        DateTime.now().add(const Duration(minutes: 5)),
      );
    }
    return sections;
  }

  ({List<AniListMedia> trending, List<AniListDiscoverySection> sections})?
      cachedDiscoverySnapshot() {
    List<AniListMedia> trending = const [];
    List<AniListDiscoverySection> sections = const [];

    if (_discoveryTrendingCache?.value.isNotEmpty ?? false) {
      trending = _discoveryTrendingCache!.value;
    } else {
      final persistedTrending = _readQueryCache('discoveryTrending', maxAge: null);
      if (persistedTrending != null) {
        final rows = (persistedTrending['items'] as List? ?? const [])
            .whereType<Map>()
            .map((e) => AniListMedia.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        trending = _sanitizeMediaList(rows);
      }
    }

    if (_discoverySectionsCache?.value.isNotEmpty ?? false) {
      sections = _discoverySectionsCache!.value;
    } else {
      final persistedSections = _readQueryCache('discoverySections', maxAge: null);
      if (persistedSections != null) {
        sections = _parseDiscoverySections(persistedSections);
      }
    }

    if (trending.isEmpty && sections.isEmpty) return null;
    return (trending: trending, sections: sections);
  }

  List<AniListLibrarySection> _parseLibrarySections(Map<String, dynamic> data) {
    return (data['sections'] as List? ?? const [])
        .whereType<Map>()
        .map((e) {
      final map = Map<String, dynamic>.from(e);
      final title = (map['title'] ?? 'Section').toString();
      final items = (map['items'] as List? ?? const [])
          .whereType<Map>()
          .map((row) =>
              AniListLibraryEntry.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      return AniListLibrarySection(title: title, items: items);
    }).toList();
  }

  List<AniListDiscoverySection> _parseDiscoverySections(
      Map<String, dynamic> data) {
    return (data['sections'] as List? ?? const [])
        .whereType<Map>()
        .map((e) {
      final map = Map<String, dynamic>.from(e);
      final title = (map['title'] ?? 'Section').toString();
      final items = (map['items'] as List? ?? const [])
          .whereType<Map>()
          .map((row) => AniListMedia.fromJson(Map<String, dynamic>.from(row)))
          .toList();
      return AniListDiscoverySection(title: title, items: items);
    }).toList();
  }
}
