import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

class MlsClient {
  final String baseUrl;
  final String? clientId;

  const MlsClient({required this.baseUrl, this.clientId});

  Uri _u(String path) => Uri.parse('$baseUrl$path');

  Map<String, String> _headers() => {
        'Content-Type': 'application/json',
        if (clientId != null && clientId!.isNotEmpty) 'X-Client-Id': clientId!,
      };

  Future<Map<String, dynamic>> searchProperty(String address) async {
    debugPrint('[MlsClient] searchProperty: $address');
    final r = await http.post(
      _u('/mls/search'),
      headers: _headers(),
      body: jsonEncode({'address': address}),
    );
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> sendDisclosure({
    required String toEmail,
    required String subject,
    required String body,
    String? docName,
    String? address,
  }) async {
    debugPrint('[MlsClient] sendDisclosure: to=$toEmail doc=$docName');
    final payload = <String, dynamic>{
      'to_email': toEmail,
      'subject': subject,
      'body': body,
      if (docName != null && docName.isNotEmpty) 'doc_name': docName,
      if (address != null && address.isNotEmpty) 'address': address,
    };
    final r = await http.post(
      _u('/mls/send_disclosure'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getListingUrl() async {
    debugPrint('[MlsClient] getListingUrl');
    final r = await http.post(_u('/mls/listing_url'), headers: _headers(), body: '{}');
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> getSessionCookies() async {
    debugPrint('[MlsClient] getSessionCookies');
    final r = await http.get(_u('/mls/session_cookies'), headers: _headers());
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> checkShowingTime({String? address}) async {
    debugPrint('[MlsClient] checkShowingTime: address=$address');
    final payload = <String, dynamic>{
      if (address != null && address.isNotEmpty) 'address': address,
    };
    final r = await http.post(
      _u('/mls/showingtime'),
      headers: _headers(),
      body: jsonEncode(payload),
    );
    return jsonDecode(r.body) as Map<String, dynamic>;
  }
}
