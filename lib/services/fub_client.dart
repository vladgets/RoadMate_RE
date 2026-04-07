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

  Future<Map<String, dynamic>> searchContacts({
    required String query,
    String? agentName,
    int limit = 10,
  }) async {
    final params = <String, String>{'q': query, 'limit': limit.toString()};
    if (agentName != null) params['agent'] = agentName;
    final uri = Uri.parse('$baseUrl/fub/contacts/search').replace(
      queryParameters: params,
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

  Future<Map<String, dynamic>> createNote({
    required String agentName,
    required String body,
    int? personId,
    String? clientName,
  }) async {
    final uri = Uri.parse('$baseUrl/fub/note');
    final payload = <String, dynamic>{
      'agent': agentName,
      'body': body,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendText({
    required String agentName,
    required String message,
    int? personId,
    String? clientName,
  }) async {
    final uri = Uri.parse('$baseUrl/fub/text');
    final body = <String, dynamic>{
      'agent': agentName,
      'message': message,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
