import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Takes a screenshot of the current phone screen via the Android
/// AccessibilityService (API 30+). Not supported on iOS.
class ScreenshotService {
  ScreenshotService._();
  static final instance = ScreenshotService._();

  static const _channel = MethodChannel('roadmate/screenshot');

  /// Capture the screen and return the path to the saved PNG file.
  /// Returns `{'ok': true, 'path': '...'}` on success or
  /// `{'ok': false, 'error': '...'}` on failure.
  Future<Map<String, dynamic>> takeScreenshot() async {
    if (!Platform.isAndroid) {
      return {'ok': false, 'error': 'Screenshots are only supported on Android'};
    }
    try {
      final path = await _channel.invokeMethod<String>('takeScreenshot');
      if (path == null) {
        return {'ok': false, 'error': 'Screenshot failed — no file returned'};
      }
      debugPrint('[Screenshot] Saved to $path');
      return {'ok': true, 'path': path};
    } on PlatformException catch (e) {
      debugPrint('[Screenshot] ${e.code}: ${e.message}');
      final msg = switch (e.code) {
        'NO_SERVICE' =>
          'RoadMate Accessibility Service is not enabled. '
          'Go to Settings → Accessibility and enable it.',
        'UNSUPPORTED' => 'Screenshots require Android 11 or newer.',
        _ => e.message ?? 'Screenshot failed',
      };
      return {'ok': false, 'error': msg};
    }
  }
}
