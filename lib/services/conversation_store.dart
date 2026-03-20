import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';
import '../models/chat_message.dart';
import '../models/conversation_session.dart';

/// Service for persisting chat conversation sessions
class ConversationStore {
  static const String _storageKey = 'conversation_sessions';
  static const String _legacyStorageKey = 'conversation_history';
  static const int _maxSessions = 10;
  static const int _maxMessagesPerSession = 500;

  final SharedPreferences _prefs;
  final Uuid _uuid = const Uuid();

  List<ConversationSession> _sessions = [];
  String? _activeSessionId;

  ConversationStore._(this._prefs);

  /// Initialize the store and load existing sessions
  static Future<ConversationStore> create() async {
    final prefs = await SharedPreferences.getInstance();
    final store = ConversationStore._(prefs);
    await store._load();
    return store;
  }

  /// Get the active session
  ConversationSession get activeSession {
    if (_activeSessionId == null || _sessions.isEmpty) {
      throw StateError('No active session. Call createNewSession() first.');
    }
    return _sessions.firstWhere(
      (session) => session.id == _activeSessionId,
      orElse: () => _sessions.first,
    );
  }

  /// Get all sessions sorted by last modified (most recent first)
  List<ConversationSession> get allSessions {
    final sorted = List<ConversationSession>.from(_sessions);
    sorted.sort((a, b) => b.lastModifiedAt.compareTo(a.lastModifiedAt));
    return List.unmodifiable(sorted);
  }

  /// Get the active session ID
  String? get activeSessionId => _activeSessionId;

  /// Check if there are any sessions
  bool get hasSessions => _sessions.isNotEmpty;

  /// Create a new session and make it active
  Future<void> createNewSession() async {
    final newSession = ConversationSession(
      id: _uuid.v4(),
      createdAt: DateTime.now(),
      lastModifiedAt: DateTime.now(),
      messages: [],
    );

    _sessions.add(newSession);
    _activeSessionId = newSession.id;

    await _prune();
    await _save();
  }

  /// Switch to a different session
  Future<void> switchToSession(String sessionId) async {
    final session = _sessions.firstWhere(
      (s) => s.id == sessionId,
      orElse: () => throw ArgumentError('Session not found: $sessionId'),
    );

    _activeSessionId = session.id;
    await _save();
  }

  /// Delete a session
  Future<void> deleteSession(String sessionId) async {
    _sessions.removeWhere((s) => s.id == sessionId);

    // If we deleted the active session, switch to most recent or create new
    if (_activeSessionId == sessionId) {
      if (_sessions.isNotEmpty) {
        final sorted = allSessions;
        _activeSessionId = sorted.first.id;
      } else {
        await createNewSession();
        return; // createNewSession already saves
      }
    }

    await _save();
  }

  /// Add a message to the active session
  Future<void> addMessageToActiveSession(ChatMessage message) async {
    if (_activeSessionId == null || _sessions.isEmpty) {
      await createNewSession();
    }

    final sessionIndex = _sessions.indexWhere((s) => s.id == _activeSessionId);
    if (sessionIndex == -1) {
      throw StateError('Active session not found');
    }

    final session = _sessions[sessionIndex];
    final updatedMessages = List<ChatMessage>.from(session.messages)..add(message);

    // Prune messages in this session if needed
    if (updatedMessages.length > _maxMessagesPerSession) {
      final excessCount = updatedMessages.length - _maxMessagesPerSession;
      updatedMessages.removeRange(0, excessCount);
    }

    _sessions[sessionIndex] = session.copyWith(
      messages: updatedMessages,
      lastModifiedAt: DateTime.now(),
    );

    await _save();
  }

  /// Add multiple messages to the active session
  Future<void> addMessagesToActiveSession(List<ChatMessage> messages) async {
    if (_activeSessionId == null || _sessions.isEmpty) {
      await createNewSession();
    }

    final sessionIndex = _sessions.indexWhere((s) => s.id == _activeSessionId);
    if (sessionIndex == -1) {
      throw StateError('Active session not found');
    }

    final session = _sessions[sessionIndex];
    final updatedMessages = List<ChatMessage>.from(session.messages)..addAll(messages);

    // Prune messages in this session if needed
    if (updatedMessages.length > _maxMessagesPerSession) {
      final excessCount = updatedMessages.length - _maxMessagesPerSession;
      updatedMessages.removeRange(0, excessCount);
    }

    _sessions[sessionIndex] = session.copyWith(
      messages: updatedMessages,
      lastModifiedAt: DateTime.now(),
    );

    await _save();
  }

  /// Update an existing message in the active session
  Future<void> updateMessageInActiveSession(String messageId, ChatMessage updatedMessage) async {
    if (_activeSessionId == null || _sessions.isEmpty) {
      return;
    }

    final sessionIndex = _sessions.indexWhere((s) => s.id == _activeSessionId);
    if (sessionIndex == -1) {
      return;
    }

    final session = _sessions[sessionIndex];
    final messageIndex = session.messages.indexWhere((msg) => msg.id == messageId);
    if (messageIndex == -1) {
      return;
    }

    final updatedMessages = List<ChatMessage>.from(session.messages);
    updatedMessages[messageIndex] = updatedMessage;

    _sessions[sessionIndex] = session.copyWith(
      messages: updatedMessages,
      lastModifiedAt: DateTime.now(),
    );

    await _save();
  }

  /// Clear all sessions
  Future<void> clearAllSessions() async {
    _sessions.clear();
    _activeSessionId = null;
    await _save();
    await createNewSession();
  }

  /// Get message count in active session
  int get activeSessionMessageCount {
    try {
      return activeSession.messages.length;
    } catch (e) {
      return 0;
    }
  }

  /// Load sessions from SharedPreferences
  Future<void> _load() async {
    try {
      // Check for legacy data and clear it
      if (_prefs.containsKey(_legacyStorageKey)) {
        await _prefs.remove(_legacyStorageKey);
      }

      final jsonString = _prefs.getString(_storageKey);
      if (jsonString == null || jsonString.isEmpty) {
        _sessions = [];
        _activeSessionId = null;
        return;
      }

      final Map<String, dynamic> data = json.decode(jsonString);
      _activeSessionId = data['active_session_id'] as String?;

      final List<dynamic> sessionsJson = data['sessions'] as List<dynamic>;
      _sessions = sessionsJson
          .map((json) => ConversationSession.fromJson(json as Map<String, dynamic>))
          .toList();

      // Validate active session exists
      if (_activeSessionId != null &&
          !_sessions.any((s) => s.id == _activeSessionId)) {
        _activeSessionId = _sessions.isNotEmpty ? _sessions.first.id : null;
      }
    } catch (e) {
      // Error loading conversation sessions - start fresh
      _sessions = [];
      _activeSessionId = null;
    }
  }

  /// Save sessions to SharedPreferences
  Future<void> _save() async {
    try {
      final data = {
        'active_session_id': _activeSessionId,
        'sessions': _sessions.map((session) => session.toJson()).toList(),
      };
      final jsonString = json.encode(data);
      await _prefs.setString(_storageKey, jsonString);
    } catch (e) {
      // Error saving conversation sessions - fail silently
    }
  }

  /// Prune old sessions if exceeding max limit
  Future<void> _prune() async {
    if (_sessions.length > _maxSessions) {
      // Sort by last modified and keep the most recent
      final sorted = List<ConversationSession>.from(_sessions);
      sorted.sort((a, b) => b.lastModifiedAt.compareTo(a.lastModifiedAt));

      // Remove excess sessions (oldest ones)
      final sessionsToRemove = sorted.sublist(_maxSessions);
      for (final session in sessionsToRemove) {
        _sessions.removeWhere((s) => s.id == session.id);
      }

      // If active session was removed, switch to most recent
      if (_activeSessionId != null &&
          !_sessions.any((s) => s.id == _activeSessionId)) {
        _activeSessionId = sorted.first.id;
      }
    }
  }
}
