import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

String _cleanSnippet(String s, {int maxLen = 220}) {
  var out = s
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      // Common HTML entities seen in Gmail snippets
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  if (out.length > maxLen) out = '${out.substring(0, maxLen).trimRight()}…';
  return out.trim();
}

/// A compact “email card” suitable for voice UX.
class GmailEmailCard {
  final String id;
  final String threadId;
  final String subject;
  final String from;
  final String date;
  final String snippet;
  final int? matchedCount;

  GmailEmailCard({
    required this.id,
    required this.threadId,
    required this.subject,
    required this.from,
    required this.date,
    required this.snippet,
    this.matchedCount,
  });

  factory GmailEmailCard.fromJson(Map<String, dynamic> j) {
    return GmailEmailCard(
      id: (j['messageId'] ?? j['id'] ?? '') as String,
      threadId: (j['threadId'] ?? '') as String,
      subject: (j['subject'] ?? '') as String,
      from: (j['from'] ?? '') as String,
      date: (j['date'] ?? '') as String,
      snippet: (j['snippet'] ?? '') as String,
      matchedCount: j['matched_count'] is num ? (j['matched_count'] as num).toInt() : null,      
    );
  }

  Map<String, dynamic> toJson() => {
        'messageId': id,
        'threadId': threadId,
        'subject': subject,
        'from': from,
        'date': date,
        'snippet': _cleanSnippet(snippet), 
        if (matchedCount != null) 'matched_count': matchedCount,
      };
}

class GmailSearchResponse {
  final bool ok;
  final String query; // the generated Gmail q string server used
  final List<GmailEmailCard> results;

  GmailSearchResponse({
    required this.ok,
    required this.query,
    required this.results,
  });

  factory GmailSearchResponse.fromJson(Map<String, dynamic> j) {
    final list = (j['results'] as List? ?? const [])
        .whereType<Map>()
        .map((m) => GmailEmailCard.fromJson(m.cast<String, dynamic>()))
        .toList();

    return GmailSearchResponse(
      ok: j['ok'] == true,
      query: (j['query'] ?? '') as String,
      results: list,
    );
  }
}

class GmailReadResponse {
  final bool ok;
  final String id;
  final String threadId;
  final String subject;
  final String from;
  final String date;
  final String snippet;

  GmailReadResponse({
    required this.ok,
    required this.id,
    required this.threadId,
    required this.subject,
    required this.from,
    required this.date,
    required this.snippet,
  });

  factory GmailReadResponse.fromJson(Map<String, dynamic> j) {
    return GmailReadResponse(
      ok: j['ok'] == true,
      id: (j['id'] ?? '') as String,
      threadId: (j['threadId'] ?? '') as String,
      subject: (j['subject'] ?? '') as String,
      from: (j['from'] ?? '') as String,
      date: (j['date'] ?? '') as String,
      snippet: (j['snippet'] ?? '') as String,
    );
  }
}

/// Server-side Gmail proxy client.
/// Uses your existing Node service that already holds OAuth tokens.
/// This does NOT talk to Google directly from Flutter.
class GmailClient {
  /// Example:
  ///   const GmailClient(baseUrl: 'https://roadmate-flutter.onrender.com');
  final String baseUrl;

  /// Optionally pass an auth token you use for your own server (if you add one).
  final Future<String?> Function()? getServerAuthToken;

  /// Client-provided unique id used by the server to select the right Gmail token file.
  /// Provide either `clientId` or `getClientId`.
  final String? clientId;
  final Future<String?> Function()? getClientId;

  const GmailClient({
    required this.baseUrl,
    this.getServerAuthToken,
    this.clientId,
    this.getClientId,    
  });

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, String>> _headers() async {
    final h = <String, String>{
      'Content-Type': 'application/json',
    };

    if (getServerAuthToken != null) {
      final token = await getServerAuthToken!();
      if (token != null && token.isNotEmpty) {
        h['Authorization'] = 'Bearer $token';
      }
    }

    final cid = clientId ?? (getClientId != null ? await getClientId!() : null);
    if (cid != null && cid.isNotEmpty) {
      h['X-Client-Id'] = cid;
    }

    return h;
  }

  /// Calls POST /gmail/search_structured
  Future<GmailSearchResponse> searchStructured({
    String? text,
    String? from,
    String? subject,
    bool? unreadOnly,
    bool? inInbox,
    int? newerThanDays,
    int maxResults = 5,
  }) async {
    final body = <String, dynamic>{
      if (text != null) 'text': text,
      if (from != null) 'from': from,
      if (subject != null) 'subject': subject,
      if (unreadOnly != null) 'unread_only': unreadOnly,
      if (inInbox != null) 'in_inbox': inInbox,
      if (newerThanDays != null) 'newer_than_days': newerThanDays,
      'max_results': maxResults,
    };

    debugPrint('[GmailClient] searchStructured request body: ${jsonEncode(body)}');
    final r = await http.post(
      _u('/gmail/search_structured'),
      headers: await _headers(),
      body: jsonEncode(body),
    );

    final data = jsonDecode(r.body) as Map<String, dynamic>;
    debugPrint('[GmailClient] searchStructured response (${r.statusCode}): ${r.body}');

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('Gmail search failed (${r.statusCode}): ${data['error'] ?? r.body}');
    }

    return GmailSearchResponse.fromJson(data);
  }

  /// Calls GET /gmail/read?id=...
  Future<GmailReadResponse> readEmailMetadata({required String id}) async {
    final uri = _u('/gmail/read').replace(queryParameters: {'id': id});
    debugPrint('[GmailClient] readEmailMetadata request: $uri');
    final r = await http.get(uri, headers: await _headers());
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    debugPrint('[GmailClient] readEmailMetadata response (${r.statusCode}): ${r.body}');

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('Gmail read failed (${r.statusCode}): ${data['error'] ?? r.body}');
    }

    return GmailReadResponse.fromJson(data);
  }
}


/// Tool wrappers to integrate into LLM function calling.
class GmailSearchTool {
  final GmailClient client;

  GmailSearchTool({required this.client});

  /// args keys follow your tool schema:
  /// text, from, subject, unread_only, in_inbox, newer_than_days, max_results
  Future<Map<String, dynamic>> call(Map<String, dynamic> args) async {
    final resp = await client.searchStructured(
      text: args['text'] as String?,
      from: args['from'] as String?,
      subject: args['subject'] as String?,
      unreadOnly: args['unread_only'] as bool?,
      inInbox: args['in_inbox'] as bool?,
      newerThanDays: args['newer_than_days'] is num ? (args['newer_than_days'] as num).toInt() : null,
      maxResults: args['max_results'] is num ? (args['max_results'] as num).toInt() : 5,
    );

    final summaryBuf = StringBuffer();
    if (resp.results.isEmpty) {
      summaryBuf.write('No matching emails found.');
    } else {
      summaryBuf.writeln('Found ${resp.results.length} matching email(s):');
      for (var i = 0; i < resp.results.length; i++) {
        final e = resp.results[i];
        final mc = (e.matchedCount != null) ? ' (thread msgs: ${e.matchedCount})' : '';
        summaryBuf.writeln(
            '${i + 1}) messageId=${e.id} | from=${e.from} | date=${e.date} | subject=${e.subject}$mc | snippet=${_cleanSnippet(e.snippet)}');
      }
    }

    return {
      'ok': true,
      // Useful for debugging / transparency, can remove if you want even smaller.
      'query': resp.query,
      'count': resp.results.length,
      // Plain-text summary is easiest for the voice model to ground on.
      'summary': summaryBuf.toString().trim(),
      // Keep structured results for follow-up tool calls.      
      'results': resp.results.map((e) => e.toJson()).toList(),
    };
  }
}

class GmailReadEmailTool {
  final GmailClient client;

  GmailReadEmailTool({required this.client});

  Future<Map<String, dynamic>> call(Map<String, dynamic> args) async {
    final id = args['message_id'] as String?;
    if (id == null || id.isEmpty) {
      return {'ok': false, 'error': 'Missing required field: message_id'};
    }

    final resp = await client.readEmailMetadata(id: id);

    return {
      'ok': true,
      'email': {
        'messageId': resp.id,
        'threadId': resp.threadId,
        'subject': resp.subject,
        'from': resp.from,
        'date': resp.date,
        'snippet': _cleanSnippet(resp.snippet, maxLen: 800),      }
    };
  }
}


/// Quick manual test you can call from your Settings menu.
///
/// It does NOT perform OAuth inside the app. OAuth must be completed in a browser
/// by visiting: baseUrl/oauth/google/start (once), because the server stores the token.
Future<void> testGmailClient(GmailClient client) async {
  debugPrint('[GmailTest] Starting Gmail client test...');
  // final client = GmailClient(baseUrl: "https://roadmate-flutter.onrender.com");
  
  try {
    // Typical voice-friendly default: unread emails from last 7 days.
    final resp = await client.searchStructured(
      unreadOnly: true,
      newerThanDays: 7,
      maxResults: 5,
    );

    debugPrint('[GmailTest] Server query used: ${resp.query}');
    debugPrint('[GmailTest] Emails returned: ${resp.results.length}');

    for (final e in resp.results) {
      debugPrint('---');
      debugPrint('ID: ${e.id}');
      debugPrint('FROM: ${e.from}');
      debugPrint('SUBJECT: ${e.subject}');
      debugPrint('DATE: ${e.date}');
      debugPrint('SNIPPET: ${e.snippet}');
    }

    debugPrint('[GmailTest] Done.');
  } catch (e) {
    debugPrint('[GmailTest] FAILED: $e');
    debugPrint('[GmailTest] If this is the first run, authorize Gmail in a browser:');
    final cid = client.clientId;
    final authUrl = (cid != null && cid.isNotEmpty)
        ? '${client.baseUrl}/oauth/google/start?client_id=$cid'
        : '${client.baseUrl}/oauth/google/start?client_id=<YOUR_CLIENT_ID>';
    debugPrint('[GmailTest]   $authUrl');
  }
}