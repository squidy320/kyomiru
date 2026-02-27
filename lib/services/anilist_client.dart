import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../core/app_logger.dart';
import '../models/anilist_models.dart';

class _CacheEntry<T> {
  const _CacheEntry(this.value, this.expiresAt);

  final T value;
  final DateTime expiresAt;

  bool get isValid => DateTime.now().isBefore(expiresAt);
}

class AniListClient {
  AniListClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const authEndpoint = 'https://anilist.co/api/v2/oauth/authorize';
  static const graphqlEndpoint = 'https://graphql.anilist.co';
  static const tokenEndpoint = 'https://anilist.co/api/v2/oauth/token';

  final List<Future<void> Function()> _serialQueue = [];
  bool _serialRunning = false;
  DateTime _nextAllowedAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const Duration _staleTtl = Duration(minutes: 30);
  final Set<String> _refreshing = <String>{};

  final Map<String, _CacheEntry<AniListUser>> _viewerCache = {};
  final Map<String, _CacheEntry<int>> _unreadCache = {};
  final Map<String, _CacheEntry<List<AniListLibraryEntry>>> _libraryCurrentCache = {};
  final Map<String, _CacheEntry<List<AniListLibrarySection>>> _librarySectionsCache = {};
  final Map<String, _CacheEntry<List<AniListNotificationItem>>> _notificationsCache = {};

  _CacheEntry<List<AniListMedia>>? _discoveryTrendingCache;
  _CacheEntry<List<AniListDiscoverySection>>? _discoverySectionsCache;

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

  Future<void> _respectGate() async {
    final now = DateTime.now();
    if (now.isBefore(_nextAllowedAt)) {
      await Future<void>.delayed(_nextAllowedAt.difference(now));
    }
    _nextAllowedAt = DateTime.now().add(const Duration(milliseconds: 250));
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
      var attempts = 0;
      while (true) {
        attempts++;
        await _respectGate();
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
              validateStatus: (_) => true,
            ),
          );

          final status = response.statusCode ?? 0;
          final body = response.data is Map<String, dynamic>
              ? response.data as Map<String, dynamic>
              : jsonDecode(response.data.toString()) as Map<String, dynamic>;

          if (status == 429 && attempts < 4) {
            final delayMs = 1200 * attempts;
            _nextAllowedAt =
                DateTime.now().add(Duration(milliseconds: delayMs));
            AppLogger.w('AniList',
                'GraphQL 429 op=$operation; backing off ${delayMs}ms');
            continue;
          }

          if (status >= 400) {
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
    const q = r'''
      mutation {
        NotificationReset
      }
    ''';
    try {
      await _graphql(query: q, token: token);
      clearUnreadCache(token);
      _notificationsCache.remove(token);
      AppLogger.i('AniList', 'Marked notifications as read');
    } catch (e, st) {
      // Non-fatal; some API variants may not expose this mutation.
      AppLogger.w('AniList', 'NotificationReset failed',
          error: e, stackTrace: st);
    }
  }

  Future<List<AniListLibraryEntry>> libraryCurrent(
    String token, {
    int? userId,
  }) async {
    final uid = userId ?? (await me(token)).id;
    final cacheKey = '$token:$uid';
    final cached = _libraryCurrentCache[cacheKey];
    if (cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('libraryCurrent:' + cacheKey, () async {
        _libraryCurrentCache.remove(cacheKey);
        final fresh = await libraryCurrent(token, userId: uid);
        _libraryCurrentCache[cacheKey] = _CacheEntry<List<AniListLibraryEntry>>(fresh, DateTime.now().add(_staleTtl));
      });
      return cached.value;
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
          out.add(AniListLibraryEntry.fromJson(entry));
        }
      }
    }
    _libraryCurrentCache[cacheKey] = _CacheEntry<List<AniListLibraryEntry>>(out, DateTime.now().add(_staleTtl));
    return out;
  }

  Future<List<AniListLibrarySection>> librarySections(
    String token, {
    int? userId,
  }) async {
    final uid = userId ?? (await me(token)).id;
    final cacheKey = '$token:$uid';
    final cached = _librarySectionsCache[cacheKey];
    if (cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('librarySections:' + cacheKey, () async {
        _librarySectionsCache.remove(cacheKey);
        final fresh = await librarySections(token, userId: uid);
        _librarySectionsCache[cacheKey] = _CacheEntry<List<AniListLibrarySection>>(fresh, DateTime.now().add(_staleTtl));
      });
      return cached.value;
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

      _librarySectionsCache[cacheKey] = _CacheEntry<List<AniListLibrarySection>>(out, DateTime.now().add(_staleTtl));
      return out;
    } catch (e, st) {
      AppLogger.w('AniList',
          'librarySections failed, falling back to current list only',
          error: e, stackTrace: st);
      final current = await libraryCurrent(token, userId: uid);
      if (current.isEmpty) return const [];
      final fallback = [AniListLibrarySection(title: 'Watching', items: current)];
      _librarySectionsCache[cacheKey] = _CacheEntry<List<AniListLibrarySection>>(fallback, DateTime.now().add(_staleTtl));
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

    const q = r'''
      query {
        Page(page: 1, perPage: 24) {
          media(type: ANIME, sort: TRENDING_DESC) {
            id
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

    final data = await _graphql(query: q);
    final media = (data['Page']?['media'] as List? ?? const []);
    final out = _sanitizeMediaList(media
        .whereType<Map<String, dynamic>>()
        .map(AniListMedia.fromJson)
        .toList());

    _discoveryTrendingCache = _CacheEntry<List<AniListMedia>>(
      out,
      DateTime.now().add(_staleTtl),
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

    final now = DateTime.now();
    final currentSeason = _season(now.month);
    final currentYear = now.year;

    const q = r'''
      query ($currentSeason: MediaSeason, $currentYear: Int) {
        topRated: Page(page: 1, perPage: 20) {
          media(type: ANIME, sort: SCORE_DESC) {
            id
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

    final data = await _graphql(query: q, variables: {
      'currentSeason': currentSeason,
      'currentYear': currentYear,
    });

    List<AniListMedia> listFrom(String key) {
      final raw = (data[key]?['media'] as List? ?? const []);
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

    return out;
  }

  Future<List<AniListMedia>> searchAnime(String query) async {
    if (query.trim().isEmpty) return const [];
    const q = r'''
      query ($search: String) {
        Page(page: 1, perPage: 20) {
          media(type: ANIME, search: $search, sort: SEARCH_MATCH) {
            id
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
    return _sanitizeMediaList(media
        .whereType<Map<String, dynamic>>()
        .map(AniListMedia.fromJson)
        .toList());
  }

  Future<AniListMedia> mediaDetails(int mediaId) async {
    const q = r'''
      query ($id: Int) {
        Media(id: $id, type: ANIME) {
          id
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
          relations {
            edges {
              relationType
              node {
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
    final data = await _graphql(query: q, variables: {'id': mediaId});
    final media = data['Media'] as Map<String, dynamic>?;
    if (media == null) throw Exception('Anime not found.');
    return AniListMedia.fromJson(media);
  }

  Future<List<AniListNotificationItem>> notifications(String token) async {
    final cached = _notificationsCache[token];
    if (cached != null) {
      if (cached.isValid) return cached.value;
      _refreshInBackground('notifications:' + token, () async {
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
      _notificationsCache[token] = _CacheEntry<List<AniListNotificationItem>>(out, DateTime.now().add(_staleTtl));
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
        _notificationsCache[token] = _CacheEntry<List<AniListNotificationItem>>(out, DateTime.now().add(_staleTtl));
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

  Future<AniListTrackingEntry?> trackingEntry(
    String token,
    int mediaId,
  ) async {
    const q = r'''
      query ($mediaId: Int) {
        MediaList(mediaId: $mediaId, type: ANIME) {
          id
          status
          progress
          score(format: POINT_10_DECIMAL)
        }
      }
    ''';
    final data = await _graphql(
      query: q,
      token: token,
      variables: {'mediaId': mediaId},
    );
    final raw = data['MediaList'];
    if (raw is! Map<String, dynamic>) return null;
    return AniListTrackingEntry.fromJson(raw);
  }

  Future<AniListTrackingEntry> saveTrackingEntry({
    required String token,
    required int mediaId,
    required String status,
    required int progress,
    required double score,
  }) async {
    const q = r'''
      mutation (
        $mediaId: Int,
        $status: MediaListStatus,
        $progress: Int,
        $score: Float
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
          score(format: POINT_10_DECIMAL)
        }
      }
    ''';
    final data = await _graphql(
      query: q,
      token: token,
      variables: {
        'mediaId': mediaId,
        'status': status,
        'progress': progress,
        'score': score,
      },
    );
    return AniListTrackingEntry.fromJson(
      (data['SaveMediaListEntry'] as Map<String, dynamic>? ?? const {}),
    );
  }

  String _season(int month) {
    if (month <= 2 || month == 12) return 'WINTER';
    if (month <= 5) return 'SPRING';
    if (month <= 8) return 'SUMMER';
    return 'FALL';
  }
}
























