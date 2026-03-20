import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/photo_attachment.dart';
import '../models/voice_memory.dart';

class CollageApiClient {
  static final CollageApiClient instance = CollageApiClient._();
  CollageApiClient._();

  Future<CollageBackgroundResponse> generateBackground({
    required List<PhotoAttachment> photos,
    required List<VoiceMemory> memories,
    String style = 'scrapbook',
  }) async {
    final url = Uri.parse('${Config.serverUrl}/collage/generate-background');

    final response = await http.post(
      url,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'photos': photos.map((p) => {
          'location': p.location,
          'timestamp': p.timestamp?.toIso8601String(),
          'latitude': p.latitude,
          'longitude': p.longitude,
        }).toList(),
        'memories': memories.map((m) => {
          'transcription': m.transcription,
          'location': m.address,
          'timestamp': m.createdAt.toIso8601String(),
        }).toList(),
        'style': style,
      }),
    );

    if (response.statusCode != 200) {
      throw Exception('Failed to generate background: ${response.statusCode}');
    }

    final data = jsonDecode(response.body);
    return CollageBackgroundResponse.fromJson(data);
  }
}

class CollageBackgroundResponse {
  final bool ok;
  final String? backgroundUrl;
  final bool fallback;
  final Map<String, dynamic>? template;
  final String theme;
  final List<String> colors;
  final String? prompt;

  CollageBackgroundResponse({
    required this.ok,
    this.backgroundUrl,
    this.fallback = false,
    this.template,
    required this.theme,
    required this.colors,
    this.prompt,
  });

  factory CollageBackgroundResponse.fromJson(Map<String, dynamic> json) {
    return CollageBackgroundResponse(
      ok: json['ok'] ?? false,
      backgroundUrl: json['background_url'],
      fallback: json['fallback'] ?? false,
      template: json['template'],
      theme: json['theme'] ?? 'nature',
      colors: List<String>.from(json['colors'] ?? []),
      prompt: json['prompt'],
    );
  }
}
