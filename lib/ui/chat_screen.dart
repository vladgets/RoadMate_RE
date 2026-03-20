import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:typed_data';
import 'dart:io';
import '../models/chat_message.dart';
import '../models/photo_attachment.dart';
import '../services/conversation_store.dart';
import '../services/openai_chat_client.dart';
import '../services/photo_capture_service.dart';
import 'main_settings_menu.dart';
import 'voice_memories_screen.dart';
import 'collage/photo_selection_screen.dart';
import 'widgets/session_list_drawer.dart';
import 'widgets/photo_viewer.dart';

class ChatScreen extends StatefulWidget {
  final ConversationStore conversationStore;
  final Future<Map<String, dynamic>> Function(String toolName, dynamic args)? toolExecutor;

  const ChatScreen({
    super.key,
    required this.conversationStore,
    this.toolExecutor,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoading = false;
  String? _errorMessage;
  late final OpenAIChatClient _chatClient;
  List<PhotoAttachment> _attachedPhotos = [];

  @override
  void initState() {
    super.initState();
    _chatClient = OpenAIChatClient();

    // Scroll to bottom when screen first loads (without animation)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom(animate: false);
    });

  }

  @override
  void dispose() {
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    final hasPhotos = _attachedPhotos.isNotEmpty;

    // Require either text or photos
    if ((text.isEmpty && !hasPhotos) || _isLoading) return;

    // Clear input
    _textController.clear();
    final photos = List<PhotoAttachment>.from(_attachedPhotos);
    setState(() {
      _attachedPhotos = []; // Clear preview
    });

    // Add user message (with photos if attached)
    final userMessage = hasPhotos
        ? ChatMessage.userWithPhotos(text.isEmpty ? '📷' : text, photos)
        : ChatMessage.userText(text);
    await widget.conversationStore.addMessageToActiveSession(userMessage);

    // Scroll to bottom
    _scrollToBottom();

    // If there's no text (only photos), don't call the API
    // Just add the message locally and return
    if (text.isEmpty) {
      setState(() {
        // Trigger rebuild to show the new message
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Get response from API
      final response = await _chatClient.sendMessage(
        widget.conversationStore.activeSession.messages,
        text,
        toolExecutor: widget.toolExecutor,
      );

      // Add assistant response (with photos if available)
      final assistantMessage = response.photos != null && response.photos!.isNotEmpty
          ? ChatMessage.assistantWithPhotos(response.text, response.photos!)
          : ChatMessage.assistant(response.text);
      await widget.conversationStore.addMessageToActiveSession(assistantMessage);

      setState(() {
        _isLoading = false;
      });

      // Scroll to bottom
      _scrollToBottom();
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error: $e';
      });
    }
  }

  void _scrollToBottom({bool animate = true}) {
    // Schedule scroll after current frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Use multiple delayed attempts to ensure we reach the bottom
      _attemptScroll(animate, attempts: 0);
    });
  }

  void _attemptScroll(bool animate, {required int attempts}) {
    if (!mounted || !_scrollController.hasClients || attempts >= 3) return;

    Future.delayed(Duration(milliseconds: 100 + (attempts * 50)), () {
      if (!mounted || !_scrollController.hasClients) return;

      final position = _scrollController.position;
      final target = position.maxScrollExtent;

      // Only scroll if we're not already at the bottom
      if ((position.pixels - target).abs() > 10) {
        if (animate && attempts == 0) {
          _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        } else {
          _scrollController.jumpTo(target);
        }

        // Try again after a short delay to ensure we reached the bottom
        if (attempts < 2) {
          _attemptScroll(false, attempts: attempts + 1);
        }
      }
    });
  }

  void _openVoiceMode() {
    // Pop back to Voice Mode
    Navigator.pop(context);
  }

  void _showPhotoOptions() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(context);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Select from Gallery'),
              onTap: () {
                Navigator.pop(context);
                _pickFromGallery();
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _takePhoto() async {
    final photos = await PhotoCaptureService.instance.takePhoto();
    if (photos != null && photos.isNotEmpty) {
      setState(() {
        _attachedPhotos.addAll(photos);
        // Limit to 10 photos
        if (_attachedPhotos.length > 10) {
          _attachedPhotos = _attachedPhotos.sublist(_attachedPhotos.length - 10);
        }
      });
    }
  }

  Future<void> _pickFromGallery() async {
    final photos = await PhotoCaptureService.instance.pickFromGallery();
    if (photos != null && photos.isNotEmpty) {
      setState(() {
        _attachedPhotos.addAll(photos);
        // Limit to 10 photos
        if (_attachedPhotos.length > 10) {
          _attachedPhotos = _attachedPhotos.sublist(_attachedPhotos.length - 10);
        }
      });
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _attachedPhotos.removeAt(index);
    });
  }

  Widget _buildPhotoPreviewRow() {
    return Container(
      height: 80,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: _attachedPhotos.length,
        itemBuilder: (context, index) {
          final photo = _attachedPhotos[index];
          return Container(
            width: 64,
            height: 64,
            margin: const EdgeInsets.only(right: 8),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _PhotoThumbnailWidget(
                    assetId: photo.id,
                    filePath: photo.path,
                    size: 64,
                  ),
                ),
                Positioned(
                  top: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: () => _removePhoto(index),
                    child: Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close,
                        size: 14,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final messages = widget.conversationStore.activeSession.messages;
    final sessionTitle = widget.conversationStore.activeSession.title;

    return Scaffold(
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            tooltip: 'Conversation History',
            onPressed: () {
              Scaffold.of(context).openDrawer();
            },
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Chat'),
            Text(
              sessionTitle,
              style: const TextStyle(fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library),
            tooltip: 'Create Photo Collage',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const PhotoSelectionScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.auto_stories),
            tooltip: 'Voice Notes',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const VoiceMemoriesScreen(),
                ),
              );
            },
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const SettingsScreen(),
                ),
              );
            },
          ),
        ],
      ),
      drawer: SessionListDrawer(
        conversationStore: widget.conversationStore,
        onSessionChanged: () {
          setState(() {
            // Rebuild to show new session's messages
          });
          _scrollToBottom(animate: false);
        },
      ),
      body: Column(
        children: [
          // Error banner
          if (_errorMessage != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              color: Colors.red.shade100,
              child: Row(
                children: [
                  Icon(Icons.error, color: Colors.red.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _errorMessage!,
                      style: TextStyle(color: Colors.red.shade700),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      setState(() {
                        _errorMessage = null;
                      });
                    },
                  ),
                ],
              ),
            ),

          // Messages list
          Expanded(
            child: messages.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.chat_bubble_outline,
                          size: 64,
                          color: Colors.grey.shade400,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No messages yet',
                          style: TextStyle(
                            fontSize: 18,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Start a conversation or use voice mode',
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade500,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      return _buildMessageBubble(message);
                    },
                  ),
          ),

          // Loading indicator
          if (_isLoading)
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Thinking...',
                    style: TextStyle(
                      color: Colors.grey.shade600,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ),
            ),

          // Input area
          Container(
            decoration: BoxDecoration(
              color: Colors.white,
              border: Border(
                top: BorderSide(color: Colors.grey.shade300),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Photo preview row (if photos attached)
                if (_attachedPhotos.isNotEmpty) _buildPhotoPreviewRow(),

                // Input row
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline),
                        onPressed: _isLoading ? null : _showPhotoOptions,
                        color: Colors.blue,
                        tooltip: 'Add photo',
                      ),
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          decoration: const InputDecoration(
                            hintText: 'Type message...',
                            border: InputBorder.none,
                          ),
                          maxLines: null,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _sendMessage(),
                          enabled: !_isLoading,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.mic),
                        onPressed: _openVoiceMode,
                        color: Colors.blue,
                        tooltip: 'Open voice mode',
                      ),
                      IconButton(
                        icon: const Icon(Icons.send),
                        onPressed: _sendMessage,
                        color: Colors.blue,
                        disabledColor: Colors.grey.shade400,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageBubble(ChatMessage message) {
    final isUser = message.role == 'user';
    final isVoice = message.type == 'voice_transcript';
    final hasPhotos = message.photos != null && message.photos!.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              backgroundColor: Colors.blue.shade100,
              child: Icon(Icons.smart_toy, size: 20, color: Colors.blue.shade700),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: isUser ? Colors.blue : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(18),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (isVoice)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.mic,
                            size: 14,
                            color: isUser ? Colors.white70 : Colors.grey.shade600,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Voice',
                            style: TextStyle(
                              fontSize: 12,
                              color: isUser ? Colors.white70 : Colors.grey.shade600,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  SelectableText(
                    message.content,
                    style: TextStyle(
                      color: isUser ? Colors.white : Colors.black87,
                      fontSize: 16,
                    ),
                  ),
                  if (hasPhotos) ...[
                    const SizedBox(height: 12),
                    _buildPhotoGallery(message.photos!),
                  ],
                ],
              ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              backgroundColor: Colors.blue.shade700,
              child: const Icon(Icons.person, size: 20, color: Colors.white),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPhotoGallery(List<PhotoAttachment> photos) {
    return SizedBox(
      height: 165, // thumbnail (140) + spacing (4) + label (11 * 1.5) ≈ 165
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: photos.length,
        itemBuilder: (context, index) {
          final photo = photos[index];
          return _buildPhotoWithLabel(photo, photos, index);
        },
      ),
    );
  }

  Widget _buildPhotoWithLabel(PhotoAttachment photo, List<PhotoAttachment> allPhotos, int index) {
    return Container(
      width: 140,
      margin: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Photo thumbnail
          GestureDetector(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => PhotoViewer(
                    photos: allPhotos,
                    initialIndex: index,
                  ),
                ),
              );
            },
            child: _PhotoThumbnailWidget(
              assetId: photo.id,
              filePath: photo.path,
              size: 140,
            ),
          ),
          const SizedBox(height: 4),
          // Date · City on one line
          if (photo.timestamp != null ||
              (photo.location != null && photo.location!.isNotEmpty))
            Text(
              [
                if (photo.timestamp != null)
                  DateFormat.MMMd().format(photo.timestamp!),
                if (photo.location != null && photo.location!.isNotEmpty)
                  photo.location!.split(',').first.trim(),
              ].join(' · '),
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey[700],
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}

/// Widget for displaying photo thumbnails using asset ID or file path
class _PhotoThumbnailWidget extends StatefulWidget {
  final String assetId;
  final String? filePath;
  final double size;

  const _PhotoThumbnailWidget({
    required this.assetId,
    this.filePath,
    this.size = 120,
  });

  @override
  State<_PhotoThumbnailWidget> createState() => _PhotoThumbnailWidgetState();
}

class _PhotoThumbnailWidgetState extends State<_PhotoThumbnailWidget> {
  Uint8List? _thumbnailData;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadThumbnail();
  }

  Future<void> _loadThumbnail() async {
    try {
      // Try to load as AssetEntity first
      final asset = await AssetEntity.fromId(widget.assetId);

      if (asset != null) {
        // Successfully loaded from AssetEntity
        final thumbnailData = await asset.thumbnailDataWithSize(
          const ThumbnailSize(200, 200),
        );

        if (mounted) {
          setState(() {
            _thumbnailData = thumbnailData;
            _isLoading = false;
          });
        }
        return;
      }

      // Asset not found - try to load from file path if provided
      if (widget.filePath != null) {
        final file = File(widget.filePath!);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          if (mounted) {
            setState(() {
              _thumbnailData = bytes;
              _isLoading = false;
            });
          }
          return;
        }
      }

      // Neither asset nor file path worked
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[300],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return const Center(
        child: SizedBox(
          width: 24,
          height: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    if (_hasError || _thumbnailData == null) {
      return const Center(
        child: Icon(Icons.broken_image, color: Colors.grey),
      );
    }

    return Image.memory(
      _thumbnailData!,
      fit: BoxFit.cover,
      errorBuilder: (context, error, stackTrace) {
        return const Center(
          child: Icon(Icons.broken_image, color: Colors.grey),
        );
      },
    );
  }
}
