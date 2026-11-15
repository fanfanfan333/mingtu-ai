import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:flutter_test/flutter_test.dart';
import 'ui_a11y_s1_test.dart' as s1;
import 'push_to_talk_ui_test.dart' as ui;
import 'mt1111_ptt_test.dart' as mt;
import 'voice_adapter_test.dart' as adapter;
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/core/ptt_feedback.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/permission_flow.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/core/wakelock_control.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';

class AttributesTts extends adapter.FakeTts {
  int calls = 0;
  bool fail = false;
  @override
  Future<dynamic> setAudioAttributesForNavigation() async {
    calls++;
    if (fail) throw StateError('unsupported');
    return 1;
  }
}

class FakeFeedback implements PttFeedback {
  final calls = <String>[];
  @override
  Future<void> start() async {
    calls.add('start');
  }

  @override
  Future<void> end() async {
    calls.add('end');
  }
}

class FakeWakelock implements WakelockGateway {
  final calls = <bool>[];
  @override
  Future<void> setEnabled(bool enabled) async => calls.add(enabled);
}

void main() {
  test('settings failure clears the paused state without advancing', () {
    final flow = PermissionFlow();
    flow.start();
    flow.onRequestResult(
        GuidePermission.microphone, PermissionOutcome.permanentlyDenied);
    expect(flow.awaitingSettingsFor, GuidePermission.microphone);
    flow.onSettingsOpenFailed(GuidePermission.microphone);
    expect(flow.awaitingSettingsFor, isNull);
    expect(flow.isDone, isTrue);
    expect(flow.currentStep, GuidePermission.microphone);
  });

  test('new notices are pinned and banned-clean', () {
    expect(permissionSettingsOpenFailedText,
        '没法打开系统设置。请稍后重试，或到手机的设置里找到明途，打开这项权限。');
    expect(talkBackToggleNoContentText, '没有听清，请双击再说一次。');
    expect(holdNoContentText, '没有听清，请按住按钮再说一次。');
    for (final text in [
      permissionSettingsOpenFailedText,
      talkBackToggleNoContentText,
      holdNoContentText
    ]) {
      expect(containsBannedWord(text), isFalse);
      expect(text.contains('安全'), isFalse);
      expect(text.contains('可以过马路'), isFalse);
    }
  });
  test('wakelock follows foreground camera, navigation and listening',
      () async {
    final gateway = FakeWakelock();
    final control = WakelockControl(gateway);
    Future<void> update(bool fg, bool camera, bool nav, bool listen) =>
        control.update(
            foreground: fg, camera: camera, navigation: nav, listening: listen);
    await update(true, false, false, false);
    await update(true, true, false, false);
    await update(true, true, false, false);
    await update(false, true, false, false);
    await update(true, true, false, false);
    await update(true, false, false, false);
    await update(true, false, true, false);
    await update(true, false, false, false);
    await update(true, false, false, true);
    await update(true, false, false, false);
    expect(gateway.calls,
        [false, true, false, true, false, true, false, true, false]);
  });

  test('foreground watchdog thresholds, latch, callbacks and resume', () {
    var now = DateTime(2026);
    final faults = <String>[];
    final watchdog = ForegroundWatchdog(now: () => now, onFault: faults.add);
    void update(bool foreground, bool camera, bool location) => watchdog.update(
        foreground: foreground, camera: camera, location: location);
    update(true, true, true);
    now = now.add(const Duration(seconds: 9));
    update(true, true, true);
    expect(faults, isEmpty);
    now = now.add(const Duration(seconds: 1));
    update(true, true, true);
    update(true, true, true);
    expect(faults, [foregroundCameraStallText]);
    watchdog.cameraCallback();
    now = now.add(const Duration(seconds: 20));
    update(true, true, true);
    expect(faults, [
      foregroundCameraStallText,
      foregroundCameraStallText,
      foregroundLocationStallText
    ]);
    watchdog.locationCallback();
    update(false, true, true);
    now = now.add(const Duration(minutes: 2));
    update(false, true, true);
    expect(faults.length, 3);
    update(true, true, true);
    update(true, false, false);
    now = now.add(const Duration(minutes: 2));
    update(true, false, false);
    expect(faults.length, 3);
    update(true, true, true);
    now = now.add(const Duration(seconds: 10));
    update(true, true, true);
    expect(faults.last, foregroundCameraStallText);
    for (final text in [
      foregroundCameraStallText,
      foregroundLocationStallText
    ]) {
      expect(containsBannedWord(text), isFalse);
      expect(text.contains('安全'), isFalse);
      expect(text.contains('可以过马路'), isFalse);
    }
  });
  for (final mode in ['false', 'throw', 'success']) {
    testWidgets('settings open $mode settles or waits for resume',
        (tester) async {
      final gateway = s1.FakePermissionGateway()
        ..requestResults[GuidePermission.microphone] =
            PermissionOutcome.permanentlyDenied
        ..openSettingsResult = mode != 'false';
      if (mode == 'throw') {
        gateway.openSettingsError = StateError('settings failed');
      }
      final store = s1.FakeGuideStore();
      mingtuPermissionGatewayOverride = gateway;
      mingtuGuideStoreOverride = store;
      addTearDown(() {
        mingtuPermissionGatewayOverride = null;
        mingtuGuideStoreOverride = null;
      });
      final h = ui.RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);
      for (var i = 0; i < 100 && gateway.openSettingsCalls == 0; i++) {
        h.completeAllSpeaks();
        await tester.pump(const Duration(milliseconds: 120));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      for (var i = 0; i < 20; i++) {
        h.completeAllSpeaks();
        await tester.pump(const Duration(milliseconds: 120));
      }
      expect(gateway.openSettingsCalls, 1);
      expect(gateway.requested, [GuidePermission.microphone]);
      expect(mingtuHomeDebugHandle!.cameraStartCalls, 0);
      expect(mingtuHomeDebugHandle!.awaitingDestination, isFalse);
      if (mode == 'success') {
        expect(mingtuHomeDebugHandle!.awaitingSettingsFor,
            GuidePermission.microphone);
        expect(mingtuHomeDebugHandle!.permissionFlowRunning, isTrue);
      } else {
        expect(
            h.events, contains('tts.speak:$permissionSettingsOpenFailedText'));
        expect(mingtuHomeDebugHandle!.awaitingSettingsFor, isNull);
        expect(mingtuHomeDebugHandle!.permissionFlowRunning, isFalse);
        tester.binding
            .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        await tester.pump();
        expect(gateway.requested, [GuidePermission.microphone]);
      }
      await ui.drainVoice(tester, h);
    });
  }

  testWidgets('toggle no match returns idle and allows another listen',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await s1.toggleStartUntilListening(tester, h);
    await s1.deliverChannelError('error_speech_timeout');
    await s1.pumpUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$talkBackToggleNoContentText'),
        'no content');
    expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    await s1.toggleStartUntilListening(tester, h);
    expect(h.count('asr.listen'), greaterThanOrEqualTo(2));
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('toggle close without final settles with no content',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await s1.toggleStartUntilListening(tester, h);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await tester.pump(const Duration(seconds: 30));
    await h.deliverCloseStatusOnly();
    await s1.pumpUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$talkBackToggleNoContentText'),
        'close without final');
    expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('toggle ASR error returns idle and allows retry', (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await s1.toggleStartUntilListening(tester, h);
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    await s1.deliverChannelError('error_busy');
    await tester.pump();
    expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    expect(find.bySemanticsLabel(talkBackToggleIdleLabel), findsOneWidget);
    await s1.toggleStartUntilListening(tester, h);
    expect(h.count('asr.listen'), greaterThanOrEqualTo(2));
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });
  for (final fail in [false, true]) {
    test('navigation audio attributes are attempted once, failure=$fail',
        () async {
      final tts = AttributesTts()..fail = fail;
      final output = SystemVoiceOutput(tts);
      expect(await output.initialize(), isTrue);
      expect(output.chineseVoiceVerified, isTrue);
      expect(tts.calls, 1);
    });
  }

  testWidgets('empty cloud recording announces toggle retry', (tester) async {
    final h = mt.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleAppMt(tester, h);
    final recorder = s1.AmplitudeFakeRecorder()..clip = null;
    await s1.armRecordingRoute(tester, h, recorder, asrText: '帮助');
    await s1.toggleStartUntilRecording(tester, h, recorder);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await s1.tapPttSemantics(tester, talkBackToggleListeningLabel);
    await s1.pumpUntilMt(
        tester,
        h,
        () => h.events.contains('tts.speak:$talkBackToggleNoContentText'),
        'empty recording');
    expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    semantics.dispose();
    await mt.settleReleasedPress(tester, h);
  });

  testWidgets('PTT feedback starts once and ends once', (tester) async {
    final feedback = FakeFeedback();
    mingtuPttFeedbackOverride = feedback;
    addTearDown(() => mingtuPttFeedbackOverride = null);
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await s1.toggleStartUntilListening(tester, h);
    expect(feedback.calls, ['start']);
    await s1.deliverChannelError('error_speech_timeout');
    await tester.pump();
    expect(feedback.calls, ['start', 'end']);
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('whole screen is one labelled large PTT target', (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    final node = s1.pttSemanticsNode(tester, talkBackToggleIdleLabel);
    expect(node.rect.width, greaterThanOrEqualTo(48));
    expect(
        node.rect.height,
        greaterThanOrEqualTo(tester.view.physicalSize.height /
            tester.view.devicePixelRatio /
            2));
    expect(find.byType(Text), findsNothing);
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });
  testWidgets('toggle listenFor close submits an already delivered final',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await s1.toggleStartUntilListening(tester, h);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 350)));
    await ui.deliverFinalResult(tester, '帮助');
    await tester.pump(const Duration(seconds: 30));
    await h.deliverCloseStatusOnly();
    await s1.pumpUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$firstLaunchGuideText'),
        'final on close');
    expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('hold error goes idle before lift and next hold listens',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    h.events.clear();
    final gesture = await ui.startPttGesture(tester);
    await s1.pumpUntil(
        tester, h, () => h.count('asr.listen') >= 1, 'hold listening');
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }
    mingtuHomeDebugHandle!.debugAsrError('error_busy');
    await tester.pump();
    expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    await gesture.up();
    await tester.pump();
    final retry = await ui.startPttGesture(tester);
    await s1.pumpUntil(
        tester, h, () => h.count('asr.listen') >= 2, 'hold retry');
    await retry.up();
    await ui.shutdownVoice(tester, h);
  });

  for (final size in [
    const Size(320, 180),
    const Size(640, 240),
    const Size(220, 300)
  ]) {
    testWidgets('tight size $size retains a 48dp target at text scale 2',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = ui.RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      final semantics = tester.ensureSemantics();
      ui.activeVoiceHarness = h;
      await tester.pumpWidget(const MediaQuery(
          data: MediaQueryData(
              accessibleNavigation: true, textScaler: TextScaler.linear(2)),
          child: MingtuApp()));
      await tester.pump(const Duration(milliseconds: 100));
      final node = s1.pttSemanticsNode(tester, talkBackToggleIdleLabel);
      expect(node.rect.width, greaterThanOrEqualTo(48));
      expect(node.rect.height, greaterThanOrEqualTo(48));
      semantics.dispose();
      await ui.shutdownVoice(tester, h);
    });
  }
  testWidgets('camera and lower area both accept a long press', (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    final upper = find.byKey(const ValueKey('camera-preview-area'));
    final lower = find.byKey(const ValueKey('push-to-talk-area'));
    for (final area in [upper, lower]) {
      final before = h.count('asr.listen');
      final gesture = await tester.startGesture(tester.getCenter(area));
      await tester.pump(const Duration(milliseconds: 600));
      await s1.pumpUntil(
          tester, h, () => h.count('asr.listen') > before, 'area press');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)));
      await gesture.up();
      await tester.pump();
      for (var i = 0; i < 40 && !mingtuHomeDebugHandle!.pttIdle; i++) {
        h.completeAllSpeaks();
        await h.deliverAllCloseStatuses();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(mingtuHomeDebugHandle!.pttIdle, isTrue);
    }
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('system feedback emits one pulse then two pulses',
      (tester) async {
    final calls = <MethodCall>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() =>
        messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final feedback = SystemPttFeedback();
    await feedback.start();
    expect(calls.where((c) => c.method == 'HapticFeedback.vibrate').length, 1);
    final end = feedback.end();
    await tester.pump(const Duration(milliseconds: 100));
    await end;
    expect(calls.where((c) => c.method == 'HapticFeedback.vibrate').length, 3);
  });
  testWidgets('cue uses info priority and danger interrupts it',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    h.events.clear();
    await s1.tapPttSemantics(tester, talkBackToggleIdleLabel);
    for (var i = 0; i < 40 && !h.events.contains('tts.speak:请说'); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(h.events, contains('tts.speak:请说'));
    expect(mingtuHomeDebugHandle!.activeSpeechText, '请说');
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.info);
    mingtuHomeDebugHandle!.debugSpeakHazard('前方有障碍，请停下。');
    for (var i = 0; i < 30 && !h.events.contains('tts.speak:前方有障碍，请停下。'); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(h.events, contains('tts.speak:前方有障碍，请停下。'));
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.danger);
    expect(h.events, isNot(contains('asr.listen')));
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });
  testWidgets('close-wait cue closes the mic and uses info priority',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await s1.settleToggleApp(tester, h);
    await s1.toggleStartUntilListening(tester, h);
    h.events.clear();
    mingtuHomeDebugHandle!.debugPttCloseWait();
    for (var i = 0; i < 50 && !h.events.contains('tts.speak:请稍等'); i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(h.events, contains('tts.speak:请稍等'));
    expect(h.events.indexOf('asr.stop'), greaterThanOrEqualTo(0));
    expect(h.events.indexOf('asr.stop'),
        lessThan(h.events.indexOf('tts.speak:请稍等')));
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.info);
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });
}
