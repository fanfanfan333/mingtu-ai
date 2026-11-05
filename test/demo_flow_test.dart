import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Widget test for the v0.2 demo flow only.
///
/// This test proves lib/main.dart compiles and its buttons drive the
/// real TaskManager through idle -> understanding -> planning ->
/// navigating -> emergency. It does NOT prove real sensor navigation,
/// real TTS, real map routes or real YOLO detection: all inputs here
/// are the labelled demo inputs in main.dart.
///
/// Buttons live in a scroll view taller than the 800x600 test window,
/// so each button is scrolled into view with ensureVisible before it
/// is tapped. pumpAndSettle is deliberately NOT used after navigation
/// starts, because the 3-second straight-prompt timer is periodic.
void main() {
  testWidgets('demo flow: voice start, plan, navigate, emergency',
      (WidgetTester tester) async {
    Future<void> tapText(String text) async {
      final Finder finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
    }

    await tester.pumpWidget(const MingtuApp());
    expect(find.text('当前任务状态：未开始'), findsOneWidget);

    await tapText('语音开始（演示输入：带我去图书馆）');
    expect(find.text('当前任务状态：正在理解你的请求'), findsOneWidget);

    await tapText('理解并规划路线');
    expect(find.text('当前任务状态：正在规划路线'), findsOneWidget);

    await tapText('开始导航（直行节奏启动）');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);
    expect(find.text('当前提示：直走'), findsOneWidget);

    await tapText('紧急求助（本地，不依赖网络和大模型）');
    // Advance fake time past the demo's simulated 1200 ms speech
    // completion delay, so no delayed timer is still pending at
    // test teardown. This does not advance the real demo clock.
    // v0.6 chains one 1200 ms completion timer per queued prompt,
    // so drain the queue with several pumps before teardown.
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
    expect(find.text('当前任务状态：紧急求助中'), findsOneWidget);
  });
}
