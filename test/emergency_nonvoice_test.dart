import 'dart:async';
import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/core/pocket_mode.dart';
import 'package:mingtu_ai/modules/emergency.dart';

void main() {
  test('emergency result does not claim contact', () {
    final result = EmergencyService().trigger(triggerType: 'test');
    expect(result.contactClaimed, isFalse);
    expect(result.statusText, contains('尚未确认联系到任何帮助站'));
    expect(result.statusText, contains('请不要等待'));
  });

  testWidgets('custom emergency action shares confirmation and expires',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    final initialState = h.taskState;
    final initialCamera = h.yoloLiveOpen;
    const action = CustomSemanticsAction(label: '紧急求助');
    void invoke() {
      final node =
          tester.getSemantics(find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'));
      expect(node.getSemanticsData().customSemanticsActionIds,
          contains(CustomSemanticsAction.getIdentifier(action)));
      node.owner!.performAction(node.id, SemanticsAction.customAction,
          CustomSemanticsAction.getIdentifier(action));
    }

    invoke();
    await tester.pump();
    expect(h.currentPromptText, contains('即将发起紧急求助，再次选择紧急求助确认'));
    expect(h.emergencyTriggerCount, 0);
    expect(h.taskState, initialState);
    expect(h.yoloLiveOpen, initialCamera);
    await tester.pump(emergencyConfirmTimeout);
    invoke();
    await tester.pump();
    expect(h.emergencyTriggerCount, 0);
    expect(h.taskState, initialState);
    expect(h.yoloLiveOpen, initialCamera);
    invoke();
    await tester.pump();
    expect(h.emergencyTriggerCount, 1);
    expect(h.statusTexts.join(), contains('尚未确认联系到任何帮助站'));
    expect(h.currentPromptText, contains('尚未确认联系到任何帮助站'));
    expect(h.currentPromptText, contains('请不要等待'));
    expect(h.currentPromptText, isNot(contains('已联系帮助站')));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('three-finger confirmation accepts custom emergency action',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    final gestures = <TestGesture>[];
    for (var i = 0; i < 3; i++) {
      gestures.add(await tester.startGesture(Offset(100.0 + i * 50, 100),
          pointer: i + 1));
    }
    await tester.pump(const Duration(milliseconds: 900));
    for (final gesture in gestures) {
      await gesture.up();
    }
    expect(h.emergencyTriggerCount, 0);
    final node =
        tester.getSemantics(find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'));
    node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
            const CustomSemanticsAction(label: '紧急求助')));
    await tester.pump();
    expect(h.emergencyTriggerCount, 1);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('pocket lock ignores custom emergency action', (tester) async {
    final proximity = StreamController<bool>.broadcast();
    mingtuProximityEventsOverride = () => proximity.stream;
    mingtuPocketNowOverride = tester.binding.clock.now;
    addTearDown(() async {
      mingtuProximityEventsOverride = null;
      mingtuPocketNowOverride = null;
      await proximity.close();
    });
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    h.debugSetPocketEnabled(true);
    proximity.add(true);
    await tester.pump();
    await tester.pump(pocketNearDuration);
    expect(h.debugIgnoreTouches, isTrue);
    final state = h.taskState;
    final camera = h.yoloLiveOpen;
    final prompt = h.currentPromptText;
    final node =
        tester.getSemantics(find.bySemanticsLabel('按住说话按钮，按住后说话，松开结束'));
    node.owner!.performAction(
        node.id,
        SemanticsAction.customAction,
        CustomSemanticsAction.getIdentifier(
            const CustomSemanticsAction(label: '紧急求助')));
    await tester.pump();
    expect(h.currentPromptText, prompt);
    expect(h.emergencyTriggerCount, 0);
    expect(h.taskState, state);
    expect(h.yoloLiveOpen, camera);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('three fingers held trigger once with truthful speech',
      (tester) async {
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    final initialState = h.taskState;
    final initialCamera = h.yoloLiveOpen;
    final gestures = <TestGesture>[];
    for (var i = 0; i < 3; i++) {
      gestures.add(await tester.startGesture(Offset(100.0 + i * 50, 100),
          pointer: i + 1));
    }
    await tester.pump(const Duration(milliseconds: 900));
    expect(h.emergencyTriggerCount, 0);
    expect(h.currentPromptText, contains('即将发起紧急求助，再次三指长按确认'));
    expect(h.yoloLiveOpen, initialCamera);
    expect(h.taskState, initialState);
    for (final gesture in gestures) {
      await gesture.up();
    }
    expect(h.taskState, initialState);
    gestures.clear();
    for (var i = 0; i < 3; i++) {
      gestures.add(await tester.startGesture(Offset(100.0 + i * 50, 100),
          pointer: i + 1));
    }
    await tester.pump(const Duration(milliseconds: 900));
    expect(h.emergencyTriggerCount, 1);
    expect(h.statusTexts.join(), contains('尚未确认联系到任何帮助站'));
    final speech = h.currentPromptText;
    expect(speech, contains('尚未确认联系到任何帮助站'));
    expect(speech, contains('请不要等待'));
    expect(speech, isNot(contains('安全')));
    expect(speech, isNot(contains('可以过马路')));
    expect(speech, isNot(contains('已联系帮助站')));
    await tester.pump(const Duration(seconds: 1));
    expect(h.emergencyTriggerCount, 1);
    for (final gesture in gestures) {
      await gesture.up();
    }
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('two fingers and early release do not trigger', (tester) async {
    await tester.pumpWidget(const MingtuApp());
    final a = await tester.startGesture(const Offset(100, 100), pointer: 1);
    final b = await tester.startGesture(const Offset(150, 100), pointer: 2);
    await tester.pump(const Duration(seconds: 1));
    expect(mingtuHomeDebugHandle!.emergencyTriggerCount, 0);
    expect(mingtuHomeDebugHandle!.currentPromptText,
        isNot(contains('即将发起紧急求助，再次三指长按确认')));
    final c = await tester.startGesture(const Offset(200, 100), pointer: 3);
    await tester.pump(const Duration(milliseconds: 400));
    await c.up();
    await tester.pump(const Duration(seconds: 1));
    expect(mingtuHomeDebugHandle!.emergencyTriggerCount, 0);
    expect(mingtuHomeDebugHandle!.currentPromptText,
        isNot(contains('即将发起紧急求助，再次三指长按确认')));
    await a.up();
    await b.up();
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('confirmation expires and requires a fresh pair of holds',
      (tester) async {
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    Future<void> hold() async {
      final gestures = <TestGesture>[];
      for (var i = 0; i < 3; i++) {
        gestures.add(await tester.startGesture(Offset(100.0 + i * 50, 100),
            pointer: i + 1));
      }
      await tester.pump(const Duration(milliseconds: 900));
      for (final gesture in gestures) {
        await gesture.up();
      }
    }

    final state = h.taskState;
    await hold();
    expect(h.currentPromptText, contains('即将发起紧急求助，再次三指长按确认'));
    await tester.pump(emergencyConfirmTimeout);
    await hold();
    expect(h.emergencyTriggerCount, 0);
    expect(h.taskState, state);
    expect(h.yoloLiveOpen, isFalse);
    await hold();
    expect(h.emergencyTriggerCount, 1);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('pocket lock ignores a three-finger hold', (tester) async {
    final proximity = StreamController<bool>.broadcast();
    mingtuProximityEventsOverride = () => proximity.stream;
    mingtuPocketNowOverride = tester.binding.clock.now;
    addTearDown(() async {
      mingtuProximityEventsOverride = null;
      mingtuPocketNowOverride = null;
      await proximity.close();
    });
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    h.debugSetPocketEnabled(true);
    proximity.add(true);
    await tester.pump();
    await tester.pump(pocketNearDuration);
    expect(h.debugIgnoreTouches, isTrue);
    final state = h.taskState;
    final camera = h.yoloLiveOpen;
    final gestures = <TestGesture>[];
    for (var i = 0; i < 3; i++) {
      gestures.add(await tester.startGesture(Offset(100.0 + i * 50, 100),
          pointer: i + 1));
    }
    await tester.pump(const Duration(milliseconds: 900));
    expect(h.currentPromptText, isNot(contains('即将发起紧急求助，再次三指长按确认')));
    expect(h.emergencyTriggerCount, 0);
    expect(h.taskState, state);
    expect(h.yoloLiveOpen, camera);
    for (final gesture in gestures) {
      await gesture.up();
    }
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('headset triple press uses a 1.5 second window', (tester) async {
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    // Do not await permission-gated calls; real presses can arrive while pending.
    h.debugHeadsetToggle();
    h.debugHeadsetToggle();
    expect(h.emergencyTriggerCount, 0);
    h.debugHeadsetToggle();
    expect(h.emergencyTriggerCount, 1);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });

  testWidgets('headset presses outside window do not trigger', (tester) async {
    await tester.pumpWidget(const MingtuApp());
    final h = mingtuHomeDebugHandle!;
    h.debugHeadsetToggle();
    await tester.pump(const Duration(milliseconds: 1600));
    h.debugHeadsetToggle();
    await tester.pump(const Duration(milliseconds: 1600));
    h.debugHeadsetToggle();
    expect(h.emergencyTriggerCount, 0);
    await tester.pumpWidget(const SizedBox());
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });
}
