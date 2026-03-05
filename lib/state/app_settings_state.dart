import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettings {
  const AppSettings({
    this.theme = 'Midnight',
    this.isOledBlack = true,
    this.enableDynamicColors = true,
    this.defaultQuality = '720p',
    this.defaultAudio = 'Sub',
    this.librarySource = 'AniList',
    this.chooseStreamEveryTime = false,
    this.doubleTapSeekSeconds = 10,
    this.autoPlayNextEpisode = true,
    this.smartSkipEnabled = false,
    this.autoSyncProgressToAniList = true,
    this.fetchPrivateLists = false,
  });

  final String theme;
  final bool isOledBlack;
  final bool enableDynamicColors;
  final String defaultQuality;
  final String defaultAudio;
  final String librarySource;
  final bool chooseStreamEveryTime;
  final int doubleTapSeekSeconds;
  final bool autoPlayNextEpisode;
  final bool smartSkipEnabled;
  final bool autoSyncProgressToAniList;
  final bool fetchPrivateLists;

  // Backward-compatible aliases used across existing UI/business logic.
  bool get oled => isOledBlack;
  String get preferredQuality => defaultQuality;
  String get preferredAudio => defaultAudio.toLowerCase();
  bool get compactBar => true;
  bool get touchOutline => true;
  String get glass => 'Off';
  String get intensity => 'Low';

  AppSettings copyWith({
    String? theme,
    bool? isOledBlack,
    bool? enableDynamicColors,
    String? defaultQuality,
    String? defaultAudio,
    String? librarySource,
    bool? chooseStreamEveryTime,
    int? doubleTapSeekSeconds,
    bool? autoPlayNextEpisode,
    bool? smartSkipEnabled,
    bool? autoSyncProgressToAniList,
    bool? fetchPrivateLists,
  }) {
    return AppSettings(
      theme: theme ?? this.theme,
      isOledBlack: isOledBlack ?? this.isOledBlack,
      enableDynamicColors: enableDynamicColors ?? this.enableDynamicColors,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      defaultAudio: defaultAudio ?? this.defaultAudio,
      librarySource: librarySource ?? this.librarySource,
      chooseStreamEveryTime:
          chooseStreamEveryTime ?? this.chooseStreamEveryTime,
      doubleTapSeekSeconds: doubleTapSeekSeconds ?? this.doubleTapSeekSeconds,
      autoPlayNextEpisode: autoPlayNextEpisode ?? this.autoPlayNextEpisode,
      smartSkipEnabled: smartSkipEnabled ?? this.smartSkipEnabled,
      autoSyncProgressToAniList:
          autoSyncProgressToAniList ?? this.autoSyncProgressToAniList,
      fetchPrivateLists: fetchPrivateLists ?? this.fetchPrivateLists,
    );
  }
}

class SettingsNotifier extends StateNotifier<AppSettings> {
  SettingsNotifier() : super(const AppSettings()) {
    _load();
  }

  static const _kTheme = 'settings.theme';
  static const _kOled = 'settings.isOledBlack';
  static const _kQuality = 'settings.defaultQuality';
  static const _kDynamicColors = 'settings.enableDynamicColors';
  static const _kAudio = 'settings.defaultAudio';
  static const _kLibrarySource = 'settings.librarySource';
  static const _kChooseEveryTime = 'settings.chooseStreamEveryTime';
  static const _kDoubleTapSeekSeconds = 'settings.doubleTapSeekSeconds';
  static const _kAutoPlayNextEpisode = 'settings.autoPlayNextEpisode';
  static const _kSmartSkipEnabled = 'settings.smartSkipEnabled';
  static const _kAutoSyncProgressToAniList =
      'settings.autoSyncProgressToAniList';
  static const _kFetchPrivateLists = 'settings.fetchPrivateLists';

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    state = AppSettings(
      theme: prefs.getString(_kTheme) ?? 'Midnight',
      isOledBlack: prefs.getBool(_kOled) ?? true,
      enableDynamicColors: prefs.getBool(_kDynamicColors) ?? true,
      defaultQuality: prefs.getString(_kQuality) ?? '720p',
      defaultAudio: prefs.getString(_kAudio) ?? 'Sub',
      librarySource: prefs.getString(_kLibrarySource) ?? 'AniList',
      chooseStreamEveryTime: prefs.getBool(_kChooseEveryTime) ?? false,
      doubleTapSeekSeconds: prefs.getInt(_kDoubleTapSeekSeconds) ?? 10,
      autoPlayNextEpisode: prefs.getBool(_kAutoPlayNextEpisode) ?? true,
      smartSkipEnabled: prefs.getBool(_kSmartSkipEnabled) ?? false,
      autoSyncProgressToAniList:
          prefs.getBool(_kAutoSyncProgressToAniList) ?? true,
      fetchPrivateLists: prefs.getBool(_kFetchPrivateLists) ?? false,
    );
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTheme, state.theme);
    await prefs.setBool(_kOled, state.isOledBlack);
    await prefs.setBool(_kDynamicColors, state.enableDynamicColors);
    await prefs.setString(_kQuality, state.defaultQuality);
    await prefs.setString(_kAudio, state.defaultAudio);
    await prefs.setString(_kLibrarySource, state.librarySource);
    await prefs.setBool(_kChooseEveryTime, state.chooseStreamEveryTime);
    await prefs.setInt(_kDoubleTapSeekSeconds, state.doubleTapSeekSeconds);
    await prefs.setBool(_kAutoPlayNextEpisode, state.autoPlayNextEpisode);
    await prefs.setBool(_kSmartSkipEnabled, state.smartSkipEnabled);
    await prefs.setBool(
      _kAutoSyncProgressToAniList,
      state.autoSyncProgressToAniList,
    );
    await prefs.setBool(_kFetchPrivateLists, state.fetchPrivateLists);
  }

  Future<void> setTheme(String value) async {
    state = state.copyWith(theme: value);
    await _save();
  }

  Future<void> setOledBlack(bool value) async {
    state = state.copyWith(isOledBlack: value);
    await _save();
  }

  Future<void> setDefaultQuality(String value) async {
    state = state.copyWith(defaultQuality: value);
    await _save();
  }

  Future<void> setEnableDynamicColors(bool value) async {
    state = state.copyWith(enableDynamicColors: value);
    await _save();
  }

  Future<void> setDefaultAudio(String value) async {
    state = state.copyWith(defaultAudio: value);
    await _save();
  }

  Future<void> setLibrarySource(String value) async {
    state = state.copyWith(librarySource: value);
    await _save();
  }

  Future<void> setChooseStreamEveryTime(bool value) async {
    state = state.copyWith(chooseStreamEveryTime: value);
    await _save();
  }

  Future<void> setDoubleTapSeekSeconds(int value) async {
    state = state.copyWith(
      doubleTapSeekSeconds: value.clamp(5, 30),
    );
    await _save();
  }

  Future<void> setAutoPlayNextEpisode(bool value) async {
    state = state.copyWith(autoPlayNextEpisode: value);
    await _save();
  }

  Future<void> setSmartSkipEnabled(bool value) async {
    state = state.copyWith(smartSkipEnabled: value);
    await _save();
  }

  Future<void> setAutoSyncProgressToAniList(bool value) async {
    state = state.copyWith(autoSyncProgressToAniList: value);
    await _save();
  }

  Future<void> setFetchPrivateLists(bool value) async {
    state = state.copyWith(fetchPrivateLists: value);
    await _save();
  }

  // Legacy method names for compatibility.
  Future<void> setOled(bool value) => setOledBlack(value);
  Future<void> setPreferredQuality(String value) => setDefaultQuality(value);
  Future<void> setPreferredAudio(String value) => setDefaultAudio(value.isEmpty
      ? 'Sub'
      : '${value[0].toUpperCase()}${value.substring(1).toLowerCase()}');
  Future<void> setCompactBar(bool value) async {}
  Future<void> setTouchOutline(bool value) async {}
  Future<void> setGlass(String value) async {}
  Future<void> setIntensity(String value) async {}

  Future<void> reset() async {
    state = const AppSettings();
    await _save();
  }
}

final appSettingsProvider =
    StateNotifierProvider<SettingsNotifier, AppSettings>(
  (ref) => SettingsNotifier(),
);
