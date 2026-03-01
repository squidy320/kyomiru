import 'package:flutter_riverpod/flutter_riverpod.dart';

class SessionSourceLock {
  const SessionSourceLock({
    required this.providerId,
    required this.quality,
    required this.audio,
    required this.format,
  });

  final String providerId;
  final String quality;
  final String audio;
  final String format;
}

String sourceProviderIdFromUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  final host = (uri?.host ?? '').toLowerCase();
  if (host.isEmpty) return 'unknown';
  final parts = host.split('.');
  if (parts.length >= 2) {
    return parts[parts.length - 2];
  }
  return host;
}

class SessionSourceLockNotifier extends StateNotifier<SessionSourceLock?> {
  SessionSourceLockNotifier() : super(null);

  void lockFromSelection({
    required String sourceUrl,
    required String quality,
    required String audio,
    required String format,
  }) {
    state = SessionSourceLock(
      providerId: sourceProviderIdFromUrl(sourceUrl),
      quality: quality.toLowerCase(),
      audio: audio.toLowerCase(),
      format: format.toLowerCase(),
    );
  }

  void clear() => state = null;
}

final sessionSourceLockProvider =
    StateNotifierProvider<SessionSourceLockNotifier, SessionSourceLock?>(
  (ref) => SessionSourceLockNotifier(),
);
