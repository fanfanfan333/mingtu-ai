import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;

/// Production-path tests for the Codex re-test of f951240.
///
/// These do NOT grep source files: the widget tests pump the
/// real app and drive its production orchestration through
/// the demo panel (the same buttons a human taps), the
/// confirmation-rule tests call the production function
/// main's getter delegates to, the startup test mocks only
/// the platform channels under the real startup, and the
/// adapter tests use the real SystemVoiceInput with fake
/// platform engines. All fixtures; no real API is called.
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
  group('straight confirmation: the tracker governs (item 4)', () {
    AmapStep step(String action) => AmapStep(
          action: action,
          orientation: '北',
          distanceM: 50,
          durationS: 40,
          polyline: const <GeoPoint>[],
        );
    NavigationTracker trackerOn(String action) => NavigationTracker(
          steps: <AmapStep>[step(action)],
          stepTexts: const <String>['x'],
          destination: const GeoPoint(latitude: 37.72, longitude: 120.44),
          destinationName: '图书馆',
        );

    test(
        'a stale demo confirmation (true) cannot bypass a tracker '
        'on a turn step', () {
      expect(
        straightSegmentConfirmedNow(
          liveNav: trackerOn('左转'),
          fallbackConfirmed: true,
        ),
        isFalse,
      );
    });

    test(
        'a tracker on a straight step confirms even when the '
        'fallback is false', () {
      expect(
        straightSegmentConfirmedNow(
          liveNav: trackerOn('直行'),
          fallbackConfirmed: false,
        ),
        isTrue,
      );
    });

    test('without a live tracker the fallback decides', () {
      expect(
        straightSegmentConfirmedNow(liveNav: null, fallbackConfirmed: true),
        isTrue,
      );
      expect(
        straightSegmentConfirmedNow(liveNav: null, fallbackConfirmed: false),
        isFalse,
      );
    });
  });

  group('production orchestration in the real app (items 1-3)', () {
    Future<void> tapText(WidgetTester tester, String text) async {
      await drivePanelAction(tester, text);
    }

    Future<void> startDemoNavigation(WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      // Let the voice-engine startup timeouts finish (no
      // engine in this environment).
      await tester.pump(const Duration(seconds: 4));
      await tester.pump(const Duration(seconds: 4));
      await tapText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapText(tester, '理解并规划路线');
      await tapText(tester, '开始导航（直行节奏启动）');
      expectTaskState('当前任务状态：正在导航');
    }

    Future<void> drain(WidgetTester tester) async {
      for (int i = 0; i < 16; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
    }

    testWidgets(
        'item 1+3: a new danger is announced while a risk is '
        'already active; a same-level danger PREEMPTS the '
        'playing one at once (Codex re-test of d01a081)',
        (WidgetTester tester) async {
      await startDemoNavigation(tester);
      await tapText(tester, '模拟 YOLO 检测：前方行人（演示，无摄像头）');
      expectTaskState('当前任务状态：正在避障');
      expect(mingtuHomeDebugHandle!.allStatusText + mingtuHomeDebugHandle!.currentPromptText, contains('前方有人，请停下'));

      // The risk state is now ACTIVE. A vehicle appears: with
      // the f951240 code this was swallowed whole by the
      // _yoloRiskActive gate -- no announcement at all.
      await tapText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      // Same level, different event: the vehicle danger
      // replaces the playing person danger IMMEDIATELY -- it
      // does not queue behind it.
      expectPromptLine('当前提示：前方有机动车，请停下。', present: true);
      expectTaskState('当前任务状态：正在避障');

      // The interrupted person danger is never replayed:
      // after the vehicle danger completes, the person text
      // does not come back as the current prompt.
      await tester.pump(const Duration(milliseconds: 1300));
      expectPromptLine('当前提示：前方有人，请停下。', present: false);
      await drain(tester);
    });

    testWidgets(
        'item 2: a danger prompt takes over from the playing '
        'straight prompt at once (the recorded physical-stop '
        'proof lives in codex_d01a081_fix_test.dart)',
        (WidgetTester tester) async {
      await startDemoNavigation(tester);
      // The straight prompt from navigation start is still
      // playing (simulated speech completes after 1200 ms;
      // no time has been pumped since).
      await tapText(tester, '模拟 YOLO 检测：前方行人（演示，无摄像头）');
      expectPromptLine('当前提示：前方有人，请停下。', present: true);
      expectTaskState('当前任务状态：正在避障');
      await drain(tester);
    });

    testWidgets(
        'item 3: release timing -- the risk-cleared info waits '
        'for the active danger, and straight never jumps ahead',
        (WidgetTester tester) async {
      await startDemoNavigation(tester);
      await tapText(tester, '模拟 YOLO 检测：前方行人（演示，无摄像头）');
      // Same-level preemption: the vehicle danger is the
      // ACTIVE prompt now, not a queued one.
      await tapText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      expectPromptLine('当前提示：前方有机动车，请停下。', present: true);
      // Clear the obstacles while the vehicle danger is
      // still playing: the cleared info queues behind it.
      await tapText(tester, '模拟 YOLO：连续 3 帧前方无障碍（演示）');
      expectTaskState('当前任务状态：正在导航');

      // The cleared info may only become current AFTER the
      // danger has spoken. Ambient info traffic (the health
      // announcement) may interleave, and a straight prompt
      // must never jump ahead of the pending info either:
      // the demo flow re-confirms straight only via 继续.
      bool infoSeen = false;
      for (int i = 0; i < 8 && !infoSeen; i++) {
        await tester.pump(const Duration(milliseconds: 1300));
        infoSeen = mingtuHomeDebugHandle!.currentPromptText
            .contains('前方已无检测到的障碍');
        expectPromptLine('当前提示：直走', present: false);
      }
      expect(infoSeen, isTrue);
      await drain(tester);
    });
  });

  group('startup with TTS up and ASR down (item 5)', () {
    testWidgets('vibrates and speaks the ASR-down greeting',
        (WidgetTester tester) async {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final List<MethodCall> ttsCalls = <MethodCall>[];
      final List<MethodCall> platformCalls = <MethodCall>[];
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (MethodCall call) async {
          ttsCalls.add(call);
          switch (call.method) {
            case 'getLanguages':
              return <String>['zh-CN', 'en-US'];
            case 'setLanguage':
              return 1;
            case 'speak':
              return 1;
            case 'stop':
              return 1;
            default:
              return null;
          }
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'),
        (MethodCall call) async {
          // Recognition engine present but refuses to start:
          // ASR is DOWN while TTS (mocked above) is fully up.
          if (call.method == 'initialize') return false;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform,
          (MethodCall call) async {
        platformCalls.add(call);
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(
            const MethodChannel('flutter_tts'), null);
        messenger.setMockMethodCallHandler(
            const MethodChannel('plugin.csdcorp.com/speech_to_text'), null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
      });

      await tester.pumpWidget(const MingtuApp());
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 300));
      }

      // The failure is FELT (vibration) ...
      expect(
        platformCalls
            .where((MethodCall c) => c.method == 'HapticFeedback.vibrate')
            .length,
        greaterThanOrEqualTo(1),
      );
      // ... and SPOKEN: the greeting that went to the TTS
      // engine is the ASR-down greeting, verbatim from the
      // startup plan.
      final List<MethodCall> speaks =
          ttsCalls.where((MethodCall c) => c.method == 'speak').toList();
      expect(speaks, isNotEmpty);
      final String spoken =
          speaks.map((MethodCall c) => '${c.arguments}').join('\n');
      expect(spoken, contains('语音识别暂时不可用'));
    });
  });

  group('adapter status holds classified codes only (item 5)', () {
    test('a throwing initialize leaves no raw exception in status', () async {
      final SystemVoiceInput input = SystemVoiceInput(_ThrowingInitStt());
      expect(await input.initialize(), isFalse);
      expect(input.status, isNot(contains('test-token-not-real')));
      expect(input.status, isNot(contains('example.invalid')));
      expect(input.status, contains(asrErrorText('error_unknown')));
    });

    test('a throwing listen leaves only the classified code text', () async {
      final SystemVoiceInput input = SystemVoiceInput(_ThrowingListenStt());
      expect(await input.initialize(), isTrue);
      expect(await input.startListening(), isFalse);
      expect(input.status, isNot(contains('test-token-not-real')));
      expect(input.status, isNot(contains('example.invalid')));
      // PlatformException code error_network passes the
      // whitelist; its fixed text -- nothing else -- is kept.
      expect(input.status, contains(asrErrorText('error_network')));
    });
  });
}

/// STT fake whose initialize throws an exception carrying a
/// synthetic token and URL (the leak shape Codex flagged).
class _ThrowingInitStt implements stt.SpeechToText {
  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    throw Exception('token=test-token-not-real https://example.invalid/hook');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('ThrowingInitStt: ${invocation.memberName}');
}

/// STT fake that initialises fine but whose listen throws a
/// PlatformException with a known code and a toxic message.
class _ThrowingListenStt implements stt.SpeechToText {
  @override
  Future<bool> initialize({
    stt.SpeechErrorListener? onError,
    stt.SpeechStatusListener? onStatus,
    dynamic debugLogging = false,
    Duration finalTimeout = const Duration(seconds: 2),
    List<stt.SpeechConfigOption>? options,
  }) async {
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #listen) {
      throw PlatformException(
        code: 'error_network',
        message: 'token=test-token-not-real https://example.invalid/hook',
      );
    }
    if (invocation.memberName == #stop) {
      return Future<void>.value();
    }
    throw UnimplementedError('ThrowingListenStt: ${invocation.memberName}');
  }
}
