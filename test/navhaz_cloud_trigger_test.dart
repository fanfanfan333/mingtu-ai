/// NAVHAZ M2 section 3.3 / acceptance 3.4 items 3-6:
/// the cloud EVENT triggers -- the crossingStop and
/// pathBlocked condition sets (each condition missing
/// defeats the trigger), the automatic-call budget
/// (>= 60 s apart, <= 5 per sliding 10-minute window,
/// one shared in-flight slot, manual calls never
/// consuming the automatic budget), the crossing
/// announcement (reference-only wording, exact text,
/// banned-word clean), and the strict parsing of the
/// two new task answers.
///
/// Everything runs on caller-passed stamps (fake clock)
/// and fake transports; no network, no real keys. All
/// thresholds are read from NavHazConfig -- the numbers
/// asserted as literals are the SPEC's own (60 s /
/// 10 min / 5 / 15 m), which the config-surface test
/// pins the constants to.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart';
import 'package:mingtu_ai/core/avoidance_advisor.dart';
import 'package:mingtu_ai/core/cloud_trigger_policy.dart';
import 'package:mingtu_ai/core/cloud_vision.dart';
import 'package:mingtu_ai/core/cloud_vision_hazard.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';

final DateTime _t0 = DateTime(2026, 1, 1, 12);

/// A snapshot whose defaults satisfy crossingStop;
/// each test breaks exactly one condition at a time.
CloudTriggerSnapshot snap({
  String? stepText = '沿人行横道过马路',
  double? distance = 10,
  bool trafficLight = false,
  bool still = true,
  Duration stillFor = const Duration(seconds: 3),
  Duration obstacleFor = Duration.zero,
  StepAdvice? advice,
  bool tactile = false,
  DateTime? at,
}) {
  return CloudTriggerSnapshot(
    currentStepText: stepText,
    distanceToStepStartM: distance,
    trafficLightVisible: trafficLight,
    currentlyStill: still,
    stillFor: stillFor,
    corridorStaticObstacleFor: obstacleFor,
    lastAdvisorAdvice: advice,
    tactilePavingInterrupted: tactile,
    now: at ?? _t0,
  );
}

void main() {
  group('crossingStop conditions (spec 3.3 trigger a)', () {
    const CloudTriggerPolicy policy = CloudTriggerPolicy();

    test('all conditions met fires crossingStop', () {
      expect(policy.evaluate(snap()), VisionTrigger.crossingStop);
    });

    test('each crossing keyword in the step text counts as context', () {
      for (final String text in <String>['前方有人行横道', '过马路后右转', '在路口左转']) {
        expect(policy.evaluate(snap(stepText: text)),
            VisionTrigger.crossingStop, reason: text);
      }
    });

    test('a traffic light in view is context on its own', () {
      expect(
        policy.evaluate(snap(stepText: '沿中山路直行', trafficLight: true)),
        VisionTrigger.crossingStop,
      );
    });

    test('no crossing context (plain step, no light) never fires', () {
      expect(policy.evaluate(snap(stepText: '沿中山路直行')), isNull);
      expect(policy.evaluate(snap(stepText: null)), isNull);
    });

    test('distance gate: beyond 15 m or unknown never fires', () {
      expect(policy.evaluate(snap(distance: 15.5)), isNull);
      expect(policy.evaluate(snap(distance: null)), isNull);
      // The boundary itself (exactly at the config value) fires.
      expect(
        policy.evaluate(
            snap(distance: NavHazConfig.cloudCrossingMaxStepDistanceM)),
        VisionTrigger.crossingStop,
      );
    });

    test('stillness gate: walking, or still for under the hold, never fires',
        () {
      expect(policy.evaluate(snap(still: false, stillFor: Duration.zero)),
          isNull);
      expect(
        policy.evaluate(snap(
            stillFor: NavHazConfig.cloudCrossingStillHold -
                const Duration(milliseconds: 1))),
        isNull,
      );
      expect(
        policy.evaluate(snap(stillFor: NavHazConfig.cloudCrossingStillHold)),
        VisionTrigger.crossingStop,
      );
    });
  });

  group('pathBlocked conditions (spec 3.3 trigger b)', () {
    const CloudTriggerPolicy policy = CloudTriggerPolicy();

    /// A snapshot that satisfies pathBlocked only (no
    /// crossing context, far from the step start).
    CloudTriggerSnapshot blocked({
      Duration obstacleFor = const Duration(seconds: 5),
      bool still = true,
      StepAdvice? advice = StepAdvice.stopOnly,
    }) {
      return snap(
        stepText: '沿中山路直行',
        distance: 100,
        obstacleFor: obstacleFor,
        still: still,
        advice: advice,
      );
    }

    test('all conditions met fires pathBlocked', () {
      expect(policy.evaluate(blocked()), VisionTrigger.pathBlocked);
    });

    test('obstacle persistence gate: under the hold never fires', () {
      expect(
        policy.evaluate(blocked(
            obstacleFor: NavHazConfig.cloudBlockedObstacleHold -
                const Duration(milliseconds: 1))),
        isNull,
      );
      expect(
        policy.evaluate(
            blocked(obstacleFor: NavHazConfig.cloudBlockedObstacleHold)),
        VisionTrigger.pathBlocked,
      );
    });

    test('advisor gate: a step verdict, or no verdict yet, never fires', () {
      expect(policy.evaluate(blocked(advice: StepAdvice.stepLeft)), isNull);
      expect(policy.evaluate(blocked(advice: StepAdvice.stepRight)), isNull);
      expect(policy.evaluate(blocked(advice: null)), isNull);
    });

    test('stillness gate: a walking user never fires', () {
      expect(policy.evaluate(blocked(still: false)), isNull);
    });

    test('when both triggers hold, crossingStop wins', () {
      expect(
        policy.evaluate(snap(
          obstacleFor: const Duration(seconds: 9),
          advice: StepAdvice.stopOnly,
        )),
        VisionTrigger.crossingStop,
      );
    });

    test('the tactile-paving seam alone never triggers (reserved for M2+)',
        () {
      expect(
        policy.evaluate(snap(
          stepText: '沿中山路直行',
          distance: 100,
          tactile: true,
        )),
        isNull,
      );
    });
  });

  group('budget arithmetic (spec 3.3)', () {
    test('the interval is explicit: 59 s apart refuses, 60 s allows', () {
      final CloudAutoTriggerBudget b = CloudAutoTriggerBudget();
      expect(b.tryBegin(VisionTrigger.crossingStop, _t0), isTrue);
      b.end();
      expect(
        b.tryBegin(VisionTrigger.pathBlocked,
            _t0.add(const Duration(seconds: 59))),
        isFalse,
      );
      expect(
        b.tryBegin(VisionTrigger.pathBlocked,
            _t0.add(const Duration(seconds: 60))),
        isTrue,
      );
      b.end();
    });

    test('the window is the hard cap: the 6th call inside 10 min refuses, '
        'and sliding out re-opens it', () {
      final CloudAutoTriggerBudget b = CloudAutoTriggerBudget();
      for (int i = 0; i < 5; i++) {
        final DateTime t = _t0.add(Duration(seconds: 60 * i));
        expect(b.tryBegin(VisionTrigger.crossingStop, t), isTrue,
            reason: 'call ${i + 1}');
        b.end();
      }
      // 6th, still inside the window holding all five.
      expect(
        b.tryBegin(VisionTrigger.crossingStop,
            _t0.add(const Duration(seconds: 300))),
        isFalse,
      );
      expect(
        b.tryBegin(VisionTrigger.crossingStop,
            _t0.add(const Duration(seconds: 599))),
        isFalse,
      );
      // At 600 s the first dispatch has slid out of the
      // (now-600, now] window: four remain, so it opens.
      expect(
        b.tryBegin(VisionTrigger.crossingStop,
            _t0.add(const Duration(seconds: 600))),
        isTrue,
      );
      b.end();
    });

    test('one in-flight slot for everyone: while a request is unreturned, '
        'every new starter is dropped', () {
      final CloudAutoTriggerBudget b = CloudAutoTriggerBudget();
      expect(b.tryBegin(VisionTrigger.crossingStop, _t0), isTrue);
      // Never ended: auto and manual alike are dropped.
      expect(
        b.tryBegin(VisionTrigger.pathBlocked,
            _t0.add(const Duration(minutes: 3))),
        isFalse,
      );
      expect(
        b.tryBegin(
            VisionTrigger.manual, _t0.add(const Duration(minutes: 3))),
        isFalse,
      );
      b.end();
      expect(
        b.tryBegin(
            VisionTrigger.manual, _t0.add(const Duration(minutes: 3))),
        isTrue,
      );
      b.end();
    });

    test('manual calls occupy the slot but never consume the automatic '
        'budget (no window entry, no interval movement)', () {
      final CloudAutoTriggerBudget b = CloudAutoTriggerBudget();
      expect(b.tryBegin(VisionTrigger.crossingStop, _t0), isTrue);
      b.end();
      final DateTime t30 = _t0.add(const Duration(seconds: 30));
      expect(b.tryBegin(VisionTrigger.manual, t30), isTrue);
      expect(b.autoDispatchesInWindow(t30), 1); // still just the auto call
      b.end();
      // The interval still runs from the AUTO call at t0:
      // the manual call at t0+30 did not move it.
      expect(
        b.tryBegin(VisionTrigger.crossingStop,
            _t0.add(const Duration(seconds: 45))),
        isFalse,
      );
      expect(
        b.tryBegin(VisionTrigger.crossingStop,
            _t0.add(const Duration(seconds: 60))),
        isTrue,
      );
      b.end();
    });
  });

  group('acceptance 3.4.3: 30 minutes of always-satisfied triggers', () {
    test('dispatches respect interval, window and average; in-flight '
        'ticks are dropped', () {
      final CloudAutoTriggerBudget budget = CloudAutoTriggerBudget();
      final List<DateTime> sentAt = <DateTime>[];
      int droppedInFlight = 0;
      // Fake transport: a dispatched request "returns"
      // 10 fake seconds after it went out.
      DateTime? inFlightUntil;
      for (int s = 0; s < 30 * 60; s += 5) {
        final DateTime now = _t0.add(Duration(seconds: s));
        if (inFlightUntil != null && !now.isBefore(inFlightUntil)) {
          budget.end();
          inFlightUntil = null;
        }
        final bool wasInFlight = budget.inFlight;
        if (budget.tryBegin(VisionTrigger.crossingStop, now)) {
          sentAt.add(now);
          inFlightUntil = now.add(const Duration(seconds: 10));
        } else if (wasInFlight) {
          droppedInFlight += 1;
        }
      }
      // The drop path was genuinely exercised.
      expect(droppedInFlight, greaterThan(0));
      // Every pair of dispatches is >= 60 s apart.
      for (int i = 1; i < sentAt.length; i++) {
        expect(sentAt[i].difference(sentAt[i - 1]),
            greaterThanOrEqualTo(const Duration(seconds: 60)),
            reason: 'gap ${i - 1}->$i');
      }
      // Every sliding 10-minute window holds <= 5.
      for (final DateTime t in sentAt) {
        final int inWindow = sentAt
            .where((DateTime x) =>
                x.isAfter(t.subtract(const Duration(minutes: 10))) &&
                !x.isAfter(t))
            .length;
        expect(inWindow, lessThanOrEqualTo(5), reason: 'window at $t');
      }
      // Whole-run average <= 0.5 calls/minute; with the
      // window pattern above it is exactly 15.
      expect(sentAt.length, lessThanOrEqualTo(15));
      expect(sentAt.length, 15);
    });
  });

  group('acceptance 3.4.4: walking with no trigger conditions', () {
    test('ten minutes of walking snapshots produce zero cloud calls', () {
      const CloudTriggerPolicy policy = CloudTriggerPolicy();
      final CloudAutoTriggerBudget budget = CloudAutoTriggerBudget();
      int dispatched = 0;
      for (int s = 0; s < 10 * 60; s += 5) {
        final DateTime now = _t0.add(Duration(seconds: s));
        final VisionTrigger? kind = policy.evaluate(snap(
          stepText: '沿中山路直行',
          distance: 200,
          still: false,
          stillFor: Duration.zero,
          at: now,
        ));
        expect(kind, isNull);
        if (kind != null && budget.tryBegin(kind, now)) {
          dispatched += 1;
          budget.end();
        }
      }
      expect(dispatched, 0);
    });
  });

  group('crossing answers: strict parse + reference-only speech '
      '(acceptance 3.4.5)', () {
    Map<String, Object?> goodCrossing() => <String, Object?>{
          'parsed': true,
          'light': 'green',
          'countdown_s': 30,
          'crosswalk_visible': true,
        };

    test('green + countdown 30 speaks the exact reference sentence', () {
      final CrossingInfo info = parseCrossingInfo(goodCrossing());
      expect(info.parsed, isTrue);
      expect(info.light, CrossingLight.green);
      expect(info.countdownS, 30);
      final String speech = crossingSpeechText(info)!;
      expect(speech, '信号灯看起来是绿灯，倒计时约30秒，仅供参考，请用你熟悉的方式确认。');
      expect(speech, contains('仅供参考'));
      expect(containsBannedWord(speech), isFalse);
    });

    test('every light form is reference-only and banned-word clean', () {
      for (final CrossingLight light in CrossingLight.values) {
        for (final int? cd in <int?>[null, 0, 30, 99]) {
          final CrossingInfo info = CrossingInfo(
            light: light,
            countdownS: cd,
            crosswalkVisible: true,
            parsed: true,
          );
          final String? speech = crossingSpeechText(info);
          if (light == CrossingLight.unknown) {
            expect(speech, isNull);
            continue;
          }
          expect(speech, isNotNull, reason: '$light/$cd');
          expect(speech, contains('仅供参考'), reason: speech);
          expect(speech, endsWith('请用你熟悉的方式确认。'), reason: speech);
          expect(containsBannedWord(speech!), isFalse, reason: speech);
        }
      }
    });

    test('the red and none forms, verbatim', () {
      expect(
        crossingSpeechText(const CrossingInfo(
            light: CrossingLight.red,
            countdownS: null,
            crosswalkVisible: true,
            parsed: true)),
        '信号灯看起来是红灯，仅供参考，请用你熟悉的方式确认。',
      );
      expect(
        crossingSpeechText(const CrossingInfo(
            light: CrossingLight.none,
            countdownS: null,
            crosswalkVisible: false,
            parsed: true)),
        '画面里没有看到信号灯，仅供参考，请用你熟悉的方式确认。',
      );
    });

    test('invalid payloads collapse to the unknown answer', () {
      // Out-of-domain light.
      expect(
          parseCrossingInfo(goodCrossing()..['light'] = 'purple').parsed,
          isFalse);
      // A boolean countdown is NOT an integer.
      expect(
          parseCrossingInfo(goodCrossing()..['countdown_s'] = true).parsed,
          isFalse);
      // Out-of-range and fractional countdowns collapse.
      expect(
          parseCrossingInfo(goodCrossing()..['countdown_s'] = 100).parsed,
          isFalse);
      expect(
          parseCrossingInfo(goodCrossing()..['countdown_s'] = 30.5).parsed,
          isFalse);
      // Non-boolean crosswalk flag collapses.
      expect(
          parseCrossingInfo(goodCrossing()..['crosswalk_visible'] = 'yes')
              .parsed,
          isFalse);
      // Missing parsed flag / not a map at all.
      expect(parseCrossingInfo(<String, Object?>{'light': 'red'}).parsed,
          isFalse);
      expect(parseCrossingInfo('prose').parsed, isFalse);
      // A null countdown is legitimate data, not a deviation.
      final CrossingInfo noCountdown =
          parseCrossingInfo(goodCrossing()..['countdown_s'] = null);
      expect(noCountdown.parsed, isTrue);
      expect(noCountdown.countdownS, isNull);
      // The unknown answer speaks nothing (the caller
      // announces the fixed downgrade sentence instead).
      expect(crossingSpeechText(CrossingInfo.unknown), isNull);
    });

    test('client: a garbage body maps to the badResponse failure (the '
        'downgrade path), a clean body parses', () async {
      CloudVisionClient clientReturning(String body) => CloudVisionClient(
            proxyBaseUrl: 'https://fc.example.invalid',
            sender: (Uri url, String b, Map<String, String> h) async => body,
            downsampler: (Uint8List b, int d) async => b,
          );
      final CrossingScanOutcome garbage = await clientReturning('not json')
          .describeCrossingReserved(
              imageBytes: Uint8List.fromList(<int>[1, 2, 3]));
      expect(garbage.failure, CloudVisionFailure.badResponse);
      expect(garbage.ok, isFalse);

      String? sentBody;
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String b, Map<String, String> h) async {
          sentBody = b;
          return jsonEncode(goodCrossing());
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final CrossingScanOutcome outcome = await client
          .describeCrossingReserved(
              imageBytes: Uint8List.fromList(<int>[1, 2, 3]));
      expect(outcome.ok, isTrue);
      expect(outcome.info!.light, CrossingLight.green);
      final Map<String, Object?> sent =
          jsonDecode(sentBody!) as Map<String, Object?>;
      expect(sent['task'], 'crossing_info');
    });
  });

  group('detour answers: strict parse, evidence only', () {
    test('a conforming answer parses; deviations collapse', () {
      final DetourInfo ok = parseDetourInfo(<String, Object?>{
        'parsed': true,
        'blocked': true,
        'open_side': 'left',
      });
      expect(ok.parsed, isTrue);
      expect(ok.blocked, isTrue);
      expect(ok.openSide, DetourOpenSide.left);
      expect(
          parseDetourInfo(<String, Object?>{
            'parsed': true,
            'blocked': 'yes',
            'open_side': 'left',
          }).parsed,
          isFalse);
      expect(
          parseDetourInfo(<String, Object?>{
            'parsed': true,
            'blocked': true,
            'open_side': 'up',
          }).parsed,
          isFalse);
    });

    test('the unknown evidence form never asserts a blockage', () {
      expect(DetourInfo.unknown.blocked, isFalse);
      expect(DetourInfo.unknown.openSide, DetourOpenSide.unknown);
      expect(DetourInfo.unknown.parsed, isFalse);
    });

    test('client sends the detour task with the pinned prompt', () async {
      String? sentBody;
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String b, Map<String, String> h) async {
          sentBody = b;
          return jsonEncode(<String, Object?>{
            'parsed': true,
            'blocked': false,
            'open_side': 'none',
          });
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final DetourScanOutcome outcome = await client.describeDetourReserved(
          imageBytes: Uint8List.fromList(<int>[1, 2, 3]));
      expect(outcome.ok, isTrue);
      final Map<String, Object?> sent =
          jsonDecode(sentBody!) as Map<String, Object?>;
      expect(sent['task'], 'detour');
      final List<Object?> messages = sent['messages'] as List<Object?>;
      final Map<String, Object?> message =
          messages.single as Map<String, Object?>;
      final List<Object?> content = message['content'] as List<Object?>;
      final Map<String, Object?> textPart = content
          .cast<Map<String, Object?>>()
          .singleWhere((Map<String, Object?> p) => p['type'] == 'text');
      expect(textPart['text'], cloudDetourPrompt);
    });
  });

  group('flag + config surface', () {
    test('the flag defaults ON and the constants carry the spec values',
        () {
      expect(NavHazConfig.cloudAutoTriggerEnabled, isTrue);
      expect(NavHazConfig.cloudAutoMinInterval,
          const Duration(seconds: 60));
      expect(NavHazConfig.cloudAutoWindow, const Duration(minutes: 10));
      expect(NavHazConfig.cloudAutoMaxPerWindow, 5);
      expect(NavHazConfig.cloudCrossingMaxStepDistanceM, 15.0);
      expect(NavHazConfig.cloudCrossingStillHold,
          const Duration(seconds: 2));
      expect(NavHazConfig.cloudBlockedObstacleHold,
          const Duration(seconds: 4));
      expect(NavHazConfig.cloudCrossingStepKeywords,
          containsAll(<String>['人行横道', '过马路', '路口']));
    });

    test('wiring: the triggers are evaluated on pipeline frames and the '
        'old automatic scan is gone from main', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('_cloudTriggerPolicy.evaluate'));
      expect(mainDart, contains('_cloudAutoBudget.tryBegin'));
      expect(mainDart, contains('_runCloudAutoTrigger'));
      expect(mainDart, isNot(contains('_hazardScanTimer')));
      // The straight-ahead pacing timer is a different,
      // unrelated periodic timer and stays; only the
      // 8-second hazard one was deleted (pinned in the
      // avoidance production-wiring test as well).
      expect(mainDart, isNot(contains('Duration(seconds: 8)')));
    });
  });
}
