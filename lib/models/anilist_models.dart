class AniListUser {
  final int id;
  final String name;
  final String? avatar;
  final String? bannerImage;

  AniListUser({
    required this.id,
    required this.name,
    this.avatar,
    this.bannerImage,
  });

  factory AniListUser.fromJson(Map<String, dynamic> json) => AniListUser(
        id: (json['id'] as num?)?.toInt() ?? 0,
        name: (json['name'] ?? 'User').toString(),
        avatar:
            ((json['avatar'] as Map<String, dynamic>?)?['large'])?.toString(),
        bannerImage: json['bannerImage']?.toString(),
      );
}

class AniListTitle {
  final String? romaji;
  final String? english;
  final String? native;

  AniListTitle({this.romaji, this.english, this.native});

  factory AniListTitle.fromJson(Map<String, dynamic> json) => AniListTitle(
        romaji: json['romaji']?.toString(),
        english: json['english']?.toString(),
        native: json['native']?.toString(),
      );

  String get best => english ?? romaji ?? native ?? 'Unknown';
}

class AniListCover {
  final String? large;
  final String? extraLarge;

  AniListCover({this.large, this.extraLarge});

  factory AniListCover.fromJson(Map<String, dynamic> json) => AniListCover(
        large: json['large']?.toString(),
        extraLarge: json['extraLarge']?.toString(),
      );

  String? get best => extraLarge ?? large;
}

class AniListStreamingEpisode {
  AniListStreamingEpisode({
    required this.title,
    required this.thumbnail,
    required this.url,
    required this.site,
  });

  final String title;
  final String? thumbnail;
  final String? url;
  final String? site;

  int? get guessedEpisodeNumber {
    final match = RegExp(r'(?:ep(?:isode)?\s*)(\d+)', caseSensitive: false)
        .firstMatch(title);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  factory AniListStreamingEpisode.fromJson(Map<String, dynamic> json) =>
      AniListStreamingEpisode(
        title: (json['title'] ?? '').toString(),
        thumbnail: json['thumbnail']?.toString(),
        url: json['url']?.toString(),
        site: json['site']?.toString(),
      );
}

class AniListMedia {
  final int id;
  final AniListTitle title;
  final AniListCover cover;
  final int? averageScore;
  final int? episodes;
  final String? description;
  final String? bannerImage;
  final String? siteUrl;
  final String? status;
  final bool isAdult;
  final List<String> genres;
  final List<AniListStreamingEpisode> streamingEpisodes;

  AniListMedia({
    required this.id,
    required this.title,
    required this.cover,
    this.averageScore,
    this.episodes,
    this.description,
    this.bannerImage,
    this.siteUrl,
    this.status,
    this.isAdult = false,
    this.genres = const [],
    this.streamingEpisodes = const [],
  });

  factory AniListMedia.fromJson(Map<String, dynamic> json) => AniListMedia(
        id: (json['id'] as num?)?.toInt() ?? 0,
        title: AniListTitle.fromJson(
            (json['title'] as Map<String, dynamic>? ?? const {})),
        cover: AniListCover.fromJson(
            (json['coverImage'] as Map<String, dynamic>? ?? const {})),
        averageScore: (json['averageScore'] as num?)?.toInt(),
        episodes: (json['episodes'] as num?)?.toInt(),
        description: json['description']?.toString(),
        bannerImage: json['bannerImage']?.toString(),
        siteUrl: json['siteUrl']?.toString(),
        status: json['status']?.toString(),
        isAdult: json['isAdult'] == true,
        genres: ((json['genres'] as List?) ?? const [])
            .map((e) => e.toString())
            .where((e) => e.isNotEmpty)
            .toList(),
        streamingEpisodes: ((json['streamingEpisodes'] as List?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(AniListStreamingEpisode.fromJson)
            .toList(),
      );
}

class AniListLibraryEntry {
  final int id;
  final int progress;
  final AniListMedia media;

  AniListLibraryEntry({
    required this.id,
    required this.progress,
    required this.media,
  });

  factory AniListLibraryEntry.fromJson(Map<String, dynamic> json) =>
      AniListLibraryEntry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        progress: (json['progress'] as num?)?.toInt() ?? 0,
        media: AniListMedia.fromJson(
            (json['media'] as Map<String, dynamic>? ?? const {})),
      );
}

class AniListLibrarySection {
  const AniListLibrarySection({required this.title, required this.items});

  final String title;
  final List<AniListLibraryEntry> items;
}

class AniListNotificationItem {
  final int id;
  final String type;
  final int createdAt;
  final String? context;
  final AniListMedia? media;

  AniListNotificationItem({
    required this.id,
    required this.type,
    required this.createdAt,
    this.context,
    this.media,
  });

  factory AniListNotificationItem.fromJson(Map<String, dynamic> json) =>
      AniListNotificationItem(
        id: (json['id'] as num?)?.toInt() ?? 0,
        type: (json['type'] ?? '').toString(),
        createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
        context: json['context']?.toString(),
        media: json['media'] is Map<String, dynamic>
            ? AniListMedia.fromJson(json['media'] as Map<String, dynamic>)
            : null,
      );
}

class AniListDiscoverySection {
  const AniListDiscoverySection({required this.title, required this.items});

  final String title;
  final List<AniListMedia> items;
}

class AniListTrackingEntry {
  final int id;
  final String status;
  final int progress;
  final double score;

  const AniListTrackingEntry({
    required this.id,
    required this.status,
    required this.progress,
    required this.score,
  });

  factory AniListTrackingEntry.fromJson(Map<String, dynamic> json) =>
      AniListTrackingEntry(
        id: (json['id'] as num?)?.toInt() ?? 0,
        status: (json['status'] ?? 'CURRENT').toString(),
        progress: (json['progress'] as num?)?.toInt() ?? 0,
        score: (json['score'] as num?)?.toDouble() ?? 0,
      );
}

class SoraExtensionManifest {
  final String id;
  final String? name;
  final bool hasGetSources;

  SoraExtensionManifest(
      {required this.id, this.name, required this.hasGetSources});

  factory SoraExtensionManifest.fromJson(Map<String, dynamic> json) {
    final hasSources = json['getSources'] != null ||
        json['get_sources'] != null ||
        json['sources'] != null;
    return SoraExtensionManifest(
      id: (json['id'] ?? '').toString(),
      name: json['name']?.toString() ?? json['sourceName']?.toString(),
      hasGetSources: hasSources,
    );
  }
}
