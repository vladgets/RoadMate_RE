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
}
