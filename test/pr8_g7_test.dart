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

  testWidgets('danger cap persists until a new hazard', (tester) async {
    final (handle, haptics) = await setup(tester);
    await tester.pump(TtsRecoveryController.dangerDurationCap);
    // Startup can install its platform haptics while fake time advances.
    handle.debugSetHaptics(haptics);
    final count = haptics.calls.where((c) => c == 'urgent').length;
    hazard(handle);
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

void clearHazard(MingtuHomeDebugHandle handle) {
  for (var i = 0; i < 15; i++) {
    handle.simulateDetections(const <Detection>[]);
  }
}
