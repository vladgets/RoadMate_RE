/// Model for individual photo metadata in the index
class PhotoMetadata {
  final String id;            // Asset ID from photo_manager
  final String path;          // Local file path
  final DateTime? timestamp;  // Photo creation time
  final double? latitude;     // GPS latitude
  final double? longitude;    // GPS longitude
  final String? address;      // Human-readable address

  PhotoMetadata({
    required this.id,
    required this.path,
    this.timestamp,
    this.latitude,
    this.longitude,
    this.address,
  });

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'path': path,
      'timestamp': timestamp?.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
    };
  }

  /// Deserialize from JSON
  factory PhotoMetadata.fromJson(Map<String, dynamic> json) {
    return PhotoMetadata(
      id: json['id'] as String,
      path: json['path'] as String,
      timestamp: json['timestamp'] != null
          ? DateTime.parse(json['timestamp'] as String)
          : null,
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      address: json['address'] as String?,
    );
  }

  @override
  String toString() {
    return 'PhotoMetadata(id: $id, timestamp: $timestamp, address: $address)';
  }
}

/// Model for the complete photo index
class PhotoIndex {
  final List<PhotoMetadata> photos;
  final DateTime? lastIndexed;
  final int totalPhotos;

  PhotoIndex({
    required this.photos,
    this.lastIndexed,
    this.totalPhotos = 0,
  });

  /// Serialize to JSON
  Map<String, dynamic> toJson() {
    return {
      'photos': photos.map((p) => p.toJson()).toList(),
      'last_indexed': lastIndexed?.toIso8601String(),
      'total_photos': totalPhotos,
    };
  }

  /// Deserialize from JSON
  factory PhotoIndex.fromJson(Map<String, dynamic> json) {
    final photosList = json['photos'] as List<dynamic>? ?? [];
    return PhotoIndex(
      photos: photosList
          .map((p) => PhotoMetadata.fromJson(p as Map<String, dynamic>))
          .toList(),
      lastIndexed: json['last_indexed'] != null
          ? DateTime.parse(json['last_indexed'] as String)
          : null,
      totalPhotos: json['total_photos'] as int? ?? 0,
    );
  }

  /// Create an empty index
  factory PhotoIndex.empty() {
    return PhotoIndex(
      photos: [],
      lastIndexed: null,
      totalPhotos: 0,
    );
  }

  @override
  String toString() {
    return 'PhotoIndex(photos: ${photos.length}, lastIndexed: $lastIndexed, totalPhotos: $totalPhotos)';
  }
}
