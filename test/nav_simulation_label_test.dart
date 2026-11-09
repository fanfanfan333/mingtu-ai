import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Navigation P0, item: simulation must be ANNOUNCED as simulation.
/// The demo (stub) flow's controls are labelled 演示 on screen, but a
/// blind user only hears the spoken prompts -- so the spoken start
/// of the simulated flow must itself say 模拟. This widget test
/// drives the demo planning step and checks the displayed current
/// prompt (which is exactly the text handed to the speech path).
void main() {
  testWidgets('simulated route planning announces 模拟 in speech',
      (WidgetTester tester) async {
    await tester.pumpWidget(const MingtuApp());
    // Let the voice-engine startup timeouts finish (no engine here).
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));

    Future<void> tapText(String text) async {
      final Finder finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
    }

    await tapText('语音开始（演示输入：带我去图书馆）');
    await tapText('理解并规划路线');
    expect(find.textContaining('模拟导航：已规划演示路线'), findsOneWidget);

    // Drain the chained simulated speech timers before teardown.
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
  });
}
