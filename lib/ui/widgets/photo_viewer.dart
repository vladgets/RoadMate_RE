import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:photo_manager/photo_manager.dart';
import 'dart:typed_data';
import 'dart:io';
import '../../models/photo_attachment.dart';

/// Full-screen photo viewer with swipe navigation
class PhotoViewer extends StatefulWidget {
  final List<PhotoAttachment> photos;
  final int initialIndex;

  const PhotoViewer({
    super.key,
    required this.photos,
    this.initialIndex = 0,
  });

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

class _PhotoViewerState extends State<PhotoViewer> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Photo viewer with swipe navigation
          PageView.builder(
            controller: _pageController,
            itemCount: widget.photos.length,
            onPageChanged: (index) {
              setState(() {
                _currentIndex = index;
              });
            },
            itemBuilder: (context, index) {
              final photo = widget.photos[index];
              return Center(
                child: InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 4.0,
                  child: _FullSizePhotoWidget(
                    assetId: photo.id,
                    filePath: photo.path,
                  ),
                ),
              );
            },
          ),

          // Top bar with close button and counter
          SafeArea(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.6),
                    Colors.transparent,
                  ],
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Text(
                    '${_currentIndex + 1} / ${widget.photos.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 48), // Balance the close button
                ],
              ),
            ),
          ),

          // Bottom info overlay
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildPhotoInfo(widget.photos[_currentIndex]),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoInfo(PhotoAttachment photo) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.transparent,
              Colors.black.withValues(alpha: 0.7),
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photo.location != null)
              Row(
                children: [
                  const Icon(Icons.location_on, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      photo.location!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            if (photo.timestamp != null) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  const Icon(Icons.access_time, color: Colors.white, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    DateFormat.yMMMMd().add_jm().format(photo.timestamp!),
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Widget for displaying full-size photos using asset ID or file path
class _FullSizePhotoWidget extends StatefulWidget {
  final String assetId;
  final String filePath;

  const _FullSizePhotoWidget({
    required this.assetId,
    required this.filePath,
  });

  @override
  State<_FullSizePhotoWidget> createState() => _FullSizePhotoWidgetState();
}

class _FullSizePhotoWidgetState extends State<_FullSizePhotoWidget> {
  Uint8List? _imageData;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  Future<void> _loadImage() async {
    try {
      // Try to load as AssetEntity first
      final asset = await AssetEntity.fromId(widget.assetId);

      if (asset != null) {
        // Successfully loaded from AssetEntity
        final file = await asset.file;
        if (file != null) {
          final imageData = await file.readAsBytes();
          if (mounted) {
            setState(() {
              _imageData = imageData;
              _isLoading = false;
            });
          }
          return;
        }
      }

      // Asset not found - try to load from file path
      final file = File(widget.filePath);
      if (await file.exists()) {
        final imageData = await file.readAsBytes();
        if (mounted) {
          setState(() {
            _imageData = imageData;
            _isLoading = false;
          });
        }
        return;
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
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(
          color: Colors.white,
        ),
      );
    }

    if (_hasError || _imageData == null) {
      return const Center(
        child: Icon(
          Icons.broken_image,
          color: Colors.white,
          size: 64,
        ),
      );
    }

    return Image.memory(
      _imageData!,
      fit: BoxFit.contain,
      errorBuilder: (context, error, stackTrace) {
        return const Center(
          child: Icon(
            Icons.broken_image,
            color: Colors.white,
            size: 64,
          ),
        );
      },
    );
  }
}
