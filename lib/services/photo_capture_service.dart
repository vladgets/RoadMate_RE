import 'package:image_picker/image_picker.dart';
import 'package:gal/gal.dart';
import '../models/photo_attachment.dart';

/// Service for capturing and selecting photos from camera/gallery
class PhotoCaptureService {
  static final PhotoCaptureService instance = PhotoCaptureService._();
  PhotoCaptureService._();

  final ImagePicker _picker = ImagePicker();

  /// Take a photo using the device camera
  Future<List<PhotoAttachment>?> takePhoto() async {
    try {
      // Capture photo with camera
      final XFile? photo = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 85, // Balance quality and file size
      );

      if (photo == null) {
        return null; // User cancelled
      }

      // Save to gallery and process
      final attachment = await _processCameraPhoto(photo);
      if (attachment == null) {
        return null;
      }

      return [attachment];
    } catch (e) {
      // Handle errors gracefully
      return null;
    }
  }

  /// Select photos from the device gallery
  Future<List<PhotoAttachment>?> pickFromGallery({bool multiple = true}) async {
    try {
      List<XFile> selectedFiles;

      if (multiple) {
        // Select multiple photos
        selectedFiles = await _picker.pickMultiImage(imageQuality: 85);
        if (selectedFiles.isEmpty) {
          return null; // User cancelled
        }
        // Limit to 10 photos
        if (selectedFiles.length > 10) {
          selectedFiles = selectedFiles.sublist(0, 10);
        }
      } else {
        // Select single photo
        final XFile? photo = await _picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 85,
        );
        if (photo == null) {
          return null; // User cancelled
        }
        selectedFiles = [photo];
      }

      // Create attachments directly from XFiles (fast, no searching/copying)
      final List<PhotoAttachment> attachments = [];
      for (final xfile in selectedFiles) {
        final attachment = await _createAttachmentFromXFile(xfile);
        if (attachment != null) {
          attachments.add(attachment);
        }
      }

      return attachments.isEmpty ? null : attachments;
    } catch (e) {
      // Handle errors gracefully
      return null;
    }
  }

  /// Create a PhotoAttachment directly from XFile (fallback when AssetEntity not found)
  Future<PhotoAttachment?> _createAttachmentFromXFile(XFile xfile) async {
    try {
      final path = xfile.path;

      // Generate a unique ID
      final id = '${DateTime.now().millisecondsSinceEpoch}_${path.split('/').last}';

      // Try to get modification date from file
      DateTime? timestamp;
      try {
        final fileInfo = await xfile.lastModified();
        timestamp = fileInfo;
      } catch (e) {
        timestamp = DateTime.now();
      }

      return PhotoAttachment(
        id: id,
        path: path,
        timestamp: timestamp,
      );
    } catch (e) {
      return null;
    }
  }

  /// Find an AssetEntity by file path (searches recent photos for efficiency)
  /// Process a photo captured from camera: save to gallery, extract metadata, index
  Future<PhotoAttachment?> _processCameraPhoto(XFile imageFile) async {
    try {
      // ignore: avoid_print
      print('[PhotoCapture] Processing camera photo: ${imageFile.path}');

      // Create attachment from the camera photo immediately
      final attachment = PhotoAttachment(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        path: imageFile.path,
        timestamp: DateTime.now(),
      );

      // Save to device gallery in the background (don't wait for result)
      // This ensures the photo appears in the user's gallery
      _saveToGalleryBackground(imageFile.path);

      // ignore: avoid_print
      print('[PhotoCapture] Created attachment from camera photo');

      return attachment;
    } catch (e) {
      // ignore: avoid_print
      print('[PhotoCapture] Error processing camera photo: $e');
      return null;
    }
  }

  /// Save photo to gallery in the background (fire and forget)
  void _saveToGalleryBackground(String imagePath) async {
    try {
      await Gal.putImage(imagePath);
      // ignore: avoid_print
      print('[PhotoCapture] Photo saved to gallery successfully');
    } catch (e) {
      // ignore: avoid_print
      print('[PhotoCapture] Failed to save to gallery: $e');
    }
  }

}
