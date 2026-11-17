import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/location_signal_speech.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/core/wakelock_control.dart';
import 'package:mingtu_ai/core/yolo_error_speech.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;
import 'tts_recovery_test.dart' as recovery;

class FakeWakelockGateway implements WakelockGateway {
  final calls = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async => calls.add(enabled);
}

class PendingRecoveryOutput implements VoiceOutput {
  final spoken = <String>[];
  final pending = <Completer<void>>[];
  @override
  bool get isAvailable => true;
  @override
  String get status => 'ready';
  @override
  Future<void> speak(String text) {
    spoken.add(text);
    final c = Completer<void>(); pending.add(c); return c.future;
  }
}

/// Real-device fix round: a GPS provider that NEVER answers. The
/// REAL-navigation start therefore stays in its waiting window,
/// which is exactly the window the progress prompt exists for.
class HangingLocation implements CurrentLocationProvider {
  final Completer<LocationResult> gate = Completer<LocationResult>();
  int calls = 0;

  @override
  Future<LocationResult> currentLocation() {
    calls++;
    return gate.future;
  }

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

/// A GPS provider that answers AT ONCE with a fix too coarse to
/// start from (80 m). The start attempt finishes immediately, so
/// the progress prompt must stay silent even though the delay is
/// just as short as in the hanging case: that is the proof the
/// prompt is conditional, not unconditional.
class InstantCoarseLocation implements CurrentLocationProvider {
  int calls = 0;

  @override
  Future<LocationResult> currentLocation() async {
    calls++;
    return LocationResult.fix(
      const GeoPoint(latitude: 39.908692, longitude: 116.397477),
      80,
    );
  }

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

/// Pump the fake clock (and complete whatever the TTS fake is
/// holding) until [until] is true or the budget runs out.
Future<void> _settleUntil(ui.RecordingVoiceChannels h, WidgetTester tester,
    bool Function() until,
    {int rounds = 20}) async {
  for (int i = 0; i < rounds && !until(); i++) {
    await tester.pump(const Duration(milliseconds: 20));
    h.completeAllSpeaks();
  }
  h.completeAllSpeaks();
  await tester.pump();
}

void main() {
  setUp(() {
    mingtuPermissionGatewayOverride = s1.FakePermissionGateway();
    mingtuGuideStoreOverride = s1.FakeGuideStore(seen: true);
    mingtuYoloAvailableOverride = true;
  });

  tearDown(() {
    mingtuPermissionGatewayOverride = null;
    mingtuGuideStoreOverride = null;
    mingtuYoloAvailableOverride = null;
    mingtuWakelockGatewayOverride = null;
    mingtuWatchdogNowOverride = null;
    mingtuYoloViewBuilderOverride = null;
    mingtuLocationProviderOverride = null;
    mingtuNavLocationProgressDelayOverride = null;
    mingtuNavLocationProgressSecondDelayOverride = null;
  });

  for (final stillActive in [true, false]) {
  testWidgets('camera stall recovery, still active: $stillActive',
      (tester) async {
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    await handle.openYoloLive();
    final output = recovery.FakeOutput();
    handle.debugFailTts(() async => output);
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 250));
    if (!stillActive) handle.closeYoloLive();
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(output.spoken.contains(foregroundCameraStallText), stillActive);
    await ui.shutdownVoice(tester, channels);
  });
  }

  for (final stillFailed in [true, false]) {
    testWidgets('location signal error on TTS recovery, still failed: $stillFailed', (tester) async {
      mingtuWakelockGatewayOverride = FakeWakelockGateway();
      final channels = ui.RecordingVoiceChannels()..install();
      addTearDown(channels.uninstall);
      await ui.settleRecordedApp(tester, channels);
      final handle = mingtuHomeDebugHandle!;
      handle.startVoiceDemo(); handle.planRoute(); handle.startNavigating();
      const a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
      const b = GeoPoint(latitude: 37.723667, longitude: 120.443212);
      handle.debugInstallLiveTracker(
        steps: const [AmapStep(action: '直行', orientation: '东', polyline: [a, b], distanceM: 200, durationS: 150)],
        stepTexts: const ['直行'], destination: b, destinationName: '图书馆');
      final output = recovery.FakeOutput();
      handle.debugFailTts(() async => output);
      handle.debugLiveLocationResult(LocationResult.error(LocationFailure.failed, 'fixture'));
      if (!stillFailed) handle.debugLiveFix(a, 5);
      await tester.pump(const Duration(seconds: 1));
      for (var i = 0; i < 8; i++) { await tester.pump(); }
      expect(output.spoken.contains(locationSignalLostText), stillFailed);
      await ui.shutdownVoice(tester, channels);
    });
  }

  testWidgets('ASR error alert interrupted by danger is retried', (tester) async {
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    final output = PendingRecoveryOutput();
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    handle.debugHandleAsrError('error_permission|permanent=true');
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(output.spoken, contains(asrPermissionSpeechText));
    handle.debugSpeakHazard('停，前方来车。');
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    final hazard = output.spoken.indexOf('停，前方来车。');
    expect(hazard, greaterThanOrEqualTo(0), reason: '${output.spoken}');
    output.pending[hazard].complete();
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken.where((s) => s == asrPermissionSpeechText).length, 2,
        reason: '${output.spoken}');
    for (final c in output.pending) { if (!c.isCompleted) c.complete(); }
    await ui.shutdownVoice(tester, channels);
  });

  testWidgets('active camera fault is replayed if new danger interrupts it', (tester) async {
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    await handle.openYoloLive();
    final output = PendingRecoveryOutput();
    handle.debugFailTts(() async => output);
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(output.spoken, contains(foregroundCameraStallText));
    handle.debugSpeakHazard('停，前方来车。');
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    final hazard = output.spoken.indexOf('停，前方来车。');
    expect(hazard, greaterThanOrEqualTo(0), reason: '${output.spoken}');
    output.pending[hazard].complete();
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken.where((s) => s == foregroundCameraStallText).length, 2,
        reason: '${output.spoken}');
    for (final c in output.pending) { if (!c.isCompleted) c.complete(); }
    await ui.shutdownVoice(tester, channels);
  });

  testWidgets('queued obstacle guidance precedes pending camera fault', (tester) async {
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    await handle.openYoloLive();
    final output = PendingRecoveryOutput();
    handle.debugFailTts(() async => output);
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(output.spoken, contains(foregroundCameraStallText));
    expect(handle.debugSayForTest(SpeechKind.emergency, text: '紧急提示'), isTrue);
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(handle.debugSayForTest(SpeechKind.obstacleAvoidance, text: '避障提示'), isTrue);
    final emergency = output.spoken.indexOf('紧急提示');
    expect(emergency, greaterThanOrEqualTo(0));
    output.pending[emergency].complete();
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken.last, '避障提示', reason: '${output.spoken}');
    output.pending.last.complete();
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken.last, foregroundCameraStallText, reason: '${output.spoken}');
    for (final c in output.pending) { if (!c.isCompleted) c.complete(); }
    await ui.shutdownVoice(tester, channels);
  });

  testWidgets('ordinary camera fault interrupted by danger is replayed', (tester) async {
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    final output = PendingRecoveryOutput();
    handle.debugFailTts(() async => output);
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    for (final c in output.pending) { if (!c.isCompleted) c.complete(); }
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    await handle.openYoloLive();
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 250));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(output.spoken, contains(foregroundCameraStallText));
    handle.debugSpeakHazard('停，前方来车。');
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    final hazard = output.spoken.indexOf('停，前方来车。');
    expect(hazard, greaterThanOrEqualTo(0));
    output.pending[hazard].complete();
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken.where((s) => s == foregroundCameraStallText).length, 2);
    for (final c in output.pending) { if (!c.isCompleted) c.complete(); }
    await ui.shutdownVoice(tester, channels);
  });

  testWidgets('danger replay survives interruption of recovery announcement', (tester) async {
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    await handle.openYoloLive();
    handle.startVoiceDemo(); handle.planRoute(); handle.startNavigating();
    for (final size in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections([Detection(label: 'car', confidence: 0.9,
          cx: 0.5, cy: 0.55, w: size, h: size)]);
    }
    final output = PendingRecoveryOutput();
    handle.debugFailTts(() async => output);
    handle.simulateDetections([const Detection(label: 'car', confidence: 0.9,
        cx: 0.5, cy: 0.55, w: 0.75, h: 0.75)]);
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    expect(output.spoken.any((s) => s.contains('语音已恢复')), isTrue);
    expect(handle.debugSayForTest(SpeechKind.alert), isTrue);
    for (var i = 0; i < 8; i++) { await tester.pump(); }
    final alert = output.spoken.indexOf('测试提示');
    if (alert >= 0) output.pending[alert].complete();
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken.any((s) => s.contains('车') || s.contains('障碍')), isTrue,
        reason: '${output.spoken}');
    for (final c in output.pending) { if (!c.isCompleted) c.complete(); }
    await ui.shutdownVoice(tester, channels);
  });

  testWidgets('danger is replayed before camera fault after TTS recovery',
      (tester) async {
    var frameTime = DateTime(2026);
    mingtuYoloNowOverride = () {
      frameTime = frameTime.add(const Duration(milliseconds: 200));
      return frameTime;
    };
    addTearDown(() => mingtuYoloNowOverride = null);
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    final channels = ui.RecordingVoiceChannels()..install();
    addTearDown(channels.uninstall);
    await ui.settleRecordedApp(tester, channels);
    final handle = mingtuHomeDebugHandle!;
    await handle.openYoloLive();
    handle.startVoiceDemo(); handle.planRoute(); handle.startNavigating();
    for (final size in <double>[0.20, 0.32, 0.45, 0.60, 0.75]) {
      handle.simulateDetections([Detection(label: 'car', confidence: 0.9,
          cx: 0.5, cy: 0.55, w: size, h: size)]);
    }
    final output = recovery.FakeOutput();
    handle.debugFailTts(() async => output);
    handle.simulateDetections([const Detection(label: 'car', confidence: 0.9,
        cx: 0.5, cy: 0.55, w: 0.75, h: 0.75)]);
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(seconds: 1));
    for (var i = 0; i < 20; i++) { await tester.pump(); }
    final hazard = output.spoken.indexWhere((s) => s.contains('车') || s.contains('障碍'));
    final fault = output.spoken.indexOf(foregroundCameraStallText);
    expect(hazard, greaterThanOrEqualTo(0), reason: '${output.spoken}');
    expect(fault, greaterThan(hazard), reason: '${output.spoken}');
    await ui.shutdownVoice(tester, channels);
  });

  testWidgets('camera request during inactive opens on resume', (tester) async {
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    final handle = mingtuHomeDebugHandle!;
    handle.closeYoloLive();
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await handle.openYoloLive();
    expect(handle.yoloLiveOpen, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 8; i++) { await tester.pump(const Duration(milliseconds: 100)); }
    expect(handle.yoloLiveOpen, isTrue);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('camera reopens after returning to foreground', (tester) async {
    mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    final handle = mingtuHomeDebugHandle!;
    await handle.openYoloLive();
    await tester.pump();
    expect(handle.yoloLiveOpen, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(handle.yoloLiveOpen, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    for (var i = 0; i < 8; i++) { await tester.pump(const Duration(milliseconds: 100)); }
    expect(handle.yoloLiveOpen, isTrue);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('camera live view enables and closing disables wakelock',
      (tester) async {
    final gateway = FakeWakelockGateway();
    mingtuWakelockGatewayOverride = gateway;
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);

    await mingtuHomeDebugHandle!.openYoloLive();
    expect(mingtuHomeDebugHandle!.yoloLiveOpen, isTrue);
    await tester.pump(const Duration(milliseconds: 250));
    expect(gateway.calls.last, isTrue);

    mingtuHomeDebugHandle!.closeYoloLive();
    await tester.pump(const Duration(milliseconds: 250));
    expect(gateway.calls.last, isFalse);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('camera stall announces a Chinese alert after ten seconds',
      (tester) async {
    var now = DateTime(2026, 1, 1);
    mingtuWatchdogNowOverride = () => now;
    mingtuWakelockGatewayOverride = FakeWakelockGateway();
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);

    await mingtuHomeDebugHandle!.openYoloLive();
    expect(mingtuHomeDebugHandle!.yoloLiveOpen, isTrue);
    now = now.add(AppConfig.foregroundCameraStallThreshold);
    await tester.pump(const Duration(milliseconds: 250));
    expect(mingtuHomeDebugHandle!.activeSpeechText, foregroundCameraStallText);
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.alert);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('YOLO model error announces the Chinese fault alert',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);

    mingtuYoloViewBuilderOverride = (onError) {
      WidgetsBinding.instance.addPostFrameCallback(
          (_) => onError(Exception('tflite model failed')));
      return const SizedBox();
    };
    await mingtuHomeDebugHandle!.openYoloLive();
    await tester.pump();
    await tester.pump();
    expect(mingtuHomeDebugHandle!.activeSpeechText,
        yoloViewErrorSpeech(YoloViewErrorKind.modelLoadFailed));
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.alert);
    await ui.shutdownVoice(tester, h);
  });
  testWidgets('listening enables wakelock and background disables it',
      (tester) async {
    final gateway = FakeWakelockGateway();
    mingtuWakelockGatewayOverride = gateway;
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await s1.settleToggleApp(tester, h);
    final before = h.count('asr.listen');
    await mingtuHomeDebugHandle!.debugHeadsetToggle();
    await s1.pumpUntil(
        tester, h, () => h.count('asr.listen') > before, 'listening');
    await tester.pump(const Duration(milliseconds: 250));
    expect(gateway.calls.last, isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(milliseconds: 250));
    expect(gateway.calls.last, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await ui.shutdownVoice(tester, h);
  });
  testWidgets('navigation enables wakelock', (tester) async {
    final gateway = FakeWakelockGateway();
    mingtuWakelockGatewayOverride = gateway;
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    mingtuHomeDebugHandle!.debugInstallLiveTracker(
        steps: <AmapStep>[],
        stepTexts: <String>[],
        destination: const GeoPoint(latitude: 1, longitude: 1),
        destinationName: '目的地');
    await tester.pump(const Duration(milliseconds: 250));
    expect(gateway.calls.last, isTrue);
    await ui.shutdownVoice(tester, h);
  });

  group('real-navigation start progress prompt', () {
    /// A CONFIGURED route client: without one the start refuses at
    /// its "proxy configured" check and the GPS is never asked (a
    /// test build has no proxy URL). Its sender must never run --
    /// the location step is where every case here stops.
    AmapWalkingClient configuredClient() => AmapWalkingClient(
          proxyBaseUrl: 'https://proxy.example.test',
          sender: (Uri url) async =>
              throw StateError('no route request expected in this test'),
        );

    /// Occurrences of one spoken line in the TTS event stream.
    int spokenCount(ui.RecordingVoiceChannels h, String text) => h.events
        .where((String e) => e == 'tts.speak:$text')
        .length;

    // The two prompts share ONE schedule source of truth: both delays
    // have their own override (AppConfig.effectiveNavLocationProgressDelay
    // / ...SecondDelay), so a test can fire them at the same instant
    // without touching the production 8 s / 22 s pair. Pinning both
    // overrides together keeps the zero-delay cases deterministic --
    // no test ever sleeps for 22 real seconds.
    void armBothPromptsImmediately() {
      mingtuNavLocationProgressDelayOverride = Duration.zero;
      mingtuNavLocationProgressSecondDelayOverride = Duration.zero;
    }

    testWidgets('a start still waiting speaks BOTH progress prompts, once each',
        (tester) async {
      final HangingLocation location = HangingLocation();
      mingtuLocationProviderOverride = location;
      armBothPromptsImmediately();
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(configuredClient());
      mingtuHomeDebugHandle!.fetchAmapRoute();
      await _settleUntil(
          h,
          tester,
          () =>
              spokenCount(h, navLocationProgressStillWaitingSpeech) >= 1);

      // The start really is waiting on the GPS...
      expect(location.calls, 1, reason: 'the GPS was asked exactly once');
      expect(location.gate.isCompleted, isFalse, reason: 'still waiting');
      // ...and the user HEARS that, twice over ~35 s, instead of
      // dead air that reads as a crash.
      expect(h.events, contains('tts.speak:$navLocationProgressSpeech'),
          reason: '${h.events}');
      expect(h.events,
          contains('tts.speak:$navLocationProgressStillWaitingSpeech'),
          reason: '${h.events}');
      // Exactly one of each: extra repeats would nag.
      expect(spokenCount(h, navLocationProgressSpeech), 1,
          reason: '${h.events}');
      expect(spokenCount(h, navLocationProgressStillWaitingSpeech), 1,
          reason: '${h.events}');
      location.gate.complete(LocationResult.error(
          LocationFailure.failed, 'test teardown'));
      await tester.pump();
      await ui.shutdownVoice(tester, h);
    });

    testWidgets('an immediate answer speaks NEITHER progress prompt',
        (tester) async {
      final InstantCoarseLocation location = InstantCoarseLocation();
      mingtuLocationProviderOverride = location;
      // SAME delays as the case above: the only difference is that
      // the attempt finishes immediately.
      armBothPromptsImmediately();
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(configuredClient());
      mingtuHomeDebugHandle!.fetchAmapRoute();
      await _settleUntil(
          h, tester, () => h.events.any((String e) => e.contains('导航没有启动')));

      expect(location.calls, 1);
      // The attempt completed, so the user got the real verdict --
      // not a "hang on" prompt for a wait that already ended.
      expect(h.events.any((String e) => e.contains('定位精度不够')), isTrue,
          reason: '${h.events}');
      expect(h.events, isNot(contains('tts.speak:$navLocationProgressSpeech')),
          reason: '${h.events}');
      expect(
          h.events,
          isNot(contains(
              'tts.speak:$navLocationProgressStillWaitingSpeech')),
          reason: '${h.events}');
      await ui.shutdownVoice(tester, h);
    });

    testWidgets('停下 cancels BOTH progress prompts', (tester) async {
      final HangingLocation location = HangingLocation();
      mingtuLocationProviderOverride = location;
      // Realistic delays here: the start is stopped INSIDE the
      // waiting window, before either prompt could ever be due.
      mingtuNavLocationProgressDelayOverride = const Duration(seconds: 8);
      mingtuNavLocationProgressSecondDelayOverride =
          const Duration(seconds: 22);
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(configuredClient());
      mingtuHomeDebugHandle!.fetchAmapRoute();
      // The start reached the GPS (still waiting)...
      await tester.pump();
      expect(location.calls, 1);
      // ...then the user says 停下.
      mingtuHomeDebugHandle!.voiceCommand('停下');
      // Past the point where the SECOND prompt would have been due
      // (22 s) -- the one most likely to leak into a later
      // navigation if only the first timer were cancelled.
      await tester.pump(const Duration(seconds: 23));
      h.completeAllSpeaks();
      await tester.pump(const Duration(seconds: 1));
      h.completeAllSpeaks();
      await tester.pump();

      expect(h.events, isNot(contains('tts.speak:$navLocationProgressSpeech')),
          reason: '${h.events}');
      expect(
          h.events,
          isNot(contains(
              'tts.speak:$navLocationProgressStillWaitingSpeech')),
          reason: '${h.events}');
      location.gate.complete(LocationResult.error(
          LocationFailure.failed, 'test teardown'));
      await tester.pump();
      await ui.shutdownVoice(tester, h);
    });

    /// A CONFIGURED client whose sender answers with ONE valid
    /// walking path, so a start attempt can actually SUCCEED. Only
    /// the "a withdrawn start must not navigate anyway" cases use
    /// it -- every other case here stops at the GPS.
    AmapWalkingClient succeedingClient() => AmapWalkingClient(
          proxyBaseUrl: 'https://proxy.example.test',
          sender: (Uri url) async => '{"status":"1","route":{"paths":[{'
              '"distance":"500","duration":"400","steps":[{'
              '"action":"直行","orientation":"北",'
              '"polyline":"120.441723,37.724409;120.443212,37.723667",'
              '"distance":"500","duration":"400"}]}]}}',
        );

    /// A fix AT the demo start point (校门口, GCJ-02, the same
    /// coordinates as `verifiedLocations`), 10 m accuracy: the
    /// accuracy gate and the 300 m proximity gate both pass, so
    /// this fix WOULD start navigation if the attempt were not
    /// withdrawn while it was still waiting.
    LocationResult demoStartFix() => LocationResult.fix(
          const GeoPoint(latitude: 37.724409, longitude: 120.441723),
          10,
        );

    // The three cases below are the regression anchors for the
    // supersede guard in `_startRealNavigation` (right after
    // `await starter.start(...)`). Before it, a user who said
    // 「取消」heard "好的，不去了" and then, seconds later, either
    // the location failure again or -- worse -- a full route
    // announcement plus live navigation starting on its own.

    testWidgets('取消 during the wait silences the late location failure',
        (tester) async {
      final HangingLocation location = HangingLocation();
      mingtuLocationProviderOverride = location;
      // Realistic delays: the user withdraws INSIDE the waiting
      // window, exactly as in the reported session.
      mingtuNavLocationProgressDelayOverride = const Duration(seconds: 8);
      mingtuNavLocationProgressSecondDelayOverride =
          const Duration(seconds: 22);
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(configuredClient());
      mingtuHomeDebugHandle!.fetchAmapRoute();
      await tester.pump();
      expect(location.calls, 1, reason: 'the GPS was asked');

      mingtuHomeDebugHandle!.voiceCommand('取消');
      await tester.pump();

      // The platform finally answers -- AFTER the withdrawal.
      location.gate.complete(LocationResult.error(
          LocationFailure.failed, 'late platform failure'));
      await tester.pump(const Duration(seconds: 1));
      h.completeAllSpeaks();
      await tester.pump(const Duration(seconds: 23));
      h.completeAllSpeaks();
      await tester.pump();

      expect(h.events.any((String e) => e.contains('定位失败')), isFalse,
          reason: 'a withdrawn start must not speak its late '
              'failure: ${h.events}');
      expect(h.events.any((String e) => e.contains('导航未启动')), isFalse,
          reason: '${h.events}');
      await ui.shutdownVoice(tester, h);
    });

    testWidgets('取消 during the wait: a late SUCCESS never navigates',
        (tester) async {
      final HangingLocation location = HangingLocation();
      mingtuLocationProviderOverride = location;
      mingtuNavLocationProgressDelayOverride = const Duration(seconds: 8);
      mingtuNavLocationProgressSecondDelayOverride =
          const Duration(seconds: 22);
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(succeedingClient());
      mingtuHomeDebugHandle!.fetchAmapRoute();
      await tester.pump();
      expect(location.calls, 1);

      mingtuHomeDebugHandle!.voiceCommand('取消');
      await tester.pump();

      // A GOOD fix arrives late. Without the guard this is the exact
      // moment the app announced 「已获取到图书馆的真实步行路线…」
      // and started live navigation on a user who said 不去了.
      location.gate.complete(demoStartFix());
      await tester.pump(const Duration(seconds: 1));
      h.completeAllSpeaks();
      await tester.pump(const Duration(seconds: 23));
      h.completeAllSpeaks();
      await tester.pump();

      expect(h.events.any((String e) => e.contains('已获取到')), isFalse,
          reason: 'a withdrawn start must not announce a route: '
              '${h.events}');
      expect(mingtuHomeDebugHandle!.taskState, isNot(TaskState.navigating),
          reason: 'a withdrawn start must never reach navigating');
      await ui.shutdownVoice(tester, h);
    });

    testWidgets('紧急求助 during the wait: a late SUCCESS never navigates',
        (tester) async {
      final HangingLocation location = HangingLocation();
      mingtuLocationProviderOverride = location;
      mingtuNavLocationProgressDelayOverride = const Duration(seconds: 8);
      mingtuNavLocationProgressSecondDelayOverride =
          const Duration(seconds: 22);
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);

      mingtuHomeDebugHandle!.debugSetAmapClient(succeedingClient());
      mingtuHomeDebugHandle!.fetchAmapRoute();
      await tester.pump();
      expect(location.calls, 1);

      mingtuHomeDebugHandle!.voiceCommand('救命');
      await tester.pump();

      location.gate.complete(demoStartFix());
      await tester.pump(const Duration(seconds: 1));
      h.completeAllSpeaks();
      await tester.pump(const Duration(seconds: 23));
      h.completeAllSpeaks();
      await tester.pump();

      expect(h.events.any((String e) => e.contains('已获取到')), isFalse,
          reason: 'an emergency must never start navigating: ${h.events}');
      expect(mingtuHomeDebugHandle!.taskState, isNot(TaskState.navigating),
          reason: 'an emergency must never reach navigating');
      await ui.shutdownVoice(tester, h);
    });
  });
}
