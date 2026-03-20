import 'photo_attachment.dart';

/// Model for chat messages in the conversation history
class ChatMessage {
  final String id;
  final String role; // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;
  final String type; // 'text', 'voice_transcript', or 'text_with_images'
  final String status; // 'sending', 'sent', 'error'
  final List<PhotoAttachment>? photos; // Optional photo attachments

  ChatMessage({
    required this.id,
    required this.role,
    required this.content,
    required this.timestamp,
    this.type = 'text',
    this.status = 'sent',
    this.photos,
  });

  /// Create a user text message
  factory ChatMessage.userText(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: content,
      timestamp: DateTime.now(),
      type: 'text',
      status: 'sent',
    );
  }

  /// Create a user voice transcript message
  factory ChatMessage.userVoice(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: content,
      timestamp: DateTime.now(),
      type: 'voice_transcript',
      status: 'sent',
    );
  }

  /// Create an assistant message
  factory ChatMessage.assistant(String content) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'assistant',
      content: content,
      timestamp: DateTime.now(),
      type: 'text',
      status: 'sent',
    );
  }

  /// Create a user message with photo attachments
  factory ChatMessage.userWithPhotos(String content, List<PhotoAttachment> photos) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'user',
      content: content,
      timestamp: DateTime.now(),
      type: 'text_with_images',
      status: 'sent',
      photos: photos,
    );
  }

  /// Create an assistant message with photo attachments
  factory ChatMessage.assistantWithPhotos(String content, List<PhotoAttachment> photos) {
    return ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      role: 'assistant',
      content: content,
      timestamp: DateTime.now(),
      type: 'text_with_images',
      status: 'sent',
      photos: photos,
    );
  }

  /// Create a copy with updated fields
  ChatMessage copyWith({
    String? id,
    String? role,
    String? content,
    DateTime? timestamp,
    String? type,
    String? status,
    List<PhotoAttachment>? photos,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      type: type ?? this.type,
      status: status ?? this.status,
      photos: photos ?? this.photos,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'role': role,
      'content': content,
      'timestamp': timestamp.toIso8601String(),
      'type': type,
      'status': status,
      'photos': photos?.map((p) => p.toJson()).toList(),
    };
  }

  /// Deserialize from JSON
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final photosList = json['photos'] as List<dynamic>?;
    return ChatMessage(
      id: json['id'] as String,
      role: json['role'] as String,
      content: json['content'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      type: json['type'] as String? ?? 'text',
      status: json['status'] as String? ?? 'sent',
      photos: photosList?.map((p) => PhotoAttachment.fromJson(p as Map<String, dynamic>)).toList(),
    );
  }

  @override
  String toString() {
    return 'ChatMessage(id: $id, role: $role, type: $type, content: ${content.substring(0, content.length > 50 ? 50 : content.length)}...)';
  }
}
