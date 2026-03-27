import 'dart:async';
import '../stubs/activity_event_stub.dart';

class DrivingMonitorService {
  DrivingMonitorService._();
  static final DrivingMonitorService instance = DrivingMonitorService._();

  Future<void> start() async {}

  Stream<ActivityEvent> get rawEvents => const Stream.empty();
  Stream<void> get visitUpdates => const Stream.empty();
  Map<String, dynamic>? get currentVisit => null;
}
