import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/anilist_client.dart';
import '../services/auth_store.dart';
import '../services/progress_store.dart';

final anilistClientProvider = Provider<AniListClient>((ref) => AniListClient());
final authStoreProvider = Provider<AuthStore>((ref) => AuthStore());
final progressStoreProvider = Provider<ProgressStore>((ref) => ProgressStore());

class AuthState {
  final String? token;
  final bool loading;

  const AuthState({this.token, this.loading = false});

  AuthState copyWith({String? token, bool? loading}) => AuthState(
        token: token ?? this.token,
        loading: loading ?? this.loading,
      );
}

class AuthController extends StateNotifier<AuthState> {
  AuthController(this._store) : super(const AuthState(loading: true)) {
    _init();
  }

  final AuthStore _store;

  Future<void> _init() async {
    final token = await _store.readToken();
    state = AuthState(token: token, loading: false);
  }

  Future<void> setToken(String token) async {
    await _store.writeToken(token);
    state = AuthState(token: token, loading: false);
  }

  Future<void> logout() async {
    await _store.clearToken();
    state = const AuthState(token: null, loading: false);
  }
}

final authControllerProvider =
    StateNotifierProvider<AuthController, AuthState>((ref) {
  return AuthController(ref.watch(authStoreProvider));
});

final unreadAlertsProvider = FutureProvider<int>((ref) async {
  final auth = ref.watch(authControllerProvider);
  final token = auth.token;
  if (token == null || token.isEmpty) return 0;
  return ref.watch(anilistClientProvider).unreadNotificationCount(token);
});
