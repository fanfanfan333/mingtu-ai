import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Production-orchestration proof for the Codex re-test of
/// d01a081 (items 1 and 3), with a RECORDING fake TTS at the
/// platform-channel seam: the real app runs, the real
/// SystemVoiceOutput drives a mocked flutter_tts channel,
/// and every speak stays "playing" until the test completes
/// it. The assertions are about the ORDER of stop/speak
/// calls the platform actually received -- not source text.
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
  group('recording fake TTS through the real app', () {
    final List<String> calls = <String>[];
    final List<Completer<dynamic>> pendingSpeaks = <Completer<dynamic>>[];

    void installMocks() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (MethodCall call) async {
          switch (call.method) {
            case 'getLanguages':
              return <String>['zh-CN', 'en-US'];
            case 'setLanguage':
              return 1;
            case 'speak':
              calls.add('speak:${call.arguments}');
              final Completer<dynamic> c = Completer<dynamic>();
              pendingSpeaks.add(c);
              return c.future;
            case 'stop':
              calls.add('stop');
              return 1;
            default:
              return 1;
          }
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'),
        (MethodCall call) async {
          // ASR down, TTS up: startup speaks the ASR-down
          // greeting and never opens a listening session.
          if (call.method == 'initialize') return false;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform,
          (MethodCall call) async {
        return null;
      });
    }

    void clearMocks() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_tts'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugin.csdcorp.com/speech_to_text'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }

    Future<void> tapText(WidgetTester tester, String text) async {
      await drivePanelAction(tester, text);
    }

    Future<void> drainSpeech(WidgetTester tester) async {
      for (int round = 0; round < 12; round++) {
        final List<Completer<dynamic>> pending = pendingSpeaks
            .where((Completer<dynamic> c) => !c.isCompleted)
            .toList();
        if (pending.isEmpty) break;
        for (final Completer<dynamic> c in pending) {
          c.complete(1);
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets(
        'with a straight prompt genuinely playing, a YOLO '
        'danger stops it BEFORE speaking; a same-level danger '
        'then preempts the same way and is never replayed',
        (WidgetTester tester) async {
      calls.clear();
      pendingSpeaks.clear();
      installMocks();
      addTearDown(clearMocks);

      await tester.pumpWidget(const MingtuApp());
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tapText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapText(tester, '理解并规划路线');
      await tapText(tester, '开始导航（直行节奏启动）');
      expectTaskState('当前任务状态：正在导航');

      // The straight prompt is genuinely PLAYING: its speak
      // future is still pending at the platform seam.
      final int straightIdx = calls.indexOf('speak:直走');
      expect(straightIdx, greaterThanOrEqualTo(0), reason: 'calls: $calls');
      final int straightSpeakPos = calls
              .sublist(0, straightIdx + 1)
              .where((String c) => c.startsWith('speak:'))
              .length -
          1;
      expect(pendingSpeaks[straightSpeakPos].isCompleted, isFalse);

      // YOLO path: the person danger arrives.
      await tapText(tester, '模拟 YOLO 检测：前方行人（演示，无摄像头）');
      final int personIdx = calls.indexOf('speak:前方有人，请停下。');
      expect(personIdx, greaterThan(straightIdx), reason: 'calls: $calls');
      // A physical stop was issued AFTER the straight speak
      // and BEFORE the danger speak -- unconditionally, not
      // keyed on any scheduler flag.
      final int stopIdx =
          calls.indexWhere((String c) => c == 'stop', straightIdx);
      expect(stopIdx, greaterThan(straightIdx), reason: 'calls: $calls');
      expect(stopIdx, lessThan(personIdx), reason: 'calls: $calls');

      // Same-level danger, different event: it preempts the
      // (still playing) person danger the same way.
      await tapText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      final int carIdx = calls.indexOf('speak:前方有机动车，请停下。');
      expect(carIdx, greaterThan(personIdx), reason: 'calls: $calls');
      final int stop2Idx =
          calls.indexWhere((String c) => c == 'stop', personIdx);
      expect(stop2Idx, greaterThan(personIdx), reason: 'calls: $calls');
      expect(stop2Idx, lessThan(carIdx), reason: 'calls: $calls');
      // The interrupted person danger is never replayed.
      expect(
        calls.where((String c) => c == 'speak:前方有人，请停下。').length,
        1,
        reason: 'calls: $calls',
      );

      await drainSpeech(tester);
    });
  });
}
