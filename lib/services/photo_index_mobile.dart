import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:photo_manager/photo_manager.dart';
import '../models/photo_index.dart';
import 'geo_time_tools.dart';
import 'time_period_parser.dart';

/// Service for indexing and searching the user's photo album
class PhotoIndexService {
  static final PhotoIndexService instance = PhotoIndexService._();
  PhotoIndexService._();

  static const String _storageKey = 'photo_album_index';
  static const int _batchSize = 100; // Process in batches
  static const int _maxPhotosToIndex = 20000;

  PhotoIndex? _index;
  bool _isIndexing = false;

/// Initialize service and load existing index
  Future<void> init() async {
    await _loadIndex();
    // ignore: avoid_print
    print('[PhotoIndexService] Initialized with ${_index?.photos.length ?? 0} photos indexed');
    if (_index != null && _index!.photos.isNotEmpty) {
      // Check for any new photos taken since the index was last built
      _checkAndIndexNewPhotos();
    }
  }

  /// Check if photos permission is granted (including ACCESS_MEDIA_LOCATION on Android)
  Future<bool> hasPermission() async {
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: true,
        ),
      ),
    );
    return state.isAuth || state == PermissionState.limited;
  }

  /// Request photos permission (including ACCESS_MEDIA_LOCATION on Android)
  Future<bool> requestPermission() async {
    final state = await PhotoManager.requestPermissionExtend(
      requestOption: const PermissionRequestOption(
        androidPermission: AndroidPermission(
          type: RequestType.image,
          mediaLocation: true,
        ),
      ),
    );
    return state.isAuth || state == PermissionState.limited;
  }

  /// Load index from SharedPreferences
  Future<void> _loadIndex() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = prefs.getString(_storageKey);

      if (jsonStr != null) {
        final json = jsonDecode(jsonStr) as Map<String, dynamic>;
        _index = PhotoIndex.fromJson(json);
      } else {
        _index = PhotoIndex.empty();
      }
    } catch (e) {
      // If loading fails, start with empty index
      _index = PhotoIndex.empty();
    }
  }

  /// Save index to SharedPreferences
  Future<void> _saveIndex() async {
    if (_index == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonStr = jsonEncode(_index!.toJson());
      await prefs.setString(_storageKey, jsonStr);
    } catch (e) {
      // Silently fail - index will be rebuilt on next launch
    }
  }

  /// Build the photo index
  Future<Map<String, dynamic>> buildIndex({bool forceRebuild = false}) async {
    if (_isIndexing) {
      return {'ok': false, 'error': 'Indexing already in progress'};
    }

    // Check permission
    if (!await hasPermission()) {
      final granted = await requestPermission();
      if (!granted) {
        return {'ok': false, 'error': 'Photo permission not granted'};
      }
    }

    _isIndexing = true;

    try {
      // Get all albums (we'll filter in the photo extraction step)
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,  // Get "All Photos" to ensure we get photos
      );

      if (albums.isEmpty) {
        _isIndexing = false;
        return {'ok': false, 'error': 'No photo albums found'};
      }

      // Try to find Camera album first, otherwise use All Photos
      AssetPathEntity? selectedAlbum;

      // First, try to find the Camera album
      for (final album in albums) {
        final albumName = album.name.toLowerCase();
        if (albumName == 'camera' ||
            albumName == 'dcim' ||
            albumName == 'camera roll' ||
            albumName.contains('camera')) {
          selectedAlbum = album;
          // ignore: avoid_print
          print('[PhotoIndexService] Found Camera album: ${album.name}');
          break;
        }
      }

      // If no Camera album found, use "All Photos" but rely on path filtering
      if (selectedAlbum == null) {
        selectedAlbum = albums.first;  // Usually "All Photos"
        // ignore: avoid_print
        print('[PhotoIndexService] No Camera album found, using: ${selectedAlbum.name}');
        // ignore: avoid_print
        print('[PhotoIndexService] Will filter by path (excluding WhatsApp, Downloads, etc.)');
      } else {
        // ignore: avoid_print
        print('[PhotoIndexService] Using Camera album: ${selectedAlbum.name}');
      }

      final totalCount = await selectedAlbum.assetCountAsync;

      // ignore: avoid_print
      print('[PhotoIndexService] Total photos in album: $totalCount');

      if (totalCount == 0) {
        _isIndexing = false;
        _index = PhotoIndex.empty();
        await _saveIndex();
        // ignore: avoid_print
        print('[PhotoIndexService] Camera album is empty - no photos to index');
        return {'ok': true, 'indexed': 0, 'total': 0};
      }

      // Determine how many photos to index
      final limit = totalCount > _maxPhotosToIndex ? _maxPhotosToIndex : totalCount;

      // Fetch photos in batches
      final List<PhotoMetadata> indexedPhotos = [];
      int processedCount = 0;
      int skippedCount = 0;

      for (int i = 0; i < limit; i += _batchSize) {
        final batch = await selectedAlbum.getAssetListRange(
          start: i,
          end: (i + _batchSize) > limit ? limit : (i + _batchSize),
        );

        for (final asset in batch) {
          final metadata = await _extractMetadata(asset);
          if (metadata != null) {
            indexedPhotos.add(metadata);
          } else {
            skippedCount++;
          }
          processedCount++;
        }
      }

      // ignore: avoid_print
      print('[PhotoIndexService] Indexing complete: ${indexedPhotos.length} included, $skippedCount filtered out');

      // Update index
      _index = PhotoIndex(
        photos: indexedPhotos,
        lastIndexed: DateTime.now(),
        totalPhotos: totalCount,
      );

      await _saveIndex();
      _isIndexing = false;

      return {
        'ok': true,
        'indexed': indexedPhotos.length,
        'total': totalCount,
        'processed': processedCount,
      };
    } catch (e) {
      _isIndexing = false;
      return {'ok': false, 'error': 'Failed to build index: $e'};
    }
  }

  /// Check if a photo was taken by the device camera (not saved/downloaded/screenshot)
  bool _isCameraPhoto(AssetEntity asset, String filePath) {
    final path = filePath.toLowerCase();
    final filename = path.split('/').last;

    if (Platform.isAndroid) {
      // On Android, camera photos live in DCIM/Camera/
      final relativePath = asset.relativePath?.toLowerCase() ?? '';
      if (!relativePath.startsWith('dcim/camera')) {
        return false;
      }
    }

    if (Platform.isIOS) {
      // Exclude screenshots using mediaSubtypes
      if (asset.subtype == 2) { // AssetSubtype.screenshot = 2
        return false;
      }

      // On iOS, camera shoots HEIC or JPEG — never PNG.
      // PNGs are screenshots or saved images.
      if (filename.endsWith('.png')) {
        return false;
      }

      // Exclude files with "screenshot" in the name
      if (filename.contains('screenshot')) {
        return false;
      }
    }

    // Cross-platform: exclude photos from messaging/social apps
    final excludedPaths = [
      'whatsapp',
      'download',
      'downloads',
      'screenshot',
      'telegram',
      'instagram',
      'facebook',
      'snapchat',
      'twitter',
      'messenger',
      'saved images',
      'pictures/reddit',
    ];

    for (final excluded in excludedPaths) {
      if (path.contains(excluded)) {
        return false;
      }
    }

    return true;
  }

  /// Extract metadata from a photo asset
  Future<PhotoMetadata?> _extractMetadata(AssetEntity asset) async {
    try {
      // Get file path
      final file = await asset.file;
      if (file == null) return null;

      // Only include photos taken by the device camera
      if (!_isCameraPhoto(asset, file.path)) {
        return null;
      }

      // Get GPS coordinates
      final latLng = await asset.latlngAsync();
      double? latitude;
      double? longitude;
      String? address;

      if (latLng != null && latLng.latitude != 0.0 && latLng.longitude != 0.0) {
        latitude = latLng.latitude;
        longitude = latLng.longitude;

        // Reverse geocode to get address
        final placemark = await reverseGeocode(latitude, longitude);
        if (placemark != null) {
          // Build readable address
          final parts = <String>[];
          if (placemark.locality != null && placemark.locality!.isNotEmpty) {
            parts.add(placemark.locality!);
          }
          if (placemark.administrativeArea != null && placemark.administrativeArea!.isNotEmpty) {
            parts.add(placemark.administrativeArea!);
          }
          if (placemark.country != null && placemark.country!.isNotEmpty) {
            parts.add(placemark.country!);
          }
          address = parts.join(', ');
        }
      }

      // Get timestamp (prefer creation date, fallback to modified date)
      final timestamp = asset.createDateTime;

      return PhotoMetadata(
        id: asset.id,
        path: file.path,
        timestamp: timestamp,
        latitude: latitude,
        longitude: longitude,
        address: address,
      );
    } catch (e) {
      // Skip photos that fail to process
      return null;
    }
  }

  /// Search photos by location
  Future<List<PhotoMetadata>> searchByLocation(String location) async {
    if (_index == null || _index!.photos.isEmpty) {
      return [];
    }

    final query = location.toLowerCase();
    return _index!.photos.where((photo) {
      if (photo.address == null) return false;
      return photo.address!.toLowerCase().contains(query);
    }).toList();
  }

  /// Search photos by time period
  Future<List<PhotoMetadata>> searchByTime(String timePeriod) async {
    if (_index == null || _index!.photos.isEmpty) {
      // ignore: avoid_print
      print('[PhotoIndexService] searchByTime: index is null or empty');
      return [];
    }

    final range = TimePeriodParser.parse(timePeriod);
    if (range == null) {
      // ignore: avoid_print
      print('[PhotoIndexService] searchByTime: could not parse "$timePeriod"');
      return [];
    }

    // ignore: avoid_print
    print('[PhotoIndexService] searchByTime: searching for photos between ${range.start} and ${range.end}');

    final results = _index!.photos.where((photo) {
      if (photo.timestamp == null) return false;
      return photo.timestamp!.isAfter(range.start) &&
             photo.timestamp!.isBefore(range.end);
    }).toList();

    // ignore: avoid_print
    print('[PhotoIndexService] searchByTime: found ${results.length} photos');

    return results;
  }

  /// Search photos by location and/or time
  Future<List<PhotoMetadata>> searchPhotos({
    String? location,
    String? timePeriod,
    int limit = 10,
  }) async {
    List<PhotoMetadata> results = [];

    if (location != null && timePeriod != null) {
      // Search by both
      final locationResults = await searchByLocation(location);
      final timeResults = await searchByTime(timePeriod);

      // Intersection of both results
      results = locationResults.where((photo) =>
        timeResults.any((t) => t.id == photo.id)
      ).toList();
    } else if (location != null) {
      results = await searchByLocation(location);
    } else if (timePeriod != null) {
      results = await searchByTime(timePeriod);
    } else {
      // No search criteria, return most recent photos
      results = _index?.photos ?? [];
    }

    // Sort by timestamp (newest first)
    results.sort((a, b) {
      if (a.timestamp == null && b.timestamp == null) return 0;
      if (a.timestamp == null) return 1;
      if (b.timestamp == null) return -1;
      return b.timestamp!.compareTo(a.timestamp!);
    });

    // Apply limit
    if (results.length > limit) {
      results = results.sublist(0, limit);
    }

    return results;
  }

  /// Start building the index in the background (non-blocking)
  void buildIndexInBackground() {
    if (_isIndexing || (_index != null && _index!.photos.isNotEmpty && !needsUpdate())) {
      return;
    }
    // Fire and forget
    buildIndex();
  }

  /// Start listening for photo library changes (real-time indexing of new photos)
  Future<void> startChangeListener() async {
    if (!await hasPermission()) return;
    await PhotoManager.startChangeNotify();
    PhotoManager.addChangeCallback(_onPhotoLibraryChanged);
    // ignore: avoid_print
    print('[PhotoIndexService] Started photo library change listener');
  }

  /// Stop listening for photo library changes
  void stopChangeListener() {
    PhotoManager.removeChangeCallback(_onPhotoLibraryChanged);
    PhotoManager.stopChangeNotify();
  }

  /// Called when the photo library changes (e.g. new photo taken)
  void _onPhotoLibraryChanged(MethodCall call) {
    _checkAndIndexNewPhotos();
  }

  /// Check for photos taken since the last index build and add them incrementally.
  /// Uses a date filter so it only fetches assets newer than [_index.lastIndexed] —
  /// fast even for large photo libraries.
  Future<void> _checkAndIndexNewPhotos() async {
    if (_isIndexing || _index == null) return;

    final lastIndexed = _index!.lastIndexed;
    if (lastIndexed == null) return;

    try {
      // Only fetch photos created after the last index build
      final filterOption = FilterOptionGroup(
        createTimeCond: DateTimeCond(
          min: lastIndexed,
          max: DateTime.now().add(const Duration(days: 1)),
        ),
      );

      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.image,
        hasAll: true,
        filterOption: filterOption,
      );
      if (albums.isEmpty) return;

      final allPhotos = albums.firstWhere(
        (a) => a.isAll,
        orElse: () => albums.first,
      );

      final count = await allPhotos.assetCountAsync;
      if (count == 0) {
        // ignore: avoid_print
        print('[PhotoIndexService] No new photos since last index build');
        return;
      }

      // ignore: avoid_print
      print('[PhotoIndexService] Found $count new photo(s) since last index — indexing...');

      final newAssets = await allPhotos.getAssetListRange(start: 0, end: count);
      int added = 0;
      for (final asset in newAssets) {
        // Skip if somehow already indexed
        if (_index!.photos.any((p) => p.id == asset.id)) continue;

        final metadata = await _extractMetadata(asset);
        if (metadata != null) {
          await addPhotoToIndex(metadata);
          added++;
        }
      }
      if (added > 0) {
        // ignore: avoid_print
        print('[PhotoIndexService] Added $added new photo(s) to index');
      }
    } catch (e) {
      // ignore: avoid_print
      print('[PhotoIndexService] _checkAndIndexNewPhotos error: $e');
    }
  }

  /// Tool handler for search_photos
  Future<Map<String, dynamic>> toolSearchPhotos(dynamic args) async {
    // ignore: avoid_print
    print('[PhotoIndexService] toolSearchPhotos called with args: $args');

    // Check if index exists
    if (_index == null) {
      await init();
    }

    // If index is empty and currently building, tell user to wait
    if (_index!.photos.isEmpty) {
      if (_isIndexing) {
        return {
          'ok': false,
          'error': 'Photo index is currently being built. Please try again in a moment.',
        };
      }
      // Not indexing and empty — start background build and return message
      buildIndexInBackground();
      return {
        'ok': false,
        'error': 'Photo index is being built for the first time. Please try again in a minute.',
      };
    }

    // Parse arguments
    final location = args['location'] as String?;
    final timePeriod = args['time_period'] as String?;
    final limit = args['limit'] as int? ?? 10;

    // Search photos
    final results = await searchPhotos(
      location: location,
      timePeriod: timePeriod,
      limit: limit,
    );

    // ignore: avoid_print
    print('[PhotoIndexService] Search completed: ${results.length} photos found');

    if (results.isEmpty) {
      return {
        'ok': true,
        'photos': [],
        'count': 0,
        'message': 'No photos found matching your criteria.',
      };
    }

    // Convert to response format
    final photosJson = results.map((photo) => {
      'id': photo.id,
      'path': photo.path,
      'timestamp': photo.timestamp?.toIso8601String(),
      'location': photo.address,
      'latitude': photo.latitude,
      'longitude': photo.longitude,
    }).toList();

    return {
      'ok': true,
      'photos': photosJson,
      'count': results.length,
      'query': '${location ?? ""}${location != null && timePeriod != null ? " " : ""}${timePeriod ?? ""}'.trim(),
    };
  }

  /// Get index statistics
  Map<String, dynamic> getStats() {
    if (_index == null) {
      return {
        'indexed': 0,
        'total': 0,
        'last_indexed': null,
        'withTimestamps': 0,
        'withLocation': 0,
        'oldestPhoto': null,
        'newestPhoto': null,
      };
    }

    final photos = _index!.photos;
    final photosWithTimestamps = photos.where((p) => p.timestamp != null).length;
    final photosWithLocation = photos.where((p) => p.latitude != null && p.longitude != null).length;

    DateTime? oldestTimestamp;
    DateTime? newestTimestamp;
    if (photosWithTimestamps > 0) {
      final withTimestamps = photos.where((p) => p.timestamp != null).toList();
      withTimestamps.sort((a, b) => a.timestamp!.compareTo(b.timestamp!));
      oldestTimestamp = withTimestamps.first.timestamp;
      newestTimestamp = withTimestamps.last.timestamp;
    }

    return {
      'indexed': _index!.photos.length,
      'total': _index!.totalPhotos,
      'last_indexed': _index!.lastIndexed?.toIso8601String(),
      'withTimestamps': photosWithTimestamps,
      'withLocation': photosWithLocation,
      'oldestPhoto': oldestTimestamp?.toIso8601String(),
      'newestPhoto': newestTimestamp?.toIso8601String(),
    };
  }

  /// Check if index needs updating
  bool needsUpdate() {
    if (_index == null || _index!.photos.isEmpty) return true;
    if (_index!.lastIndexed == null) return true;

    // Re-index if last indexed more than 1 day ago
    final daysSinceIndexed = DateTime.now().difference(_index!.lastIndexed!).inDays;
    return daysSinceIndexed >= 1;
  }

  /// Update index with new photos
  Future<Map<String, dynamic>> updateIndex() async {
    // For now, just rebuild the entire index
    // Future enhancement: incremental updates
    return await buildIndex(forceRebuild: true);
  }

  /// Add a single photo to the index incrementally
  Future<void> addPhotoToIndex(PhotoMetadata photo) async {
    try {
      // Load existing index if not loaded
      if (_index == null) {
        await _loadIndex();
      }

      // If still null, initialize empty
      _index ??= PhotoIndex.empty();

      // Check if photo already exists in index
      final exists = _index!.photos.any((p) => p.id == photo.id);
      if (exists) {
        return; // Photo already indexed
      }

      // Add photo to index
      final updatedPhotos = List<PhotoMetadata>.from(_index!.photos);
      updatedPhotos.add(photo);

      // Apply storage limit (keep most recent 20,000 photos)
      if (updatedPhotos.length > _maxPhotosToIndex) {
        // Sort by timestamp (newest first)
        updatedPhotos.sort((a, b) {
          if (a.timestamp == null && b.timestamp == null) return 0;
          if (a.timestamp == null) return 1;
          if (b.timestamp == null) return -1;
          return b.timestamp!.compareTo(a.timestamp!);
        });

        // Keep only the most recent photos
        updatedPhotos.removeRange(_maxPhotosToIndex, updatedPhotos.length);
      }

      // Update index
      _index = PhotoIndex(
        photos: updatedPhotos,
        lastIndexed: DateTime.now(),
        totalPhotos: _index!.totalPhotos + 1,
      );

      // Save to SharedPreferences
      await _saveIndex();
    } catch (e) {
      // Fail silently - indexing is not critical
    }
  }

  /// Get all photos from the index (for collage feature)
  Future<List<PhotoMetadata>> getAllPhotos() async {
    if (_index == null) {
      await init();
    }
    return _index?.photos ?? [];
  }
}
