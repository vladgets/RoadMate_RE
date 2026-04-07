import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
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
  /// Resolves clientId from SharedPreferences if not provided.
  /// Overwrites the file for this session if it already exists.
  static Future<void> upload({
    String? clientId,
    required String sessionStart,
    required List<ChatMessage> messages,
    String? agentName,
  }) async {
    if (messages.isEmpty) return;
    try {
      // Resolve clientId from SharedPreferences if not passed in
      String? cid = clientId;
      if (cid == null || cid.isEmpty) {
        final prefs = await SharedPreferences.getInstance();
        cid = prefs.getString(Config.prefKeyClientId);
      }
      if (cid == null || cid.isEmpty) return;

      // Config.serverUrl is '' on web — use absolute URL via Uri.base
      final base = Config.serverUrl.isNotEmpty
          ? Config.serverUrl
          : '${Uri.base.scheme}://${Uri.base.host}${Uri.base.port != 80 && Uri.base.port != 443 ? ":${Uri.base.port}" : ""}';
      final uri = Uri.parse('$base/conversation/save');
      final body = jsonEncode({
        'client_id': cid,
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
