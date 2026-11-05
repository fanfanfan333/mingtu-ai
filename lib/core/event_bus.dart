/// Unified event bus for Mingtu AI (refactor phase 1).
///
/// Rules, per spec section 6:
/// - Every event carries an id, type, task id, time, source, data
///   version, reliability and expiry.
/// - Duplicate event ids are dropped, never replayed.
/// - Expired events are dropped, never applied.
/// - A lower data version for the same (type, task) than the last
///   accepted one is stale and is dropped, so an old event can never
///   overwrite a newer system state.
/// - Subscribers receive only events of the type they subscribed to.
library;

enum MingtuEventType {
  userIntentReceived,
  taskCreated,
  taskStateChanged,
  cameraHealthChanged,
  locationUpdated,
  locationUncertain,
  objectDetected,
  obstacleDetected,
  tactilePavingDetected,
  pathBlocked,
  passableAreaUpdated,
  riskUpdated,
  routeUpdated,
  routeDeviationDetected,
  navigationInstructionCreated,
  navigationInstructionInvalidated,
  speechRequested,
  speechInterrupted,
  speechCompleted,
  actionStatusUpdated,
  destinationApproaching,
  entranceCandidateFound,
  entranceConfirmed,
  indoorTaskStarted,
  skillStarted,
  skillCompleted,
  skillFailed,
  emergencyTriggered,
  recordingConsentUpdated,
  taskCompleted,
  systemDegraded,
}

class MingtuEvent {
  final String eventId;
  final MingtuEventType type;
  final String? taskId;
  final DateTime createdAt;
  final String source;
  final int dataVersion;
  final String reliability;
  final DateTime expiresAt;
  final Map<String, Object?> payload;

  const MingtuEvent({
    required this.eventId,
    required this.type,
    this.taskId,
    required this.createdAt,
    required this.source,
    this.dataVersion = 0,
    this.reliability = 'unknown',
    required this.expiresAt,
    this.payload = const {},
  });

  bool isExpired(DateTime now) => now.isAfter(expiresAt);
}

typedef MingtuEventHandler = void Function(MingtuEvent event);

class EventBus {
  final Set<String> _seenIds = {};
  final Map<String, int> _lastVersionByKey = {};
  final Map<MingtuEventType, List<MingtuEventHandler>> _subscribers = {};
  final List<MingtuEvent> history = [];
  int droppedDuplicates = 0;
  int droppedExpired = 0;
  int droppedStale = 0;

  void subscribe(MingtuEventType type, MingtuEventHandler handler) {
    _subscribers.putIfAbsent(type, () => []).add(handler);
  }

  /// Returns true only if the event was accepted and delivered.
  bool publish(MingtuEvent event, DateTime now) {
    if (event.isExpired(now)) {
      droppedExpired++;
      return false;
    }
    if (!_seenIds.add(event.eventId)) {
      droppedDuplicates++;
      return false;
    }
    final String key = '${event.type.name}:${event.taskId ?? ''}';
    final int? last = _lastVersionByKey[key];
    if (last != null && event.dataVersion < last) {
      droppedStale++;
      return false;
    }
    _lastVersionByKey[key] = event.dataVersion;
    history.add(event);
    for (final handler in _subscribers[event.type] ?? const []) {
      handler(event);
    }
    return true;
  }

  MingtuEvent? lastOf(MingtuEventType type) {
    for (var i = history.length - 1; i >= 0; i--) {
      if (history[i].type == type) return history[i];
    }
    return null;
  }
}
