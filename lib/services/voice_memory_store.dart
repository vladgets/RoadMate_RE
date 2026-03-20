import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/voice_memory.dart';
import 'geo_time_tools.dart';
import 'time_period_parser.dart';

/// Singleton service for storing and searching voice memories.
/// Follows the same patterns as RemindersService and PhotoIndexService.
class VoiceMemoryStore {
  VoiceMemoryStore._();
  static final VoiceMemoryStore instance = VoiceMemoryStore._();

  static const String _storageKey = 'voice_memories_v1';
  static const int _maxMemories = 200;
  static const _uuid = Uuid();

  List<VoiceMemory> _memories = [];
  bool _initialized = false;

  /// Initialize service and load existing memories
  Future<void> init() async {
    if (_initialized) return;
    await _load();
    _initialized = true;
    debugPrint('[VoiceMemoryStore] Initialized with ${_memories.length} memories');
  }

  /// All memories sorted newest-first
  List<VoiceMemory> get allMemories => List.unmodifiable(_memories);

  /// Create a new memory with current location
  Future<VoiceMemory> createMemory({required String transcription}) async {
    await init();

    // Get current location (best-effort, non-blocking)
    double? lat;
    double? lon;
    String? address;

    try {
      final locResult = await getBestEffortBackgroundLocation();
      if (locResult['ok'] == true) {
        lat = locResult['lat'] as double?;
        lon = locResult['lon'] as double?;
        final addr = locResult['address'];
        if (addr is Map) {
          final parts = <String>[];
          if (addr['city'] != null && (addr['city'] as String).isNotEmpty) {
            parts.add(addr['city'] as String);
          }
          if (addr['state'] != null && (addr['state'] as String).isNotEmpty) {
            parts.add(addr['state'] as String);
          }
          if (addr['country'] != null && (addr['country'] as String).isNotEmpty) {
            parts.add(addr['country'] as String);
          }
          if (parts.isNotEmpty) address = parts.join(', ');
        }
      }
    } catch (e) {
      debugPrint('[VoiceMemoryStore] Location fetch failed: $e');
    }

    final memory = VoiceMemory(
      id: _uuid.v4(),
      transcription: transcription,
      createdAt: DateTime.now(),
      latitude: lat,
      longitude: lon,
      address: address,
    );

    _memories.insert(0, memory);

    // Auto-prune oldest if over limit
    if (_memories.length > _maxMemories) {
      _memories = _memories.sublist(0, _maxMemories);
    }

    await _save();
    debugPrint('[VoiceMemoryStore] Created memory: ${memory.id}');
    return memory;
  }

  /// Update the transcription text of a memory
  Future<void> editMemory(String memoryId, String newTranscription) async {
    await init();
    final i = _memories.indexWhere((m) => m.id == memoryId);
    if (i == -1) return;
    _memories[i] = _memories[i].copyWith(transcription: newTranscription);
    await _save();
  }

  /// Link photo asset IDs to a memory (replaces any existing links)
  Future<void> linkPhotos(String memoryId, List<String> photoIds) async {
    await init();
    final i = _memories.indexWhere((m) => m.id == memoryId);
    if (i == -1) return;
    _memories[i] = _memories[i].copyWith(linkedPhotoIds: photoIds);
    await _save();
  }

  /// Delete a memory by ID
  Future<bool> deleteMemory(String id) async {
    await init();
    final before = _memories.length;
    _memories.removeWhere((m) => m.id == id);
    if (_memories.length < before) {
      await _save();
      return true;
    }
    return false;
  }

  /// Search by text (case-insensitive substring on transcription)
  List<VoiceMemory> searchByText(String query) {
    final q = query.toLowerCase();
    return _memories.where((m) =>
      m.transcription.toLowerCase().contains(q)
    ).toList();
  }

  /// Search by location (case-insensitive substring on address)
  List<VoiceMemory> searchByLocation(String location) {
    final q = location.toLowerCase();
    return _memories.where((m) {
      if (m.address == null) return false;
      return m.address!.toLowerCase().contains(q);
    }).toList();
  }

  /// Search by time period
  List<VoiceMemory> searchByTime(String timePeriod) {
    final range = TimePeriodParser.parse(timePeriod);
    if (range == null) return [];

    return _memories.where((m) =>
      m.createdAt.isAfter(range.start) && m.createdAt.isBefore(range.end)
    ).toList();
  }

  /// Combined search with intersection
  List<VoiceMemory> search({
    String? text,
    String? location,
    String? timePeriod,
    int limit = 5,
  }) {
    List<VoiceMemory> results = List.from(_memories);

    if (text != null && text.isNotEmpty) {
      final textResults = searchByText(text).map((m) => m.id).toSet();
      results = results.where((m) => textResults.contains(m.id)).toList();
    }

    if (location != null && location.isNotEmpty) {
      final locResults = searchByLocation(location).map((m) => m.id).toSet();
      results = results.where((m) => locResults.contains(m.id)).toList();
    }

    if (timePeriod != null && timePeriod.isNotEmpty) {
      final timeResults = searchByTime(timePeriod).map((m) => m.id).toSet();
      results = results.where((m) => timeResults.contains(m.id)).toList();
    }

    // Already sorted newest-first from _memories order
    if (results.length > limit) {
      results = results.sublist(0, limit);
    }

    return results;
  }

  // ---- Tool handlers ----

  /// Tool handler for save_voice_memory
  Future<Map<String, dynamic>> toolSaveMemory(dynamic args) async {
    await init();

    final a = _parseArgs(args);
    final text = (a['text'] ?? '').toString().trim();

    if (text.isEmpty) {
      return {'ok': false, 'error': 'Missing "text" parameter'};
    }

    final memory = await createMemory(transcription: text);
    return {
      'ok': true,
      'memory': {
        'id': memory.id,
        'address': memory.address,
        'created_at': memory.createdAt.toIso8601String(),
      },
      'message': 'Memory saved successfully${memory.address != null ? ' at ${memory.address}' : ''}.',
    };
  }

  /// Tool handler for search_voice_memories
  Future<Map<String, dynamic>> toolSearchMemories(dynamic args) async {
    await init();

    final a = _parseArgs(args);
    final text = a['text'] as String?;
    final location = a['location'] as String?;
    final timePeriod = a['time_period'] as String?;
    final limit = (a['limit'] as int?) ?? 5;

    final results = search(
      text: text,
      location: location,
      timePeriod: timePeriod,
      limit: limit,
    );

    if (results.isEmpty) {
      return {
        'ok': true,
        'memories': [],
        'count': 0,
        'message': 'No voice memories found matching your criteria.',
      };
    }

    return {
      'ok': true,
      'memories': results.map((m) => {
        'id': m.id,
        'transcription': m.transcription,
        'created_at': m.createdAt.toIso8601String(),
        'address': m.address,
      }).toList(),
      'count': results.length,
    };
  }

  // ---- Internal ----

  Map<String, dynamic> _parseArgs(dynamic args) {
    if (args == null) return {};
    if (args is Map<String, dynamic>) return args;
    if (args is Map) return args.cast<String, dynamic>();
    if (args is String && args.trim().isNotEmpty) {
      return jsonDecode(args) as Map<String, dynamic>;
    }
    return {};
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.trim().isEmpty) {
        _memories = [];
        return;
      }

      final decoded = jsonDecode(raw);
      if (decoded is! List) {
        _memories = [];
        return;
      }

      _memories = decoded
          .whereType<Map>()
          .map((m) => VoiceMemory.fromJson(m.cast<String, dynamic>()))
          .toList();

      // Ensure newest-first ordering
      _memories.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (e) {
      debugPrint('[VoiceMemoryStore] Failed to load: $e');
      _memories = [];
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final encoded = jsonEncode(_memories.map((m) => m.toJson()).toList());
      await prefs.setString(_storageKey, encoded);
    } catch (e) {
      debugPrint('[VoiceMemoryStore] Failed to save: $e');
    }
  }
}
