import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

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

  static const _clientId =
      String.fromEnvironment('ANILIST_CLIENT_ID', defaultValue: '36271');
  static const _clientSecret =
      String.fromEnvironment('ANILIST_CLIENT_SECRET', defaultValue: '');

  // Keep this fixed to avoid broken builds from wrong env values.
  static const _redirectUri = 'kyomiru://auth';

  @override
  void initState() {
    super.initState();
    final client = ref.read(anilistClientProvider);
    final state = _randomState();

    final useCodeFlow = _clientSecret.isNotEmpty;
    final authUrl = client.buildAuthUrl(
      clientId: _clientId,
      redirectUri: _redirectUri,
      state: state,
      useCodeFlow: useCodeFlow,
    );

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            final url = request.url;

            // Handle scheme variants: kyomiru://auth and kyomiru:/auth.
            final isCallback =
                url.startsWith('kyomiru://') || url.startsWith('kyomiru:/');
            if (isCallback) {
              await _completeLogin(url);
              return NavigationDecision.prevent;
            }

            // Misconfigured AniList app can redirect to token endpoint and show grant errors.
            if (url.startsWith('https://anilist.co/api/v2/oauth/token')) {
              setState(() {
                _error =
                    'AniList redirect is misconfigured. Set AniList app Redirect URL to: kyomiru://auth';
              });
            }

            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(authUrl));
  }

  String _randomState() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random();
    return List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
  }

  Future<void> _completeLogin(String callbackUrl) async {
    try {
      final uri = Uri.parse(callbackUrl);
      final fragment =
          Uri.splitQueryString(uri.fragment.isEmpty ? '' : uri.fragment);
      final query = uri.queryParameters;

      final token =
          (fragment['access_token'] ?? query['access_token'] ?? '').trim();
      if (token.isNotEmpty) {
        await ref.read(authControllerProvider.notifier).setToken(token);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      final code = (query['code'] ?? fragment['code'] ?? '').trim();
      if (code.isNotEmpty) {
        if (_clientSecret.isEmpty) {
          throw Exception(
              'AniList returned code flow but client secret is missing.');
        }
        final exchanged =
            await ref.read(anilistClientProvider).exchangeCodeForToken(
                  clientId: _clientId,
                  clientSecret: _clientSecret,
                  code: code,
                  redirectUri: _redirectUri,
                );
        await ref.read(authControllerProvider.notifier).setToken(exchanged);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      final err = (query['error'] ?? fragment['error'] ?? '').trim();
      final errDesc =
          (query['error_description'] ?? fragment['error_description'] ?? '')
              .trim();
      if (err.isNotEmpty) {
        throw Exception(
            'AniList auth error: $err${errDesc.isNotEmpty ? ' - $errDesc' : ''}');
      }

      throw Exception(
          'AniList callback did not contain access token or auth code.');
    } catch (e) {
      setState(() => _error = e.toString());
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
          Expanded(child: WebViewWidget(controller: _controller)),
        ],
      ),
    );
  }
}
