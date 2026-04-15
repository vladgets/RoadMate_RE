import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';

class FubClient {
  final String baseUrl;
  FubClient() : baseUrl = Config.serverUrl;

  /// Returns an error map if no agent is configured, null otherwise.
  Map<String, dynamic>? _noAgentError() {
    if (Config.fubAgentId == null) {
      return {
        'ok': false,
        'error': 'No CRM agent selected. Please open Settings → CRM Identity and select your name first.',
      };
    }
    return null;
  }

  /// Adds agent identity params to a query map.
  /// Prefers agent_id (unambiguous) over agent name.
  void _addAgent(Map<String, String> params, {int? agentId, String? agentName}) {
    if (agentId != null) {
      params['agent_id'] = agentId.toString();
    } else if (agentName != null) {
      params['agent'] = agentName;
    }
  }

  /// Adds agent identity fields to a JSON body map.
  void _addAgentToBody(Map<String, dynamic> body, {int? agentId, String? agentName}) {
    if (agentId != null) {
      body['agent_id'] = agentId;
    } else if (agentName != null) {
      body['agent'] = agentName;
    }
  }

  Future<Map<String, dynamic>> createTask({
    required String description,
    required String dueDate,
    required String taskType,
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/task');
    final body = <String, dynamic>{
      'description': description,
      'due_date': dueDate,
      'task_type': taskType,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    _addAgentToBody(body, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateTask({
    required int taskId,
    String? description,
    String? dueDate,
    String? taskType,
    bool? isCompleted,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/task/$taskId');
    final body = <String, dynamic>{
      if (description != null) 'description': description,
      if (dueDate != null) 'due_date': dueDate,
      if (taskType != null) 'task_type': taskType,
      if (isCompleted != null) 'is_completed': isCompleted,
    };
    final resp = await http.put(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPersonTasks({
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
    String status = 'all',
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final params = <String, String>{'status': status};
    if (personId != null) params['person_id'] = personId.toString();
    if (clientName != null) params['client_name'] = clientName;
    _addAgent(params, agentId: agentId, agentName: agentName);
    final uri = Uri.parse('$baseUrl/fub/person-tasks').replace(queryParameters: params);
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getTasks({
    String? dueDate,
    String? agentName,
    int? agentId,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final params = <String, String>{};
    if (dueDate != null) params['dueDate'] = dueDate;
    _addAgent(params, agentId: agentId, agentName: agentName);
    final uri = Uri.parse('$baseUrl/fub/tasks').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> searchContacts({
    required String query,
    String? agentName,
    int? agentId,
    int limit = 10,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final params = <String, String>{'q': query, 'limit': limit.toString()};
    _addAgent(params, agentId: agentId, agentName: agentName);
    final uri = Uri.parse('$baseUrl/fub/contacts/search').replace(
      queryParameters: params,
    );
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getRecentContacts({
    String? agentName,
    int? agentId,
    int limit = 5,
    int? days,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final params = <String, String>{'limit': limit.toString()};
    _addAgent(params, agentId: agentId, agentName: agentName);
    if (days != null) params['days'] = days.toString();
    final uri = Uri.parse('$baseUrl/fub/contacts/recent').replace(
      queryParameters: params,
    );
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createNote({
    required String body,
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/note');
    final payload = <String, dynamic>{
      'body': body,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    _addAgentToBody(payload, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updatePerson({
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
    String? stage,
    String? name,
    String? backgroundInfo,
    String? source,
    String? lender,
    String? assignedTo,
    Map<String, dynamic>? collaborators,
    Map<String, dynamic>? tags,
    List<Map<String, dynamic>>? phones,
    List<Map<String, dynamic>>? emails,
    Map<String, dynamic>? address,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/contact/update');
    final body = <String, dynamic>{
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
      if (stage != null) 'stage': stage,
      if (name != null) 'name': name,
      if (backgroundInfo != null) 'background_info': backgroundInfo,
      if (source != null) 'source': source,
      if (lender != null) 'lender': lender,
      if (assignedTo != null) 'assigned_to': assignedTo,
      if (collaborators != null) 'collaborators': collaborators,
      if (tags != null) 'tags': tags,
      if (phones != null) 'phones': phones,
      if (emails != null) 'emails': emails,
      if (address != null) 'address': address,
    };
    _addAgentToBody(body, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getPersonDetails({
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final params = <String, String>{};
    if (personId != null) params['person_id'] = personId.toString();
    if (clientName != null) params['client_name'] = clientName;
    _addAgent(params, agentId: agentId, agentName: agentName);
    final uri = Uri.parse('$baseUrl/fub/contact/details').replace(queryParameters: params.isEmpty ? null : params);
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSources() async {
    final uri = Uri.parse('$baseUrl/fub/sources');
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateTags({
    required String mode,
    required List<String> tags,
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/contact/tags');
    final body = <String, dynamic>{
      'mode': mode,
      'tags': tags,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    _addAgentToBody(body, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getLenders() async {
    final uri = Uri.parse('$baseUrl/fub/lenders');
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getStages() async {
    final uri = Uri.parse('$baseUrl/fub/stages');
    final resp = await http.get(uri);
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> updateStage({
    required String stage,
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/contact/stage');
    final body = <String, dynamic>{
      'stage': stage,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    _addAgentToBody(body, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> createAppointment({
    required String title,
    required String start,
    String? end,
    String? location,
    String? description,
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/appointment');
    final body = <String, dynamic>{
      'title': title,
      'start': start,
      if (end != null) 'end': end,
      if (location != null) 'location': location,
      if (description != null) 'description': description,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    _addAgentToBody(body, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendText({
    required String message,
    String? agentName,
    int? agentId,
    int? personId,
    String? clientName,
  }) async {
    final err = _noAgentError(); if (err != null) return err;
    final uri = Uri.parse('$baseUrl/fub/text');
    final body = <String, dynamic>{
      'message': message,
      if (personId != null) 'person_id': personId,
      if (clientName != null) 'client_name': clientName,
    };
    _addAgentToBody(body, agentId: agentId, agentName: agentName);
    final resp = await http.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(body),
    );
    return jsonDecode(resp.body) as Map<String, dynamic>;
  }
}
