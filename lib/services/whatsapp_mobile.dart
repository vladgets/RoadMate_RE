import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../models/whatsapp_contact.dart';
import 'memory_store.dart';
import 'photo_index_service.dart';
import 'whatsapp_baileys_service.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Service for sending WhatsApp messages via voice commands.
class WhatsAppService {
  static final WhatsAppService instance = WhatsAppService._();
  WhatsAppService._();

  /// Main tool handler for sending WhatsApp messages.
  ///
  /// Parameters:
  /// - contact_name (required): Name to lookup in memory
  /// - message (required): Text to send
  /// - photo_location (optional): Location to find photo
  /// - photo_time (optional): Time period for photo
  /// - include_sender_name (optional): Prepend sender name to message
  Future<Map<String, dynamic>> toolSendWhatsAppMessage(dynamic args) async {
    try {
      final contactName = args['contact_name'] as String?;
      final message = args['message'] as String?;
      final photoLocation = args['photo_location'] as String?;
      final photoTime = args['photo_time'] as String?;
      final photoLimit = (args['photo_limit'] as num?)?.toInt() ?? 1;
      final includeSenderName = args['include_sender_name'] as bool? ?? false;

      final screenshotPath = args['screenshot_path'] as String?;

      // Validate required parameters
      if (contactName == null || contactName.isEmpty) {
        return {
          'status': 'error',
          'message': 'Contact name is required',
        };
      }

      if (message == null || message.isEmpty) {
        return {
          'status': 'error',
          'message': 'Message text is required',
        };
      }

      // Find contact in memory
      final contact = await _findContact(contactName);
      if (contact == null) {
        return {
          'status': 'error',
          'message': 'Could not find $contactName\'s WhatsApp in memory. '
              'Please save it first by saying "remember $contactName\'s WhatsApp is +[phone number]"',
        };
      }

      // Compose final message text
      String finalMessage = message;
      if (includeSenderName) {
        final senderName = await _getSenderName();
        if (senderName != null && senderName.isNotEmpty) {
          finalMessage = 'From $senderName: $message';
        }
      }

      // Check if Baileys auto-send is available (account paired on server).
      final baileysStatus = await WhatsAppBaileysService.instance.getStatus();
      final autoSend = baileysStatus.connected;

      // Resolve image: screenshot takes priority, then photo album search.
      String? imagePath = screenshotPath;
      List<String>? photoPaths;
      if (imagePath == null && (photoLocation != null || photoTime != null)) {
        photoPaths = await _findPhotos(photoLocation, photoTime, photoLimit.clamp(1, 10));
        if (photoPaths != null && photoPaths.isNotEmpty) {
          imagePath = photoPaths.first;
        }
      }

      // Clean phone number for all paths
      final cleanPhone = contact.phoneNumber.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');

      // ── Auto-send path (Baileys connected) ──────────────────────────────
      if (autoSend) {
        final sent = await WhatsAppBaileysService.instance.send(
          phone: cleanPhone,
          message: finalMessage,
          imagePath: imagePath,
        );
        if (sent) {
          final hasImage = imagePath != null;
          final imageDesc = screenshotPath != null ? 'screenshot' : 'photo';
          return {
            'status': 'success',
            'message': hasImage
                ? 'WhatsApp message with $imageDesc sent automatically to ${contact.name}.'
                : 'WhatsApp message sent automatically to ${contact.name}.',
            'contact': contact.name,
            'phone': contact.phoneNumber,
            'auto_sent': true,
          };
        }
        // Baileys send failed — fall through to manual path.
      }

      // ── Manual path (fallback: open WhatsApp) ───────────────────────────
      final allPhotoPaths = [
        if (screenshotPath != null) screenshotPath,
        ...?photoPaths,
      ];
      if (allPhotoPaths.isNotEmpty) {
        final success = await _sendWithPhotos(contact.phoneNumber, finalMessage, allPhotoPaths);
        if (success) {
          final count = allPhotoPaths.length;
          return {
            'status': 'success',
            'message': 'Share sheet opened with ${count == 1 ? 'your photo' : '$count photos'} and message. '
                'Select WhatsApp and choose ${contact.name} to send.',
            'contact': contact.name,
            'phone': contact.phoneNumber,
            'has_photo': true,
            'photo_count': count,
          };
        }
        // Fallback to text-only if photo share failed.
      }

      final textSuccess = await _sendTextOnly(contact.phoneNumber, finalMessage);
      if (textSuccess) {
        return {
          'status': 'success',
          'message': 'WhatsApp opened with your message to ${contact.name}. '
              'Please tap Send to confirm.',
          'contact': contact.name,
          'phone': contact.phoneNumber,
          'has_photo': false,
        };
      }

      return {
        'status': 'error',
        'message': 'Could not send WhatsApp message. Is WhatsApp installed?',
      };
    } catch (e) {
      return {
        'status': 'error',
        'message': 'Failed to send WhatsApp message: $e',
      };
    }
  }

  /// Find WhatsApp contact in memory by name.
  Future<WhatsAppContact?> _findContact(String query) async {
    try {
      final memoryData = await MemoryStore.toolRead();
      final memoryText = memoryData['text'] as String? ?? '';
      final lines = memoryText.split('\n');

      final queryLower = query.toLowerCase();

      // First pass: exact match
      for (final line in lines) {
        final contact = WhatsAppContact.fromMemoryLine(line);
        if (contact != null && contact.name.toLowerCase() == queryLower) {
          return contact;
        }
      }

      // Second pass: contains match
      for (final line in lines) {
        final contact = WhatsAppContact.fromMemoryLine(line);
        if (contact != null && contact.name.toLowerCase().contains(queryLower)) {
          return contact;
        }
      }

      return null;
    } catch (e) {
      // debugPrint('Error finding WhatsApp contact: $e');
      return null;
    }
  }

  /// Get sender name from preferences.
  Future<String?> _getSenderName() async {
    try {
      final prefsText = await PreferencesStore.readAll();
      final lines = prefsText.split('\n');

      for (final line in lines) {
        if (line.toLowerCase().contains('sender_name_for_whatsapp:')) {
          final parts = line.split(':');
          if (parts.length >= 2) {
            return parts[1].trim();
          }
        }
      }

      return null;
    } catch (e) {
      // debugPrint('Error getting sender name: $e');
      return null;
    }
  }

  /// Find photos by location and/or time. Returns up to [limit] temp file paths.
  Future<List<String>?> _findPhotos(String? location, String? timePeriod, int limit) async {
    try {
      final results = await PhotoIndexService.instance.searchPhotos(
        location: location,
        timePeriod: timePeriod,
        limit: limit,
      );

      if (results.isEmpty) return null;

      final tempDir = await getTemporaryDirectory();
      final paths = <String>[];
      final now = DateTime.now().millisecondsSinceEpoch;

      for (var i = 0; i < results.length; i++) {
        final asset = await AssetEntity.fromId(results[i].id);
        if (asset == null) continue;
        final file = await asset.file;
        if (file == null) continue;
        final tempPath = '${tempDir.path}/whatsapp_${now}_$i.jpg';
        await file.copy(tempPath);
        paths.add(tempPath);
      }

      return paths.isEmpty ? null : paths;
    } catch (e) {
      // debugPrint('Error finding photos: $e');
      return null;
    }
  }

  /// Send text-only message via WhatsApp URL scheme.
  Future<bool> _sendTextOnly(String phoneNumber, String message) async {
    try {
      // Clean phone number (remove spaces, dashes, etc.)
      final cleanPhone = phoneNumber.replaceAll(RegExp(r'[\s\-\(\)]'), '');

      // Try native WhatsApp URL scheme first
      final nativeUri = Uri.parse(
          'whatsapp://send?phone=$cleanPhone&text=${Uri.encodeComponent(message)}');

      if (await canLaunchUrl(nativeUri)) {
        return await launchUrl(nativeUri, mode: LaunchMode.externalApplication);
      }

      // Fallback to web link
      final webUri = Uri.parse(
          'https://wa.me/$cleanPhone?text=${Uri.encodeComponent(message)}');

      return await launchUrl(webUri, mode: LaunchMode.externalApplication);
    } catch (e) {
      // debugPrint('Error sending text-only WhatsApp: $e');
      return false;
    }
  }

  /// Send message with one or more photos via share intent.
  /// Note: Due to platform limitations, we can't pre-select WhatsApp or recipient.
  /// User will need to choose WhatsApp and select recipient from share sheet.
  Future<bool> _sendWithPhotos(String phoneNumber, String message, List<String> photoPaths) async {
    try {
      final result = await Share.shareXFiles(
        photoPaths.map((p) => XFile(p)).toList(),
        text: message,
      );

      // Clean up temp files after a delay
      Future.delayed(const Duration(seconds: 5), () {
        for (final path in photoPaths) {
          try {
            final file = File(path);
            if (file.existsSync()) file.delete();
          } catch (e) {
            // Silent fail
          }
        }
      });

      return result.status != ShareResultStatus.dismissed;
    } catch (e) {
      // debugPrint('Error sending WhatsApp with photos: $e');
      for (final path in photoPaths) {
        try {
          final file = File(path);
          if (file.existsSync()) file.delete();
        } catch (e) {
          // Silent fail
        }
      }
      return false;
    }
  }
}
