import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/asr_errors.dart';
import 'package:mingtu_ai/core/danger_alerts.dart';
import 'package:mingtu_ai/core/destination_dialogue.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Step 2 voice navigation flow: destination dialogue, live
/// tracking over a simulated GPS track, danger alerts, and
/// the ASR error whitelist. All fixtures -- no real API, no
/// real GPS.
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
  group('destination dialogue', () {
    test('the question is asked verbatim', () {
      expect(destinationAskText, '你要去哪里？请说出目的地。');
    });

    test('plain and prefixed answers resolve to the library', () {
      expect(resolveDestinationAnswer('图书馆')?.id, 'library');
      expect(resolveDestinationAnswer('去图书馆')?.id, 'library');
      expect(resolveDestinationAnswer('我想去图书馆。')?.id, 'library');
      expect(resolveDestinationAnswer('带我去图书馆')?.id, 'library');
    });

    test('the school gate resolves by name and alias', () {
      expect(resolveDestinationAnswer('校门口')?.id, 'school-gate');
      expect(resolveDestinationAnswer('学校大门')?.id, 'school-gate');
    });

    test('unknown places are NEVER guessed', () {
      expect(resolveDestinationAnswer('火车站'), isNull);
      expect(resolveDestinationAnswer(''), isNull);
      expect(resolveDestinationAnswer('随便走走'), isNull);
    });

    test(
        're-ask and give-up texts list real choices and '
        'contain no safety promise', () {
      expect(destinationNotFoundText(), contains('图书馆'));
      expect(destinationNotFoundText(), isNot(contains('安全')));
      expect(destinationGiveUpText(), contains('停止询问'));
    });
  });

  group('navigation tracker over a simulated track', () {
    const GeoPoint gate = GeoPoint(latitude: 37.724409, longitude: 120.441723);
    const GeoPoint mid = GeoPoint(latitude: 37.724409, longitude: 120.442723);
    const GeoPoint library =
        GeoPoint(latitude: 37.723667, longitude: 120.443212);
    final List<AmapStep> steps = <AmapStep>[
      const AmapStep(
        action: '直行',
        orientation: '东',
        polyline: <GeoPoint>[gate, mid],
        distanceM: 89,
        durationS: 70,
      ),
      const AmapStep(
        action: '左转',
        orientation: '南',
        polyline: <GeoPoint>[mid, library],
        distanceM: 93,
        durationS: 80,
      ),
    ];
    NavigationTracker tracker() => NavigationTracker(
          steps: steps,
          stepTexts: const <String>['第一段：向东直行。', '第二段：左转，往南走。'],
          destination: library,
          destinationName: '图书馆',
        );
    NavFix fix(GeoPoint p, {double acc = 10}) => NavFix(
          point: p,
          accuracyM: acc,
          at: DateTime(2026, 1, 1, 12),
        );

    test('start: remaining is the whole route, no events', () {
      final NavigationTracker t = tracker();
      final List<NavEvent> ev = t.onFix(fix(gate));
      expect(ev, isEmpty);
      expect(t.remainingM!, greaterThan(150));
    });

    test('approaching the turn point announces the next step', () {
      final NavigationTracker t = tracker();
      t.onFix(fix(gate));
      // ~9 m west of the turn point: inside the 30 m window.
      final List<NavEvent> ev = t.onFix(
          fix(const GeoPoint(latitude: 37.724409, longitude: 120.442623)));
      expect(ev, hasLength(1));
      expect(ev.single.kind, NavEventKind.turnAhead);
      expect(ev.single.stepIndex, 1);
      expect(ev.single.text, '第二段：左转，往南走。');
      // Announced once only.
      expect(t.onFix(fix(mid)), isEmpty);
    });

    test('arrival fires once at the destination', () {
      final NavigationTracker t = tracker();
      final List<NavEvent> ev = t.onFix(fix(library));
      expect(ev.single.kind, NavEventKind.arrived);
      expect(ev.single.text, contains('已到达图书馆附近'));
      expect(t.onFix(fix(library)), isEmpty);
    });

    test(
        'sustained off-route fires once; reroute gate '
        'throttles and exhausts', () {
      final NavigationTracker t = tracker();
      const GeoPoint farNorth =
          GeoPoint(latitude: 37.725500, longitude: 120.441723);
      expect(t.onFix(fix(farNorth)), isEmpty); // streak 1
      final List<NavEvent> ev = t.onFix(fix(farNorth)); // streak 2
      expect(ev.single.kind, NavEventKind.offRoute);
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      expect(t.rerouteDecision(t0), RerouteDecision.doIt);
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 30))),
        RerouteDecision.throttled,
      );
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 61))),
        RerouteDecision.doIt,
      );
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 122))),
        RerouteDecision.doIt,
      );
      expect(
        t.rerouteDecision(t0.add(const Duration(seconds: 183))),
        RerouteDecision.exhausted,
      );
    });

    test('the re-plan budget survives tracker rebuilds (trip level)', () {
      final RerouteBudget budget = RerouteBudget();
      NavigationTracker build() => NavigationTracker(
            steps: steps,
            stepTexts: const <String>['第一段：向东直行。', '第二段：左转，往南走。'],
            destination: library,
            destinationName: '图书馆',
            budget: budget,
          );
      final DateTime t0 = DateTime(2026, 1, 1, 10);
      final NavigationTracker first = build();
      expect(first.rerouteDecision(t0), RerouteDecision.doIt);
      expect(first.rerouteDecision(t0.add(const Duration(seconds: 61))),
          RerouteDecision.doIt);
      // A re-plan REBUILDS the tracker -- the budget must not
      // reset (that was the Codex finding).
      final NavigationTracker rebuilt = build();
      expect(rebuilt.rerouteCount, 2);
      expect(rebuilt.rerouteDecision(t0.add(const Duration(seconds: 122))),
          RerouteDecision.doIt);
      final NavigationTracker rebuiltAgain = build();
      expect(rebuiltAgain.rerouteDecision(t0.add(const Duration(seconds: 183))),
          RerouteDecision.exhausted);
      expect(rebuiltAgain.rerouteCount, 3);
    });

    test('off-route re-arms after a failed or throttled re-plan', () {
      final NavigationTracker t = tracker();
      const GeoPoint farNorth =
          GeoPoint(latitude: 37.725500, longitude: 120.441723);
      expect(t.onFix(fix(farNorth)), isEmpty);
      expect(t.onFix(fix(farNorth)).single.kind, NavEventKind.offRoute);
      // Still off route: without a re-arm nothing fires again.
      expect(t.onFix(fix(farNorth)), isEmpty);
      expect(t.onFix(fix(farNorth)), isEmpty);
      // The re-plan failed (or was throttled): main re-arms,
      // and the next sustained off-route fires again so the
      // re-plan can be retried under the trip budget.
      t.resetOffRouteStreak();
      expect(t.onFix(fix(farNorth)), isEmpty);
      expect(t.onFix(fix(farNorth)).single.kind, NavEventKind.offRoute);
    });

    test(
        'weak GPS is announced, throttled, and derives no '
        'turns', () {
      final NavigationTracker t = tracker();
      final NavFix weak = NavFix(
        point: mid,
        accuracyM: 80,
        at: DateTime(2026, 1, 1, 12),
      );
      expect(t.onFix(weak).single.kind, NavEventKind.weakSignal);
      expect(
        t.onFix(NavFix(
          point: mid,
          accuracyM: 80,
          at: DateTime(2026, 1, 1, 12, 0, 30),
        )),
        isEmpty,
      );
    });
  });

  group('danger alerts', () {
    test('categories and texts', () {
      expect(dangerCategoryFor('car'), DangerCategory.vehicle);
      expect(dangerCategoryFor('truck'), DangerCategory.vehicle);
      expect(dangerCategoryFor('bicycle'), DangerCategory.vehicle);
      expect(dangerCategoryFor('person'), DangerCategory.person);
      expect(dangerCategoryFor('dog'), DangerCategory.other);
      expect(dangerTextFor(DangerCategory.vehicle), '前方有车，请停下。');
      expect(dangerTextFor(DangerCategory.person), '前方有人，请停下。');
      expect(
        dangerTextFor(DangerCategory.other, otherName: '行人'),
        '前方检测到行人，请停下。',
      );
    });

    test('the gate cools a category down for 10 seconds', () {
      final DangerAlertGate gate = DangerAlertGate();
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      expect(gate.tryPass(DangerCategory.vehicle, t0), isTrue);
      expect(
        gate.tryPass(
            DangerCategory.vehicle, t0.add(const Duration(seconds: 5))),
        isFalse,
      );
      expect(
        gate.tryPass(
            DangerCategory.vehicle, t0.add(const Duration(seconds: 11))),
        isTrue,
      );
      // A different category is not blocked by the vehicle.
      expect(
        gate.tryPass(DangerCategory.person, t0.add(const Duration(seconds: 5))),
        isTrue,
      );
    });
  });

  group('ASR error whitelist', () {
    test('known codes survive; raw platform strings collapse', () {
      expect(asrErrorCode('error_permission'), 'error_permission');
      expect(asrErrorCode('error_no_match'), 'error_no_match');
      expect(
        asrErrorCode('a raw platform sentence with details'),
        'error_unknown',
      );
      expect(asrErrorCode(''), 'error_unknown');
    });

    test('every code has a fixed Chinese text', () {
      expect(asrErrorText('error_permission'), contains('权限'));
      expect(asrErrorText('error_unknown'), '语音识别出错。');
      for (final String code in knownAsrErrorCodes) {
        expect(asrErrorText(code), isNot(contains('error_')));
      }
    });
  });

  group(
      'location provider defaults (permission-denied '
      'degradation seam)', () {
    test('unavailable provider: permission refused, no stream', () async {
      const UnavailableCurrentLocation p = UnavailableCurrentLocation();
      expect(await p.ensurePermission(), isFalse);
      expect(await p.positions().isEmpty, isTrue);
    });
  });

  group('voice-first home (widget)', () {
    testWidgets(
        'the big status line and the two big companion '
        'buttons lead the page', (WidgetTester tester) async {
      await tester.pumpWidget(const MingtuApp());
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 1500));
      }
      // First commit (panel-era layout still in place): the
      // big status line leads the page and the two big
      // companion buttons are on it. The zero-Text form of
      // this test belongs to the second commit.
      expect(mingtuHomeDebugHandle!.bigStatusText, '明途');
      expect(find.text('明途'), findsOneWidget);
      expect(find.text('停下'), findsWidgets);
      expect(find.text('重新问目的地'), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('push-to-talk-area')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('camera-preview-area')),
        findsOneWidget,
      );
    });
  });

  group('production wiring (source level)', () {
    final String mainDart = File('lib/main.dart').readAsStringSync();

    test(
        'speech closes the mic first (awaited), via the single '
        'choke point', () {
      expect(mainDart, contains('unawaited(_speakActiveSequenced(request))'));
      expect(mainDart, contains('await speakAfterClosingMic('));
      // Danger/emergency prompts physically stop the current
      // utterance first: the sequenced speak path awaits an
      // unconditional, bounded stop before speaking (the
      // order itself is proven behaviourally, with a
      // recording fake TTS, in codex_d01a081_fix_test.dart).
      expect(mainDart, contains('await _stopTtsPlayback().timeout'));
      expect(mainDart, contains('kind: SpeechKind.danger'));
      // The re-plan budget is trip-level: created once per
      // trip, shared by every rebuilt tracker.
      expect(mainDart, contains('_tripRerouteBudget = RerouteBudget()'));
      expect(mainDart, contains('budget: _tripRerouteBudget'));
      expect(mainDart, contains('unawaited(_kickoffVoiceNavFlow'));
      expect(mainDart, contains('_locationProvider.ensurePermission()'));
      expect(
          mainDart, contains('_beginLiveNavigation(outcome, destinationName)'));
      expect(mainDart, contains('_answerDestination(text)'));
      expect(mainDart, contains('SpeechKind.alert'));
    });
  });
  // The reroute-failure source-slice tests that stood here
  // were replaced by the behavioural seam test in
  // test/codex_ptt_fix_test.dart (off-route event fires,
  // the starter fails before any route request, and
  // resetOffRouteStreak re-arms the budgeted retry).
}
