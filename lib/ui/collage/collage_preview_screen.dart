import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:io';
import '../../models/collage_composition.dart';
import '../../services/collage_composer.dart';
import 'collage_painter.dart';

class CollagePreviewScreen extends StatefulWidget {
  final CollageComposition composition;
  final bool usedFallback;

  const CollagePreviewScreen({
    super.key,
    required this.composition,
    this.usedFallback = false,
  });

  @override
  State<CollagePreviewScreen> createState() => _CollagePreviewScreenState();
}

class _CollagePreviewScreenState extends State<CollagePreviewScreen> {
  final GlobalKey _repaintBoundaryKey = GlobalKey();
  bool _isExporting = false;

  Future<void> _shareCollage() async {
    setState(() {
      _isExporting = true;
    });

    try {
      // Export to PNG
      final pngBytes = await CollageComposer.instance.exportToPng(
        _repaintBoundaryKey,
      );

      // Save to temp directory
      final tempDir = await getTemporaryDirectory();
      final file = File('${tempDir.path}/collage_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes);

      // Share
      await Share.shareXFiles(
        [XFile(file.path)],
        text: 'Check out my photo collage!',
      );

      // Clean up
      Future.delayed(const Duration(seconds: 5), () {
        if (file.existsSync()) {
          file.delete();
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to share: $e')),
        );
      }
    } finally {
      setState(() {
        _isExporting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your Collage'),
        actions: [
          if (widget.usedFallback)
            const Padding(
              padding: EdgeInsets.only(right: 8),
              child: Chip(
                label: Text('Fallback Template'),
                backgroundColor: Colors.orange,
              ),
            ),
          IconButton(
            icon: _isExporting
                ? const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.share),
            onPressed: _isExporting ? null : _shareCollage,
          ),
        ],
      ),
      body: Center(
        child: RepaintBoundary(
          key: _repaintBoundaryKey,
          child: CollagePainter(
            composition: widget.composition,
          ),
        ),
      ),
    );
  }
}
