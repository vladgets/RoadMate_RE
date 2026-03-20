import 'package:flutter/material.dart';
import 'photo_attachment.dart';
import 'voice_memory.dart';

class CollageComposition {
  final String backgroundUrl;
  final List<PhotoAttachment> photos;
  final List<VoiceMemory> memories;
  final List<CollagePhotoSlot> photoSlots;
  final List<CollageTextSlot> textSlots;
  final String theme;
  final List<String> colors;
  final String layoutStyle;

  CollageComposition({
    required this.backgroundUrl,
    required this.photos,
    required this.memories,
    required this.photoSlots,
    required this.textSlots,
    required this.theme,
    required this.colors,
    required this.layoutStyle,
  });
}

class CollagePhotoSlot {
  final Offset position; // Normalized 0-1
  final Size size; // Normalized 0-1
  final double rotation; // Radians

  CollagePhotoSlot({
    required this.position,
    required this.size,
    required this.rotation,
  });
}

class CollageTextSlot {
  final Offset position; // Normalized 0-1
  final double maxWidth; // Normalized 0-1
  final double fontSize;
  final Color color;
  final String style; // 'handwritten' | 'modern'

  CollageTextSlot({
    required this.position,
    required this.maxWidth,
    required this.fontSize,
    required this.color,
    required this.style,
  });
}
