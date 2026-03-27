import 'package:shared_preferences/shared_preferences.dart';

// Web-compatible memory store using SharedPreferences (localStorage).

class MemoryStore {
  static const _key = 'roadmate_memory';

  static Future<String> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? '';
  }

  static Future<void> writeAll(String text) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, _normalize(text));
  }

  static Future<void> appendLine(String text) async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_key) ?? '';
    final line = _sanitizeOneLine(text);
    await prefs.setString(_key, existing.isEmpty ? '$line\n' : '$existing$line\n');
  }

  static Future<void> overwrite(String text) async {
    await writeAll(text);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }

  static String _normalize(String text) {
    var s = text.replaceAll('\r\n', '\n');
    if (s.trim().isNotEmpty && !s.endsWith('\n')) s = '$s\n';
    return s;
  }

  static String _sanitizeOneLine(String s) {
    var x = s.replaceAll('\r', ' ').replaceAll('\n', ' ');
    x = x.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (x.isEmpty) return '(empty)';
    if (x.length > 500) x = x.substring(0, 500).trimRight();
    return x;
  }

  static Future<Map<String, dynamic>> toolAppend(dynamic args) async {
    final text = (args is Map && args['text'] is String)
        ? args['text'] as String
        : '';
    await appendLine(text);
    return {'ok': true, 'stored': _sanitizeOneLine(text)};
  }

  static Future<Map<String, dynamic>> toolRead() async {
    final text = await readAll();
    final lines = text.isEmpty
        ? 0
        : text.split('\n').where((l) => l.trim().isNotEmpty).length;
    return {'text': text, 'lines': lines, 'bytes': text.codeUnits.length};
  }
}

class PreferencesStore {
  static const _key = 'roadmate_preferences';

  static Future<String> readAll() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_key) ?? '';
  }

  static Future<void> writeAll(String text) async {
    final prefs = await SharedPreferences.getInstance();
    var s = text.replaceAll('\r\n', '\n');
    if (s.trim().isNotEmpty && !s.endsWith('\n')) s = '$s\n';
    await prefs.setString(_key, s);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}
