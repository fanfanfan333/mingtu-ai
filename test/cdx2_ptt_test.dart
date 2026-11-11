// CDX2 tests in their OWN process (test files run in
// separate isolates): the streak rule, the bounded
// recovery cancel, and the unified TalkBack cap timer.
//
// These tests drive several erroring presses in a row
// through a fake-backed adapter. Two cross-test hazards
// shaped the harness choices, both consequences of
// process-global plugin state:
//  * speech_to_text is a singleton: in THIS process the
//    channel-recogniser wiring belongs to the first app
//    instance's adapter, so presses here cannot be driven
//    through the channel -- the fake-backed adapter (the
//    file's [installFakeBackedInput] seam) is used from
//    the first test on, and its fake counts (File-local
//    processFakeStt) start clean.
//  * The adapter close-watchdog ladder runs on a 3 s
//    FAKE-zone timer (the codex harness documents the
//    same): a settle that advances fake time past 3 s
//    with a close unconfirmed force-restarts the engine
//    and winds a LATER press up. Settles in this file
//    therefore advance fake time in steps of at most
//    ~2.9 s before the closes are confirmed by delivered
//    statuses (the 3 s final-wait expiry is reached via
//    the status-driven completion instead).
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/cloud_asr.dart';
import 'package:mingtu_ai/main.dart';

import 'mt1111_ptt_test.dart';

void main() {
  cdx2Group();
}

/// CDX2 group: the true-streak rule, the bounded recovery
/// cancel, and the unified TalkBack cap timer.
void cdx2Group() {
  group('CDX2 streak / bounded cancel / TalkBack timer', () {
    /// One full press whose session errors once with
    Future<void> errorPress(
        WidgetTester tester, RecordingVoiceChannels h,
        String code) async {
      final int baseline = processFakeStt!.listenCalls;
      final TestGesture g = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g,
          expectRecorder: false, useFakeListen: true,
          fakeListenBaseline: baseline);
      await deliverError(tester, code, true);
      await holdPastThreshold(tester);
      await g.up();
      // Settle through the press's OWN fake-time machinery:
      // the 3 s final-wait timer is a fake-zone Timer, so
      // fake pumps run the cancel-confirm step to
      // completion, while the wall clock (and with it the
      // adapter's 3 s real-time watchdog ladder) barely
      // moves -- the ladder never fires mid-test. The
      // statuses are delivered densely so every close
      // confirms.
      for (int i = 0; i < 29; i++) {
        h.completeAllSpeaks();
        await deliverFakeStatus(tester, 'notListening');
        await tester.pump(const Duration(milliseconds: 100));
      }
      h.events.clear();
    }

    testWidgets(
        'CDX2 streak: busy, client, busy does NOT escalate '
        '-- a different code breaks the streak, and the '
        'fourth press still listens locally',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      h.events.clear();

      await errorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse);

      await errorPress(tester, h, 'error_client');
      // The different code RESTARTED the streak: client's
      // pre-escalation count is 1, not 2.
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_client');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse);

      await errorPress(tester, h, 'error_busy');
      // busy again -- but the streak was broken twice
      // (client in between, and each recovery listen
      // starting), so this is streak 1, never 2.
      expect(mingtuHomeDebugHandle!.asrStreakCode, 'error_busy');
      expect(mingtuHomeDebugHandle!.asrStreakCount, 1);
      expect(mingtuHomeDebugHandle!.localAsrBroken, isFalse,
          reason: 'busy, client, busy must not route to cloud');

      // RED LINE: the fourth press listens locally.
      final int listensBefore = processFakeStt!.listenCalls;
      final TestGesture g4 = await startPttGesture(tester);
      await pressUntilCapture(tester, h, g4,
          expectRecorder: false, useFakeListen: true,
          fakeListenBaseline: listensBefore);
      expect(processFakeStt!.listenCalls, listensBefore + 1,
          reason: 'the fourth press must listen, not record');
      await holdPastThreshold(tester);
      await g4.up();
      for (int i = 0; i < 29; i++) {
        h.completeAllSpeaks();
        await deliverFakeStatus(tester, 'notListening');
        await tester.pump(const Duration(milliseconds: 100));
      }
      await drainVoice(tester, h);
    });

    testWidgets(
        'CDX2: a platform cancel that NEVER returns -- the '
        'recovery bounds its wait at 1 s, still initializes, '
        'and the press listens (never wedges)',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      await installFakeBackedInput(tester);
      h.events.clear();

      await errorPress(tester, h, 'error_busy');
      expect(mingtuHomeDebugHandle!.recoveryPending, isTrue);

      // The platform cancel now hangs forever.
      processFakeStt!.cancelHangs = true;
      final int initBefore = processFakeStt!.initializeCalls;
      final int listensBefore = processFakeStt!.listenCalls;
      final TestGesture g2 = await startPttGesture(tester);
      // pressUntilCapture pumps fake time in 50 ms rounds;
      // the 1 s timeout fires inside those rounds and the
      // recovery proceeds to initialize -> listen.
      await pressUntilCapture(tester, h, g2,
          expectRecorder: false, useFakeListen: true,
          fakeListenBaseline: listensBefore);
      expect(processFakeStt!.initializeCalls,
          greaterThan(initBefore),
          reason: 'initialize ran despite the hanging cancel');
      expect(processFakeStt!.listenCalls, listensBefore + 1,
          reason: 'the press reached listen -- it did not wedge');
      expect(processFakeStt!.ops,
          containsAllInOrder(<String>['cancel', 'initialize', 'listen']));
      await holdPastThreshold(tester);
      await g2.up();
      for (int i = 0; i < 29; i++) {
        h.completeAllSpeaks();
        await deliverFakeStatus(tester, 'notListening');
        await tester.pump(const Duration(milliseconds: 100));
      }
      await drainVoice(tester, h);
    });

    /// Drive a TalkBack long press (the debug seam calls
    /// the very method the Semantics action calls) until
    /// the recorder has started.
    Future<void> talkBackUntilRecording(
        WidgetTester tester, RecordingVoiceChannels h,
        FakeRecorder recorder) async {
      mingtuHomeDebugHandle!.debugTalkBackLongPress();
      for (int i = 0;
          i < 40 &&
              !h.speakQueue.any(
                  (MapEntry<String, Completer<dynamic>> e) =>
                      e.key == '请说' && !e.value.isCompleted);
          i++) {
        h.completeAllSpeaks();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      h.completeSpeak('请说');
      for (int i = 0; i < 40 && !recorder.started; i++) {
        h.completeAllSpeaks();
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(recorder.started, isTrue,
          reason: 'TalkBack press reached the recorder: ${h.events}');
    }

    testWidgets(
        'CDX2 TalkBack: a recording started by the TalkBack '
        'long press caps through the unified point -- cap '
        'notice spoken, transcribed exactly once',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final FakeRecorder recorder = FakeRecorder();
      await armFallbackRecorderOnly(tester, h, recorder,
          asrText: '去图书馆');
      mingtuHomeDebugHandle!.setRecordCapMs(300);

      await talkBackUntilRecording(tester, h, recorder);
      await holdPastThreshold(tester);
      // The completion is driven through the debug seam --
      // the SAME _onPttRecordCapReached the one shared
      // Timer (armed by _talkBackLongPress for this very
      // session) calls; the widget fake clock cannot fire
      // the app's wall-clock-armed timer reliably.
      mingtuHomeDebugHandle!.debugFireRecordCap();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.started, isFalse,
          reason: 'the cap auto-stopped the TalkBack recording');
      await pumpUntilSpeak(tester, h, asrRecordCapSpeechText);
      expect(fallbackSenderCalls!(), 1,
          reason: 'the capped TalkBack clip was transcribed once');
      await drainVoice(tester, h);
    });

    testWidgets(
        'CDX2 TalkBack: session 1 cap timer fired LATE, '
        'during session 2, is a no-op -- session 2 records '
        'on and caps only at its own fire',
        (WidgetTester tester) async {
      final RecordingVoiceChannels h = RecordingVoiceChannels()
        ..install();
      addTearDown(h.uninstall);
      await settleRecordedApp(tester, h);
      h.events.clear();

      final FakeRecorder recorder = FakeRecorder();
      await armFallbackRecorderOnly(tester, h, recorder,
          asrText: '去图书馆');
      mingtuHomeDebugHandle!.setRecordCapMs(300);

      // Session 1: TalkBack recording, capped normally.
      await talkBackUntilRecording(tester, h, recorder);
      final int sid1 = mingtuHomeDebugHandle!.pttSessionId;
      await holdPastThreshold(tester);
      mingtuHomeDebugHandle!.debugFireRecordCap();
      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.started, isFalse);
      expect(fallbackSenderCalls!(), 1);
      await drainVoice(tester, h);

      // Session 2: a fresh TalkBack recording.
      recorder.started = false;
      await talkBackUntilRecording(tester, h, recorder);
      final int sid2 = mingtuHomeDebugHandle!.pttSessionId;
      expect(sid2, greaterThan(sid1));
      await holdPastThreshold(tester);

      // Session 1's timer callback fires LATE (the old
      // Future.delayed race): bound to sid1, it must not
      // touch session 2 at all.
      mingtuHomeDebugHandle!.debugFireCapTimerFor(sid1);
      await tester.pump(const Duration(milliseconds: 200));
      expect(recorder.started, isTrue,
          reason: 'the stale timer must not end session 2');
      expect(fallbackSenderCalls!(), 1,
          reason: 'no transcription from the stale fire');

      // Session 2's OWN cap fire completes it normally.
      mingtuHomeDebugHandle!.debugFireRecordCap();
      await tester.pump(const Duration(milliseconds: 100));
      expect(recorder.started, isFalse);
      expect(fallbackSenderCalls!(), 2,
          reason: 'session 2 capped and transcribed once');
      await pumpUntilSpeak(tester, h, asrRecordCapSpeechText);
      await drainVoice(tester, h);
    });

    test(
        'CDX2 source guard: the un-cancellable, session-less '
        'Future.delayed(10 s) TalkBack auto-end is gone, and '
        'the Semantics action routes through the shared-timer '
        'entry', () {
      final String mainDart =
          File('lib/main.dart').readAsStringSync();
      expect(
          mainDart.contains(
              'Future<void>.delayed(const Duration(seconds: 10)'),
          isFalse,
          reason: 'no second, unbound 10 s auto-end may exist');
      expect(mainDart.contains('onLongPress: _talkBackLongPress'),
          isTrue);
      expect(mainDart.contains('_onPttCapTimerFired'), isTrue);
    });
  });
}

