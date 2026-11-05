import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Widget test for v0.5 blind-first voice additions only.
///
/// It proves the new voice commands drive the real state machine:
/// "停下" pauses navigation (straight timer stopped), and "现在到哪了"
/// answers in Chinese (no English enum name in the prompt).
void main() {
  testWidgets('voice: stop pauses, status answers in Chinese',
      (WidgetTester tester) async {
    Future<void> tapText(String text) async {
      final Finder finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
    }

    Future<void> sendVoice(String text) async {
      await tester.enterText(find.byType(TextField), text);
      await tester.pump();
      await tapText('发送语音指令（演示）');
    }

    await tester.pumpWidget(const MingtuApp());
    await tapText('语音开始（演示输入：带我去图书馆）');
    await tapText('理解并规划路线');
    await tapText('开始导航（直行节奏启动）');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);

    await sendVoice('停下');
    expect(find.text('当前任务状态：已暂停'), findsOneWidget);
    expect(find.textContaining('已暂停导航'), findsOneWidget);

    await sendVoice('现在到哪了');
    expect(find.textContaining('当前状态：已暂停'), findsOneWidget);
    expect(find.textContaining('understanding'), findsNothing);
    expect(find.textContaining('paused'), findsNothing);
    // Advance past the demo's simulated 1200 ms speech completion
    // delays, so no timer is pending at teardown (v0.6 chains one
    // timer per queued prompt).
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
  });
}
