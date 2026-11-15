import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/main.dart';

import 'push_to_talk_ui_test.dart' as ui;

const prompt = '前方有车靠近。';

Future<void> speakPrompt(
    WidgetTester tester, ui.RecordingVoiceChannels h) async {
  mingtuHomeDebugHandle!.debugSpeakHazard(prompt);
  await ui.pumpUntilSpeak(tester, h, prompt);
  expect(mingtuHomeDebugHandle!.activeSpeechText, prompt);
  expect(mingtuHomeDebugHandle!.currentPrompt, prompt);
  expect(h.completeSpeak(prompt), isTrue);
  await tester.pump(const Duration(milliseconds: 200));
}

Future<void> verifyCommands(
    WidgetTester tester, ui.RecordingVoiceChannels h) async {
  h.events.clear();
  mingtuHomeDebugHandle!.voiceCommand('再说一遍');
  await ui.pumpUntilSpeak(tester, h, prompt);
  expect(h.events, contains('tts.speak:$prompt'));
  expect(mingtuHomeDebugHandle!.activeSpeechText, prompt);
  expect(h.completeSpeak(prompt), isTrue);
  await tester.pump(const Duration(milliseconds: 200));
  h.events.clear();
  mingtuHomeDebugHandle!.voiceCommand('什么状态');
  for (var i = 0;
      i < 30 && !h.events.any((e) => e.startsWith('tts.speak:当前状态：'));
      i++) {
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 100));
  }
  final status = h.events.singleWhere((e) => e.startsWith('tts.speak:当前状态：'));
  expect(status, contains('当前提示：$prompt'));
  expect(status, isNot(contains('当前提示：请说')));
  expect(status, isNot(contains('当前提示：请稍等')));
}

void main() {
  testWidgets('hold cue preserves the previous prompt for repeat and status',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1700)));
    await ui.drainVoice(tester, h);
    await speakPrompt(tester, h);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1700)));
    await ui.drainVoice(tester, h);
    h.events.clear();
    final gesture = await ui.pressPtt(tester, h);
    await ui.pumpUntilSpeak(tester, h, '请说');
    expect(h.events, contains('tts.speak:请说'));
    expect(mingtuHomeDebugHandle!.activeSpeechText, '请说');
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.info);
    expect(mingtuHomeDebugHandle!.currentPrompt, prompt);
    await tester.pump(const Duration(milliseconds: 200));
    await ui.pressUntilPttListeningFrom(tester, h, gesture);
    await ui.holdPastThreshold(tester);
    await ui.deliverFinalResult(tester, '再说一遍');
    await gesture.up();
    await h.deliverAllCloseStatuses();
    await tester.pump(const Duration(milliseconds: 200));
    await ui.drainVoice(tester, h);
    await verifyCommands(tester, h);
    await ui.shutdownVoice(tester, h);
  });

  testWidgets('close-wait cue preserves the previous prompt', (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    await speakPrompt(tester, h);
    h.events.clear();
    mingtuHomeDebugHandle!.debugPttCloseWait();
    await ui.pumpUntilSpeak(tester, h, '请稍等');
    expect(h.events, contains('tts.speak:请稍等'));
    expect(mingtuHomeDebugHandle!.activeSpeechText, '请稍等');
    expect(mingtuHomeDebugHandle!.activeSpeechKind, SpeechKind.info);
    expect(mingtuHomeDebugHandle!.currentPrompt, prompt);
    expect(h.completeSpeak('请稍等'), isTrue);
    await tester.pump(const Duration(milliseconds: 200));
    await verifyCommands(tester, h);
    await ui.shutdownVoice(tester, h);
  });
}
