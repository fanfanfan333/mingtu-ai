import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/permission_flow.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:mingtu_ai/main.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;

void main() {
  testWidgets('headset toggles a live press and ends it', (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await s1.settleToggleApp(tester, h);
    final before = h.count('asr.listen');
    await mingtuHomeDebugHandle!.debugHeadsetToggle();
    await s1.pumpUntil(tester, h, () => h.count('asr.listen') > before,
        'headset starts listening');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await mingtuHomeDebugHandle!.debugHeadsetToggle();
    await ui.deliverFinalResult(tester, '帮助');
    await s1.pumpUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$firstLaunchGuideText'),
        'headset ends press');
    expect(find.bySemanticsLabel(talkBackToggleIdleLabel), findsOneWidget);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('unauthorized headset speaks and never opens microphone',
      (tester) async {
    final gateway = s1.FakePermissionGateway();
    gateway.statusResults[GuidePermission.microphone] =
        PermissionOutcome.denied;
    mingtuPermissionGatewayOverride = gateway;
    mingtuGuideStoreOverride = s1.FakeGuideStore(seen: true);
    addTearDown(() {
      mingtuPermissionGatewayOverride = null;
      mingtuGuideStoreOverride = null;
    });
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await s1.settleToggleApp(tester, h);
    h.events.clear();
    final before = h.count('asr.listen');
    final initialized = mingtuHomeDebugHandle!.microphoneInitializeCalls;
    await mingtuHomeDebugHandle!.debugHeadsetToggle();
    await s1.pumpUntil(
        tester,
        h,
        () => h.events.any((e) =>
            e.contains(permissionDeniedText(GuidePermission.microphone))),
        'microphone permission reason');
    expect(h.count('asr.listen'), before);
    expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, initialized);
    expect(initialized, 0);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('background headset event is ignored', (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await s1.settleToggleApp(tester, h);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    final before = h.count('asr.listen');
    await mingtuHomeDebugHandle!.debugHeadsetToggle();
    await tester.pump();
    expect(h.count('asr.listen'), before);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await ui.shutdownVoice(tester, h);
  });

  test('source keeps foreground filter and headset path independent of touch',
      () {
    final activity = File(
            'android/app/src/main/kotlin/com/mingtu/ai/mingtu_ai/MainActivity.kt')
        .readAsStringSync();
    final filter = File(
            'android/app/src/main/kotlin/com/mingtu/ai/mingtu_ai/HeadsetKeyFilter.kt')
        .readAsStringSync();
    final dart = File('lib/main.dart').readAsStringSync();
    expect(activity, contains('dispatchKeyEvent'));
    expect(activity, contains('HeadsetKeyFilter.accepts'));
    expect(activity, contains('resumed'));
    expect(filter, contains('resumed &&'));
    expect(filter, contains('keyCode == 79 || keyCode == 85'));
    expect(filter, contains('action == 0'));
    expect(filter, contains('repeatCount == 0'));
    final path = dart.substring(dart.indexOf('  Future<void> _headsetToggle()'),
        dart.indexOf('  /// UI-01: arm the amplitude'));
    expect(path, isNot(contains('ignoreTouches')));
    final sources = activity +
        filter +
        File('pubspec.yaml').readAsStringSync() +
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    for (final forbidden in [
      'audio_service',
      'MediaSession',
      'FOREGROUND_SERVICE_MEDIA_PLAYBACK'
    ]) {
      expect(sources, isNot(contains(forbidden)));
    }
  });
}
