import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';

class FubClient {
  final String baseUrl;
  FubClient() : baseUrl = Config.serverUrl;

  Future<Map<String, dynamic>> getTasks({String? dueDate, String? agentName}) async {
    final params = <String, String>{};
    if (dueDate != null) params['dueDate'] = dueDate;
    if (agentName != null) params['agent'] = agentName;
    final uri = Uri.parse('$baseUrl/fub/tasks').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getRecentContacts({
    String? agentName,
    int limit = 5,
    int? days,
  }) async {
    final params = <String, String>{'limit': limit.toString()};
    if (agentName != null) params['agent'] = agentName;
    if (days != null) params['days'] = days.toString();
    final uri = Uri.parse('$baseUrl/fub/contacts/recent').replace(
      queryParameters: params,
    );
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
