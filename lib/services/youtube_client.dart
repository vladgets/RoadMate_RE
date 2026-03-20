import 'dart:convert';
import 'package:youtube_transcript_api/youtube_transcript_api.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';


/// A video from the user's YouTube subscriptions feed.
class YouTubeSubscriptionVideo {
  final String videoId;
  final String title;
  final String url;
  final DateTime publishedAt;

  YouTubeSubscriptionVideo({
    required this.videoId,
    required this.title,
    required this.url,
    required this.publishedAt,
  });

  factory YouTubeSubscriptionVideo.fromJson(Map<String, dynamic> j) {
    final publishedAtStr = (j['publishedAt'] ?? '') as String;
    return YouTubeSubscriptionVideo(
      videoId: (j['videoId'] ?? '') as String,
      title: (j['title'] ?? '') as String,
      url: (j['url'] ?? '') as String,
      publishedAt: publishedAtStr.isNotEmpty ? DateTime.tryParse(publishedAtStr) ?? DateTime.now() : DateTime.now(),
    );
  }
}

/// Server-side YouTube proxy client.
/// Uses the Node service that holds OAuth tokens.
class YouTubeClient {
  final String baseUrl;
  final String? clientId;

  const YouTubeClient({
    required this.baseUrl,
    required this.clientId,
  });

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Future<Map<String, String>> _headers() async {
    final h = <String, String>{
      'Content-Type': 'application/json',
    };
    if (clientId != null && clientId!.isNotEmpty) {
      h['X-Client-Id'] = clientId!;
    }
    return h;
  }

  /// Fetches videos from subscriptions feed (last 30 days).
  /// Throws on auth failure or server error.
  Future<List<YouTubeSubscriptionVideo>> getSubscriptionsFeed() async {
    final uri = _u('/youtube/subscriptions_feed');
    debugPrint('[YouTubeClient] getSubscriptionsFeed request: $uri');
    final r = await http.get(uri, headers: await _headers());
    final data = jsonDecode(r.body) as Map<String, dynamic>;
    debugPrint('[YouTubeClient] getSubscriptionsFeed response (${r.statusCode}): ${r.body}');

    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw Exception('YouTube feed failed (${r.statusCode}): ${data['error'] ?? r.body}');
    }

    final list = (data['videos'] as List? ?? []).whereType<Map>().toList();
    return list.map((m) => YouTubeSubscriptionVideo.fromJson(m.cast<String, dynamic>())).toList();
  }

  /// Tool wrapper for LLM/tool-calling usage.
  /// Returns plain JSON so it can be safely serialized over MCP/agent tools.
  Future<Map<String, dynamic>> getSubscriptionsFeedTool() async {
    // Get up to 50 videos for tool usage.
    final videos = (await getSubscriptionsFeed()).take(50).toList();

    return {
      'videos': videos
          .map((v) => {
                'videoId': v.videoId,
                'title': v.title,
                'url': v.url,
                'publishedAt': v.publishedAt.toIso8601String(),
              })
          .toList(),
    };
  }
}


/// Opens the YouTube app (if installed) or web browser to play the given video.
Future<void> openYoutubeVideo(
  String urlOrId, {
  int? startSeconds,
  bool autoplay = true,
}) async {
  final videoId = _extractVideoId(urlOrId);
  if (videoId == null || videoId.isEmpty) return;

  final start = startSeconds ?? 0;
  final auto = autoplay ? 1 : 0;

  final appUri = Uri.parse(
    'youtube://watch?v=$videoId&t=${start}s&autoplay=$auto',
  );

  final webUri = Uri.parse(
    'https://www.youtube.com/watch?v=$videoId&t=${start}s&autoplay=$auto',
  );

  if (await canLaunchUrl(appUri)) {
    await launchUrl(appUri);
  } else {
    await launchUrl(webUri, mode: LaunchMode.externalApplication);
  }
}

final _api = YouTubeTranscriptApi();

/// Fetches the full transcript text of a YouTube video by URL or ID.
Future<String?> getYoutubeTranscriptText(String urlOrId) async {
  try {
    final id = _extractVideoId(urlOrId);
    if (id == null) return null;

    final items = await _api.fetch(id);
    return items.map((e) => e.text).join(' ');
  } catch (_) {
    return null;
  }
}

String? _extractVideoId(String input) {
  final trimmed = input.trim();
  if (!trimmed.contains('http')) return trimmed.isEmpty ? null : trimmed;

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;

  if (uri.host.contains('youtu.be')) {
    return uri.pathSegments.first;
  }

  if (uri.queryParameters['v'] != null) {
    return uri.queryParameters['v'];
  }

  if (uri.pathSegments.length >= 2 &&
      (uri.pathSegments.first == 'shorts' ||
          uri.pathSegments.first == 'embed')) {
    return uri.pathSegments[1];
  }

  return null;
}


/// Tool to open a YouTube video by URL or ID.
Future<Map<String, dynamic>> openYoutubeVideoTool(Map<String, dynamic> args) async {
  final url = args['url'] as String?;
  if (url == null) {
    return {'error': 'Missing url'};
  }

  final startSeconds = (args['startSeconds'] as int?) ?? 0;
  final autoplay = true;

  try {
    await openYoutubeVideo(
      url,
      startSeconds: startSeconds,
      autoplay: autoplay,
    );
    return {'status': 'ok'};
  } catch (e) {
    return {'error': e.toString()};
  }
}
