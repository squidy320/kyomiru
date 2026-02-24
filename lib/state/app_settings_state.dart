import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

class AppSettings {
  const AppSettings({
    this.theme = 'Midnight',
    this.oled = true,
    this.compactBar = true,
    this.touchOutline = true,
    this.glass = 'Auto',
    this.intensity = 'High',
  });

  final String theme;
  final bool oled;
  final bool compactBar;
  final bool touchOutline;
  final String glass;
  final String intensity;

  AppSettings copyWith({
    String? theme,
    bool? oled,
    bool? compactBar,
    bool? touchOutline,
    String? glass,
    String? intensity,
  }) {
    return AppSettings(
      theme: theme ?? this.theme,
      oled: oled ?? this.oled,
      compactBar: compactBar ?? this.compactBar,
      touchOutline: touchOutline ?? this.touchOutline,
      glass: glass ?? this.glass,
      intensity: intensity ?? this.intensity,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'theme': theme,
      'oled': oled,
      'compactBar': compactBar,
      'touchOutline': touchOutline,
      'glass': glass,
      'intensity': intensity,
    };
  }

  static AppSettings fromJson(Map<dynamic, dynamic>? json) {
    if (json == null) return const AppSettings();
    return AppSettings(
      theme: (json['theme'] as String?) ?? 'Midnight',
      oled: (json['oled'] as bool?) ?? true,
      compactBar: (json['compactBar'] as bool?) ?? true,
      touchOutline: (json['touchOutline'] as bool?) ?? true,
      glass: (json['glass'] as String?) ?? 'Auto',
      intensity: (json['intensity'] as String?) ?? 'High',
    );
  }
}

class AppSettingsController extends StateNotifier<AppSettings> {
  AppSettingsController() : super(const AppSettings()) {
    _load();
  }

  static const _key = 'ui';

  Box get _box => Hive.box('app_settings');

  void _load() {
    final data = _box.get(_key);
    if (data is Map) {
      state = AppSettings.fromJson(data);
    }
  }

  Future<void> _save() => _box.put(_key, state.toJson());

  Future<void> setTheme(String value) async {
    state = state.copyWith(theme: value);
    await _save();
  }

  Future<void> setOled(bool value) async {
    state = state.copyWith(oled: value);
    await _save();
  }

  Future<void> setCompactBar(bool value) async {
    state = state.copyWith(compactBar: value);
    await _save();
  }

  Future<void> setTouchOutline(bool value) async {
    state = state.copyWith(touchOutline: value);
    await _save();
  }

  Future<void> setGlass(String value) async {
    state = state.copyWith(glass: value);
    await _save();
  }

  Future<void> setIntensity(String value) async {
    state = state.copyWith(intensity: value);
    await _save();
  }

  Future<void> reset() async {
    state = const AppSettings();
    await _save();
  }
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsController, AppSettings>(
        (ref) => AppSettingsController());
