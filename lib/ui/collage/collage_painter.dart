import 'package:flutter/material.dart';
import 'dart:ui' as ui;
import '../../models/collage_composition.dart';
import '../../services/collage_composer.dart';

class CollagePainter extends StatefulWidget {
  final CollageComposition composition;

  const CollagePainter({
    super.key,
    required this.composition,
  });

  @override
  State<CollagePainter> createState() => _CollagePainterState();
}

class _CollagePainterState extends State<CollagePainter> {
  ui.Image? _backgroundImage;
  List<ui.Image?> _photoImages = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadImages();
  }

  Future<void> _loadImages() async {
    try {
      // Load background (skip if URL is empty - will use gradient fallback)
      ui.Image? bg;
      if (widget.composition.backgroundUrl.isNotEmpty) {
        try {
          bg = await CollageComposer.instance.loadBackgroundFromUrl(
            widget.composition.backgroundUrl,
          );
        } catch (e) {
          // Background loading failed, will use gradient fallback
          bg = null;
        }
      }

      // Load photos
      final photos = <ui.Image?>[];
      for (final photo in widget.composition.photos) {
        final img = await CollageComposer.instance.loadPhotoFromAsset(photo.id);
        photos.add(img);
      }

      setState(() {
        _backgroundImage = bg;
        _photoImages = photos;
        _isLoading = false;
      });
    } catch (e) {
      // Handle error
      setState(() {
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return CustomPaint(
      painter: _CollagePainterImpl(
        backgroundImage: _backgroundImage,
        photoImages: _photoImages,
        composition: widget.composition,
      ),
      child: Container(),
    );
  }
}

class _CollagePainterImpl extends CustomPainter {
  final ui.Image? backgroundImage;
  final List<ui.Image?> photoImages;
  final CollageComposition composition;

  _CollagePainterImpl({
    required this.backgroundImage,
    required this.photoImages,
    required this.composition,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Draw background
    if (backgroundImage != null) {
      paintImage(
        canvas: canvas,
        rect: Rect.fromLTWH(0, 0, size.width, size.height),
        image: backgroundImage!,
        fit: BoxFit.cover,
      );
    } else {
      // Fallback: Draw gradient background
      final gradient = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color(int.parse('0xFF${composition.colors[0].substring(1)}')),
          Color(int.parse('0xFF${composition.colors[1].substring(1)}')),
          Color(int.parse('0xFF${composition.colors[2].substring(1)}')),
        ],
      );

      final paint = Paint()
        ..shader = gradient.createShader(
          Rect.fromLTWH(0, 0, size.width, size.height),
        );

      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        paint,
      );
    }

    // Draw photos
    for (int i = 0; i < photoImages.length && i < composition.photoSlots.length; i++) {
      final photo = photoImages[i];
      final slot = composition.photoSlots[i];

      if (photo == null) continue;

      canvas.save();

      // Calculate actual position and size
      final x = slot.position.dx * size.width;
      final y = slot.position.dy * size.height;
      final w = slot.size.width * size.width;
      final h = slot.size.height * size.height;

      // Translate to center of photo
      canvas.translate(x + w / 2, y + h / 2);

      // Rotate
      canvas.rotate(slot.rotation);

      // Draw photo (centered)
      final rect = Rect.fromLTWH(-w / 2, -h / 2, w, h);

      // Draw shadow
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(8)),
        Paint()
          ..color = Colors.black.withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );

      // Draw photo
      paintImage(
        canvas: canvas,
        rect: rect,
        image: photo,
        fit: BoxFit.cover,
      );

      canvas.restore();
    }

    // Draw text overlays
    for (int i = 0; i < composition.memories.length && i < composition.textSlots.length; i++) {
      final memory = composition.memories[i];
      final slot = composition.textSlots[i];

      // Parse theme colors for glow effect
      Color glowColor1 = _parseColor(composition.colors[0]);
      Color glowColor2 = composition.colors.length > 1
          ? _parseColor(composition.colors[1])
          : glowColor1;

      final textPainter = TextPainter(
        text: TextSpan(
          text: memory.transcription.length > 120
              ? '${memory.transcription.substring(0, 120)}...'
              : memory.transcription,
          style: TextStyle(
            color: Colors.white,
            fontSize: slot.fontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
            height: 1.5,
            fontFamily: slot.style == 'handwritten' ? 'Courier' : null,
            shadows: [
              // Outer glow (theme color 1)
              Shadow(
                color: glowColor1.withValues(alpha: 0.9),
                offset: const Offset(0, 0),
                blurRadius: 20,
              ),
              Shadow(
                color: glowColor1.withValues(alpha: 0.7),
                offset: const Offset(0, 0),
                blurRadius: 12,
              ),
              // Inner glow (theme color 2)
              Shadow(
                color: glowColor2.withValues(alpha: 0.8),
                offset: const Offset(0, 0),
                blurRadius: 8,
              ),
              // Strong black shadow for readability
              Shadow(
                color: Colors.black.withValues(alpha: 0.9),
                offset: const Offset(3, 3),
                blurRadius: 6,
              ),
              Shadow(
                color: Colors.black.withValues(alpha: 0.7),
                offset: const Offset(2, 2),
                blurRadius: 4,
              ),
              // Subtle white highlight
              Shadow(
                color: Colors.white.withValues(alpha: 0.3),
                offset: const Offset(-1, -1),
                blurRadius: 2,
              ),
            ],
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 4,
      );

      textPainter.layout(maxWidth: slot.maxWidth * size.width);

      final textX = slot.position.dx * size.width;
      final textY = slot.position.dy * size.height;

      // Paint the text with glow effect
      textPainter.paint(
        canvas,
        Offset(textX, textY),
      );
    }
  }

  // Helper to parse hex color strings
  Color _parseColor(String hex) {
    try {
      return Color(int.parse('0xFF${hex.substring(1)}'));
    } catch (e) {
      return Colors.blue; // Fallback color
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
