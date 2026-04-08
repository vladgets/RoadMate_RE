import 'dart:convert';
import 'package:http/http.dart' as http;

/// HTTP client for reading Google Drive files via the RoadMate server proxy.
class GDriveClient {
  final String baseUrl;
  final String? clientId;

  const GDriveClient({required this.baseUrl, this.clientId});

  Map<String, String> _headers() {
    final h = <String, String>{'Content-Type': 'application/json'};
    if (clientId != null && clientId!.isNotEmpty) h['X-Client-Id'] = clientId!;
    return h;
  }

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  /// Read the text content of a Drive file (PDF, Google Doc, Google Sheet).
  /// Returns a map with: ok, file_name, mime_type, text, char_count, truncated.
  Future<Map<String, dynamic>> readFile({
    required String fileId,
    int? maxChars,
  }) async {
    final params = <String, String>{'file_id': fileId};
    if (maxChars != null) params['max_chars'] = maxChars.toString();

    final uri = _u('/drive/read_file').replace(queryParameters: params);
    try {
      final r = await http.get(uri, headers: _headers());
      final body = jsonDecode(r.body) as Map<String, dynamic>;
      if (r.statusCode != 200) {
        return {'ok': false, 'error': body['error'] ?? 'HTTP ${r.statusCode}'};
      }
      return body;
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Tool-compatible wrapper called by the AI.
  Future<Map<String, dynamic>> toolReadDriveFile(dynamic args) async {
    if (args is! Map) return {'ok': false, 'error': 'Invalid arguments'};
    final fileId = args['file_id'] as String?;
    if (fileId == null || fileId.isEmpty) {
      return {'ok': false, 'error': 'file_id is required'};
    }
    final maxChars = args['max_chars'] as int?;
    return readFile(fileId: fileId, maxChars: maxChars);
  }
}
