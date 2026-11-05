/// Unified data contracts for Mingtu AI (refactor phase 1).
///
/// These types are the single shared vocabulary for the layers in the
/// full-module spec. Existing modules keep their own internal types;
/// when they cross a module boundary they must translate to these
/// contracts instead of inventing a private format. Nothing here
/// invents a measurement: a missing distance stays null, a missing
/// spatial confidence stays low, and a service that is not wired in
/// stays unavailable -- never a faked "ok".
library;

import 'task_manager.dart';

/// Health of one service. `stale` means the last data is old, `untrusted`
/// means the data arrived but must not drive a safety decision.
enum ServiceHealthStatus { ok, degraded, unavailable, stale, untrusted }

class ServiceHealth {
  final String service;
  final ServiceHealthStatus status;
  final String detail;
  final DateTime updatedAt;
  const ServiceHealth({
    required this.service,
    required this.status,
    required this.detail,
    required this.updatedAt,
  });

  bool get isUsable =>
      status == ServiceHealthStatus.ok ||
      status == ServiceHealthStatus.degraded;
}

/// The one task context all modules must read. Modules must NOT keep a
/// private copy of "current navigation state" that can contradict this.
class TaskContext {
  final String taskId;
  final String goal;
  final TaskState state;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int navigationVersion;
  final String? currentRiskEventId;
  final Map<String, ServiceHealth> health;

  const TaskContext({
    required this.taskId,
    required this.goal,
    required this.state,
    required this.createdAt,
    required this.updatedAt,
    required this.navigationVersion,
    this.currentRiskEventId,
    this.health = const {},
  });

  /// v0.4 single-source snapshot: build the context from the one
  /// TaskManager instead of letting a caller invent a state. The
  /// navigation version and health map are supplied by the caller
  /// that owns them; a snapshot never invents a healthy service.
  factory TaskContext.fromTaskManager(
    TaskManager manager, {
    required int navigationVersion,
    Map<String, ServiceHealth> health = const {},
    String? currentRiskEventId,
  }) {
    final now = DateTime.now();
    return TaskContext(
      taskId: manager.taskId ?? '',
      goal: manager.goal ?? '',
      state: manager.state,
      createdAt: now,
      updatedAt: now,
      navigationVersion: navigationVersion,
      currentRiskEventId: currentRiskEventId,
      health: health,
    );
  }

  TaskContext copyWith({
    TaskState? state,
    int? navigationVersion,
    String? currentRiskEventId,
    Map<String, ServiceHealth>? health,
  }) {
    return TaskContext(
      taskId: taskId,
      goal: goal,
      state: state ?? this.state,
      createdAt: createdAt,
      updatedAt: DateTime.now(),
      navigationVersion: navigationVersion ?? this.navigationVersion,
      currentRiskEventId: currentRiskEventId ?? this.currentRiskEventId,
      health: health ?? this.health,
    );
  }
}

/// One unified environment event, per spec section 3.
/// `distanceM` is null when there is no reliable distance estimate --
/// callers must treat that as "unknown distance", never as "close" or
/// "far". `spatialConfidence` is separate from `detectionConfidence`.
class EnvironmentEvent {
  final String eventId;
  final DateTime timestamp;
  final String? taskId;
  final String source;
  final String objectType;
  final String? positionEstimate;
  final double? distanceM;
  final String? motionEstimate;
  final double detectionConfidence;
  final double spatialConfidence;
  final Duration observationAge;
  final ServiceHealthStatus sensorHealth;
  final String? sceneContext;
  final List<String> limitations;

  const EnvironmentEvent({
    required this.eventId,
    required this.timestamp,
    this.taskId,
    required this.source,
    required this.objectType,
    this.positionEstimate,
    this.distanceM,
    this.motionEstimate,
    required this.detectionConfidence,
    required this.spatialConfidence,
    required this.observationAge,
    required this.sensorHealth,
    this.sceneContext,
    this.limitations = const [],
  });

  /// Reliable spatial evidence exists only when both the confidence
  /// threshold and a real distance estimate are present. This mirrors
  /// RiskEngine.minSpatialConfidenceForStep (0.6).
  bool get hasReliableSpatial =>
      spatialConfidence >= 0.6 && distanceM != null;
}

/// One action instruction, per spec section 7. Speech completion is a
/// separate status from action completion; this type never conflates them.
enum InstructionStatus { created, spoken, actionPending, actionConfirmed, actionUncertain, invalidated }

class NavigationInstruction {
  final String commandId;
  final String taskId;
  final DateTime createdAt;
  final DateTime expiresAt;
  final int priority;
  final String commandType;
  final String text;
  final String? relatedRiskEventId;
  final String navigationStateVersion;
  final List<String> requiredPreconditions;
  final double confidence;
  final bool requiresConfirmation;
  final InstructionStatus status;

  const NavigationInstruction({
    required this.commandId,
    required this.taskId,
    required this.createdAt,
    required this.expiresAt,
    required this.priority,
    required this.commandType,
    required this.text,
    this.relatedRiskEventId,
    required this.navigationStateVersion,
    this.requiredPreconditions = const [],
    required this.confidence,
    this.requiresConfirmation = false,
    this.status = InstructionStatus.created,
  });

  bool isExpired(DateTime now) => now.isAfter(expiresAt);

  /// An instruction is valid only if it has not expired, its navigation
  /// version still matches, and it is not a straight prompt while a
  /// risk is active. Anything else must be invalidated, not replayed.
  bool isValidFor({
    required DateTime now,
    required String currentNavigationVersion,
    required bool riskActive,
  }) {
    if (isExpired(now)) return false;
    if (navigationStateVersion != currentNavigationVersion) return false;
    if (riskActive && commandType == 'straight') return false;
    return status == InstructionStatus.created ||
        status == InstructionStatus.spoken ||
        status == InstructionStatus.actionPending;
  }
}

/// Explicit user consent, per spec section 14. Defaults are deny.
class UserConsent {
  final bool recordingAllowed;
  final bool cloudUploadAllowed;
  final bool locationSharingAllowed;
  const UserConsent({
    this.recordingAllowed = false,
    this.cloudUploadAllowed = false,
    this.locationSharingAllowed = false,
  });
}
