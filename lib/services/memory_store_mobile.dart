import 'dart:io';
import 'package:path_provider/path_provider.dart';

class _LocalTextFile {
  final String fileName;
  const _LocalTextFile(this.fileName);

  Future<File> file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$fileName');
  }

  Future<bool> exists() async {
    final f = await file();
    return f.exists();
  }

  Future<String> readAll({String ifMissing = ''}) async {
    final f = await file();
    if (!await f.exists()) return ifMissing;
    return f.readAsString();
  }

  Future<void> writeAll(String text) async {
    final f = await file(); 

    // Normalize Windows CRLF to LF for consistency
    var normalized = text.replaceAll('\r\n', '\n');

    // Ensure trailing newline if file is not empty
    if (normalized.trim().isNotEmpty && !normalized.endsWith('\n')) {
      normalized = '$normalized\n';
    }

    await f.writeAsString(normalized, mode: FileMode.write, flush: true);
  }

  Future<void> appendLine(String line) async {
    final f = await file();
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
  }

  Future<void> clear() async {
    final f = await file();
    if (await f.exists()) {
      await f.writeAsString('', mode: FileMode.write, flush: true);
    }
  }
}

class MemoryStore {
  static const _LocalTextFile _store = _LocalTextFile('roadmate_memory.txt');

  static Future<String> readAll() async {
    return _store.readAll(ifMissing: '');
  }

  /// Overwrite the entire memory file with the provided text.
  /// Normalizes line endings and ensures a trailing newline when non-empty.
  static Future<void> writeAll(String text) async {
    await _store.writeAll(text);
  }

  static Future<void> appendLine(String text) async {
    final line = _sanitizeOneLine(text);
    await _store.appendLine(line);
  }

  static Future<void> overwrite(String text) async {
    final f = await _store.file();
    await f.writeAsString(text, mode: FileMode.write, flush: true);
  }

  static Future<void> clear() async {
    await _store.clear();
  }

  static String _sanitizeOneLine(String s) {
    var x = s.replaceAll('\r', ' ').replaceAll('\n', ' ');
    x = x.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (x.isEmpty) return '(empty)';
    if (x.length > 500) x = x.substring(0, 500).trimRight();
    return x;
  }

  /// Tool-compatible wrapper: append a fact into memory
  /// Expected args: { "text": "..." }
  static Future<Map<String, dynamic>> toolAppend(dynamic args) async {
    final text = (args is Map && args['text'] is String)
        ? args['text'] as String
        : '';

    await appendLine(text);

    return {
      'ok': true,
      'stored': _sanitizeOneLine(text),
    };
  }

  /// Tool-compatible wrapper: read full memory contents
  static Future<Map<String, dynamic>> toolRead() async {
    final text = await readAll();

    final lines = text.isEmpty
        ? 0
        : text.split('\n').where((l) => l.trim().isNotEmpty).length;

    return {
      'text': text,
      'lines': lines,
      'bytes': text.codeUnits.length,
    };
  }
}

class PreferencesStore {
  static const _LocalTextFile _store = _LocalTextFile('roadmate_preferences.txt');

  /// Returns the preferences text; if the file doesn't exist yet, returns an empty string.
  static Future<String> readAll() async {
    return _store.readAll(ifMissing: '');
  }

  /// Overwrite the entire preferences file with the provided text.
  /// Normalizes line endings and ensures a trailing newline when non-empty.
  static Future<void> writeAll(String text) async {
    await _store.writeAll(text);
  }

  static Future<void> clear() async {
    await _store.clear();
  }
}

