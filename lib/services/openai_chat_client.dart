import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config.dart';
import '../models/chat_message.dart';
import '../models/photo_attachment.dart';

/// Response from chat API with optional photo attachments
class ChatResponse {
  final String text;
  final List<PhotoAttachment>? photos;

  ChatResponse(this.text, {this.photos});
}

/// Client for OpenAI Chat Completions API (text-based chat)
class OpenAIChatClient {
  OpenAIChatClient();

  /// Send a chat message and get a response
  /// Returns the assistant's response (text and optional photos)
  /// Throws exception on error
  Future<ChatResponse> sendMessage(
    List<ChatMessage> conversationHistory,
    String newMessage, {
    Future<Map<String, dynamic>> Function(String toolName, dynamic args)? toolExecutor,
  }) async {
    // Build messages array for API
    final messages = [
      {
        'role': 'system',
        'content': Config.systemPromptTemplate
            .replaceAll('{{CURRENT_DATE_READABLE}}', _getCurrentDate()),
      },
      // Add conversation history (limit to last 20 messages for context)
      ...conversationHistory
          .take(conversationHistory.length > 20 ? 20 : conversationHistory.length)
          .map((msg) => {
                'role': msg.role,
                'content': msg.content,
              }),
      // Add new message
      {
        'role': 'user',
        'content': newMessage,
      },
    ];

    // Transform tools from Realtime API format to Chat Completions API format
    final chatTools = Config.tools.map((tool) {
      return {
        'type': 'function',
        'function': {
          'name': tool['name'],
          'description': tool['description'],
          'parameters': tool['parameters'],
        },
      };
    }).toList();

    // Make API call via server proxy
    final response = await http.post(
      Uri.parse('${Config.serverUrl}/chat'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'model': 'gpt-4o-mini',
        'messages': messages,
        'tools': chatTools,
        'tool_choice': 'auto',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Chat API error: ${response.statusCode} ${response.body}');
    }

    final data = json.decode(response.body);
    final choice = data['choices'][0];

    // Check if assistant wants to call tools
    if (choice['message']['tool_calls'] != null) {
      return await _handleToolCalls(
        choice['message']['tool_calls'],
        messages,
        chatTools,
        toolExecutor,
      );
    }

    // Return assistant's text response
    return ChatResponse(choice['message']['content'] as String? ?? '');
  }

  /// Handle tool calls from assistant
  Future<ChatResponse> _handleToolCalls(
    List<dynamic> toolCalls,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> chatTools,
    Future<Map<String, dynamic>> Function(String toolName, dynamic args)? toolExecutor,
  ) async {
    // Execute all tool calls
    final toolMessages = <Map<String, dynamic>>[];
    List<PhotoAttachment>? photos;

    for (final toolCall in toolCalls) {
      final toolCallId = toolCall['id'] as String;
      final functionName = toolCall['function']['name'] as String;
      final argumentsJson = toolCall['function']['arguments'] as String;
      final arguments = json.decode(argumentsJson);

      // Execute tool if executor is provided
      Map<String, dynamic> result;
      if (toolExecutor != null) {
        try {
          result = await toolExecutor(functionName, arguments);

          // Check if this is a search_photos result
          if (functionName == 'search_photos' &&
              result['ok'] == true &&
              result['photos'] != null) {
            final photosList = result['photos'] as List<dynamic>;
            photos = photosList.map((p) => PhotoAttachment(
              id: p['id'] as String,
              path: p['path'] as String,
              location: p['location'] as String?,
              timestamp: p['timestamp'] != null
                ? DateTime.parse(p['timestamp'] as String)
                : null,
              latitude: p['latitude'] as double?,
              longitude: p['longitude'] as double?,
            )).toList();
          }
        } catch (e) {
          result = {'error': e.toString()};
        }
      } else {
        result = {'error': 'Tool execution not available'};
      }

      // For photo results, send only the count to the model — not individual
      // photo details (timestamps, paths, coordinates). The thumbnails already
      // show all that; giving it to the model causes it to repeat every date
      // in the message text.
      final resultForModel = (functionName == 'search_photos' &&
              result['ok'] == true &&
              result['photos'] is List)
          ? {
              'ok': true,
              'count': (result['photos'] as List).length,
              if (result['query'] != null && (result['query'] as String).isNotEmpty)
                'query': result['query'],
              if (result['message'] != null) 'message': result['message'],
            }
          : result;

      toolMessages.add({
        'role': 'tool',
        'tool_call_id': toolCallId,
        'content': json.encode(resultForModel),
      });
    }

    // Make follow-up API call with tool results
    final followUpMessages = [
      ...messages,
      {
        'role': 'assistant',
        'tool_calls': toolCalls,
      },
      ...toolMessages,
    ];

    final response = await http.post(
      Uri.parse('${Config.serverUrl}/chat'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: json.encode({
        'model': 'gpt-4o-mini',
        'messages': followUpMessages,
        'tools': chatTools,
        'tool_choice': 'auto',
      }),
    );

    if (response.statusCode != 200) {
      throw Exception(
          'Chat API error (tool follow-up): ${response.statusCode} ${response.body}');
    }

    final data = json.decode(response.body);
    final choice = data['choices'][0];

    // Check if the assistant wants to make more tool calls
    if (choice['message']['tool_calls'] != null) {
      // Recursively handle more tool calls
      return await _handleToolCalls(
        choice['message']['tool_calls'],
        followUpMessages,
        chatTools,
        toolExecutor,
      );
    }

    return ChatResponse(
      choice['message']['content'] as String? ?? '',
      photos: photos,
    );
  }

  String _getCurrentDate() {
    final now = DateTime.now();
    final weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday'
    ];
    final months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return '${weekdays[now.weekday - 1]}, ${months[now.month - 1]} ${now.day}, ${now.year}';
  }
}
