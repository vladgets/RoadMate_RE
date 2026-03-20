import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:photo_manager/photo_manager.dart';

/// A modal bottom sheet that lets the user pick up to [maxSelection] photos.
/// Returns a [List<String>] of selected asset IDs, or null if cancelled.
class PhotoPickerSheet extends StatefulWidget {
  final List<String> initialSelected;
  final int maxSelection;

  const PhotoPickerSheet({
    super.key,
    this.initialSelected = const [],
    this.maxSelection = 3,
  });

  static Future<List<String>?> show(
    BuildContext context, {
    List<String> initialSelected = const [],
    int maxSelection = 3,
  }) {
    return showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => PhotoPickerSheet(
        initialSelected: initialSelected,
        maxSelection: maxSelection,
      ),
    );
  }

  @override
  State<PhotoPickerSheet> createState() => _PhotoPickerSheetState();
}

class _PhotoPickerSheetState extends State<PhotoPickerSheet> {
  List<AssetEntity> _assets = [];
  Set<String> _selected = {};
  bool _loading = true;
  bool _permissionDenied = false;

  @override
  void initState() {
    super.initState();
    _selected = Set.from(widget.initialSelected);
    _loadPhotos();
  }

  Future<void> _loadPhotos() async {
    final permission = await PhotoManager.requestPermissionExtend();
    if (!permission.hasAccess) {
      if (mounted) setState(() { _permissionDenied = true; _loading = false; });
      return;
    }

    final filterOption = FilterOptionGroup(
      orders: [const OrderOption(type: OrderOptionType.createDate, asc: false)],
    );
    final albums = await PhotoManager.getAssetPathList(
      type: RequestType.image,
      filterOption: filterOption,
    );
    if (albums.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }

    final album = _pickCameraAlbum(albums);
    final assets = await album.getAssetListPaged(page: 0, size: 200);
    if (mounted) {
      setState(() {
        _assets = assets;
        _loading = false;
      });
    }
  }

  /// Returns the camera roll album, preferring device-camera photos over
  /// WhatsApp received images, screenshots, downloads, etc.
  AssetPathEntity _pickCameraAlbum(List<AssetPathEntity> albums) {
    if (Platform.isAndroid) {
      // Android: "Camera" album contains only photos taken by the device camera
      for (final a in albums) {
        if (a.name.toLowerCase() == 'camera') return a;
      }
    } else {
      // iOS: look for "Camera Roll" or "Recents" smart album
      for (final a in albums) {
        final n = a.name.toLowerCase();
        if (n == 'camera roll' || n == 'recents') return a;
      }
    }
    // Fall back to the all-photos virtual album, then whatever is first
    return albums.firstWhere((a) => a.isAll, orElse: () => albums.first);
  }

  void _toggle(String id) {
    setState(() {
      if (_selected.contains(id)) {
        _selected.remove(id);
      } else if (_selected.length < widget.maxSelection) {
        _selected.add(id);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(
        children: [
          // Handle + header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade300,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const Spacer(),
                Text(
                  'Select Photos (${_selected.length}/${widget.maxSelection})',
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context, _selected.toList()),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // Body
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_permissionDenied) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.photo_library_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                'Photo access denied.\nPlease enable it in Settings.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey),
              ),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => PhotoManager.openSetting(),
                child: const Text('Open Settings'),
              ),
            ],
          ),
        ),
      );
    }
    if (_assets.isEmpty) {
      return const Center(child: Text('No photos found', style: TextStyle(color: Colors.grey)));
    }

    return GridView.builder(
      padding: const EdgeInsets.all(4),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 2,
        mainAxisSpacing: 2,
      ),
      itemCount: _assets.length,
      itemBuilder: (context, index) {
        final asset = _assets[index];
        final isSelected = _selected.contains(asset.id);
        final selectionIndex = isSelected ? _selected.toList().indexOf(asset.id) + 1 : null;

        return GestureDetector(
          onTap: () => _toggle(asset.id),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _AssetThumbnail(asset: asset),
              // Overlay when selected
              if (isSelected)
                Container(
                  color: Colors.blue.withValues(alpha: 0.35),
                ),
              // Selection badge
              Positioned(
                top: 6,
                right: 6,
                child: isSelected
                    ? Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          color: Colors.blue,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: Center(
                          child: Text(
                            '$selectionIndex',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      )
                    : Container(
                        width: 22,
                        height: 22,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 1.5),
                          color: Colors.black26,
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AssetThumbnail extends StatefulWidget {
  final AssetEntity asset;
  const _AssetThumbnail({required this.asset});

  @override
  State<_AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<_AssetThumbnail> {
  Uint8List? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await widget.asset.thumbnailDataWithSize(const ThumbnailSize(200, 200));
    if (mounted) setState(() => _data = data);
  }

  @override
  Widget build(BuildContext context) {
    if (_data == null) {
      return Container(color: Colors.grey.shade200);
    }
    return Image.memory(_data!, fit: BoxFit.cover);
  }
}
