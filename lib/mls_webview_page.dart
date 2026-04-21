import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class MlsWebViewPage extends StatefulWidget {
  // listingUrl is a frame-internal URL (start/listing/id/...) used to navigate
  // view_frame after the main Flexmls frameset loads.
  final String listingUrl;
  final List<Map<String, dynamic>> cookies;

  const MlsWebViewPage({super.key, required this.listingUrl, required this.cookies});

  @override
  State<MlsWebViewPage> createState() => _MlsWebViewPageState();
}

class _MlsWebViewPageState extends State<MlsWebViewPage> {
  late final WebViewController _controller;
  bool _loading = true;
  bool _listingNavigated = false;

  static const _mainUrl = 'https://mo.flexmls.com/';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'FlutterLog',
        onMessageReceived: (msg) => debugPrint('[WebView] ${msg.message}'),
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (url) {
          debugPrint('[WebView] pageStarted: $url');
          setState(() => _loading = true);
        },
        onPageFinished: (url) async {
          debugPrint('[WebView] pageFinished: $url');
          setState(() => _loading = false);

          // Log DOM state to help debug
          await _controller.runJavaScript(
            "FlutterLog.postMessage('title=' + document.title + ' body=' + document.body?.innerHTML?.slice(0,200));",
          ).catchError((_) {});

          // After the main Flexmls frameset loads, navigate view_frame to the listing.
          if (!_listingNavigated && url.contains('flexmls.com')) {
            _listingNavigated = true;
            await Future.delayed(const Duration(milliseconds: 1500));
            final escaped = widget.listingUrl.replaceAll("'", "\\'");
            await _controller.runJavaScript(
              "var vf = document.querySelector('frame[name=\"view_frame\"]')"
              " || document.querySelector('iframe[name=\"view_frame\"]');"
              "FlutterLog.postMessage('view_frame found: ' + !!vf + ' url=' + window.location.href);"
              "if (vf) { vf.src = '$escaped'; }",
            );
          }
        },
        onWebResourceError: (err) => debugPrint('[WebView] error: ${err.description}'),
      ));
    _injectCookiesAndLoad();
  }

  Future<void> _injectCookiesAndLoad() async {
    final cookieManager = WebViewCookieManager();

    // Build Cookie header string for the initial request (most reliable on iOS WKWebView)
    final cookiePairs = <String>[];
    for (final c in widget.cookies) {
      final name = c['name'] as String? ?? '';
      final value = c['value'] as String? ?? '';
      final domain = c['domain'] as String? ?? '';
      if (name.isEmpty || domain.isEmpty) continue;

      cookiePairs.add('$name=$value');

      // Also register in cookie store for subsequent navigation requests
      final cleanDomain = domain.startsWith('.') ? domain.substring(1) : domain;
      final path = (c['path'] as String?) ?? '/';
      await cookieManager.setCookie(WebViewCookie(
        name: name,
        value: value,
        domain: cleanDomain,
        path: path,
      ));
    }

    await _controller.loadRequest(
      Uri.parse(_mainUrl),
      headers: cookiePairs.isNotEmpty
          ? {'Cookie': cookiePairs.join('; ')}
          : {},
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('MLS Listing'),
        backgroundColor: Colors.black87,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _listingNavigated = false;
              _controller.reload();
            },
          ),
        ],
      ),
      body: Stack(
        children: [
          WebViewWidget(controller: _controller),
          if (_loading)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
