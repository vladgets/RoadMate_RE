import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class MlsWebViewPage extends StatefulWidget {
  final String url;
  final List<Map<String, dynamic>> cookies;

  const MlsWebViewPage({super.key, required this.url, required this.cookies});

  @override
  State<MlsWebViewPage> createState() => _MlsWebViewPageState();
}

class _MlsWebViewPageState extends State<MlsWebViewPage> {
  late final WebViewController _controller;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) => setState(() => _loading = true),
        onPageFinished: (_) => setState(() => _loading = false),
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
    await _controller.loadRequest(Uri.parse(widget.url));
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
            onPressed: () => _controller.reload(),
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
