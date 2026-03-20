/// Model for a voice memory — a rich narrative with location and time context
class VoiceMemory {
  final String id;
  final String transcription;
  final DateTime createdAt;
  final double? latitude;
  final double? longitude;
  final String? address;
  final int? durationSeconds;
  final List<String> linkedPhotoIds;

  VoiceMemory({
    required this.id,
    required this.transcription,
    required this.createdAt,
    this.latitude,
    this.longitude,
    this.address,
    this.durationSeconds,
    this.linkedPhotoIds = const [],
  });

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'transcription': transcription,
      'created_at': createdAt.toIso8601String(),
      'latitude': latitude,
      'longitude': longitude,
      'address': address,
      'duration_seconds': durationSeconds,
      'linked_photo_ids': linkedPhotoIds,
    };
  }

  factory VoiceMemory.fromJson(Map<String, dynamic> json) {
    return VoiceMemory(
      id: json['id'] as String,
      transcription: json['transcription'] as String,
      createdAt: DateTime.parse(json['created_at'] as String),
      latitude: json['latitude'] as double?,
      longitude: json['longitude'] as double?,
      address: json['address'] as String?,
      durationSeconds: json['duration_seconds'] as int?,
      linkedPhotoIds: List<String>.from(json['linked_photo_ids'] ?? []),
    );
  }

  VoiceMemory copyWith({String? transcription, List<String>? linkedPhotoIds}) => VoiceMemory(
    id: id,
    transcription: transcription ?? this.transcription,
    createdAt: createdAt,
    latitude: latitude,
    longitude: longitude,
    address: address,
    durationSeconds: durationSeconds,
    linkedPhotoIds: linkedPhotoIds ?? this.linkedPhotoIds,
  );

  @override
  String toString() {
    return 'VoiceMemory(id: $id, createdAt: $createdAt, address: $address)';
  }
}
