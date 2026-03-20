import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:typed_data';

/// A reusable thumbnail widget for displaying photos
class PhotoThumbnail extends StatefulWidget {
  final String assetId;
  final VoidCallback? onTap;
  final double size;

  const PhotoThumbnail({
    super.key,
    required this.assetId,
    this.onTap,
    this.size = 120,
  });

  @override
  State<PhotoThumbnail> createState() => _PhotoThumbnailState();
}

class _PhotoThumbnailState extends State<PhotoThumbnail> {
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
      final asset = await AssetEntity.fromId(widget.assetId);
      if (asset == null) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
        return;
      }

      final thumbnailData = await asset.thumbnailDataWithSize(
        const ThumbnailSize(200, 200),
      );

      if (mounted) {
        setState(() {
          _thumbnailData = thumbnailData;
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
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        width: widget.size,
        height: widget.size,
        margin: const EdgeInsets.only(right: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: Colors.grey[300],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _buildContent(),
        ),
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
