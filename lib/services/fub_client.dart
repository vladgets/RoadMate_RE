import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';

class FubClient {
  final String baseUrl;
  FubClient() : baseUrl = Config.serverUrl;

  Future<Map<String, dynamic>> getTasks({String? dueDate}) async {
    final uri = Uri.parse('$baseUrl/fub/tasks').replace(
      queryParameters: dueDate != null ? {'dueDate': dueDate} : null,
    );
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
