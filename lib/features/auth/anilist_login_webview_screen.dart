import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_logger.dart';
import '../../state/auth_state.dart';

class AniListLoginWebViewScreen extends ConsumerStatefulWidget {
  const AniListLoginWebViewScreen({super.key});

  @override
  ConsumerState<AniListLoginWebViewScreen> createState() =>
      _AniListLoginWebViewScreenState();
}

class _AniListLoginWebViewScreenState
    extends ConsumerState<AniListLoginWebViewScreen> {
  late final WebViewController _controller;
  String _error = '';
  bool _completed = false;
  bool _authInFlight = false;

  static const _clientId =
      String.fromEnvironment('ANILIST_CLIENT_ID', defaultValue: '36271');
  static const _clientSecret = String.fromEnvironment(
    'ANILIST_CLIENT_SECRET',
    defaultValue: 'LwVZw1mcI7iWatIXJfhcSg9FmYSH3MY7zPNu3XAL',
  );
  static const _redirectUri = 'kyomiru://auth';

  @override
  void initState() {
    super.initState();
    final client = ref.read(anilistClientProvider);
    final state = _randomState();

    final authUrl = client.buildAuthUrl(
      clientId: _clientId,
      redirectUri: _redirectUri,
      state: state,
      useCodeFlow: true,
    );

    AppLogger.i('AniListAuth', 'Opening AniList login WebView');
    AppLogger.d('AniListAuth', 'Auth URL: $authUrl');

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (url) {
            AppLogger.d('AniListAuth', 'onPageStarted: $url');
          },
          onPageFinished: (url) async {
            AppLogger.d('AniListAuth', 'onPageFinished: $url');
            await _maybeHandleCallback(url, source: 'onPageFinished(url)');

            // Some WebView implementations can miss fragment redirects in URL callbacks.
            try {
              final href = await _controller
                  .runJavaScriptReturningResult('window.location.href');
              final cleanHref = href.toString().replaceAll('"', '');
              if (cleanHref.isNotEmpty) {
                await _maybeHandleCallback(cleanHref,
                    source: 'onPageFinished(window.location.href)');
              }
            } catch (e, st) {
              AppLogger.w('AniListAuth', 'Failed reading window.location.href',
                  error: e, stackTrace: st);
            }
          },
          onWebResourceError: (error) {
            AppLogger.w('AniListAuth', 'Web resource error', error: error);
          },
          onUrlChange: (change) async {
            final url = change.url ?? '';
            if (_isCallback(url)) {
              AppLogger.i('AniListAuth', 'Callback detected via onUrlChange');
              await _completeLogin(url);
            }
          },
          onNavigationRequest: (request) async {
            final url = request.url;
            if (_isCallback(url)) {
              AppLogger.i(
                  'AniListAuth', 'Callback detected via navigation request');
              await _completeLogin(url);
              return NavigationDecision.prevent;
            }
            if (url.startsWith('https://anilist.co/api/v2/oauth/token')) {
              AppLogger.w('AniListAuth',
                  'WebView navigated to AniList token endpoint (redirect misconfiguration likely)');
              setState(() {
                _error =
                    'AniList redirect is misconfigured. Set AniList Redirect URL to: kyomiru://auth';
              });
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(authUrl));
  }

  Future<void> _maybeHandleCallback(String url,
      {required String source}) async {
    if (_completed || _authInFlight) return;
    if (_isCallback(url)) {
      AppLogger.i('AniListAuth', 'Callback detected via $source');
      await _completeLogin(url);
    }
  }

  bool _isCallback(String url) {
    return url.startsWith('kyomiru://') || url.startsWith('kyomiru:/');
  }

  String _randomState() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random();
    return List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<String> _exchangeCodeForToken(String code) async {
    final client = ref.read(anilistClientProvider);
    return client.exchangeCodeForToken(
      clientId: _clientId,
      clientSecret: _clientSecret,
      code: code,
      redirectUri: _redirectUri,
    );
  }

  Future<void> _completeLogin(String callbackUrl) async {
    if (_completed || _authInFlight) return;
    _authInFlight = true;
    try {
      final uri = Uri.parse(callbackUrl);
      final fragment =
          Uri.splitQueryString(uri.fragment.isEmpty ? '' : uri.fragment);
      final query = uri.queryParameters;

      final token =
          (fragment['access_token'] ?? query['access_token'] ?? '').trim();
      if (token.isNotEmpty) {
        AppLogger.i(
            'AniListAuth', 'Received implicit access_token from callback');
        _completed = true;
        await ref.read(authControllerProvider.notifier).setToken(token);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      final code = (query['code'] ?? fragment['code'] ?? '').trim();
      if (code.isNotEmpty) {
        AppLogger.i('AniListAuth',
            'Received auth code from callback; exchanging token');
        final exchanged = await _exchangeCodeForToken(code);
        _completed = true;
        await ref.read(authControllerProvider.notifier).setToken(exchanged);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      final err = (query['error'] ?? fragment['error'] ?? '').trim();
      final errDesc =
          (query['error_description'] ?? fragment['error_description'] ?? '')
              .trim();
      if (err.isNotEmpty) {
        AppLogger.w('AniListAuth',
            'AniList callback error: $err${errDesc.isNotEmpty ? ' - $errDesc' : ''}');
        throw Exception(
            'AniList auth error: $err${errDesc.isNotEmpty ? ' - $errDesc' : ''}');
      }

      throw Exception('AniList callback did not contain access token/code.');
    } catch (e, st) {
      AppLogger.e('AniListAuth', 'Login callback handling failed',
          error: e, stackTrace: st);
      setState(() => _error = e.toString());
    } finally {
      _authInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('AniList Login')),
      body: Column(
        children: [
          if (_error.isNotEmpty)
            Container(
              width: double.infinity,
              color: Colors.red.withValues(alpha: 0.2),
              padding: const EdgeInsets.all(10),
              child:
                  Text(_error, style: const TextStyle(color: Colors.redAccent)),
            ),
          const LinearProgressIndicator(minHeight: 1),
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
