import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../core/app_logger.dart';
import '../../core/glass_widgets.dart';
import '../../state/auth_state.dart';

class AniListLoginWebViewScreen extends ConsumerStatefulWidget {
  const AniListLoginWebViewScreen({super.key});

  @override
  ConsumerState<AniListLoginWebViewScreen> createState() =>
      _AniListLoginWebViewScreenState();
}

class _AniListLoginWebViewScreenState
    extends ConsumerState<AniListLoginWebViewScreen> {
  static const _clientId =
      String.fromEnvironment('ANILIST_CLIENT_ID', defaultValue: '36271');
  static const _clientSecret = String.fromEnvironment(
    'ANILIST_CLIENT_SECRET',
    defaultValue: 'LwVZw1mcI7iWatIXJfhcSg9FmYSH3MY7zPNu3XAL',
  );
  static const _redirectUri = 'kyomiru://auth';
  static const _desktopLoopbackPort = 4321;
  WebViewController? _controller;
  HttpServer? _loopbackServer;
  String _desktopRedirectUri = 'http://localhost:$_desktopLoopbackPort';
  String _desktopAuthState = '';

  String _error = '';
  bool _completed = false;
  bool _authInFlight = false;
  bool _desktopBrowserOpenAttempted = false;

  bool get _useDesktopLoopbackAuth => Platform.isWindows || Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: GlassAppBar(
        title: const Text('AniList Login'),
        leading: IconButton(
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 18),
        ),
      ),
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
          Expanded(
            child: _useDesktopLoopbackAuth
                ? _buildDesktopLoopbackBody(context)
                : WebViewWidget(controller: _controller!),
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    if (_useDesktopLoopbackAuth) {
      unawaited(_startDesktopLoopbackFlow());
      return;
    }
    _initWebViewFlow();
  }

  @override
  void dispose() {
    unawaited(_closeLoopbackServer());
    super.dispose();
  }

  Widget _buildDesktopLoopbackBody(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: GlassCard(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Continue AniList Login In Browser',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Desktop OAuth uses a local callback server at '
                    '$_desktopRedirectUri.',
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Set your AniList app Redirect URL to '
                    '"http://localhost:4321" to complete login.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: GlassButton(
                          onPressed: () => unawaited(_startDesktopLoopbackFlow(
                            forceRestart: true,
                          )),
                          child: const Text(
                            'Open Browser Login',
                            style: TextStyle(fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _initWebViewFlow() {
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
                  ?.runJavaScriptReturningResult('window.location.href');
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

  Future<void> _startDesktopLoopbackFlow({bool forceRestart = false}) async {
    if (_completed) return;
    if (_desktopBrowserOpenAttempted && !forceRestart) return;
    _desktopBrowserOpenAttempted = true;
    if (forceRestart) {
      setState(() => _error = '');
      await _closeLoopbackServer();
    }
    try {
      final client = ref.read(anilistClientProvider);
      _desktopAuthState = _randomState();
      _loopbackServer = await _bindDesktopLoopbackServer();
      _desktopRedirectUri = 'http://localhost:${_loopbackServer!.port}';
      AppLogger.i(
        'AniListAuth',
        'Desktop loopback server listening on $_desktopRedirectUri',
      );
      unawaited(_listenForLoopbackRequests(_loopbackServer!));
      final authUrl = client.buildAuthUrl(
        clientId: _clientId,
        redirectUri: _desktopRedirectUri,
        state: _desktopAuthState,
        useCodeFlow: true,
      );
      await _openExternalBrowser(authUrl);
    } catch (e, st) {
      AppLogger.e(
        'AniListAuth',
        'Desktop loopback auth init failed',
        error: e,
        stackTrace: st,
      );
      if (!mounted) return;
      setState(() {
        _error = 'Failed to start Desktop OAuth callback server on '
            'http://localhost:$_desktopLoopbackPort. Close other app using '
            'that port and retry.';
      });
    }
  }

  Future<HttpServer> _bindDesktopLoopbackServer() async {
    try {
      return await HttpServer.bind(
        InternetAddress.anyIPv6,
        _desktopLoopbackPort,
        shared: true,
        v6Only: false,
      );
    } catch (_) {
      return HttpServer.bind(
        InternetAddress.loopbackIPv4,
        _desktopLoopbackPort,
        shared: true,
      );
    }
  }

  Future<void> _openExternalBrowser(String url) async {
    AppLogger.i('AniListAuth', 'Opening external browser for AniList auth');
    if (Platform.isWindows) {
      await Process.start(
        'rundll32',
        ['url.dll,FileProtocolHandler', url],
        runInShell: true,
      );
      return;
    }
    await Process.start('open', [url], runInShell: true);
  }

  Future<void> _listenForLoopbackRequests(HttpServer server) async {
    await for (final request in server) {
      final uri = request.uri;
      final query = uri.queryParameters;
      AppLogger.d('AniListAuth', 'Loopback callback uri=$uri');
      final html = _buildLoopbackHtml(query.containsKey('error'));
      request.response
        ..headers.contentType = ContentType.html
        ..statusCode = 200
        ..write(html);
      await request.response.close();

      if (_completed) continue;
      final err = (query['error'] ?? '').trim();
      final errDesc = (query['error_description'] ?? '').trim();
      if (err.isNotEmpty) {
        setState(() {
          _error = 'AniList auth error: $err'
              '${errDesc.isNotEmpty ? ' - $errDesc' : ''}';
        });
        continue;
      }
      final code = (query['code'] ?? '').trim();
      final callbackState = (query['state'] ?? '').trim();
      if (_desktopAuthState.isNotEmpty &&
          callbackState.isNotEmpty &&
          callbackState != _desktopAuthState) {
        AppLogger.w(
          'AniListAuth',
          'Desktop callback state mismatch; continuing because code is present',
        );
      }
      if (code.isEmpty) continue;
      await _completeDesktopLoopbackLogin(code);
    }
  }

  String _buildLoopbackHtml(bool hasError) {
    final title = hasError ? 'Kyomiru Login Failed' : 'Kyomiru Login Complete';
    final subtitle = hasError
        ? 'You can close this tab and retry in the app.'
        : 'You can close this tab and return to Kyomiru.';
    return '''
<!doctype html>
<html>
  <head><meta charset="utf-8"><title>$title</title></head>
  <body style="background:#0b1020;color:#fff;font-family:Segoe UI,Arial,sans-serif;display:flex;align-items:center;justify-content:center;min-height:100vh;">
    <div style="max-width:520px;padding:28px;border-radius:14px;background:rgba(255,255,255,0.08);border:1px solid rgba(255,255,255,0.2)">
      <h2 style="margin:0 0 12px 0;">$title</h2>
      <p style="margin:0;color:rgba(255,255,255,0.85)">$subtitle</p>
    </div>
  </body>
</html>
''';
  }

  Future<void> _completeDesktopLoopbackLogin(String code) async {
    if (_completed || _authInFlight) return;
    _authInFlight = true;
    try {
      final exchanged =
          await ref.read(anilistClientProvider).exchangeCodeForToken(
                clientId: _clientId,
                clientSecret: _clientSecret,
                code: code,
                redirectUri: _desktopRedirectUri,
              );
      _completed = true;
      await ref.read(authControllerProvider.notifier).setToken(exchanged);
      await _closeLoopbackServer();
      if (mounted) Navigator.of(context).pop(true);
    } catch (e, st) {
      AppLogger.e(
        'AniListAuth',
        'Desktop loopback login failed',
        error: e,
        stackTrace: st,
      );
      if (mounted) {
        setState(() => _error = e.toString());
      }
    } finally {
      _authInFlight = false;
    }
  }

  Future<void> _closeLoopbackServer() async {
    try {
      await _loopbackServer?.close(force: true);
    } catch (_) {}
    _loopbackServer = null;
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

  Future<String> _exchangeCodeForToken(String code) async {
    final client = ref.read(anilistClientProvider);
    return client.exchangeCodeForToken(
      clientId: _clientId,
      clientSecret: _clientSecret,
      code: code,
      redirectUri: _redirectUri,
    );
  }

  bool _isCallback(String url) {
    return url.startsWith('kyomiru://') || url.startsWith('kyomiru:/');
  }

  Future<void> _maybeHandleCallback(String url,
      {required String source}) async {
    if (_completed || _authInFlight) return;
    if (_isCallback(url)) {
      AppLogger.i('AniListAuth', 'Callback detected via $source');
      await _completeLogin(url);
    }
  }

  String _randomState() {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final rnd = Random();
    return List.generate(12, (_) => chars[rnd.nextInt(chars.length)]).join();
  }
}
