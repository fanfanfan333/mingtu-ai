import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/haptics.dart';
import 'package:mingtu_ai/core/tts_recovery.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'tts_recovery_test.dart' show FakeStartupTts;

void main() {
  test('repeated danger calls do not extend the episode cap', () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger();
      clock.elapse(TtsRecoveryController.dangerDurationCap -
          const Duration(milliseconds: 400));
      controller.danger();
      expect(controller.vibrating, isTrue);
      clock.elapse(const Duration(milliseconds: 400));
      expect(controller.vibrating, isFalse);
      final count = haptics.calls.length;
      controller.danger();
      clock.elapse(const Duration(seconds: 1));
      expect(haptics.calls.length, count);
      controller.stopDanger();
      controller.danger();
      expect(haptics.calls.length, count + 1);
      controller.dispose();
    });
  });

  test('identity and escalation restart active and exhausted episodes', () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger(trackId: 1, level: DangerLevel.warning);
      expect(haptics.calls, ['warning']);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 2, level: DangerLevel.warning);
      expect(haptics.calls.last, 'warning');
      clock.elapse(const Duration(seconds: 11));
      expect(controller.vibrating, isTrue);
      clock.elapse(const Duration(seconds: 19));
      expect(controller.vibrating, isFalse);
      final count = haptics.calls.length;
      controller.danger(trackId: 2, level: DangerLevel.warning);
      expect(haptics.calls.length, count);
      controller.danger(trackId: 2, level: DangerLevel.urgent);
      expect(haptics.calls.last, 'urgent');
      expect(haptics.calls.length, count + 1);
      clock.elapse(const Duration(seconds: 30));
      controller.danger(eventId: 'first');
      clock.elapse(const Duration(seconds: 30));
      final beforeNewEvent = haptics.calls.length;
      controller.danger(eventId: 'second');
      expect(haptics.calls.length, beforeNewEvent + 1);
      controller.dispose();
    });
  });

  test('rolling cap limits new tracks and urgent escalation is exempt', () {
    fakeAsync((clock) {
      final start = DateTime(2026);
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        now: () => start.add(clock.elapsed),
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger(trackId: 1, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 2, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 3, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 5));
      expect(controller.vibrating, isFalse);
      final count = haptics.calls.length;
      controller.danger(trackId: 4, level: DangerLevel.warning);
      expect(haptics.calls.length, count);
      controller.danger(trackId: 4, level: DangerLevel.urgent);
      expect(haptics.calls.last, 'urgent');
      expect(haptics.calls.length, count + 1);
      clock.elapse(const Duration(milliseconds: 400));
      expect(haptics.calls.length, count + 2);
      controller.dispose();
    });
  });

  test('warning after danger clears remains limited by the rolling cap', () {
    fakeAsync((clock) {
      final start = DateTime(2026);
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        now: () => start.add(clock.elapsed),
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger(trackId: 1, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 2, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 3, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 5));
      expect(controller.vibrating, isFalse);
      controller.stopDanger();
      final count = haptics.calls.length;
      controller.danger(trackId: 4, level: DangerLevel.warning);
      expect(controller.vibrating, isFalse);
      expect(haptics.calls.length, count);
      controller.dispose();
    });
  });

  test('new urgent after danger clears is exempt from the rolling cap', () {
    fakeAsync((clock) {
      final start = DateTime(2026);
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        now: () => start.add(clock.elapsed),
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger(trackId: 1, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 2, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 3, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 5));
      expect(controller.vibrating, isFalse);
      controller.stopDanger();
      final count = haptics.calls.length;
      controller.danger(trackId: 5, level: DangerLevel.urgent);
      expect(controller.vibrating, isTrue);
      expect(haptics.calls.last, 'urgent');
      expect(haptics.calls.length, count + 1);
      clock.elapse(const Duration(milliseconds: 400));
      expect(haptics.calls.last, 'urgent');
      expect(haptics.calls.length, count + 2);
      clock.elapse(const Duration(milliseconds: 29600));
      expect(controller.vibrating, isFalse);
      final afterEpisode = haptics.calls.length;
      controller.danger(trackId: 5, level: DangerLevel.urgent);
      clock.elapse(const Duration(seconds: 1));
      expect(controller.vibrating, isFalse);
      expect(haptics.calls.length, afterEpisode);
      controller.dispose();
    });
  });

  test('new urgent track is exempt from the rolling cap', () {
    fakeAsync((clock) {
      final start = DateTime(2026);
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        now: () => start.add(clock.elapsed),
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger(trackId: 1, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 2, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 20));
      controller.danger(trackId: 3, level: DangerLevel.warning);
      clock.elapse(const Duration(seconds: 5));
      expect(controller.vibrating, isFalse);
      // Escalation starts an urgent episode (already exempt). After that
      // episode ends, a different urgent track is not an escalation and
      // must still vibrate under G16 (old code would stay silent).
      controller.danger(trackId: 4, level: DangerLevel.urgent);
      clock.elapse(const Duration(seconds: 30));
      expect(controller.vibrating, isFalse);
      final count = haptics.calls.length;
      controller.danger(trackId: 5, level: DangerLevel.urgent);
      expect(haptics.calls.last, 'urgent');
      expect(haptics.calls.length, count + 1);
      clock.elapse(const Duration(milliseconds: 400));
      expect(haptics.calls.last, 'urgent');
      expect(haptics.calls.length, count + 2);
      clock.elapse(const Duration(milliseconds: 29600));
      expect(controller.vibrating, isFalse);
      final afterEpisode = haptics.calls.length;
      controller.danger(trackId: 5, level: DangerLevel.urgent);
      expect(controller.vibrating, isFalse);
      expect(haptics.calls.length, afterEpisode);
      controller.dispose();
    });
  });

  test('warning and urgent repeat at their respective intervals', () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger(level: DangerLevel.warning);
      clock.elapse(const Duration(milliseconds: 1499));
      expect(haptics.calls, ['warning']);
      clock.elapse(const Duration(milliseconds: 1));
      expect(haptics.calls, ['warning', 'warning']);
      controller.danger(level: DangerLevel.urgent);
      expect(haptics.calls.last, 'urgent');
      clock.elapse(const Duration(milliseconds: 399));
      expect(haptics.calls.where((c) => c == 'urgent').length, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(haptics.calls.where((c) => c == 'urgent').length, 2);
      controller.dispose();
    });
  });

  Future<(MingtuHomeDebugHandle, RecordingHaptics)> setup(
      WidgetTester tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final haptics = RecordingHaptics();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => null);
    hazard(handle);
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.where((c) => c == 'urgent').length, greaterThan(1));
    return (handle, haptics);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  }

  final exits = <String, void Function(MingtuHomeDebugHandle, WidgetTester)>{
    'hazard clears': (h, _) => clearHazard(h),
    'emergency': (h, _) => h.triggerEmergency(),
    'navigation ends': (h, _) => h.debugEndLiveNavigation(),
    'task cancelled': (h, _) => h.voiceCommand('取消任务'),
    'camera closes': (h, _) => h.closeYoloLive(),
    'app background': (_, tester) =>
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused),
    'YOLO error': (h, _) => h.debugYoloViewError(Exception('camera error')),
  };
  for (final exit in exits.entries) {
    testWidgets('danger stops when ${exit.key}', (tester) async {
      final (handle, haptics) = await setup(tester);
      exit.value(handle, tester);
      await tester.pump();
      final count = haptics.calls.where((c) => c == 'urgent').length;
      await tester.pump(const Duration(milliseconds: 1200));
      expect(haptics.calls.where((c) => c == 'urgent').length, count);
      await dispose(tester);
    });
  }

  testWidgets('new track restarts capped danger while the first remains',
      (tester) async {
    final (handle, haptics) = await setup(tester);
    await tester.pump(TtsRecoveryController.dangerDurationCap);
    handle.debugSetHaptics(haptics);
    final count = haptics.calls.length;
    for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        const Detection(
            label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: 0.75, h: 0.75),
        Detection(
            label: 'person', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
      ]);
    }
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.length, greaterThan(count));
    await dispose(tester);
  });

  testWidgets('same continuing track stays silent after the cap',
      (tester) async {
    final (handle, haptics) = await setup(tester);
    await tester.pump(TtsRecoveryController.dangerDurationCap);
    handle.debugSetHaptics(haptics);
    final count = haptics.calls.length;
    continueHazard(handle);
    await tester.pump(const Duration(seconds: 1));
    expect(haptics.calls.length, count);
    await dispose(tester);
  });

  testWidgets('same track escalation restarts capped warning as urgent',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final haptics = RecordingHaptics();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => null);
    for (var i = 0; i < 5; i++) {
      handle.simulateDetections(const <Detection>[
        Detection(
            label: 'person', confidence: 0.9, cx: 0.5, cy: 0.8, w: 0.2, h: 0.2),
      ]);
    }
    expect(haptics.calls, contains('warning'));
    await tester.pump(TtsRecoveryController.dangerDurationCap);
    handle.debugSetHaptics(haptics);
    final count = haptics.calls.length;
    for (final s in <double>[0.22, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        Detection(
            label: 'person', confidence: 0.9, cx: 0.5, cy: 0.75, w: s, h: s),
      ]);
    }
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.skip(count), contains('urgent'));
    await dispose(tester);
  });

  testWidgets('danger cap persists until a new hazard', (tester) async {
    final (handle, haptics) = await setup(tester);
    await tester.pump(TtsRecoveryController.dangerDurationCap);
    // Startup can install its platform haptics while fake time advances.
    handle.debugSetHaptics(haptics);
    final count = haptics.calls.where((c) => c == 'urgent').length;
    continueHazard(handle);
    await tester.pump(const Duration(seconds: 1));
    expect(haptics.calls.where((c) => c == 'urgent').length, count);
    clearHazard(handle);
    hazard(handle, label: 'person');
    await tester.pump(const Duration(milliseconds: 800));
    expect(
        haptics.calls.where((c) => c == 'urgent').length, greaterThan(count));
    await dispose(tester);
  });
}

void hazard(MingtuHomeDebugHandle handle, {String label = 'car'}) {
  for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
    handle.simulateDetections(<Detection>[
      Detection(label: label, confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
    ]);
  }
}

void continueHazard(MingtuHomeDebugHandle handle) {
  for (var i = 0; i < 5; i++) {
    handle.simulateDetections(const <Detection>[
      Detection(
          label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: 0.75, h: 0.75),
    ]);
  }
}

void clearHazard(MingtuHomeDebugHandle handle) {
  for (var i = 0; i < 15; i++) {
    handle.simulateDetections(const <Detection>[]);
  }
}
