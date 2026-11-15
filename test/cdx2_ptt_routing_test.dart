import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:mingtu_ai/main.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;

const holdLabel = '按住说话按钮，按住后说话，松开结束';

void main() {
  for (final toggle in [true, false]) {
    testWidgets(
        'semantics long press owns the ${toggle ? "toggle" : "hold"} session',
        (tester) async {
      final h = ui.RecordingVoiceChannels()..install();
      addTearDown(h.uninstall);
      final semantics = tester.ensureSemantics();
      if (toggle) {
        await s1.settleToggleApp(tester, h);
      } else {
        await ui.settleRecordedApp(tester, h);
      }
      final node = tester.getSemantics(
          find.bySemanticsLabel(toggle ? talkBackToggleIdleLabel : holdLabel));
      expect(
          node.getSemanticsData().hasAction(SemanticsAction.longPress), isTrue);
      final before = h.count('asr.listen');
      node.owner!.performAction(node.id, SemanticsAction.longPress);
      await s1.pumpUntil(tester, h, () => h.count('asr.listen') > before,
          'semantics long press starts listening');
      final debug = mingtuHomeDebugHandle!;
      final session = debug.pttSessionId;
      if (toggle) {
        expect(debug.debugPttToggleSessionId, session);
        expect(debug.debugTalkBackCapSessionId, isNot(session));
      } else {
        expect(debug.debugTalkBackCapSessionId, session);
        expect(debug.debugPttToggleSessionId, isNot(session));
      }
      semantics.dispose();
      if (!toggle) {
        await tester.pump(const Duration(seconds: 11));
        await ui.drainVoice(tester, h);
      }
      await ui.shutdownVoice(tester, h);
    });
  }

  testWidgets('pocket lock permits release but blocks a new hold',
      (tester) async {
    final proximity = StreamController<bool>.broadcast();
    mingtuProximityEventsOverride = () => proximity.stream;
    addTearDown(() async {
      mingtuProximityEventsOverride = null;
      await proximity.close();
    });
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await ui.settleRecordedApp(tester, h);
    final debug = mingtuHomeDebugHandle!;
    debug.debugSetPocketEnabled(true);
    await ui.drainVoice(tester, h);
    final before = h.count('asr.listen');
    final gesture = await tester
        .startGesture(tester.getCenter(find.bySemanticsLabel(holdLabel)));
    await tester.pump(const Duration(milliseconds: 600));
    await s1.pumpUntil(tester, h, () => h.count('asr.listen') > before,
        'hold starts listening');
    proximity.add(true);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(debug.debugIgnoreTouches, isTrue);
    await gesture.up();
    await s1.pumpUntil(tester, h, () => debug.pttIdle, 'release ends hold');
    final after = h.count('asr.listen');
    final node = tester.getSemantics(find.bySemanticsLabel(holdLabel));
    node.owner!.performAction(node.id, SemanticsAction.longPress);
    await tester.longPress(find.bySemanticsLabel(holdLabel));
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.count('asr.listen'), after);
    expect(debug.pttIdle, isTrue);
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });

  testWidgets(
      'pocket lock blocks semantics while danger and headset still work',
      (tester) async {
    final proximity = StreamController<bool>.broadcast();
    mingtuProximityEventsOverride = () => proximity.stream;
    addTearDown(() async {
      mingtuProximityEventsOverride = null;
      await proximity.close();
    });
    final h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    final semantics = tester.ensureSemantics();
    await ui.settleRecordedApp(tester, h);
    final debug = mingtuHomeDebugHandle!;
    debug.debugSetPocketEnabled(true);
    await ui.drainVoice(tester, h);
    proximity.add(true);
    await tester.pump();
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1500)));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(debug.debugIgnoreTouches, isTrue);
    final before = h.count('asr.listen');
    final mark = h.events.length;
    final node = tester.getSemantics(find.bySemanticsLabel(holdLabel));
    node.owner!.performAction(node.id, SemanticsAction.longPress);
    await tester.longPress(find.bySemanticsLabel(holdLabel));
    await tester.pump(const Duration(milliseconds: 500));
    expect(h.count('asr.listen'), before);
    expect(h.events.sublist(mark), isNot(contains('tts.speak:请说')));
    const hazard = '前方有车辆快速驶来，请立即停下';
    debug.debugSpeakHazard(hazard);
    await s1.pumpUntil(tester, h, () => h.events.contains('tts.speak:$hazard'),
        'danger speech');
    await ui.drainVoice(tester, h);
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 1600)));
    await debug.debugHeadsetToggle();
    await s1.pumpUntil(tester, h, () => h.count('asr.listen') > before,
        'headset starts listening in pocket mode');
    semantics.dispose();
    await ui.shutdownVoice(tester, h);
  });
}
