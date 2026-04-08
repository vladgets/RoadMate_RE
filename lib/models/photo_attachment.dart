/// Model for photo attachments in chat messages
class PhotoAttachment {
  final String id;         // Asset ID from photo_manager
  final String path;       // Local file path (may be temporary/expired)
  final String? location;  // Human-readable location
  final DateTime? timestamp;
  final double? latitude;
  final double? longitude;

  PhotoAttachment({
    required this.id,
    required this.path,
    this.location,
    this.timestamp,
    this.latitude,
    this.longitude,
  });

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'location': location,
      'timestamp': timestamp?.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
    };
  }

  /// Deserialize from JSON
  factory PhotoAttachment.fromJson(Map<String, dynamic> json) {
    return PhotoAttachment(
      id: json['id'] as String,
      path: json['path'] as String,
      location: json['location'] as String?,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
    );
  }

  @override
  String toString() {
    return 'PhotoAttachment(path: $path, location: $location, timestamp: $timestamp)';
  }
}
