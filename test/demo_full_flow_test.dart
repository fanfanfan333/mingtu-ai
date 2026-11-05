import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Full v0.2 demo-flow widget test, following docs/DEMO_SCRIPT.md.
///
/// Covers, in order: voice start, route plan, navigate, turn,
/// turn recovery, uncertain-side obstacle (stop, no step), its
/// resolution, confirmed-side obstacle (one step in demo data),
/// action re-perception, destination approach, entrance finding,
/// indoor steps, task verification, task completion and local
/// recording save. It does NOT prove real sensor navigation:
/// every input here is a labelled demo input in main.dart.
void main() {
  testWidgets('demo full flow: campus library scene',
      (WidgetTester tester) async {
    Future<void> tapText(String text) async {
      final Finder finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
    }

    await tester.pumpWidget(const MingtuApp());
    await tapText('语音开始（演示输入：带我去图书馆）');
    expect(find.text('当前任务状态：正在理解你的请求'), findsOneWidget);
    await tapText('理解并规划路线');
    expect(find.text('当前任务状态：正在规划路线'), findsOneWidget);
    await tapText('开始导航（直行节奏启动）');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);

    await tapText('前方转弯（暂停直行）');
    await tapText('重新确认直行路段并恢复');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);

    await tapText('模拟障碍：侧方未确认（应停下，不给步数）');
    expect(find.text('当前任务状态：正在避障'), findsOneWidget);
    expect(find.textContaining('未给出左右步数'), findsOneWidget);
    await tapText('障碍已移开，重新评估并恢复直行');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);

    await tapText('模拟障碍：侧方已确认（仅演示数据给一步）');
    expect(find.text('当前任务状态：正在避障'), findsOneWidget);
    // Prompt text plus obstacle detail text both contain the step.
    expect(find.textContaining('向右移动一步'), findsNWidgets(2));
    await tapText('动作后重新感知，确认后恢复导航');
    expect(find.text('当前任务状态：正在导航'), findsOneWidget);

    await tapText('模拟行进至接近目的地');
    expect(find.text('当前任务状态：正在找入口'), findsOneWidget);
    await tapText('寻找入口（先看占位，再看演示已核验候选）');
    await tapText('进入室内引导');
    expect(find.text('当前任务状态：正在室内引导'), findsOneWidget);
    await tapText('室内步骤：用演示证据推进');
    await tapText('室内步骤：用演示证据推进');
    await tapText('室内步骤：用演示证据推进');
    await tapText('验证任务（室内全部完成才可）');
    expect(find.text('当前任务状态：正在等待你确认'), findsOneWidget);
    await tapText('确认任务完成');
    expect(find.text('当前任务状态：已完成'), findsOneWidget);
    await tapText('保留录像（本地）');

    // Advance fake time past the demo's simulated speech-completion
    // delays so no delayed timer is pending at test teardown.
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.text('当前任务状态：已完成'), findsOneWidget);
  });
}
