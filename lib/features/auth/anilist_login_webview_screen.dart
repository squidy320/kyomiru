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
  static const _redirectUri = String.fromEnvironment('ANILIST_REDIRECT_URI',
      defaultValue: 'kyomiru://auth');

  @override
  void initState() {
    super.initState();
    final client = ref.read(anilistClientProvider);
    final state = _randomState();
    final authUrl = client.buildAuthUrl(
      clientId: _clientId,
      redirectUri: _redirectUri,
      state: state,
      useCodeFlow: _clientSecret.isNotEmpty,
    );

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) async {
            final url = request.url;
            if (url.startsWith(_redirectUri)) {
              await _completeLogin(url);
              return NavigationDecision.prevent;
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

      if (_clientSecret.isEmpty) {
        final token =
            (fragment['access_token'] ?? query['access_token'] ?? '').trim();
        if (token.isEmpty) {
          throw Exception('AniList did not return access_token.');
        }
        await ref.read(authControllerProvider.notifier).setToken(token);
        if (mounted) {
          Navigator.of(context).pop(true);
        }
        return;
      }

      final code = (query['code'] ?? '').trim();
      if (code.isEmpty) {
        throw Exception('AniList did not return authorization code.');
      }

      final token = await ref.read(anilistClientProvider).exchangeCodeForToken(
            clientId: _clientId,
            clientSecret: _clientSecret,
            code: code,
            redirectUri: _redirectUri,
          );
      await ref.read(authControllerProvider.notifier).setToken(token);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
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
