import '../models/photo_index.dart';

class PhotoIndexService {
  static final PhotoIndexService instance = PhotoIndexService._();
  PhotoIndexService._();

  Future<void> init() async {}
  void buildIndexInBackground() {}
  void startChangeListener() {}

  Future<Map<String, dynamic>> toolSearchPhotos(dynamic args) async =>
      {'ok': false, 'error': 'Photo search is not available on web.'};

  Future<Map<String, dynamic>> buildIndex({bool forceRebuild = false}) async =>
      {'ok': false, 'error': 'Photo index is not available on web.'};

  Map<String, dynamic> getStats() => {'totalPhotos': 0, 'indexedPhotos': 0};

  Future<List<PhotoMetadata>> getAllPhotos() async => [];
}
