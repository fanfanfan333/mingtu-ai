import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/wakelock_control.dart';
import 'package:mingtu_ai/core/yolo_error_speech.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;

class FakeWakelockGateway implements WakelockGateway {
  final calls = <bool>[];

  @override
  Future<void> setEnabled(bool enabled) async => calls.add(enabled);
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
