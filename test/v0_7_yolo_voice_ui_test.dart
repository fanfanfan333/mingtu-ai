import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Widget test for the v0.7 voice audit fixes that need the real UI:
/// - health degradation is announced with Chinese service names;
/// - a simulated YOLO person detection warns by voice and stops
///   straight prompts; three clear frames lift the risk without
///   auto-resuming straight; saying "继续" then re-confirms straight.
void main() {
  testWidgets('yolo warning, clear, and voice re-confirm',
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
    // Let the voice-engine startup timeouts finish (no engine here).
    await tester.pump(const Duration(seconds: 4));
    await tester.pump(const Duration(seconds: 4));
    // P0 follow-up: the startup voice plan now surfaces the honest
    // voice state in several places (status line, current prompt,
    // log), all of which legitimately contain 语音播报. This
    // assertion therefore names the health line it actually checks:
    // Chinese service names in the health announcement, and no
    // English identifier anywhere.
    expect(find.textContaining('系统健康：注意：语音播报、语音识别'), findsOneWidget);
    expect(find.textContaining('voice_output'), findsNothing);

    await tapText('语音开始（演示输入：带我去图书馆）');
    await tapText('理解并规划路线');
    await tapText('开始导航（直行节奏启动）');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);

    await tapText('模拟 YOLO 检测：前方行人（演示，无摄像头）');
    expect(find.text('当前任务状态：正在避障'), findsOneWidget);
    expect(find.textContaining('前方检测到行人'), findsOneWidget);

    await tapText('模拟 YOLO：连续 3 帧前方无障碍（演示）');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);
    expect(find.textContaining('前方已无检测到的障碍'), findsOneWidget);

    await sendVoice('继续');
    expect(find.textContaining('已重新确认直线路段，继续直走'), findsOneWidget);

    // Drain the chained simulated speech timers before teardown.
    for (int i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
  });
}
