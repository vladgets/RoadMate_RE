import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Persists spoken place names → address strings.
/// e.g. "home" → "123 Main St, New York, NY"
class PlaceAliasStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/place_aliases.json');
  }

  static Future<Map<String, String>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      final decoded = jsonDecode(raw) as Map;
      return decoded.map((k, v) => MapEntry(k as String, v as String));
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, String> data) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(data), flush: true);
  }

  /// Look up a place alias. Returns the address or null if not stored.
  static Future<String?> lookup(String alias) async {
    final data = await _read();
    return data[alias.toLowerCase().trim()];
  }

  /// Tool handler: save alias → address.
  static Future<Map<String, dynamic>> toolRemember(dynamic args) async {
    try {
      final alias = args is Map ? (args['alias'] as String?)?.trim() ?? '' : '';
      final address = args is Map ? (args['address'] as String?)?.trim() ?? '' : '';
      if (alias.isEmpty || address.isEmpty) {
        return {'ok': false, 'error': 'alias and address are both required'};
      }
      final data = await _read();
      data[alias.toLowerCase()] = address;
      await _write(data);
      return {'ok': true, 'saved': alias, 'address': address};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Tool handler: remove a place alias.
  static Future<Map<String, dynamic>> toolForget(dynamic args) async {
    try {
      final alias = args is Map ? (args['alias'] as String?)?.trim() ?? '' : '';
      if (alias.isEmpty) return {'ok': false, 'error': 'alias is required'};
      final data = await _read();
      final removed = data.remove(alias.toLowerCase()) != null;
      if (removed) await _write(data);
      return {'ok': removed, 'alias': alias};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Tool handler: list all saved place aliases.
  static Future<Map<String, dynamic>> toolList() async {
    try {
      final data = await _read();
      if (data.isEmpty) return {'ok': true, 'count': 0, 'places': []};
      final entries = data.entries
          .map((e) => {'alias': e.key, 'address': e.value})
          .toList();
      return {'ok': true, 'count': entries.length, 'places': entries};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  static Future<Map<String, String>> readAll() => _read();
}
