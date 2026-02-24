import 'dart:convert';

import 'package:dio/dio.dart';

import '../models/anilist_models.dart';

class AniListClient {
  AniListClient({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const authEndpoint = 'https://anilist.co/api/v2/oauth/authorize';
  static const graphqlEndpoint = 'https://graphql.anilist.co';
  static const tokenEndpoint = 'https://anilist.co/api/v2/oauth/token';

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
    return uri.toString();
  }

  Future<String> exchangeCodeForToken({
    required String clientId,
    required String clientSecret,
    required String code,
    required String redirectUri,
  }) async {
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
      ),
    );

    final data = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : jsonDecode(response.data.toString()) as Map<String, dynamic>;

    final token = (data['access_token'] ?? '').toString();
    if (token.isEmpty) {
      throw Exception('AniList token exchange returned no access token.');
    }
    return token;
  }

  Future<Map<String, dynamic>> _graphql({
    required String query,
    Map<String, dynamic>? variables,
    String? token,
  }) async {
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
      ),
    );

    final body = response.data is Map<String, dynamic>
        ? response.data as Map<String, dynamic>
        : jsonDecode(response.data.toString()) as Map<String, dynamic>;

    if (body['errors'] is List && (body['errors'] as List).isNotEmpty) {
      final first = (body['errors'] as List).first;
      throw Exception(
        'AniList GraphQL error: ${first is Map ? (first['message'] ?? first) : first}',
      );
    }

    return (body['data'] as Map<String, dynamic>? ?? <String, dynamic>{});
  }

  Future<AniListUser> me(String token) async {
    const q = r'''
      query {
        Viewer {
          id
          name
          avatar { large }
        }
      }
    ''';
    final data = await _graphql(query: q, token: token);
    return AniListUser.fromJson(
        (data['Viewer'] as Map<String, dynamic>? ?? const {}));
  }

  Future<int> unreadNotificationCount(String token) async {
    const q = r'''
      query {
        Viewer { unreadNotificationCount }
      }
    ''';
    final data = await _graphql(query: q, token: token);
    return (data['Viewer']?['unreadNotificationCount'] as num?)?.toInt() ?? 0;
  }

  Future<List<AniListLibraryEntry>> libraryCurrent(String token) async {
    const q = r'''
      query {
        MediaListCollection(type: ANIME, status_in: [CURRENT, REPEATING]) {
          lists {
            entries {
              id
              progress
              media {
                id
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
              }
            }
          }
        }
      }
    ''';

    final data = await _graphql(query: q, token: token);
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
    return out;
  }

  Future<List<AniListLibrarySection>> librarySections(String token) async {
    const q = r'''
      query {
        MediaListCollection(type: ANIME, status_in: [CURRENT, PLANNING, COMPLETED]) {
          lists {
            name
            entries {
              id
              progress
              media {
                id
                episodes
                averageScore
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                bannerImage
                status
              }
            }
          }
        }
      }
    ''';

    final data = await _graphql(query: q, token: token);
    final lists = (data['MediaListCollection']?['lists'] as List? ?? const []);
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

    return out;
  }

  Future<List<AniListMedia>> discoveryTrending() async {
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
          }
        }
      }
    ''';

    final data = await _graphql(query: q);
    final media = (data['Page']?['media'] as List? ?? const []);
    return media
        .whereType<Map<String, dynamic>>()
        .map(AniListMedia.fromJson)
        .toList();
  }

  Future<List<AniListDiscoverySection>> discoverySections() async {
    final now = DateTime.now();
    final currentSeason = _season(now.month);
    final currentYear = now.year;

    const q = r'''
      query ($currentSeason: MediaSeason, $currentYear: Int) {
        trending: Page(page: 1, perPage: 20) {
          media(type: ANIME, sort: TRENDING_DESC) {
            id
            episodes
            averageScore
            title { romaji english native }
            coverImage { large extraLarge }
            siteUrl
            bannerImage
            status
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
      return raw
          .whereType<Map<String, dynamic>>()
          .map(AniListMedia.fromJson)
          .toList();
    }

    return [
      AniListDiscoverySection(title: 'Trending', items: listFrom('trending')),
      AniListDiscoverySection(
          title: 'New Releases', items: listFrom('newReleases')),
      AniListDiscoverySection(title: 'Hot Now', items: listFrom('hotNow')),
    ];
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
          }
        }
      }
    ''';
    final data = await _graphql(query: q, variables: {'search': query});
    final media = (data['Page']?['media'] as List? ?? const []);
    return media
        .whereType<Map<String, dynamic>>()
        .map(AniListMedia.fromJson)
        .toList();
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
          description(asHtml: false)
          streamingEpisodes {
            title
            thumbnail
            url
            site
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
    const q = r'''
      query {
        Page(page: 1, perPage: 30) {
          notifications(resetNotificationCount: true) {
            ... on AiringNotification {
              id
              type
              createdAt
              context
              media {
                id
                title { romaji english native }
                coverImage { large extraLarge }
                siteUrl
                status
              }
            }
          }
        }
      }
    ''';

    final data = await _graphql(query: q, token: token);
    final raw = (data['Page']?['notifications'] as List? ?? const []);
    return raw
        .whereType<Map<String, dynamic>>()
        .map(AniListNotificationItem.fromJson)
        .toList();
  }

  String _season(int month) {
    if (month <= 2 || month == 12) return 'WINTER';
    if (month <= 5) return 'SPRING';
    if (month <= 8) return 'SUMMER';
    return 'FALL';
  }
}
