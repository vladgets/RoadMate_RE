import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Persists spoken-name → contact mappings so the model doesn't need to
/// re-disambiguate or re-ask for aliases across sessions.
///
/// Stored as JSON: { "mom": {"name": "Jane Smith", "phone": "+1..."}, ... }
/// Keys are lowercased for case-insensitive lookup.
class ContactAliasStore {
  static Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/contact_aliases.json');
  }

  static Future<Map<String, dynamic>> _read() async {
    try {
      final f = await _file();
      if (!await f.exists()) return {};
      final raw = await f.readAsString();
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return {};
    }
  }

  static Future<void> _write(Map<String, dynamic> data) async {
    final f = await _file();
    await f.writeAsString(jsonEncode(data), flush: true);
  }

  /// Look up an alias. Returns {name, phone} or null if not stored.
  static Future<Map<String, String>?> lookup(String alias) async {
    final data = await _read();
    final entry = data[alias.toLowerCase().trim()];
    if (entry == null) return null;
    return {'name': entry['name'] as String, 'phone': entry['phone'] as String};
  }

  /// Tool handler: save alias → {name, phone}.
  static Future<Map<String, dynamic>> toolRemember(dynamic args) async {
    try {
      final alias = args is Map ? (args['alias'] as String?)?.trim() ?? '' : '';
      final name = args is Map ? (args['name'] as String?)?.trim() ?? '' : '';
      final phone = args is Map ? (args['phone'] as String?)?.trim() ?? '' : '';
      if (alias.isEmpty || name.isEmpty || phone.isEmpty) {
        return {'ok': false, 'error': 'alias, name, and phone are all required'};
      }
      final data = await _read();
      data[alias.toLowerCase()] = {'name': name, 'phone': phone};
      await _write(data);
      return {'ok': true, 'saved': alias, 'name': name, 'phone': phone};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Tool handler: list all saved aliases (for user awareness).
  static Future<Map<String, dynamic>> toolList() async {
    try {
      final data = await _read();
      if (data.isEmpty) return {'ok': true, 'count': 0, 'aliases': []};
      final entries = data.entries.map((e) => {
        'alias': e.key,
        'name': (e.value as Map)['name'],
        'phone': (e.value as Map)['phone'],
      }).toList();
      return {'ok': true, 'count': entries.length, 'aliases': entries};
    } catch (e) {
      return {'ok': false, 'error': e.toString()};
    }
  }

  /// Tool handler: remove an alias.
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
}
