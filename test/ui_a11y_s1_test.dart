import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsData, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_asr_client.dart';
import 'package:mingtu_ai/adapters/voice_recorder.dart';
import 'package:mingtu_ai/core/cloud_asr.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/permission_flow.dart';
import 'package:mingtu_ai/core/recording_silence.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:mingtu_ai/main.dart';

import 'mt1111_ptt_test.dart' as mt;
import 'push_to_talk_ui_test.dart' as ui;

/// UI-A11Y S1: UI-01 (TalkBack toggle push-to-talk) and
/// UI-06 (all-voice permission flow).
///
/// Widget tests drive the app the way TalkBack does: the
/// app is pumped inside a MediaQuery with
/// accessibleNavigation on, and the big button is driven
/// through its semantics actions (tester.semantics), never
/// through physical gestures. The voice channels are the
/// recording fakes of push_to_talk_ui_test.dart; the
/// recording-route tests reuse mt1111_ptt_test.dart's
/// fake-backed adapter helpers.

// ----------------------------------------------------------------
// Shared drivers
// ----------------------------------------------------------------

/// Pump the app in TalkBack (accessible navigation) mode
/// and settle startup, mirroring ui.settleRecordedApp's
/// quiescence loop.
Future<void> settleToggleApp(
    WidgetTester tester, ui.RecordingVoiceChannels h) async {
  ui.activeVoiceHarness = h;
  await tester.pumpWidget(
    const MediaQuery(
      data: MediaQueryData(accessibleNavigation: true),
      child: MingtuApp(),
    ),
  );
  await tester.pump();
  int quietRounds = 0;
  int lastEventCount = -1;
  for (int round = 0; round < 64; round++) {
    await tester.pump(const Duration(milliseconds: 250));
    await h.deliverAllCloseStatuses();
    // Real-loop turns every round (mt1111's settle
    // recipe): the kickoff's location answer resolves on
    // the real event loop; it must land HERE, not
    // mid-press.
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    if (h.pendingSpeaks().isEmpty && h.events.length == lastEventCount) {
      quietRounds++;
    } else {
      quietRounds = 0;
    }
    lastEventCount = h.events.length;
    h.completeAllSpeaks();
    if (round >= 16 && quietRounds >= 3) break;
  }
  // The startup kickoff's location-permission answer
  // resolves on the REAL event loop and can land late;
  // if it landed mid-press instead, its alert would be
  // spoken through the speech path that closes the
  // just-opened microphone session (the hazard
  // mt1111_ptt_test's settle documents). Give the real
  // loop generous turns here so the answer (and its
  // fixed alert) always land during the settle.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)));
  for (int round = 0; round < 10; round++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

SemanticsNode pttSemanticsNode(WidgetTester tester, String label) =>
    tester.getSemantics(find.bySemanticsLabel(label));

Future<void> tapPttSemantics(WidgetTester tester, String label) async {
  final SemanticsNode node = pttSemanticsNode(tester, label);
  node.owner!.performAction(node.id, SemanticsAction.tap);
  await tester.pump();
}

/// Poll (completing the cue and queued closing statuses)
/// until [condition] holds; used for the real-event-loop
/// turns between the cue and the session opening.
Future<void> pumpUntil(WidgetTester tester, ui.RecordingVoiceChannels h,
    bool Function() condition, String what) async {
  for (int i = 0; i < 60; i++) {
    if (condition()) return;
    h.completeSpeak('请说');
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!condition()) {
    fail('never reached: $what; events: ${h.events}');
  }
}

/// Toggle-tap start; returns once the local session is
/// listening (an asr.listen beyond the pre-tap count).
Future<void> toggleStartUntilListening(
    WidgetTester tester, ui.RecordingVoiceChannels h) async {
  final int listensBefore = h.count('asr.listen');
  await tapPttSemantics(tester, talkBackToggleIdleLabel);
  await pumpUntil(tester, h, () => h.count('asr.listen') > listensBefore,
      'toggle press opened its session');
}

/// Inject one recognition error on the plugin channel,
/// speech_to_text 7.5.0's wire shape (permanent is true
/// for every error the plugin sends).
Future<void> deliverChannelError(String code) async {
  final String json = jsonEncode(<String, Object?>{
    'errorMsg': code,
    'permanent': true,
  });
  final ByteData data = const StandardMethodCodec()
      .encodeMethodCall(MethodCall('notifyError', json));
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
    'plugin.csdcorp.com/speech_to_text',
    data,
    (ByteData? _) {},
  );
}

// ----------------------------------------------------------------
// UI-06 fakes
// ----------------------------------------------------------------

class FakePermissionGateway implements PermissionGateway {
  final Map<GuidePermission, PermissionOutcome> requestResults =
      <GuidePermission, PermissionOutcome>{};
  final Map<GuidePermission, PermissionOutcome> statusResults =
      <GuidePermission, PermissionOutcome>{};
  final List<GuidePermission> requested = <GuidePermission>[];
  int openSettingsCalls = 0;

  @override
  bool get isAvailable => true;

  @override
  Future<PermissionOutcome> request(GuidePermission permission) async {
    requested.add(permission);
    return requestResults[permission] ?? PermissionOutcome.granted;
  }

  @override
  Future<PermissionOutcome> status(GuidePermission permission) async =>
      statusResults[permission] ?? PermissionOutcome.granted;

  @override
  Future<void> openSettings() async {
    openSettingsCalls++;
  }
}

class FakeGuideStore implements GuideStore {
  FakeGuideStore({this.seen = false});

  bool seen;
  bool marked = false;

  @override
  Future<bool> hasSeenGuide() async => seen;

  @override
  Future<void> markGuideSeen() async {
    marked = true;
    seen = true;
  }
}

// ----------------------------------------------------------------
// UI-01 recording fake (mt1111's FakeRecorder + amplitude)
// ----------------------------------------------------------------

class AmplitudeFakeRecorder extends mt.FakeRecorder
    implements VoiceRecorderAmplitude {
  final StreamController<double> amplitudes =
      StreamController<double>.broadcast();
  int stopCalls = 0;

  @override
  Future<Uint8List?> stop() async {
    stopCalls++;
    return super.stop();
  }

  @override
  Stream<double> amplitudeDbfs() => amplitudes.stream;
}

/// Toggle-mode settle for mt1111's harness flavour (its
/// helpers take its own RecordingVoiceChannels type).
Future<void> settleToggleAppMt(
    WidgetTester tester, mt.RecordingVoiceChannels h) async {
  mt.activeHarness = h;
  await tester.pumpWidget(
    const MediaQuery(
      data: MediaQueryData(accessibleNavigation: true),
      child: MingtuApp(),
    ),
  );
  await tester.pump();
  int quietRounds = 0;
  int lastEventCount = -1;
  for (int round = 0; round < 64; round++) {
    await tester.pump(const Duration(milliseconds: 250));
    await h.deliverAllCloseStatuses();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    final bool speaksPending = h.speakQueue
        .any((MapEntry<String, Completer<dynamic>> e) =>
            !e.value.isCompleted);
    if (!speaksPending && h.events.length == lastEventCount) {
      quietRounds++;
    } else {
      quietRounds = 0;
    }
    lastEventCount = h.events.length;
    h.completeAllSpeaks();
    if (round >= 16 && quietRounds >= 3) break;
  }
  // Same late-kickoff-answer flush as settleToggleApp.
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)));
  for (int round = 0; round < 10; round++) {
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 200));
  }
}

/// pumpUntil for mt1111's harness flavour.
Future<void> pumpUntilMt(WidgetTester tester, mt.RecordingVoiceChannels h,
    bool Function() condition, String what) async {
  for (int i = 0; i < 60; i++) {
    if (condition()) return;
    h.completeSpeak('请说');
    h.completeAllSpeaks();
    await h.deliverAllCloseStatuses();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await tester.pump(const Duration(milliseconds: 50));
  }
  if (!condition()) {
    fail('never reached: $what; events: ${h.events}');
  }
}

/// Break the local recogniser with a permission error on
/// a first press (mt1111's route), so later presses take
/// the recording route.
Future<void> armRecordingRoute(WidgetTester tester,
    mt.RecordingVoiceChannels h, AmplitudeFakeRecorder recorder,
    {required String asrText}) async {
  mingtuHomeDebugHandle!.setRecorder(recorder);
  mingtuHomeDebugHandle!.setCloudAsrClient(CloudAsrClient(
    proxyBaseUrl: 'https://fc.example',
    sender: (Uri url, String body, Map<String, String> headers) async =>
        jsonEncode(<String, Object?>{'text': asrText}),
  ));
  await mt.installFakeBackedInput(tester);
  final TestGesture g0 = await ui.startPttGesture(tester);
  await mt.pressUntilCapture(tester, h, g0,
      expectRecorder: false, useFakeListen: true);
  await mt.deliverError(tester, 'error_permission', true);
  expect(mingtuHomeDebugHandle!.localAsrBroken, isTrue);
  await ui.holdPastThreshold(tester);
  await g0.up();
  await tester.pump(const Duration(milliseconds: 200));
  await mt.deliverFakeStatus(tester, 'notListening');
  await mt.settleReleasedPress(tester, h);
  h.events.clear();
}

/// Toggle-tap start on the recording route; returns once
/// the recorder is capturing.
Future<void> toggleStartUntilRecording(WidgetTester tester,
    mt.RecordingVoiceChannels h, AmplitudeFakeRecorder recorder) async {
  await tapPttSemantics(tester, talkBackToggleIdleLabel);
  await pumpUntilMt(tester, h, () => recorder.started, 'recorder capturing');
}

void main() {
  // --------------------------------------------------------------
  // UI-01 widget: local path under TalkBack semantics
  // --------------------------------------------------------------
  group('UI-01 toggle mode (semantics-driven, local ASR)', () {
    testWidgets(
        'labels and actions: idle invites a double-tap start; '
        'a live session invites a double-tap end; tap start '
        'opens a session, tap end settles it with the final',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleToggleApp(tester, h);
      h.events.clear();

      SemanticsNode node = pttSemanticsNode(tester, talkBackToggleIdleLabel);
      expect(node.getSemanticsData().label, talkBackToggleIdleLabel);
      expect(
          node.getSemanticsData().value, mingtuHomeDebugHandle!.bigStatusText);
      expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
      expect(node.getSemanticsData().hasAction(SemanticsAction.longPress),
          isTrue);

      await toggleStartUntilListening(tester, h);
      expect(h.events, contains('vibrate'));
      expect(h.events, contains('tts.speak:请说'));

      node = pttSemanticsNode(tester, talkBackToggleListeningLabel);
      expect(node.getSemanticsData().label, talkBackToggleListeningLabel);

      // Keep the press past the 300 ms too-short floor in
      // REAL time, then end it with the second tap.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)));
      await tapPttSemantics(tester, talkBackToggleListeningLabel);
      await ui.deliverFinalResult(tester, '帮助');
      // The help command speaks the guide first, then the
      // command list: wait for the list (the later one).
      await pumpUntil(
          tester,
          h,
          () => h.events.contains('tts.speak:${voiceCommandHelpText()}'),
          'press settled with the help command');
      expect(h.events, contains('tts.speak:$firstLaunchGuideText'));

      node = pttSemanticsNode(tester, talkBackToggleIdleLabel);
      expect(node.getSemanticsData().label, talkBackToggleIdleLabel);
      handle.dispose();
      await ui.shutdownVoice(tester, h);
    });

    testWidgets(
        'silence end: the engine ends the session by itself '
        '(pauseFor) after a final arrived -- the toggle press '
        'settles with it, no second tap, no new listen',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleToggleApp(tester, h);
      h.events.clear();

      await toggleStartUntilListening(tester, h);
      final int listens = h.count('asr.listen');
      // A real pauseFor end is seconds after the press;
      // hold real time past the 300 ms too-short floor so
      // the release path treats this as the full press it
      // is on device.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)));
      // A final arrives while the press is still "held":
      // cached only, nothing submits yet.
      await ui.deliverFinalResult(tester, '帮助');
      await tester.pump(const Duration(milliseconds: 100));
      expect(h.events, isNot(contains('tts.speak:$firstLaunchGuideText')));

      // The engine closes the session (its own silence
      // detection): exactly the closing status, no outcome
      // error. The press must now settle with the final.
      // The settle ladder (release stop + the 3 s
      // final-wait bookkeeping) needs the long driver, the
      // same one the Xiaomi sequences use.
      await h.deliverCloseStatusOnly();
      for (int i = 0;
          i < 70 &&
              !h.events.contains('tts.speak:$firstLaunchGuideText');
          i++) {
        h.completeAllSpeaks();
        await h.deliverAllCloseStatuses();
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(h.events, contains('tts.speak:$firstLaunchGuideText'),
          reason: 'silence-ended press settled: ${h.events}');
      expect(h.count('asr.listen'), listens,
          reason: 'no relisten after a self-ended session');
      final SemanticsNode node =
          pttSemanticsNode(tester, talkBackToggleIdleLabel);
      expect(node.getSemanticsData().label, talkBackToggleIdleLabel);
      handle.dispose();
      await ui.shutdownVoice(tester, h);
    });

    testWidgets(
        'no-match end: the engine ends the session with '
        'error_speech_timeout while held -- the press settles '
        'with the no-content notice',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleToggleApp(tester, h);
      h.events.clear();

      await toggleStartUntilListening(tester, h);
      await deliverChannelError('error_speech_timeout');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await pumpUntil(
          tester,
          h,
          () => h.events
              .contains('tts.speak:没有听清，请按住按钮再说一次。'),
          'no-match toggle press announced no-content');
      final SemanticsNode node =
          pttSemanticsNode(tester, talkBackToggleIdleLabel);
      expect(node.getSemanticsData().label, talkBackToggleIdleLabel);
      handle.dispose();
      await ui.shutdownVoice(tester, h);
    });
  });

  // --------------------------------------------------------------
  // UI-06 widget: the flow end to end under fake seams
  // --------------------------------------------------------------
  group('UI-06 permission flow (widget, fake gateway/store)', () {
    late FakePermissionGateway gateway;
    late FakeGuideStore store;

    setUp(() {
      gateway = FakePermissionGateway();
      store = FakeGuideStore();
      mingtuPermissionGatewayOverride = gateway;
      mingtuGuideStoreOverride = store;
    });

    tearDown(() {
      mingtuPermissionGatewayOverride = null;
      mingtuGuideStoreOverride = null;
    });

    Future<void> driveFlow(WidgetTester tester,
        ui.RecordingVoiceChannels h) async {
      for (int i = 0;
          i < 80 && mingtuHomeDebugHandle!.permissionFlowRunning;
          i++) {
        h.completeAllSpeaks();
        await tester.pump(const Duration(milliseconds: 120));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 25)));
      }
      h.completeAllSpeaks();
    }

    testWidgets(
        'first launch: guide, then purposes and grants in '
        'order mic -> location -> camera, marker written',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);
      await driveFlow(tester, h);

      final List<String> speaks = h.events
          .where((String e) => e.startsWith('tts.speak:'))
          .toList();
      final List<String> flowSpeaks = speaks
          .where((String e) =>
              e == 'tts.speak:$firstLaunchGuideText' ||
              PermissionFlow.steps.any((GuidePermission p) =>
                  e == 'tts.speak:${permissionPurposeText(p)}' ||
                  e == 'tts.speak:${permissionGrantedText(p)}') ||
              e == 'tts.speak:$permissionFlowEndText')
          .toList();
      expect(
          flowSpeaks,
          <String>[
            'tts.speak:$firstLaunchGuideText',
            'tts.speak:${permissionPurposeText(GuidePermission.microphone)}',
            'tts.speak:${permissionGrantedText(GuidePermission.microphone)}',
            'tts.speak:${permissionPurposeText(GuidePermission.location)}',
            'tts.speak:${permissionGrantedText(GuidePermission.location)}',
            'tts.speak:${permissionPurposeText(GuidePermission.camera)}',
            'tts.speak:${permissionGrantedText(GuidePermission.camera)}',
            'tts.speak:$permissionFlowEndText',
          ],
          reason: 'full event log: ${h.events}');
      expect(gateway.requested, PermissionFlow.steps);
      expect(gateway.requested,
          isNot(contains(GuidePermission.backgroundLocationService)));
      expect(store.marked, isTrue);
      expect(mingtuHomeDebugHandle!.permissionFlowRunning, isFalse);
      await ui.drainVoice(tester, h);
    });

    testWidgets(
        'permanent denial: settings opens, the flow pauses; '
        'on resume the permission is re-checked and the '
        'flow completes',
        (WidgetTester tester) async {
      gateway.requestResults[GuidePermission.microphone] =
          PermissionOutcome.permanentlyDenied;
      gateway.statusResults[GuidePermission.microphone] =
          PermissionOutcome.permanentlyDenied;
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await ui.settleRecordedApp(tester, h);
      await driveFlow(tester, h);

      // Paused on the settings page for the microphone.
      expect(gateway.openSettingsCalls, 1);
      expect(mingtuHomeDebugHandle!.permissionFlowRunning, isTrue);
      expect(
          h.events,
          contains(
              'tts.speak:${permissionPermanentlyDeniedText(GuidePermission.microphone)}'));
      expect(store.marked, isFalse);

      // The user grants it in settings and comes back.
      gateway.statusResults[GuidePermission.microphone] =
          PermissionOutcome.granted;
      tester.binding
          .handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await driveFlow(tester, h);

      expect(
          h.events,
          contains(
              'tts.speak:${permissionRecheckGrantedText(GuidePermission.microphone)}'));
      expect(h.events, contains('tts.speak:$permissionFlowEndText'));
      expect(store.marked, isTrue);
      expect(mingtuHomeDebugHandle!.permissionFlowRunning, isFalse);
      await ui.drainVoice(tester, h);
    });
  });

  // --------------------------------------------------------------
  // UI-01 widget: recording path silence end (fake amplitudes)
  // --------------------------------------------------------------
  group('UI-01 toggle mode (recording path, fake amplitude)', () {
    testWidgets(
        'voice then >=3 s of quiet ends the clip and submits '
        'it; the 10 s cap text is NOT spoken',
        (WidgetTester tester) async {
      final mt.RecordingVoiceChannels h = mt.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleToggleAppMt(tester, h);
      final AmplitudeFakeRecorder recorder = AmplitudeFakeRecorder();
      await armRecordingRoute(tester, h, recorder, asrText: '帮助');

      DateTime fakeNow = DateTime(2026, 1, 1, 12);
      mingtuHomeDebugHandle!.debugSetSilenceClock(() => fakeNow);
      await toggleStartUntilRecording(tester, h, recorder);
      // Clear the app's 300 ms too-short floor in real time.
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)));

      // Speech, then quiet samples: the quiet run starts
      // at the first quiet sample and fires once it has
      // lasted 3 s (the 200 ms-cadence samples of the real
      // feed are represented by the run's endpoints).
      recorder.amplitudes.add(-20);
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(milliseconds: 200));
      recorder.amplitudes.add(-60);
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(seconds: 3, milliseconds: 100));
      recorder.amplitudes.add(-60);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      await pumpUntilMt(
          tester,
          h,
          () => h.events.contains('tts.speak:$firstLaunchGuideText'),
          'silence-ended clip transcribed and submitted');
      expect(recorder.stopCalls, 1);
      expect(h.events, isNot(contains('tts.speak:$asrRecordCapSpeechText')));
      final SemanticsNode node =
          pttSemanticsNode(tester, talkBackToggleIdleLabel);
      expect(node.getSemanticsData().label, talkBackToggleIdleLabel);
      handle.dispose();
      await mt.settleReleasedPress(tester, h);
    });

    testWidgets(
        'no voice ever heard: quiet samples never end the '
        'clip; the second tap still ends it normally',
        (WidgetTester tester) async {
      final mt.RecordingVoiceChannels h = mt.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleToggleAppMt(tester, h);
      final AmplitudeFakeRecorder recorder = AmplitudeFakeRecorder();
      await armRecordingRoute(tester, h, recorder, asrText: '帮助');

      DateTime fakeNow = DateTime(2026, 1, 1, 12);
      mingtuHomeDebugHandle!.debugSetSilenceClock(() => fakeNow);
      await toggleStartUntilRecording(tester, h, recorder);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)));

      // Ten seconds of pure quiet: nothing may fire.
      for (int i = 0; i < 4; i++) {
        fakeNow = fakeNow.add(const Duration(seconds: 2, milliseconds: 500));
        recorder.amplitudes.add(-60);
        await tester.pump();
      }
      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.started, isTrue);
      expect(recorder.stopCalls, 0);

      await tapPttSemantics(tester, talkBackToggleListeningLabel);
      await pumpUntilMt(
          tester,
          h,
          () => h.events.contains('tts.speak:$firstLaunchGuideText'),
          'tap-ended clip transcribed and submitted');
      expect(recorder.stopCalls, 1);
      handle.dispose();
      await mt.settleReleasedPress(tester, h);
    });

    testWidgets(
        'the 10 s hard cap still wins over an unfinished '
        'silence run',
        (WidgetTester tester) async {
      final mt.RecordingVoiceChannels h = mt.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await settleToggleAppMt(tester, h);
      final AmplitudeFakeRecorder recorder = AmplitudeFakeRecorder();
      await armRecordingRoute(tester, h, recorder, asrText: '帮助');

      DateTime fakeNow = DateTime(2026, 1, 1, 12);
      mingtuHomeDebugHandle!.debugSetSilenceClock(() => fakeNow);
      await toggleStartUntilRecording(tester, h, recorder);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 350)));

      // Voice, then a quiet run far short of 3 s: the
      // silence end is not due; the cap (fired through its
      // debug seam, the same entry the real timer calls)
      // ends it.
      recorder.amplitudes.add(-20);
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(milliseconds: 200));
      recorder.amplitudes.add(-60);
      await tester.pump();
      fakeNow = fakeNow.add(const Duration(seconds: 1));
      recorder.amplitudes.add(-60);
      await tester.pump();
      expect(recorder.stopCalls, 0);

      mingtuHomeDebugHandle!.debugFireRecordCap();
      await pumpUntilMt(
          tester,
          h,
          () => h.events.contains('tts.speak:$asrRecordCapSpeechText'),
          'cap notice spoken');
      expect(recorder.stopCalls, 1);
      handle.dispose();
      await mt.settleReleasedPress(tester, h);
    });
  });

  // --------------------------------------------------------------
  // UI-01 regression: hold mode untouched
  // --------------------------------------------------------------
  group('UI-01 hold mode (regression spot check)', () {
    testWidgets(
        'without accessible navigation the button keeps the '
        'hold label and has NO tap action',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      final SemanticsHandle handle = tester.ensureSemantics();
      await ui.settleRecordedApp(tester, h);

      final SemanticsNode node = tester.getSemantics(
          find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'));
      final SemanticsData data = node.getSemanticsData();
      expect(data.label, '按住说话按钮，按住后说话，松开结束');
      expect(data.hasAction(SemanticsAction.longPress), isTrue);
      expect(data.hasAction(SemanticsAction.tap), isFalse);
      handle.dispose();
      await ui.drainVoice(tester, h);
    });
  });

  // --------------------------------------------------------------
  // UI-06 unit: the pure machine, every branch, literal pins
  // --------------------------------------------------------------
  group('UI-06 permission flow machine', () {
    List<String> speakTexts(List<Object> effects) => effects
        .whereType<PermissionSpeakEffect>()
        .map((PermissionSpeakEffect e) => e.text)
        .toList();

    test('steps are mic -> location -> camera; the deferred '
        'background step is never among them', () {
      expect(
          PermissionFlow.steps,
          <GuidePermission>[
            GuidePermission.microphone,
            GuidePermission.location,
            GuidePermission.camera,
          ]);
      expect(PermissionFlow.steps,
          isNot(contains(GuidePermission.backgroundLocationService)));
      // The deferred step carries no texts at all.
      expect(
          permissionPurposeText(GuidePermission.backgroundLocationService),
          '');
      expect(permissionDeniedText(GuidePermission.backgroundLocationService),
          '');
    });

    test('all granted: purposes, confirmations and the '
        'closing line in order, then done', () {
      final PermissionFlow flow = PermissionFlow();
      List<Object> fx = flow.start();
      expect(speakTexts(fx),
          <String>[permissionPurposeText(GuidePermission.microphone)]);
      expect(fx.whereType<PermissionRequestEffect>().single.permission,
          GuidePermission.microphone);

      fx = flow.onRequestResult(
          GuidePermission.microphone, PermissionOutcome.granted);
      expect(
          speakTexts(fx),
          <String>[
            permissionGrantedText(GuidePermission.microphone),
            permissionPurposeText(GuidePermission.location),
          ]);
      expect(fx.whereType<PermissionSpeakEffect>().first.alert, isFalse);

      fx = flow.onRequestResult(
          GuidePermission.location, PermissionOutcome.granted);
      expect(
          speakTexts(fx),
          <String>[
            permissionGrantedText(GuidePermission.location),
            permissionPurposeText(GuidePermission.camera),
          ]);

      fx = flow.onRequestResult(
          GuidePermission.camera, PermissionOutcome.granted);
      expect(
          speakTexts(fx),
          <String>[
            permissionGrantedText(GuidePermission.camera),
            permissionFlowEndText,
          ]);
      expect(fx.whereType<PermissionFlowDoneEffect>(), hasLength(1));
      expect(flow.isDone, isTrue);
    });

    test('denied: the impact text (alert level) is spoken '
        'and the flow advances', () {
      final PermissionFlow flow = PermissionFlow();
      flow.start();
      final List<Object> fx = flow.onRequestResult(
          GuidePermission.microphone, PermissionOutcome.denied);
      expect(speakTexts(fx),
          <String>[
            permissionDeniedText(GuidePermission.microphone),
            permissionPurposeText(GuidePermission.location),
          ]);
      expect(fx.whereType<PermissionSpeakEffect>().first.alert, isTrue);
      expect(flow.awaitingSettingsFor, isNull);
    });

    test('permanently denied: impact + settings effect, '
        'the flow pauses; a granted recheck resumes it', () {
      final PermissionFlow flow = PermissionFlow();
      flow.start();
      List<Object> fx = flow.onRequestResult(
          GuidePermission.microphone, PermissionOutcome.permanentlyDenied);
      expect(
          speakTexts(fx),
          <String>[
            permissionPermanentlyDeniedText(GuidePermission.microphone)
          ]);
      expect(fx.whereType<PermissionSpeakEffect>().single.alert, isTrue);
      expect(fx.whereType<PermissionOpenSettingsEffect>().single.permission,
          GuidePermission.microphone);
      expect(flow.awaitingSettingsFor, GuidePermission.microphone);
      expect(flow.isDone, isFalse);

      fx = flow.onSettingsReturn(
          GuidePermission.microphone, PermissionOutcome.granted);
      expect(
          speakTexts(fx),
          <String>[
            permissionRecheckGrantedText(GuidePermission.microphone),
            permissionPurposeText(GuidePermission.location),
          ]);
      expect(flow.awaitingSettingsFor, isNull);
    });

    test('permanently denied on the LAST step, recheck '
        'still denied: recheck-denied text, then the end', () {
      final PermissionFlow flow = PermissionFlow();
      flow.start();
      flow.onRequestResult(
          GuidePermission.microphone, PermissionOutcome.granted);
      flow.onRequestResult(
          GuidePermission.location, PermissionOutcome.granted);
      flow.onRequestResult(
          GuidePermission.camera, PermissionOutcome.permanentlyDenied);
      final List<Object> fx = flow.onSettingsReturn(
          GuidePermission.camera, PermissionOutcome.denied);
      expect(
          speakTexts(fx),
          <String>[
            permissionRecheckDeniedText(GuidePermission.camera),
            permissionFlowEndText,
          ]);
      expect(fx.whereType<PermissionSpeakEffect>().first.alert, isTrue);
      expect(fx.whereType<PermissionFlowDoneEffect>(), hasLength(1));
      expect(flow.isDone, isTrue);
    });

    test('misuse fails loudly', () {
      final PermissionFlow flow = PermissionFlow();
      expect(
          () => flow.onRequestResult(
              GuidePermission.microphone, PermissionOutcome.granted),
          throwsStateError);
      flow.start();
      expect(() => flow.start(), throwsStateError);
      expect(
          () => flow.onSettingsReturn(
              GuidePermission.microphone, PermissionOutcome.granted),
          throwsStateError);
      expect(
          () => flow.onRequestResult(
              GuidePermission.camera, PermissionOutcome.granted),
          throwsStateError);
    });

    test('every flow text is literal-pinned and banned-clean',
        () {
      expect(firstLaunchGuideText,
          '欢迎使用明途。说话的方法：按住屏幕下方的大按钮，说完松开；'
          '开着读屏软件时，双击按钮开始说话，再双击一次结束。'
          '走路时听到危险提醒，先停下脚步，再听说明。'
          '想再听这段说明，任何时候说一声帮助就可以。');
      expect(permissionFlowEndText, '权限问完了。想再听使用说明，说一声帮助就可以。');
      const Map<GuidePermission, List<String>> pinned =
          <GuidePermission, List<String>>{
        GuidePermission.microphone: <String>[
          '先问麦克风。明途要用麦克风听你说话，你按住按钮说的话才能变成命令。接下来系统会弹出询问，请点允许。',
          '麦克风已打开。',
          '麦克风没有打开，明途听不到你说话，按住说话用不了。之后想用，可以去系统设置里打开。',
          '麦克风被设为不再询问，明途听不到你说话。我现在帮你打开系统设置，请找到明途，把麦克风权限打开，再回到明途。',
          '麦克风已经打开了。',
          '麦克风还是没有打开，按住说话用不了。之后可以在系统设置里打开。',
        ],
        GuidePermission.location: <String>[
          '再问位置。明途要用你的位置来导航，告诉你往哪走、还有多远。接下来系统会弹出询问，请点允许。',
          '位置已打开。',
          '位置没有打开，明途不能导航，也报不了你走到了哪里。之后想用，可以去系统设置里打开。',
          '位置被设为不再询问，明途不能导航。我现在帮你打开系统设置，请找到明途，把位置权限打开，再回到明途。',
          '位置已经打开了。',
          '位置还是没有打开，明途不能导航。之后可以在系统设置里打开。',
        ],
        GuidePermission.camera: <String>[
          '最后问摄像头。明途要用摄像头看前面的路，提醒你车辆、行人和障碍物。接下来系统会弹出询问，请点允许。',
          '摄像头已打开。',
          '摄像头没有打开，明途看不到前面的路，不能提醒障碍。之后想用，可以去系统设置里打开。',
          '摄像头被设为不再询问，明途不能提醒障碍。我现在帮你打开系统设置，请找到明途，把摄像头权限打开，再回到明途。',
          '摄像头已经打开了。',
          '摄像头还是没有打开，明途不能提醒障碍。之后可以在系统设置里打开。',
        ],
      };
      for (final MapEntry<GuidePermission, List<String>> entry
          in pinned.entries) {
        final GuidePermission p = entry.key;
        expect(permissionPurposeText(p), entry.value[0]);
        expect(permissionGrantedText(p), entry.value[1]);
        expect(permissionDeniedText(p), entry.value[2]);
        expect(permissionPermanentlyDeniedText(p), entry.value[3]);
        expect(permissionRecheckGrantedText(p), entry.value[4]);
        expect(permissionRecheckDeniedText(p), entry.value[5]);
      }
      final List<String> all = <String>[
        firstLaunchGuideText,
        permissionFlowEndText,
        for (final List<String> texts in pinned.values) ...texts,
      ];
      for (final String text in all) {
        expect(containsBannedWord(text), isFalse, reason: text);
      }
    });
  });

  // --------------------------------------------------------------
  // UI-01 unit: the silence tracker fixtures
  // --------------------------------------------------------------
  group('UI-01 recording silence tracker', () {
    final DateTime t0 = DateTime(2026, 1, 1, 12);

    test('thresholds and duration are the pinned constants', () {
      expect(RecordingSilenceTracker.voiceThresholdDbfs, -40.0);
      expect(RecordingSilenceTracker.silenceThresholdDbfs, -50.0);
      expect(RecordingSilenceTracker.silenceDuration,
          const Duration(seconds: 3));
    });

    test('voice then 3 s of quiet fires exactly at 3 s, once',
        () {
      final RecordingSilenceTracker tr = RecordingSilenceTracker();
      expect(tr.addSample(-20, t0), isFalse);
      expect(
          tr.addSample(-60, t0.add(const Duration(seconds: 1))), isFalse);
      expect(
          tr.addSample(-60, t0.add(const Duration(milliseconds: 3999))),
          isFalse);
      expect(tr.addSample(-60, t0.add(const Duration(seconds: 4))), isTrue);
      expect(tr.addSample(-60, t0.add(const Duration(seconds: 5))), isFalse);
      expect(tr.heardVoice, isTrue);
    });

    test('no voice ever: quiet never fires, however long', () {
      final RecordingSilenceTracker tr = RecordingSilenceTracker();
      for (int s = 0; s <= 60; s += 5) {
        expect(tr.addSample(-60, t0.add(Duration(seconds: s))), isFalse);
      }
      expect(tr.heardVoice, isFalse);
    });

    test('a hysteresis-band sample restarts the quiet run',
        () {
      final RecordingSilenceTracker tr = RecordingSilenceTracker();
      expect(tr.addSample(-20, t0), isFalse);
      expect(
          tr.addSample(-60, t0.add(const Duration(seconds: 1))), isFalse);
      // -45 dBFS is in the band: not quiet enough to count.
      expect(
          tr.addSample(-45, t0.add(const Duration(seconds: 3))), isFalse);
      expect(
          tr.addSample(-60, t0.add(const Duration(seconds: 4))), isFalse);
      expect(
          tr.addSample(
              -60, t0.add(const Duration(seconds: 6, milliseconds: 999))),
          isFalse);
      expect(tr.addSample(-60, t0.add(const Duration(seconds: 7))), isTrue);
    });

    test('fresh voice restarts the quiet run', () {
      final RecordingSilenceTracker tr = RecordingSilenceTracker();
      expect(tr.addSample(-20, t0), isFalse);
      expect(
          tr.addSample(-60, t0.add(const Duration(seconds: 1))), isFalse);
      expect(
          tr.addSample(-25, t0.add(const Duration(seconds: 3))), isFalse);
      expect(
          tr.addSample(-60, t0.add(const Duration(seconds: 4))), isFalse);
      expect(tr.addSample(-60, t0.add(const Duration(seconds: 7))), isTrue);
    });
  });

  // --------------------------------------------------------------
  // Source guards: announce, manifest, priority mapping
  // --------------------------------------------------------------
  group('S1 source guards', () {
    test('no SemanticsService announcement anywhere in lib/',
        () {
      final List<File> dartFiles = Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList();
      expect(dartFiles, isNotEmpty);
      for (final File f in dartFiles) {
        expect(f.readAsStringSync().contains('SemanticsService'), isFalse,
            reason: f.path);
      }
    });

    test('the manifest gains no background capability', () {
      final String manifest = File('android/app/src/main/AndroidManifest.xml')
          .readAsStringSync();
      expect(manifest.contains('ACCESS_BACKGROUND_LOCATION'), isFalse);
      expect(manifest.contains('FOREGROUND_SERVICE'), isFalse);
    });

    test('flow speech maps onto scheduler kinds: denials '
        'ride the alert level, the rest info', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(
          mainDart
              .contains('kind: alert ? SpeechKind.alert : SpeechKind.info'),
          isTrue);
      // Danger / emergency outrank both levels in the
      // scheduler itself (existing priority table).
      expect(
          priorityOf(SpeechKind.emergency) < priorityOf(SpeechKind.alert),
          isTrue);
      expect(priorityOf(SpeechKind.danger) < priorityOf(SpeechKind.alert),
          isTrue);
    });

    test('toggle labels are the pinned literals', () {
      expect(talkBackToggleIdleLabel, '按住说话，双击开始');
      expect(talkBackToggleListeningLabel, '正在听，双击结束');
      expect(containsBannedWord(talkBackToggleIdleLabel), isFalse);
      expect(containsBannedWord(talkBackToggleListeningLabel), isFalse);
    });
  });
}
