import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

class KyomiruImageCache {
  KyomiruImageCache._();

  static final CacheManager manager = CacheManager(
    Config(
      'kyomiruImageCache',
      stalePeriod: const Duration(days: 7),
      // Approximate a large on-disk cache budget (~1GB target) via object count.
      maxNrOfCacheObjects: 12000,
    ),
  );

  static ImageProvider provider(String url) =>
      CachedNetworkImageProvider(url, cacheManager: manager);

  static Widget image(
    String url, {
    BoxFit fit = BoxFit.cover,
    Widget? placeholder,
    Widget? error,
  }) {
    return CachedNetworkImage(
      imageUrl: url,
      fit: fit,
      cacheManager: manager,
      placeholder: (_, __) => placeholder ?? const SizedBox.shrink(),
      errorWidget: (_, __, ___) => error ?? const SizedBox.shrink(),
    );
  }
}
