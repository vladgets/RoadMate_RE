import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Matches the Node server's `sources` items: { title, url }
class WebSearchSource {
  final String title;
  final String url;

  WebSearchSource({
    required this.title,
    required this.url,
  });

  factory WebSearchSource.fromJson(Map<String, dynamic> j) => WebSearchSource(
        title: (j['title'] ?? '') as String,
        url: (j['url'] ?? '') as String,
      );

  Map<String, dynamic> toJson() => {
        'title': title,
        'url': url,
      };
}

class WebSearchAnswerResponse {
  final String answer;
  final List<WebSearchSource> sources;

  WebSearchAnswerResponse({
    required this.answer,
    required this.sources,
  });
}


/// A thin client for the hardcoded Render endpoint:
/// POST https://roadmate-flutter.onrender.com/websearch
/// body: { query: string, model: "gpt-4.1-mini" }
/// response: { ok: true, query: string, answer: string, sources: [{title,url}, ...] }
class WebSearchClient {
  WebSearchClient({
    http.Client? httpClient,
    Duration timeout = const Duration(seconds: 10),
  })  : _http = httpClient ?? http.Client(),
        _timeout = timeout;

  // Hardcoded server endpoint (includes /websearch)
  static const String _serverUrl = "https://roadmate-flutter.onrender.com/websearch";
  // Hardcoded model sent to the server
  static const String _model = "gpt-4.1-mini";

  final http.Client _http;
  final Duration _timeout;

  Uri _endpoint() => Uri.parse(_serverUrl);

  /// Returns ONLY the parsed results array from server.
  /// Throws an Exception on non-2xx or ok:false.
  Future<WebSearchAnswerResponse> search({
    required String query,
  }) async {
    final q = query.trim();
    if (q.isEmpty) {
      throw ArgumentError('query must be non-empty');
    }

    final body = <String, dynamic>{
      'query': q,
      'model': _model,
    };

    final resp = await _http
        .post(
          _endpoint(),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(_timeout);

    debugPrint('WebSearch HTTP ${resp.statusCode}');
    debugPrint('WebSearch response body: ${resp.body}');

    Map<String, dynamic> data;
    try {
      data = (jsonDecode(resp.body) as Map).cast<String, dynamic>();
    } catch (_) {
      throw Exception('WebSearch server returned non-JSON (${resp.statusCode}): ${resp.body}');
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('WebSearch HTTP ${resp.statusCode}: ${resp.body}');
    }

    if (data['ok'] != true) {
      final err = (data['error'] ?? 'Unknown websearch error').toString();
      throw Exception('WebSearch ok=false: $err');
    }

    final answer = (data['answer'] ?? '') as String;
    final sources = (data['sources'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => WebSearchSource.fromJson(m.cast<String, dynamic>()))
        .toList();

    return WebSearchAnswerResponse(answer: answer, sources: sources);
  }

  void close() => _http.close();
}


/// Minimal WebSearch tool for Realtime voice.
/// Input:  { query: string }
/// Output: { ok: true, answer: string, sources: [{title,url}, ...] }
/// Error:  { ok: false, error: string }
class WebSearchTool {
  WebSearchTool({required WebSearchClient client}) : _client = client;

  final WebSearchClient _client;

  Future<Map<String, dynamic>> call(dynamic args) async {
    Map<String, dynamic> a = {};

    // Args may arrive as JSON string or Map
    if (args is String && args.trim().isNotEmpty) {
      a = (jsonDecode(args) as Map).cast<String, dynamic>();
    } else if (args is Map) {
      a = args.cast<String, dynamic>();
    }

    final query = (a['query'] ?? '').toString().trim();
    if (query.isEmpty) {
      return {
        'ok': false,
        'error': 'Missing query',
      };
    }

    try {
      final resp = await _client.search(query: query);

      return {
        'ok': true,
        'answer': resp.answer,
        'sources': resp.sources.map((s) => s.toJson()).toList(),
      };
    } catch (e) {
      return {
        'ok': false,
        'error': e.toString(),
      };
    }
  }
}

Future<void> testWebSearch() async {
  final client = WebSearchClient();
  try {
    final resp = await client.search(query: 'Is Bagby Hot Springs open right now?');
    debugPrint('WebSearch answer: ${resp.answer}');
    debugPrint('WebSearch sources: ${resp.sources.length}');
    for (final s in resp.sources) {
      debugPrint('TITLE: ${s.title}');
      debugPrint('URL: ${s.url}');
      debugPrint('---');
    }
  } catch (e) {
    debugPrint('WebSearch error: $e');
  } finally {
    client.close();
  }
}