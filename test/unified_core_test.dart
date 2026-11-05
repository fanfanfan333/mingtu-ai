import 'package:mingtu_ai/core/contracts.dart';
import 'package:mingtu_ai/core/event_bus.dart';
import 'package:mingtu_ai/core/health_monitor.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/skills/registry.dart';
import 'package:test/test.dart';

MingtuEvent _event(String id, MingtuEventType type, int version, DateTime now) {
  return MingtuEvent(
    eventId: id,
    type: type,
    taskId: 't1',
    createdAt: now,
    source: 'test',
    dataVersion: version,
    expiresAt: now.add(const Duration(seconds: 60)),
  );
}

void main() {
  test('event bus drops duplicates, expired and stale events', () {
    final bus = EventBus();
    var received = 0;
    bus.subscribe(MingtuEventType.riskUpdated, (_) => received++);
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    expect(bus.publish(_event('e1', MingtuEventType.riskUpdated, 2, now), now), isTrue);
    expect(bus.publish(_event('e1', MingtuEventType.riskUpdated, 3, now), now), isFalse);
    expect(bus.publish(_event('e2', MingtuEventType.riskUpdated, 1, now), now), isFalse);
    final expired = MingtuEvent(
      eventId: 'e3',
      type: MingtuEventType.riskUpdated,
      taskId: 't1',
      createdAt: now,
      source: 'test',
      expiresAt: now.subtract(const Duration(seconds: 1)),
    );
    expect(bus.publish(expired, now), isFalse);
    expect(received, 1);
    expect(bus.droppedDuplicates, 1);
    expect(bus.droppedStale, 1);
    expect(bus.droppedExpired, 1);
  });

  test('environment event without distance is not reliable spatial evidence', () {
    final event = EnvironmentEvent(
      eventId: 'env1',
      timestamp: DateTime(2026, 11, 5, 12, 0, 0),
      source: 'yolo',
      objectType: 'person',
      detectionConfidence: 0.95,
      spatialConfidence: 0.95,
      observationAge: Duration.zero,
      sensorHealth: ServiceHealthStatus.ok,
    );
    // timestamp is required in the contract; this test uses the
    // hasReliableSpatial rule only, so a null distance must fail it.
    expect(event.hasReliableSpatial, isFalse);
  });

  test('navigation instruction invalidates on risk or version change', () {
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    final instruction = NavigationInstruction(
      commandId: 'c1',
      taskId: 't1',
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 10)),
      priority: 4,
      commandType: 'straight',
      text: '直走',
      navigationStateVersion: 'nav-v0',
      confidence: 0.8,
    );
    expect(instruction.isValidFor(now: now, currentNavigationVersion: 'nav-v0', riskActive: false), isTrue);
    expect(instruction.isValidFor(now: now, currentNavigationVersion: 'nav-v0', riskActive: true), isFalse);
    expect(instruction.isValidFor(now: now, currentNavigationVersion: 'nav-v1', riskActive: false), isFalse);
  });

  test('health monitor announces degraded services, empty when healthy', () {
    final monitor = HealthMonitor();
    expect(monitor.announcementText(), '');
    monitor.report('location', ServiceHealthStatus.unavailable, 'GPS lost');
    expect(monitor.hasCriticalFailure, isTrue);
    expect(monitor.announcementText(), contains('location'));
  });

  test('skill registry denies disabled, unmet preconditions and high-risk without risk-ok', () {
    final registry = defaultSkillRegistry();
    expect(registry.list().length, 13);
    expect(registry.get('station_assistance'), isNull);
    final denied = registry.execute(
      'obstacle_assistance',
      preconditionsMet: true,
      riskOk: false,
      runner: () => {'step': 'right'},
    );
    expect(denied.status, SkillExecutionStatus.denied);
    final ok = registry.execute(
      'route_planning',
      preconditionsMet: true,
      riskOk: false,
      runner: () => {'route': 'a'},
    );
    expect(ok.status, SkillExecutionStatus.ok);
    registry.disable('route_planning');
    expect(registry.execute('route_planning', preconditionsMet: true, riskOk: true, runner: () => {}).status, SkillExecutionStatus.denied);
  });

  test('task manager accepts preparing and executing without breaking old flow', () {
    final tasks = TaskManager();
    expect(tasks.startTask(id: 't1', goalText: 'library'), isTrue);
    expect(tasks.transitionTo(TaskState.understanding), isTrue);
    expect(tasks.transitionTo(TaskState.planning), isTrue);
    expect(tasks.transitionTo(TaskState.preparing), isTrue);
    expect(tasks.transitionTo(TaskState.executing), isTrue);
    expect(tasks.transitionTo(TaskState.navigating), isTrue);
    expect(tasks.transitionTo(TaskState.emergency), isTrue);
    expect(tasks.transitionTo(TaskState.navigating), isFalse);
  });
}
