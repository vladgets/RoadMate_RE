import 'package:flutter/material.dart';
import '../widgets/photo_thumbnail.dart';
import '../../models/photo_attachment.dart';
import '../../models/photo_index.dart';
import '../../services/photo_index_service.dart';
import 'memory_selection_screen.dart';

class PhotoSelectionScreen extends StatefulWidget {
  const PhotoSelectionScreen({super.key});

  @override
  State<PhotoSelectionScreen> createState() => _PhotoSelectionScreenState();
}

class _PhotoSelectionScreenState extends State<PhotoSelectionScreen> {
  final List<PhotoAttachment> _selectedPhotos = [];
  List<PhotoMetadata> _allPhotos = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final photos = await PhotoIndexService.instance.getAllPhotos();

    // Sort by timestamp (newest first)
    photos.sort((a, b) {
      if (a.timestamp == null && b.timestamp == null) return 0;
      if (a.timestamp == null) return 1; // Put photos without dates at the end
      if (b.timestamp == null) return -1;
      return b.timestamp!.compareTo(a.timestamp!); // Descending order (newest first)
    });

    setState(() {
      _allPhotos = photos;
      _isLoading = false;
    });
  }

  void _togglePhoto(PhotoMetadata photo) {
    setState(() {
      final isSelected = _selectedPhotos.any((p) => p.id == photo.id);
      if (isSelected) {
        _selectedPhotos.removeWhere((p) => p.id == photo.id);
      } else if (_selectedPhotos.length < 6) {
        _selectedPhotos.add(PhotoAttachment.fromMetadata(photo));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Photos'),
        actions: [
          TextButton(
            onPressed: _selectedPhotos.length >= 2
                ? () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => MemorySelectionScreen(
                          selectedPhotos: _selectedPhotos,
                        ),
                      ),
                    );
                  }
                : null,
            child: const Text('Next'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Select 2-6 photos (${_selectedPhotos.length}/6)',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : GridView.builder(
                    padding: const EdgeInsets.all(8),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _allPhotos.length,
                    itemBuilder: (context, index) {
                      final photo = _allPhotos[index];
                      final isSelected = _selectedPhotos.any((p) => p.id == photo.id);

                      return GestureDetector(
                        onTap: () => _togglePhoto(photo),
                        child: Stack(
                          children: [
                            PhotoThumbnail(
                              assetId: photo.id,
                              size: 120,
                            ),
                            if (isSelected)
                              Positioned.fill(
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.5),
                                    border: Border.all(
                                      color: Colors.blue,
                                      width: 3,
                                    ),
                                  ),
                                  child: const Icon(
                                    Icons.check_circle,
                                    color: Colors.white,
                                    size: 40,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
