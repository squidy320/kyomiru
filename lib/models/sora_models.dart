class SoraAnimeMatch {
  const SoraAnimeMatch({
    required this.title,
    required this.image,
    required this.href,
    required this.session,
  });

  final String title;
  final String image;
  final String href;
  final String session;
}

class SoraEpisode {
  const SoraEpisode({
    required this.number,
    required this.session,
    required this.playUrl,
  });

  final int number;
  final String session;
  final String playUrl;
}

class SoraSource {
  const SoraSource({
    required this.url,
    required this.quality,
    required this.subOrDub,
    required this.format,
    required this.headers,
  });

  final String url;
  final String quality;
  final String subOrDub;
  final String format;
  final Map<String, String> headers;
}
