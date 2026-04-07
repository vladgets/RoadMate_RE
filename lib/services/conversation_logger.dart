import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/chat_message.dart';

class ConversationLogger {
  static String get _platform {
    if (kIsWeb) return 'web';
    try {
      if (Platform.isIOS) return 'ios';
      if (Platform.isAndroid) return 'android';
      if (Platform.isMacOS) return 'macos';
    } catch (_) {}
    return 'unknown';
  }

  /// Upload the current session transcript to the server.
  /// Overwrites the file for this session if it already exists.
  static Future<void> upload({
    required String clientId,
    required String sessionStart,
    required List<ChatMessage> messages,
    String? agentName,
  }) async {
    if (messages.isEmpty) return;
    try {
      final uri = Uri.parse('${Config.serverUrl}/conversation/save');
      final body = jsonEncode({
        'client_id': clientId,
        'platform': _platform,
        'session_start': sessionStart,
        'agent_name': agentName,
        'messages': messages.map((m) => m.toJson()).toList(),
      });
      await http.post(uri, headers: {'Content-Type': 'application/json'}, body: body);
    } catch (_) {
      // Fail silently — logging should never break the app
    }
  }
}
