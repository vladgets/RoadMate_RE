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
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (url) async {
          setState(() => _loading = false);
          // After the main Flexmls frameset loads, navigate view_frame to the listing.
          // Only do this once — subsequent onPageFinished fires are from frame navigations.
          if (!_listingNavigated && url.contains('flexmls.com')) {
            _listingNavigated = true;
            await Future.delayed(const Duration(milliseconds: 800));
            final escaped = widget.listingUrl.replaceAll("'", "\\'");
            await _controller.runJavaScript(
              "var vf = document.querySelector('frame[name=\"view_frame\"]') "
              "|| document.querySelector('iframe[name=\"view_frame\"]');"
              "if (vf) { vf.src = '$escaped'; }",
            );
          }
        },
      ));
    _injectCookiesAndLoad();
  }

  Future<void> _injectCookiesAndLoad() async {
    final cookieManager = WebViewCookieManager();
    for (final c in widget.cookies) {
      final name = c['name'] as String? ?? '';
      final value = c['value'] as String? ?? '';
      final domain = c['domain'] as String? ?? '';
      final path = (c['path'] as String?) ?? '/';
      if (name.isEmpty || domain.isEmpty) continue;
      await cookieManager.setCookie(WebViewCookie(
        name: name,
        value: value,
        domain: domain.startsWith('.') ? domain.substring(1) : domain,
        path: path,
      ));
    }
    await _controller.loadRequest(Uri.parse(_mainUrl));
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
