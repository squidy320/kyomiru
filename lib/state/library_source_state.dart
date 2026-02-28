import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app_settings_state.dart';

enum LibrarySource {
  anilist,
  local,
}

final librarySourceProvider = Provider<LibrarySource>((ref) {
  final raw = ref.watch(appSettingsProvider).librarySource.toLowerCase();
  return raw == 'local' ? LibrarySource.local : LibrarySource.anilist;
});

