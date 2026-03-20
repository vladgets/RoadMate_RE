import 'dart:io';
import 'package:android_intent_plus/android_intent.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:url_launcher/url_launcher.dart';


/// Support direct phone calls on Android with permission handling.
/// On iOS, falls back to opening the dialer.
Future<void> callNumber(String phoneNumber) async {
  if (!Platform.isAndroid) {
    // iOS fallback: always opens dialer
    final uri = Uri(scheme: 'tel', path: phoneNumber);
    await launchUrl(uri, mode: LaunchMode.externalApplication);
    return;
  }

  final status = await Permission.phone.status;
  if (!status.isGranted) {
    final result = await Permission.phone.request();
    if (!result.isGranted) {
      throw Exception('Phone call permission denied');
    }
  }

  final intent = AndroidIntent(
    action: 'android.intent.action.CALL',
    data: 'tel:$phoneNumber',
  );

  await intent.launch();
}

/// Handle the LLM tool call for `call_phone`.
/// Returns a structured map for tool compatibility.
Future<Map<String, dynamic>> handlePhoneCallTool(Map<String, dynamic> args) async {
  final raw = args["phone_number"];
  final phone = (raw is String) ? raw.trim() : '';
  final contactName = args["contact_name"] is String ? (args["contact_name"] as String).trim() : '';

  if (phone.isEmpty) {
    return {
      "ok": false,
      "error": "Missing phone_number",
    };
  }

  try {
    await callNumber(phone);
    return {
      "ok": true,
      "status": "calling",
      "phone_number": phone,
      "contact_name": contactName,
    };
  } catch (e) {
    return {
      "ok": false,
      "error": e.toString(),
    };
  }
}

