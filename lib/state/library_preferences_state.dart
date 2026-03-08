import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum LibrarySortMode {
  az('A-Z'),
  za('Z-A'),
  recentlyUpdated('Recently Updated'),
  dateAdded('Date Added'),
  highestScore('Highest Score');

  const LibrarySortMode(this.label);
  final String label;

  static LibrarySortMode fromKey(String raw) {
    return LibrarySortMode.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => LibrarySortMode.recentlyUpdated,
    );
  }
}

enum LibraryLayoutMode {
  grid,
  list;

  static LibraryLayoutMode fromKey(String raw) {
    return LibraryLayoutMode.values.firstWhere(
      (e) => e.name == raw,
      orElse: () => LibraryLayoutMode.grid,
    );
  }
}

class CustomCatalog {
  const CustomCatalog({
    required this.id,
    required this.title,
    this.mediaIds = const <int>{},
  });

  final String id;
  final String title;
  final Set<int> mediaIds;

  CustomCatalog copyWith({
    String? id,
    String? title,
    Set<int>? mediaIds,
  }) {
    return CustomCatalog(
      id: id ?? this.id,
      title: title ?? this.title,
      mediaIds: mediaIds ?? this.mediaIds,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'mediaIds': mediaIds.toList(),
      };

  factory CustomCatalog.fromJson(Map<String, dynamic> json) {
    return CustomCatalog(
      id: (json['id'] ?? '').toString(),
      title: (json['title'] ?? '').toString(),
      mediaIds: ((json['mediaIds'] as List?) ?? const <dynamic>[])
          .map((e) => int.tryParse(e.toString()) ?? 0)
          .where((e) => e > 0)
          .toSet(),
    );
  }
}

class LibraryPreferences {
  const LibraryPreferences({
    this.hiddenCatalogIds = const <String>{},
    this.catalogOrder = const <String>[
      'current',
      'planning',
      'completed',
      'paused',
      'dropped',
    ],
    this.customCatalogs = const <CustomCatalog>[],
    this.defaultSort = LibrarySortMode.recentlyUpdated,
    this.layoutMode = LibraryLayoutMode.grid,
    this.catalogSortOverrides = const <String, LibrarySortMode>{},
  });

  final Set<String> hiddenCatalogIds;
  final List<String> catalogOrder;
  final List<CustomCatalog> customCatalogs;
  final LibrarySortMode defaultSort;
  final LibraryLayoutMode layoutMode;
  final Map<String, LibrarySortMode> catalogSortOverrides;

  LibraryPreferences copyWith({
    Set<String>? hiddenCatalogIds,
    List<String>? catalogOrder,
    List<CustomCatalog>? customCatalogs,
    LibrarySortMode? defaultSort,
    LibraryLayoutMode? layoutMode,
    Map<String, LibrarySortMode>? catalogSortOverrides,
  }) {
    return LibraryPreferences(
      hiddenCatalogIds: hiddenCatalogIds ?? this.hiddenCatalogIds,
      catalogOrder: catalogOrder ?? this.catalogOrder,
      customCatalogs: customCatalogs ?? this.customCatalogs,
      defaultSort: defaultSort ?? this.defaultSort,
      layoutMode: layoutMode ?? this.layoutMode,
      catalogSortOverrides: catalogSortOverrides ?? this.catalogSortOverrides,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'hiddenCatalogIds': hiddenCatalogIds.toList(),
        'catalogOrder': catalogOrder,
        'customCatalogs': customCatalogs.map((e) => e.toJson()).toList(),
        'defaultSort': defaultSort.name,
        'layoutMode': layoutMode.name,
        'catalogSortOverrides':
            catalogSortOverrides.map((k, v) => MapEntry(k, v.name)),
      };

  factory LibraryPreferences.fromJson(Map<String, dynamic> json) {
    final overridesRaw =
        (json['catalogSortOverrides'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{};
    return LibraryPreferences(
      hiddenCatalogIds: ((json['hiddenCatalogIds'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toSet(),
      catalogOrder: ((json['catalogOrder'] as List?) ?? const [])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty)
          .toList(),
      customCatalogs: ((json['customCatalogs'] as List?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(CustomCatalog.fromJson)
          .toList(),
      defaultSort: LibrarySortMode.fromKey(
        (json['defaultSort'] ?? LibrarySortMode.recentlyUpdated.name)
            .toString(),
      ),
      layoutMode: LibraryLayoutMode.fromKey(
        (json['layoutMode'] ?? LibraryLayoutMode.grid.name).toString(),
      ),
      catalogSortOverrides: overridesRaw.map(
        (k, v) => MapEntry(k, LibrarySortMode.fromKey(v.toString())),
      ),
    );
  }
}

class LibraryPreferencesNotifier extends StateNotifier<LibraryPreferences> {
  LibraryPreferencesNotifier() : super(const LibraryPreferences()) {
    _load();
  }

  static const _kPrefsKey = 'settings.libraryPreferences.v1';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kPrefsKey);
    if (raw == null || raw.isEmpty) return;
    try {
      final parsed = jsonDecode(raw);
      if (parsed is Map<String, dynamic>) {
        state = LibraryPreferences.fromJson(parsed);
      }
    } catch (_) {}
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kPrefsKey, jsonEncode(state.toJson()));
  }

  bool isVisible(String catalogId) => !state.hiddenCatalogIds.contains(catalogId);

  LibrarySortMode sortForCatalog(String catalogId) =>
      state.catalogSortOverrides[catalogId] ?? state.defaultSort;

  Future<void> setCatalogVisible(String catalogId, bool visible) async {
    final hidden = Set<String>.from(state.hiddenCatalogIds);
    if (visible) {
      hidden.remove(catalogId);
    } else {
      hidden.add(catalogId);
    }
    state = state.copyWith(hiddenCatalogIds: hidden);
    await _save();
  }

  Future<void> setDefaultSort(LibrarySortMode mode) async {
    state = state.copyWith(defaultSort: mode);
    await _save();
  }

  Future<void> setLayoutMode(LibraryLayoutMode mode) async {
    state = state.copyWith(layoutMode: mode);
    await _save();
  }

  Future<void> setCatalogSort(String catalogId, LibrarySortMode mode) async {
    final next = Map<String, LibrarySortMode>.from(state.catalogSortOverrides);
    next[catalogId] = mode;
    state = state.copyWith(catalogSortOverrides: next);
    await _save();
  }

  Future<void> reorderCatalogs(List<String> ids) async {
    state = state.copyWith(catalogOrder: ids);
    await _save();
  }

  Future<void> createCustomCatalog(String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final id =
        'custom_${DateTime.now().millisecondsSinceEpoch}_${trimmed.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}';
    final next = List<CustomCatalog>.from(state.customCatalogs)
      ..add(CustomCatalog(id: id, title: trimmed));
    final order = List<String>.from(state.catalogOrder)..add(id);
    state = state.copyWith(customCatalogs: next, catalogOrder: order);
    await _save();
  }

  Future<void> renameCustomCatalog(String catalogId, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return;
    final next = state.customCatalogs
        .map((e) => e.id == catalogId ? e.copyWith(title: trimmed) : e)
        .toList();
    state = state.copyWith(customCatalogs: next);
    await _save();
  }

  Future<void> deleteCustomCatalog(String catalogId) async {
    final next = state.customCatalogs.where((e) => e.id != catalogId).toList();
    final order = List<String>.from(state.catalogOrder)..remove(catalogId);
    final hidden = Set<String>.from(state.hiddenCatalogIds)..remove(catalogId);
    final overrides =
        Map<String, LibrarySortMode>.from(state.catalogSortOverrides)
          ..remove(catalogId);
    state = state.copyWith(
      customCatalogs: next,
      catalogOrder: order,
      hiddenCatalogIds: hidden,
      catalogSortOverrides: overrides,
    );
    await _save();
  }

  Future<void> toggleMediaInCustomCatalog(String catalogId, int mediaId) async {
    if (mediaId <= 0) return;
    final next = state.customCatalogs.map((c) {
      if (c.id != catalogId) return c;
      final ids = Set<int>.from(c.mediaIds);
      if (ids.contains(mediaId)) {
        ids.remove(mediaId);
      } else {
        ids.add(mediaId);
      }
      return c.copyWith(mediaIds: ids);
    }).toList();
    state = state.copyWith(customCatalogs: next);
    await _save();
  }
}

final libraryPreferencesProvider =
    StateNotifierProvider<LibraryPreferencesNotifier, LibraryPreferences>(
  (ref) => LibraryPreferencesNotifier(),
);
