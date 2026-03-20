import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart';
import '../models/collage_composition.dart';
import '../models/photo_attachment.dart';
import '../models/voice_memory.dart';

class CollageComposer {
  static final CollageComposer instance = CollageComposer._();
  CollageComposer._();

  /// Load background image from URL
  Future<ui.Image> loadBackgroundFromUrl(String url) async {
    final response = await http.get(Uri.parse(url));
    if (response.statusCode != 200) {
      throw Exception('Failed to load background image');
    }

    final bytes = response.bodyBytes;
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Load photo from AssetEntity
  Future<ui.Image?> loadPhotoFromAsset(String assetId) async {
    final asset = await AssetEntity.fromId(assetId);
    if (asset == null) return null;

    final bytes = await asset.thumbnailDataWithSize(
      const ThumbnailSize(800, 800),
    );
    if (bytes == null) return null;

    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Generate collage composition with layout algorithm
  CollageComposition generateComposition({
    required String backgroundUrl,
    required List<PhotoAttachment> photos,
    required List<VoiceMemory> memories,
    required String theme,
    required List<String> colors,
    String layoutStyle = 'scrapbook',
  }) {
    // Generate photo slots based on count
    final photoSlots = _generatePhotoSlots(photos.length, layoutStyle);

    // Generate text slots for memories
    final textSlots = _generateTextSlots(memories.length, layoutStyle);

    return CollageComposition(
      backgroundUrl: backgroundUrl,
      photos: photos,
      memories: memories,
      photoSlots: photoSlots,
      textSlots: textSlots,
      theme: theme,
      colors: colors,
      layoutStyle: layoutStyle,
    );
  }

  /// Scrapbook layout: overlapping, rotated photos
  List<CollagePhotoSlot> _generatePhotoSlots(int count, String style) {
    if (style == 'scrapbook') {
      return _scrapbookLayout(count);
    } else if (style == 'magazine') {
      return _magazineLayout(count);
    } else {
      return _gridLayout(count);
    }
  }

  List<CollagePhotoSlot> _scrapbookLayout(int count) {
    // Non-overlapping layout with slight rotation for visual interest
    final slots = <CollagePhotoSlot>[];

    if (count == 2) {
      slots.add(CollagePhotoSlot(
        position: const Offset(0.1, 0.12),
        size: const Size(0.8, 0.35),
        rotation: -0.02, // -1 degree
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.1, 0.52),
        size: const Size(0.8, 0.35),
        rotation: 0.02, // 1 degree
      ));
    } else if (count == 3) {
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.08),
        size: const Size(0.9, 0.26),
        rotation: -0.015,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.37),
        size: const Size(0.9, 0.26),
        rotation: 0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.66),
        size: const Size(0.9, 0.26),
        rotation: -0.01,
      ));
    } else if (count == 4) {
      // 2x2 grid with slight rotation
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.08),
        size: const Size(0.42, 0.36),
        rotation: -0.015,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.53, 0.08),
        size: const Size(0.42, 0.36),
        rotation: 0.015,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.48),
        size: const Size(0.42, 0.36),
        rotation: 0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.53, 0.48),
        size: const Size(0.42, 0.36),
        rotation: -0.01,
      ));
    } else if (count == 5) {
      // 2 + 3 layout
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.08),
        size: const Size(0.42, 0.28),
        rotation: -0.015,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.53, 0.08),
        size: const Size(0.42, 0.28),
        rotation: 0.015,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.40),
        size: const Size(0.28, 0.22),
        rotation: 0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.36, 0.40),
        size: const Size(0.28, 0.22),
        rotation: -0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.67, 0.40),
        size: const Size(0.28, 0.22),
        rotation: 0.01,
      ));
    } else if (count >= 6) {
      // 3x2 grid
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.08),
        size: const Size(0.28, 0.26),
        rotation: -0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.36, 0.08),
        size: const Size(0.28, 0.26),
        rotation: 0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.67, 0.08),
        size: const Size(0.28, 0.26),
        rotation: -0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.37),
        size: const Size(0.28, 0.26),
        rotation: 0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.36, 0.37),
        size: const Size(0.28, 0.26),
        rotation: -0.01,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.67, 0.37),
        size: const Size(0.28, 0.26),
        rotation: 0.01,
      ));
    }

    return slots;
  }

  List<CollagePhotoSlot> _magazineLayout(int count) {
    // Hero photo + smaller supporting images
    final slots = <CollagePhotoSlot>[];

    // Hero photo (large, top)
    slots.add(CollagePhotoSlot(
      position: const Offset(0.1, 0.08),
      size: const Size(0.8, 0.45),
      rotation: 0.0,
    ));

    // Smaller photos below
    if (count >= 2) {
      slots.add(CollagePhotoSlot(
        position: const Offset(0.1, 0.58),
        size: const Size(0.35, 0.25),
        rotation: 0.0,
      ));
    }
    if (count >= 3) {
      slots.add(CollagePhotoSlot(
        position: const Offset(0.55, 0.58),
        size: const Size(0.35, 0.25),
        rotation: 0.0,
      ));
    }

    return slots;
  }

  List<CollagePhotoSlot> _gridLayout(int count) {
    // Even grid, no rotation
    final slots = <CollagePhotoSlot>[];

    if (count == 2) {
      slots.add(CollagePhotoSlot(
        position: const Offset(0.1, 0.15),
        size: const Size(0.8, 0.35),
        rotation: 0.0,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.1, 0.55),
        size: const Size(0.8, 0.35),
        rotation: 0.0,
      ));
    } else if (count == 4) {
      // 2x2 grid
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.1),
        size: const Size(0.42, 0.35),
        rotation: 0.0,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.53, 0.1),
        size: const Size(0.42, 0.35),
        rotation: 0.0,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.05, 0.5),
        size: const Size(0.42, 0.35),
        rotation: 0.0,
      ));
      slots.add(CollagePhotoSlot(
        position: const Offset(0.53, 0.5),
        size: const Size(0.42, 0.35),
        rotation: 0.0,
      ));
    }

    return slots;
  }

  List<CollageTextSlot> _generateTextSlots(int count, String style) {
    final slots = <CollageTextSlot>[];

    if (count >= 1) {
      slots.add(CollageTextSlot(
        position: const Offset(0.05, 0.85),
        maxWidth: 0.9,
        fontSize: 20,
        color: Colors.white,
        style: style == 'scrapbook' ? 'handwritten' : 'modern',
      ));
    }

    return slots;
  }

  /// Export collage to PNG file
  Future<Uint8List> exportToPng(
    GlobalKey repaintBoundaryKey,
  ) async {
    final boundary = repaintBoundaryKey.currentContext!.findRenderObject()
        as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }
}
