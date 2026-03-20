import 'chat_message.dart';

/// Model for a conversation session containing multiple messages
class ConversationSession {
  final String id;
  final DateTime createdAt;
  final DateTime lastModifiedAt;
  final List<ChatMessage> messages;

  ConversationSession({
    required this.id,
    required this.createdAt,
    required this.lastModifiedAt,
    required this.messages,
  });

  /// Get a human-readable title from the first message
  String get title {
    if (messages.isEmpty) {
      return 'New Chat';
    }
    final firstMessage = messages.first;
    final maxLength = 30;
    if (firstMessage.content.length <= maxLength) {
      return firstMessage.content;
    }
    return '${firstMessage.content.substring(0, maxLength)}...';
  }

  /// Get a preview from the last message
  String get preview {
    if (messages.isEmpty) {
      return 'No messages yet';
    }
    final lastMessage = messages.last;
    final maxLength = 50;
    if (lastMessage.content.length <= maxLength) {
      return lastMessage.content;
    }
    return '${lastMessage.content.substring(0, maxLength)}...';
  }

  /// Get a relative or absolute timestamp for display
  String get displayTime {
    final now = DateTime.now();
    final difference = now.difference(lastModifiedAt);

    if (difference.inMinutes < 1) {
      return 'Just now';
    } else if (difference.inHours < 1) {
      final minutes = difference.inMinutes;
      return '$minutes ${minutes == 1 ? 'minute' : 'minutes'} ago';
    } else if (difference.inDays < 1) {
      final hours = difference.inHours;
      return '$hours ${hours == 1 ? 'hour' : 'hours'} ago';
    } else if (difference.inDays < 7) {
      final days = difference.inDays;
      return '$days ${days == 1 ? 'day' : 'days'} ago';
    } else {
      // Format as "Feb 5, 2:30 PM"
      final hour = lastModifiedAt.hour > 12
          ? lastModifiedAt.hour - 12
          : lastModifiedAt.hour == 0
              ? 12
              : lastModifiedAt.hour;
      final period = lastModifiedAt.hour >= 12 ? 'PM' : 'AM';
      final minute = lastModifiedAt.minute.toString().padLeft(2, '0');
      final months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      return '${months[lastModifiedAt.month - 1]} ${lastModifiedAt.day}, $hour:$minute $period';
    }
  }

  /// Create a copy with updated fields
  ConversationSession copyWith({
    String? id,
    DateTime? createdAt,
    DateTime? lastModifiedAt,
    List<ChatMessage>? messages,
  }) {
    return ConversationSession(
      id: id ?? this.id,
      createdAt: createdAt ?? this.createdAt,
      lastModifiedAt: lastModifiedAt ?? this.lastModifiedAt,
      messages: messages ?? this.messages,
    );
  }

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'created_at': createdAt.toIso8601String(),
      'last_modified_at': lastModifiedAt.toIso8601String(),
      'messages': messages.map((msg) => msg.toJson()).toList(),
    };
  }

  /// Deserialize from JSON
  factory ConversationSession.fromJson(Map<String, dynamic> json) {
    return ConversationSession(
      id: json['id'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      lastModifiedAt: DateTime.parse(json['last_modified_at'] as String),
      messages: (json['messages'] as List<dynamic>)
          .map((msgJson) => ChatMessage.fromJson(msgJson as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  String toString() {
    return 'ConversationSession(id: $id, createdAt: $createdAt, messages: ${messages.length})';
  }
}
