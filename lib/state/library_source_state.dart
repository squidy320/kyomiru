import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LibrarySource {
  anilist,
  local,
}

class LibrarySourceController extends StateNotifier<LibrarySource> {
  LibrarySourceController() : super(LibrarySource.anilist) {
    _load();
  }

  static const _prefKey = 'library_source';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == LibrarySource.local.name) {
      state = LibrarySource.local;
      return;
    }
    state = LibrarySource.anilist;
  }

  Future<void> setSource(LibrarySource source) async {
    state = source;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, source.name);
  }
}

final librarySourceProvider =
    StateNotifierProvider<LibrarySourceController, LibrarySource>(
  (ref) => LibrarySourceController(),
);

