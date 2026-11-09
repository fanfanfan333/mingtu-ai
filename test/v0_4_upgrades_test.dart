import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:mingtu_ai/core/contracts.dart';
import 'package:mingtu_ai/core/risk_engine.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/modules/learning_backlog.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/recording.dart';
import 'package:mingtu_ai/modules/traffic_scene.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';
import 'package:mingtu_ai/skills/registry.dart';
import 'package:test/test.dart';

RiskEvent _event(String type, PerceptionEvidence evidence) {
  final now = DateTime(2026, 11, 5, 12, 0, 0);
  return RiskEvent(
    id: 'e-$type',
    type: type,
    createdAt: now,
    expiresAt: now.add(const Duration(seconds: 30)),
    evidence: evidence,
  );
}

const _confirmedSide = PerceptionEvidence(
  detectionConfidence: 0.95,
  spatialConfidence: 0.95,
  hasDistanceEstimate: true,
  distanceM: 2.5,
  sideSpaceConfirmed: true,
  confirmedSafeSide: StepDirection.right,
);

void main() {
  test('traffic and location-uncertain events never produce a step', () {
    final engine = RiskEngine();
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    for (final type in ['traffic', 'traffic_uncertain', 'location_uncertain']) {
      final a = engine.assess(_event(type, _confirmedSide), now);
      expect(a.stepDirection, StepDirection.none);
      expect(a.action, RiskAction.stop);
    }
    // Ordinary obstacle with the same evidence may still step.
    final ok = engine.assess(_event('obstacle', _confirmedSide), now);
    expect(ok.stepDirection, StepDirection.right);
  });

  test('traffic scene service never allows crossing', () {
    final service = TrafficSceneService();
    final a = service.assess(
      lightDetected: true,
      lightDirectionConfirmed: true,
      locationAccuracyOk: true,
      crossingConfirmed: true,
    );
    expect(a.allowsCrossing, isFalse);
    expect(a.speechText, contains('不能作为过马路的许可'));
    final b = service.assess(
      lightDetected: true,
      lightDirectionConfirmed: false,
      locationAccuracyOk: true,
      crossingConfirmed: false,
    );
    expect(b.outcome, TrafficSceneOutcome.stopAndAskHelp);
  });

  test('speech scheduler drops turn vs avoidance conflicts', () {
    // v0.5 correction: this v0.4 test had the direction backwards.
    // A turn must be dropped while avoidance is active; avoidance
    // must never be dropped while a turn is active (see v0.5 test).
    final scheduler = SpeechScheduler();
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    SpeechRequest req(String id, SpeechKind kind) => SpeechRequest(
          id: id,
          eventId: id,
          text: id,
          kind: kind,
          createdAt: now,
          expiresAt: now.add(const Duration(seconds: 10)),
          navigationStateVersion: 'nav-v0',
        );
    expect(scheduler.submit(req('avoid-1', SpeechKind.obstacleAvoidance), now),
        isTrue);
    expect(scheduler.submit(req('turn-1', SpeechKind.turn), now), isFalse);
    expect(scheduler.droppedConflictLog, contains('turn-1'));
  });

  test('map replan needs deviation and good accuracy', () {
    final service = MapNavigationService(StubMapProvider());
    expect(service.shouldReplan(distanceFromRouteM: 20, locationAccuracyM: 20),
        isTrue);
    expect(service.shouldReplan(distanceFromRouteM: 20, locationAccuracyM: 50),
        isFalse);
    expect(service.shouldReplan(distanceFromRouteM: 5, locationAccuracyM: 20),
        isFalse);
  });

  test('low-confidence detections create no track', () {
    final perception = VisualPerception();
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    final events = perception.processFrame(
      const [Detection(label: 'person', confidence: 0.2, cx: 0.5, cy: 0.5)],
      now,
    );
    expect(events, isEmpty);
    expect(perception.tracks, isEmpty);
  });

  test('recording album export is explicitly NOT_CONFIGURED', () {
    expect(RecordingManager.albumExportStatus, contains('NOT_CONFIGURED'));
  });

  test('wake word is explicitly NOT_IMPLEMENTED with an alternative', () {
    expect(wakeWordStatus, contains('NOT_IMPLEMENTED'));
    // v0.7: the alternative is now the turn-taking loop (greeting +
    // listen again after each prompt), not just in-app voice control.
    expect(wakeWordStatus, contains('轮流对话'));
  });

  test('learning backlog records only and never applies a rule', () {
    final backlog = LearningBacklog();
    backlog.record('f1', 'uncertain-side-space', 'demo', DateTime(2026, 11, 5));
    expect(backlog.count, 1);
    expect(backlog.automaticallyAppliedRuleChanges, isEmpty);
    expect(RiskEngine.minSpatialConfidenceForStep, 0.6);
  });

  test('registry has 12 skills, traffic info in, station and hospital out', () {
    final registry = defaultSkillRegistry();
    expect(registry.list().length, 12);
    expect(registry.get('traffic_scene_info'), isNotNull);
    expect(registry.get('station_assistance'), isNull);
    // The user's flow is navigation + obstacle avoidance
    // only: the hospital skill is out of the registry.
    expect(registry.get('hospital_registration'), isNull);
  });

  test('task context snapshot follows the one task manager', () {
    final tasks = TaskManager();
    tasks.startTask(id: 't1', goalText: 'library');
    tasks.transitionTo(TaskState.understanding);
    final ctx = TaskContext.fromTaskManager(tasks, navigationVersion: 3);
    expect(ctx.taskId, 't1');
    expect(ctx.state, TaskState.understanding);
    expect(ctx.navigationVersion, 3);
  });
}
