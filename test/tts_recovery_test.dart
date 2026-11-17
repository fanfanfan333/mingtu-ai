import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/haptics.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';
import 'package:mingtu_ai/core/permission_flow.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/tts_recovery.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

class FakeStartupTts extends SystemVoiceOutput {
  @override
  Future<bool> initialize() async => false;
}

class FakeOutput implements VoiceOutput {
  final spoken = <String>[];
  @override
  bool get isAvailable => true;
  @override
  String get status => 'ready';
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }
}

/// Records speech and finishes each utterance on a short fake timer.
///
/// The timer (rather than an immediate completion) keeps any runaway
/// re-speak loop bounded by fake time: a regression that replays the same
/// fault forever fails on a count assertion instead of hanging the run.
class PacedFakeOutput extends FakeOutput {
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  testWidgets('permission timeout during TTS failure is spoken after recovery', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp()); await tester.pump();
    final handle = mingtuHomeDebugHandle!; final output = FakeOutput();
    handle.debugFailTts(() async => output);
    expect(handle.debugSayForTest(SpeechKind.alert, text: permissionRequestTimeoutText), isFalse);
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 10; i++) { await tester.pump(); }
    expect(output.spoken, contains(permissionRequestTimeoutText));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'recovered foreground fault is announced once and never replayed again',
      (tester) async {
    var watchdogNow = DateTime(2026);
    mingtuWatchdogNowOverride = () => watchdogNow;
    addTearDown(() => mingtuWatchdogNowOverride = null);
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
    const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
    const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
    // A live tracker arms the foreground location watchdog (location: true).
    handle.debugInstallLiveTracker(
      steps: const <AmapStep>[
        AmapStep(
            action: '直行',
            orientation: '北',
            polyline: [a, b],
            distanceM: 200,
            durationS: 150),
        AmapStep(
            action: '右转',
            orientation: '东',
            polyline: [b, c],
            distanceM: 100,
            durationS: 75),
      ],
      stepTexts: const ['直行', '右转进入林荫道'],
      destination: c,
      destinationName: '图书馆',
    );
    final output = PacedFakeOutput();
    handle.debugFailTts(() async => output);
    // Let the 250 ms foreground ticker observe the live tracker.
    await tester.pump(const Duration(milliseconds: 300));
    // 31 s without a fix latches a location stall while TTS is down: the
    // fault is registered for replay but must stay silent for now.
    watchdogNow = watchdogNow.add(const Duration(seconds: 31));
    await tester.pump(const Duration(milliseconds: 300));
    expect(output.spoken, isNot(contains(foregroundLocationStallText)));
    // TTS recovers -> the stalled fault is announced, and only then marked
    // delivered (the mark is written when the utterance COMPLETES).
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 10; i++) {
      await tester.pump();
    }
    expect(output.spoken, contains(foregroundLocationStallText));
    await tester.pump(const Duration(seconds: 1));
    // Second replay window: another alert finishes while the stall is still
    // active. The same fault text must NOT be spoken a second time.
    handle.debugSayForTest(SpeechKind.alert, text: '测试提示');
    await tester.pump(const Duration(seconds: 2));
    expect(
        output.spoken.where((text) => text == foregroundLocationStallText).length,
        1,
        reason: '同一个前景故障每次卡住只能补发一次，不能反复重播');
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('ASR fault recovery waits for foreground', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp()); await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    handle.debugHandleAsrError('error_permission|permanent=true');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 10; i++) { await tester.pump(); }
    expect(output.spoken, isNot(contains(asrPermissionSpeechText)));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 10; i++) { await tester.pump(); }
    expect(output.spoken, contains(asrPermissionSpeechText));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('ASR permission error during TTS failure is spoken on recovery', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    handle.debugHandleAsrError('error_permission|permanent=true');
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 10; i++) { await tester.pump(); }
    expect(output.spoken, contains(asrPermissionSpeechText));
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 10; i++) { await tester.pump(); }
    expect(output.spoken.where((s) => s == asrPermissionSpeechText).length, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('combined recording and stop command pauses navigation',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    expect(handle.taskState, TaskState.navigating);
    handle.voiceCommand('不要取消导航');
    expect(handle.taskState, TaskState.navigating);
    handle.voiceCommand('我不需要帮助');
    expect(handle.taskState, TaskState.navigating);
    handle.voiceCommand('别删除录像，停下');
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('navigation hazards vibrate after TTS failure pauses the task',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    expect(handle.taskState, TaskState.navigating);
    final haptics = RecordingHaptics();
    final output = FakeOutput();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => output);
    expect(handle.taskState, TaskState.paused);
    for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
      ]);
    }
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.where((c) => c == 'urgent').length,
        greaterThanOrEqualTo(2));
    expect(handle.activeSpeechKind, isNull);
    expect(handle.debugSpeechQueueLength, 0);
    expect(output.spoken, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('entrance search keeps watching hazards during TTS failure',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    handle.destinationApproach();
    expect(handle.taskState, TaskState.findingEntrance);
    final haptics = RecordingHaptics();
    final output = FakeOutput();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => output);
    expect(handle.taskState, TaskState.paused);
    for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
      ]);
    }
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.where((c) => c == 'urgent').length,
        greaterThanOrEqualTo(2));
    expect(handle.activeSpeechKind, isNull);
    expect(handle.debugSpeechQueueLength, 0);
    expect(output.spoken, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('navigation recovery replays a hazard that appeared during failure',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    expect(handle.taskState, TaskState.navigating);
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    expect(handle.taskState, TaskState.paused);
    for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
      ]);
    }
    expect(handle.taskState, TaskState.paused);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(handle.taskState, TaskState.navigating);
    expect(output.spoken.any((text) => text.contains('语音已恢复')), isTrue);
    expect(output.spoken.every((text) => !text.contains('继续导航')), isTrue);
    expect(output.spoken.any((text) => text.contains('车') || text.contains('障碍')), isTrue);
    expect(output.spoken, contains('用盲杖确认。'));
    final recoveryIndex = output.spoken.indexWhere((text) => text.contains('语音已恢复'));
    final hazardIndex = output.spoken.indexWhere(
        (text) => text.contains('车') || text.contains('障碍'));
    expect(recoveryIndex, lessThan(hazardIndex));
    expect(recoveryIndex, lessThan(output.spoken.indexOf('用盲杖确认。')));
    expect(output.spoken.every((text) => !text.contains('直走')), isTrue);
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(output.spoken.every((text) => !text.contains('直走')), isTrue);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('recovery resumes navigation and announces subsequent hazards',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    expect(handle.taskState, TaskState.paused);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(handle.taskState, TaskState.navigating);
    expect(output.spoken, contains('语音已恢复，继续导航。'));
    for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
      ]);
    }
    await tester.pump();
    await tester.pump();
    expect(output.spoken.any((text) => text != '语音已恢复，继续导航。'), isTrue);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('recovery restores emergency and replays fallback guidance',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    handle.triggerEmergency();
    expect(handle.taskState, TaskState.emergency);
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    expect(handle.taskState, TaskState.paused);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(handle.taskState, TaskState.emergency);
    expect(output.spoken.any((text) => text.contains('语音已恢复')), isTrue);
    expect(output.spoken.every((text) => !text.contains('继续导航')), isTrue);
    expect(output.spoken.any((text) => text.contains('备用办法')), isTrue);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('pause during TTS failure remains paused after recovery', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    handle.voiceCommand('暂停');
    expect(handle.taskState, TaskState.paused);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    expect(output.spoken, contains('语音已恢复，导航仍在暂停。'));
    expect(output.spoken.any((text) => text.contains('直走')), isFalse);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
    const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
    const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
    handle.debugInstallLiveTracker(
      steps: const <AmapStep>[
        AmapStep(action: '直行', orientation: '北', polyline: [a, b],
            distanceM: 200, durationS: 150),
        AmapStep(action: '右转', orientation: '东', polyline: [b, c],
            distanceM: 100, durationS: 75),
      ],
      stepTexts: const ['直行', '右转进入林荫道'],
      destination: c,
      destinationName: '图书馆',
    );
    handle.debugLiveFix(GeoPoint(
        latitude: b.latitude! - 25 / 111194.9, longitude: b.longitude), 5);
    await tester.pump();
    await tester.pump();
    expect(output.spoken.any((text) =>
        text.contains('右转') || text.contains('左转') || text.contains('转弯')), isFalse);
    const far = GeoPoint(latitude: 37.730, longitude: 120.450);
    handle.debugLiveFix(far, 5);
    handle.debugLiveFix(far, 5);
    await tester.pump();
    await tester.pump();
    expect(output.spoken.any((text) =>
        text.contains('偏离路线') || text.contains('重新规划')), isFalse);
    expect(handle.taskState, TaskState.paused);
    final haptics = RecordingHaptics();
    handle.debugSetHaptics(haptics);
    for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections(<Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
      ]);
    }
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(haptics.calls.any((c) => c == 'urgent' || c == 'warning'), isTrue);
    expect(output.spoken.any((text) => text.contains('车') ||
        text.contains('障碍') || text.contains('用盲杖确认。')), isTrue);
    expect(handle.taskState, TaskState.paused);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  for (final bool offRoute in <bool>[false, true]) {
    testWidgets(
        offRoute ? 'resume catches up off-route during TTS pause' :
            'resume catches up turn during TTS pause', (tester) async {
      mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
      addTearDown(() => mingtuStartupTtsFactoryOverride = null);
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      final handle = mingtuHomeDebugHandle!;
      handle.startVoiceDemo();
      handle.planRoute();
      handle.startNavigating();
      final output = FakeOutput();
      handle.debugFailTts(() async => output);
      handle.voiceCommand('暂停');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(handle.taskState, TaskState.paused);
      const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
      const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
      const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
      handle.debugInstallLiveTracker(
        steps: const <AmapStep>[
          AmapStep(action: '直行', orientation: '北', polyline: [a, b],
              distanceM: 200, durationS: 150),
          AmapStep(action: '右转', orientation: '东', polyline: [b, c],
              distanceM: 100, durationS: 75),
        ],
        stepTexts: const ['直行', '右转进入林荫道'],
        destination: c,
        destinationName: '图书馆',
      );
      if (offRoute) {
        const far = GeoPoint(latitude: 37.730, longitude: 120.450);
        handle.debugLiveFix(far, 5);
        handle.debugLiveFix(far, 5);
      } else {
        handle.debugLiveFix(GeoPoint(
            latitude: b.latitude! - 25 / 111194.9, longitude: b.longitude), 5);
      }
      await tester.pump();
      await tester.pump();
      expect(output.spoken.any((text) => text.contains('右转') ||
          text.contains('偏离路线') || text.contains('重新规划')), isFalse);
      handle.voiceCommand('继续');
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(handle.taskState, TaskState.navigating);
      expect(output.spoken.any((text) => text.contains(
          offRoute ? '偏离路线' : '右转进入林荫道')), isTrue);
      expect(output.spoken.any((text) => text.contains('已恢复导航，但直行提醒还没有恢复')), isTrue);
      if (offRoute) expect(handle.debugRerouting, isTrue);
      expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('resume skips a passed turn and announces the next turn', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    handle.voiceCommand('暂停');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    expect(output.spoken, contains('语音已恢复，导航仍在暂停。'));

    const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
    const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
    const pastB = GeoPoint(latitude: 37.726206, longitude: 120.441950);
    const beforeC = GeoPoint(latitude: 37.726206, longitude: 120.442575);
    const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
    const d = GeoPoint(latitude: 37.728, longitude: 120.442859);
    handle.debugInstallLiveTracker(
      steps: const <AmapStep>[
        AmapStep(action: '直行', orientation: '北', polyline: [a, b],
            distanceM: 200, durationS: 150),
        AmapStep(action: '右转', orientation: '东',
            polyline: [b, pastB, beforeC, c], distanceM: 100, durationS: 75),
        AmapStep(action: '左转', orientation: '北', polyline: [c, d],
            distanceM: 200, durationS: 150),
      ],
      stepTexts: const ['直行', '右转进入林荫道', '左转进入广场'],
      destination: d,
      destinationName: '广场',
    );
    handle.debugLiveFix(GeoPoint(
        latitude: b.latitude! - 25 / 111194.9, longitude: b.longitude), 5);
    await tester.pump();
    await tester.pump();
    expect(output.spoken.any((text) => text.contains('右转')), isFalse);
    handle.debugLiveFix(pastB, 5);
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    expect(output.spoken.any((text) => text.contains('右转')), isFalse);

    handle.voiceCommand('继续');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(handle.taskState, TaskState.navigating);
    expect(output.spoken.any((text) => text.contains('右转进入林荫道')), isFalse);

    handle.debugLiveFix(beforeC, 5);
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(output.spoken.any((text) => text.contains('左转进入广场')), isTrue);
    expect(output.spoken.every((text) => !containsBannedWord(text) &&
        !text.contains('左右移步') && !text.contains('可以通行') &&
        !text.contains('放心') && !text.contains('畅通') &&
        !text.contains('没有障碍')), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('resume catches up bare turn near the kerb', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    handle.voiceCommand('暂停');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
    const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
    const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
    handle.debugInstallLiveTracker(
      steps: const <AmapStep>[
        AmapStep(action: '直行', orientation: '北', polyline: [a, b],
            distanceM: 200, durationS: 150),
        AmapStep(action: '右转', orientation: '东', polyline: [b, c],
            distanceM: 100, durationS: 75),
      ],
      stepTexts: const ['直行', '右转进入林荫道'],
      destination: c,
      destinationName: '图书馆',
    );
    handle.debugLiveFix(GeoPoint(
        latitude: b.latitude! - 1 / 111194.9, longitude: b.longitude), 5);
    await tester.pump();
    await tester.pump();
    expect(output.spoken.any((text) => text.contains('右转')), isFalse);
    handle.voiceCommand('继续');
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(handle.taskState, TaskState.navigating);
    final turns = output.spoken.where((text) => text.contains('右转进入林荫道'));
    expect(turns, isNotEmpty);
    expect(turns.every((text) => !text.contains('前方') && !text.contains('米')), isTrue);
    expect(output.spoken.every((text) => !text.contains('左右移步') &&
        !text.contains('左移') && !text.contains('右移')), isTrue);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  for (final bool stale in <bool>[false, true]) {
    testWidgets(stale ? 'resume ignores stale off-route fix' :
        'resume ignores low-accuracy off-route fix', (tester) async {
      mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
      addTearDown(() => mingtuStartupTtsFactoryOverride = null);
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      final handle = mingtuHomeDebugHandle!;
      handle.startVoiceDemo();
      handle.planRoute();
      handle.startNavigating();
      final output = FakeOutput();
      handle.debugFailTts(() async => output);
      handle.voiceCommand('暂停');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(handle.taskState, TaskState.paused);
      expect(output.spoken, contains('语音已恢复，导航仍在暂停。'));
      const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
      const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
      const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
      handle.debugInstallLiveTracker(
        steps: const <AmapStep>[
          AmapStep(action: '直行', orientation: '北', polyline: [a, b],
              distanceM: 200, durationS: 150),
          AmapStep(action: '右转', orientation: '东', polyline: [b, c],
              distanceM: 100, durationS: 75),
        ],
        stepTexts: const ['直行', '右转进入林荫道'],
        destination: c,
        destinationName: '图书馆',
      );
      const far = GeoPoint(latitude: 37.730, longitude: 120.450);
      for (var i = 0; i < NavigationTracker.offRouteFixesNeeded; i++) {
        handle.debugLiveFix(far, stale ? 5 : 80);
      }
      if (stale) {
        handle.debugSetLastFixAt(DateTime.now().subtract(const Duration(days: 1)));
      }
      await tester.pump();
      expect(output.spoken.any((text) => text.contains('偏离路线') ||
          text.contains('重新规划')), isFalse);
      handle.voiceCommand('继续');
      await tester.pump();
      await tester.pump();
      expect(handle.taskState, TaskState.navigating);
      expect(handle.debugRerouting, isFalse);
      expect(output.spoken.any((text) => text.contains('偏离路线') ||
          text.contains('重新规划')), isFalse);
      for (var i = 0; i < NavigationTracker.offRouteFixesNeeded; i++) {
        handle.debugLiveFix(far, 5);
      }
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(output.spoken.any((text) => text.contains('偏离路线')), isTrue);
      expect(handle.debugRerouting, isTrue);
      expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });
  }

  for (final scenario in <String>[
    'stale', 'inaccurate', 'cancel', 'emergency', 'end', 'arrival', 'new turn', 'off route'
  ]) {
    testWidgets('deferred turn catch-up: $scenario', (tester) async {
      mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
      addTearDown(() => mingtuStartupTtsFactoryOverride = null);
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      final handle = mingtuHomeDebugHandle!;
      handle.startVoiceDemo();
      handle.planRoute();
      handle.startNavigating();
      final output = FakeOutput();
      handle.debugFailTts(() async => output);
      handle.voiceCommand('暂停');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(handle.taskState, TaskState.paused);
      const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
      const b = GeoPoint(latitude: 37.726206, longitude: 120.441723);
      const pastB = GeoPoint(latitude: 37.726206, longitude: 120.441950);
      const beforeC = GeoPoint(latitude: 37.726206, longitude: 120.442575);
      const c = GeoPoint(latitude: 37.726206, longitude: 120.442859);
      const d = GeoPoint(latitude: 37.728, longitude: 120.442859);
      final beforeB = GeoPoint(
          latitude: b.latitude! - 25 / 111194.9, longitude: b.longitude);
      handle.debugInstallLiveTracker(
        steps: const <AmapStep>[
          AmapStep(action: '直行', orientation: '北', polyline: [a, b],
              distanceM: 200, durationS: 150),
          AmapStep(action: '右转', orientation: '东',
              polyline: [b, pastB, beforeC, c], distanceM: 100, durationS: 75),
          AmapStep(action: '左转', orientation: '北', polyline: [c, d],
              distanceM: 200, durationS: 150),
        ],
        stepTexts: const ['直行', '右转进入林荫道', '左转进入广场'],
        destination: d,
        destinationName: '广场',
      );
      handle.debugLiveFix(beforeB, 5);
      expect(handle.debugPendingTurnStepIndex, isNotNull);
      if (scenario == 'stale') {
        handle.debugSetLastFixAt(DateTime.now().subtract(const Duration(days: 1)));
      } else {
        handle.debugLiveFix(beforeB, 80);
      }
      handle.voiceCommand('继续');
      await tester.pump();
      await tester.pump();
      expect(handle.debugPendingTurnStepIndex, isNotNull);
      expect(output.spoken.any((text) => text.contains('右转进入林荫道')), isFalse);
      handle.debugLiveFix(beforeB, 80);
      await tester.pump();
      expect(handle.debugPendingTurnStepIndex, isNotNull);
      expect(output.spoken.any((text) => text.contains('右转进入林荫道') ||
          text.contains('偏离路线')), isFalse);
      switch (scenario) {
        case 'cancel':
          handle.voiceCommand('取消');
        case 'emergency':
          handle.triggerEmergency();
        case 'end':
          handle.debugEndLiveNavigation();
        case 'arrival':
          handle.debugFinishEntranceTrip();
        case 'new turn':
          handle.debugLiveFix(beforeC, 5);
        case 'off route':
          handle.debugLiveFix(const GeoPoint(latitude: 37.730, longitude: 120.450), 5);
        default:
          handle.debugLiveFix(beforeB, 5);
      }
      if (<String>['cancel', 'emergency', 'end', 'arrival'].contains(scenario)) {
        expect(handle.debugPendingTurnStepIndex, isNull);
        handle.debugLiveFix(beforeB, 5);
      }
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));
      await tester.pump();
      expect(handle.debugPendingTurnStepIndex, isNull);
      expect(output.spoken.any((text) => text.contains('右转进入林荫道')),
          scenario == 'stale' || scenario == 'inaccurate');
      if (scenario == 'new turn') {
        expect(output.spoken.any((text) => text.contains('左转进入广场')), isTrue);
      }
      if (scenario == 'off route') {
        expect(output.spoken.any((text) => text.contains('偏离路线')), isTrue);
        expect(handle.debugRerouting, isTrue);
      }
      expect(output.spoken.every((text) => !containsBannedWord(text) &&
          !text.contains('左移') && !text.contains('右移') &&
          !text.contains('可以通行') && !text.contains('放心') &&
          !text.contains('畅通') && !text.contains('没有障碍')), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('recovery restores entrance search with matching wording', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    handle.destinationApproach();
    expect(handle.taskState, TaskState.findingEntrance);
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    await tester.pump();
    expect(handle.taskState, TaskState.findingEntrance);
    expect(output.spoken, contains('语音已恢复，仍在寻找入口。'));
    expect(output.spoken.any((text) => text.contains('继续')), isFalse);
    expect(output.spoken.any((text) => text.contains('直走')), isFalse);
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('recovery preserves a user initiated pause', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    handle.voiceCommand('暂停');
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(handle.taskState, TaskState.paused);
    expect(output.spoken, contains('语音已恢复，导航仍在暂停。'));
    expect(containsBannedWord(output.spoken.last), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'navigation recovery re-arms straight prompts at 3 second intervals',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    var now = DateTime(2026);
    handle.debugSetStraightClock(() => now);
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    expect(handle.taskState, TaskState.navigating);
    expect(output.spoken, isNot(contains('直走')));
    expect(handle.activeSpeechText, isNot('直走'));
    expect(handle.debugSpeechQueueLength, 0);
    now = now.add(const Duration(seconds: 2));
    await tester.pump(const Duration(seconds: 2));
    expect(output.spoken, isNot(contains('直走')));
    expect(handle.activeSpeechText, isNot('直走'));
    expect(handle.debugSpeechQueueLength, 0);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(output.spoken.where((text) => text == '直走').length, 1);
    now = now.add(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    expect(output.spoken.where((text) => text == '直走').length,
        greaterThanOrEqualTo(2));
    expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  for (final scenario in <String>['hazard remains', 'hazard clears', 'demo hazard clears']) {
    testWidgets('recovery when $scenario during TTS failure', (tester) async {
      mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
      var frameTime = DateTime(2026);
      mingtuYoloNowOverride = () {
        frameTime = frameTime.add(const Duration(milliseconds: 200));
        return frameTime;
      };
      addTearDown(() => mingtuYoloNowOverride = null);
      addTearDown(() => mingtuStartupTtsFactoryOverride = null);
      await tester.pumpWidget(const MingtuApp());
      await tester.pump();
      final handle = mingtuHomeDebugHandle!;
      var now = DateTime(2026);
      handle.debugSetStraightClock(() => now);
      handle.startVoiceDemo();
      handle.planRoute();
      handle.startNavigating();
      final output = FakeOutput();
      if (scenario == 'demo hazard clears') {
        handle.debugFailTts(() async => output);
      }
      for (final s in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
        handle.simulateDetections(<Detection>[
          Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: s, h: s),
        ]);
      }
      await tester.pump();
      if (scenario != 'demo hazard clears') {
        expect(handle.taskState, TaskState.avoidingObstacle);
        handle.debugFailTts(() async => output);
      }
      expect(handle.taskState, TaskState.paused);
      if (scenario == 'hazard remains') {
        handle.simulateDetections(<Detection>[
          const Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: 0.75, h: 0.75),
        ]);
      } else {
        for (var i = 0; i < 3; i++) {
          handle.simulateDetections(const <Detection>[]);
        }
      }
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      if (scenario == 'hazard remains') {
        expect(handle.taskState, TaskState.avoidingObstacle);
        expect(output.spoken.any((text) => text.contains('语音已恢复')), isTrue);
        expect(output.spoken.every((text) => !text.contains('继续导航')), isTrue);
        expect(output.spoken.any((text) => text.contains('车') || text.contains('障碍')), isTrue);
        expect(output.spoken, contains('用盲杖确认。'));
        // 顺序断言：危险仍在时必须先说「语音已恢复」，再说危险，最后说
        // 「用盲杖确认。」——先报危险会让用户误以为语音已可用。
        final recoveryIndex = output.spoken.indexWhere((text) => text.contains('语音已恢复'));
        final hazardIndex = output.spoken.indexWhere(
            (text) => text.contains('车') || text.contains('障碍'));
        final confirmIndex = output.spoken.indexOf('用盲杖确认。');
        expect(recoveryIndex, lessThan(hazardIndex));
        expect(hazardIndex, lessThan(confirmIndex));
        // 危险仍在时不得播「直走」：这是最危险的误导（会让人直接撞上去）。
        expect(output.spoken.every((text) => !text.contains('直走')), isTrue);
      } else {
        expect(handle.taskState, TaskState.navigating);
        expect(output.spoken, contains('语音已恢复，继续导航。'));
        expect(output.spoken.any((text) => text.contains('请说继续')), isFalse);
        now = now.add(const Duration(seconds: 3));
        await tester.pump(const Duration(seconds: 3));
        await tester.pump();
        expect(output.spoken, contains('直走'));
      }
      expect(output.spoken.every((text) => !containsBannedWord(text)), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
    });
  }

  testWidgets('user pause remains quiet after TTS recovery', (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    handle.startVoiceDemo();
    handle.planRoute();
    handle.startNavigating();
    handle.voiceCommand('暂停');
    await tester.pump();
    final output = FakeOutput();
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 10));
    expect(handle.taskState, TaskState.paused);
    expect(output.spoken, isNot(contains('直走')));
    expect(handle.activeSpeechText, isNot('直走'));
    expect(handle.debugSpeechQueueLength, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  test('retries after 1, 3, 10 and repeated 10 second delays', () {
    fakeAsync((clock) {
      var attempts = 0;
      final announcements = <String>[];
      final start = DateTime(2026);
      final controller = TtsRecoveryController(
        now: () => start.add(clock.elapsed),
        haptics: RecordingHaptics.new,
        rebuild: () async {
          attempts++;
          return attempts == 4 ? FakeOutput() : null;
        },
        onRecovered: (_, text) => announcements.add(text),
      );
      controller.fail();
      expect(controller.failedAt, start);
      clock.elapse(const Duration(milliseconds: 999));
      expect(attempts, 0);
      clock.elapse(const Duration(milliseconds: 1));
      expect(attempts, 1);
      clock.elapse(const Duration(milliseconds: 2999));
      expect(attempts, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(attempts, 2);
      clock.elapse(const Duration(seconds: 10));
      expect(attempts, 3);
      clock.elapse(const Duration(seconds: 10));
      expect(attempts, 4);
      expect(announcements, ['语音已恢复']);
      expect(containsBannedWord(announcements.single), isFalse);
      clock.elapse(const Duration(seconds: 30));
      expect(announcements, hasLength(1));
      controller.dispose();
    });
  });

  test('active danger repeats until recovery and can start on another failure',
      () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      var attempts = 0;
      final announcements = <String>[];
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => ++attempts == 1 ? null : FakeOutput(),
        onRecovered: (_, text) => announcements.add(text),
      );
      controller.fail();
      controller.danger();
      controller.danger();
      clock.elapse(const Duration(milliseconds: 800));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent']);
      expect(controller.vibrating, isTrue);
      clock.elapse(const Duration(milliseconds: 3200));
      expect(controller.failed, isFalse);
      expect(controller.vibrating, isFalse);
      final count = haptics.calls.length;
      controller.danger();
      clock.elapse(const Duration(seconds: 1));
      expect(haptics.calls.length, count);
      controller.fail();
      controller.danger();
      expect(haptics.calls.length, count + 1);
      clock.elapse(const Duration(seconds: 1));
      expect(announcements, ['语音已恢复', '语音已恢复']);
      controller.dispose();
    });
  });
  test('cleared danger stops while failed and a new danger can restart', () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger();
      clock.elapse(const Duration(milliseconds: 800));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent']);
      controller.stopDanger();
      expect(controller.failed, isTrue);
      expect(controller.vibrating, isFalse);
      clock.elapse(const Duration(seconds: 2));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent']);
      controller.danger();
      expect(haptics.calls, ['urgent', 'urgent', 'urgent', 'urgent']);
      clock.elapse(const Duration(milliseconds: 400));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent', 'urgent', 'urgent']);
      controller.dispose();
    });
  });

  testWidgets('failed emergency and alert use one-shot haptics without speech',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    final haptics = RecordingHaptics();
    final output = FakeOutput();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => output);
    expect(handle.debugSayForTest(SpeechKind.emergency), isFalse);
    expect(handle.debugSayForTest(SpeechKind.alert), isFalse);
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls, ['urgent', 'warning']);
    expect(handle.activeSpeechKind, isNull);
    expect(handle.debugSpeechQueueLength, 0);
    expect(output.spoken, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'failed danger is not completed as speech; recovery restores speech',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    final haptics = RecordingHaptics();
    final output = FakeOutput();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => output);
    handle.debugSpeakHazard('前方有障碍');
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.where((c) => c == 'urgent').length, greaterThan(1));
    expect(handle.activeSpeechKind, isNull);
    expect(output.spoken, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    expect(output.spoken, contains('语音已恢复'));
    final count = haptics.calls.length;
    handle.debugSpeakHazard('前方有障碍');
    await tester.pump();
    await tester.pump();
    expect(output.spoken, contains('前方有障碍'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(haptics.calls.length, count);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
