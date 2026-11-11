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
/// MT-1111-PTT-C: the demo panel is gone from the app's
/// interface; flows its buttons drove are driven through
/// the app's debug handle (the same handlers), and state
/// the panel rendered is asserted on the handle's state
/// getters instead of screen text.
Future<void> drivePanelAction(WidgetTester tester, String label) async {
  final MingtuHomeDebugHandle h = mingtuHomeDebugHandle!;
  switch (label) {
    case '停止语音识别':
      h.stopVoiceRecognition();
    case '重新问目的地':
      h.askDestination();
    case '停下':
      h.voiceCommand('停下');
    case '语音开始（演示输入：带我去图书馆）':
      h.startVoiceDemo();
    case '理解并规划路线':
      h.planRoute();
    case '开始导航（直行节奏启动）':
      h.startNavigating();
    case '前方转弯（暂停直行）':
      h.turnAhead();
    case '直行提示（手动，3 秒间隔内不重复）':
      h.manualStraight();
    case '重新确认直行路段并恢复':
      h.reconfirmStraight();
    case '模拟障碍：侧方未确认（应停下，不给步数）':
      h.obstacleUncertain();
    case '障碍已移开，重新评估并恢复直行':
      h.obstacleUncertainResolved();
    case '模拟障碍：侧方已确认（仅演示数据给一步）':
      h.obstacleConfirmed();
    case '动作后重新感知，确认后恢复导航':
      h.obstacleConfirmedVerified();
    case '路口信息提示（只提示，不放行）':
      h.trafficInfo();
    case '模拟行进至接近目的地':
      h.destinationApproach();
    case '寻找入口（先看占位，再看演示已核验候选）':
      h.findEntrance();
    case '进入室内引导':
      h.enterIndoor();
    case '室内步骤：用演示证据推进':
      h.indoorStep();
    case '验证任务（室内全部完成才可）':
      h.taskVerify();
    case '确认任务完成':
      h.confirmComplete();
    case '保留录像（本地）':
      h.recordingSave();
    case '删除录像（本地）':
      h.recordingDelete();
    case '云端网关演示（只返回决策，无真实调用）':
      h.llmDemo();
    case '云端视觉辅助（低频，经代理，本地检测仍为主）':
      h.triggerManualVision();
    case '紧急求助（本地，不依赖网络和大模型）':
      h.triggerEmergency();
    case '重置演示':
      h.resetDemo();
    case '高德真实路线（真实导航：需已核验目的地与路线代理）':
      h.fetchAmapRoute();
    case '模拟 YOLO 检测：前方行人（演示，无摄像头）':
      h.simulatePersonAhead();
    case '模拟 YOLO 检测：前方车辆（演示，无摄像头）':
      h.simulateVehicleAhead();
    case '模拟 YOLO：连续 3 帧前方无障碍（演示）':
      h.simulateClearFrames();
    case '暂停导航（语音）':
      h.voiceCommand('暂停');
    case '继续导航（语音，需重新确认直行）':
      h.voiceCommand('继续');
    case '再说一遍':
      h.voiceCommand('再说一遍');
    case '现在到哪了':
      h.voiceCommand('现在到哪了');
    case '取消任务（语音）':
      h.voiceCommand('取消');
    case '打开摄像头（YOLO 实时检测）':
      await h.openYoloLive();
    default:
      fail('no debug-handle mapping for panel label: $label');
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

/// State-line assertion, migrated: the panel's rendered
/// '当前任务状态：…' line is now read from state.
void expectTaskState(String stateLine) {
  expect(mingtuHomeDebugHandle!.taskStateText, stateLine);
}

/// Prompt-line assertion, migrated: the panel's rendered
/// '当前提示：…' line is now read from state.
void expectPromptLine(String promptLine, {required bool present}) {
  final String actual = mingtuHomeDebugHandle!.currentPromptText;
  if (present) {
    expect(actual, promptLine);
  } else {
    expect(actual, isNot(promptLine));
  }
}

void main() {
  testWidgets('demo flow: voice start, plan, navigate, emergency',
      (WidgetTester tester) async {
    Future<void> tapText(String text) async {
      await drivePanelAction(tester, text);
    }

    await tester.pumpWidget(const MingtuApp());
    expectTaskState('当前任务状态：未开始');

    await tapText('语音开始（演示输入：带我去图书馆）');
    expectTaskState('当前任务状态：正在理解你的请求');

    await tapText('理解并规划路线');
    expectTaskState('当前任务状态：正在规划路线');

    await tapText('开始导航（直行节奏启动）');
    expectTaskState('当前任务状态：正在导航');
    expectPromptLine('当前提示：直走', present: true);

    await tapText('紧急求助（本地，不依赖网络和大模型）');
    // Advance fake time past the demo's simulated 1200 ms speech
    // completion delay, so no delayed timer is still pending at
    // test teardown. This does not advance the real demo clock.
    // v0.6 chains one 1200 ms completion timer per queued prompt,
    // so drain the queue with several pumps before teardown.
    for (int i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
    expectTaskState('当前任务状态：紧急求助中');
  });
}
