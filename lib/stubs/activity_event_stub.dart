// Web stubs for activity_recognition_flutter types.
enum ActivityType { inVehicle, onBicycle, onFoot, walking, running, still, tilting, unknown }

class ActivityEvent {
  final ActivityType type;
  final int confidence;
  final DateTime timeStamp;
  ActivityEvent({required this.type, this.confidence = 0, DateTime? timeStamp})
      : timeStamp = timeStamp ?? DateTime.now();
  String get typeString => type.name;
}
