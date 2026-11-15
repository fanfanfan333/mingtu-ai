import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/emergency.dart';

void main() {
  test('emergency result does not claim contact', () {
    final result = EmergencyService().trigger(triggerType: 'test');
    expect(result.contactClaimed, isFalse);
    expect(result.statusText, contains('尚未确认联系到任何帮助站'));
    expect(result.statusText, contains('请不要等待'));
  });

  testWidgets('three fingers held trigger once with truthful speech',
      (tester) async {
    await tester.pumpWidget(const MingtuApp());
    final gestures = <TestGesture>[];
    for (var i = 0; i < 3; i++) {
      gestures.add(await tester.startGesture(Offset(100.0 + i * 50, 100),
          pointer: i + 1));
    }
    await tester.pump(const Duration(milliseconds: 900));
    final h = mingtuHomeDebugHandle!;
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
    final c = await tester.startGesture(const Offset(200, 100), pointer: 3);
    await tester.pump(const Duration(milliseconds: 400));
    await c.up();
    await tester.pump(const Duration(seconds: 1));
    expect(mingtuHomeDebugHandle!.emergencyTriggerCount, 0);
    await a.up();
    await b.up();
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
