import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/location_signal_speech.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
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
}
