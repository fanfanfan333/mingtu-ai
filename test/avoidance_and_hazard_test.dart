import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/cloud_vision_client.dart';
import 'package:mingtu_ai/core/avoidance_advisor.dart';
import 'package:mingtu_ai/core/cloud_vision.dart';
import 'package:mingtu_ai/core/cloud_vision_hazard.dart';
import 'package:mingtu_ai/core/orientation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

Detection det(String label, double cx, double bottom, {double h = 0.4}) {
  return Detection(
    label: label,
    confidence: 0.9,
    cx: cx,
    cy: bottom - h / 2,
    w: 0.3,
    h: h,
  );
}

void main() {
  group('avoidance advisor: distance levels and the corridor', () {
    final AvoidanceAdvisor advisor = AvoidanceAdvisor();

    test('box bottom maps to near / mid / far; no box is unknown', () {
      expect(
          advisor.distanceLevelOf(det('car', 0.5, 0.9)), BoxDistanceLevel.near);
      expect(
          advisor.distanceLevelOf(det('car', 0.5, 0.7)), BoxDistanceLevel.mid);
      expect(
          advisor.distanceLevelOf(det('car', 0.5, 0.5)), BoxDistanceLevel.far);
      expect(
        advisor.distanceLevelOf(
            const Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.9)),
        BoxDistanceLevel.unknown,
      );
    });

    test('hazard categories are named as the user specified', () {
      expect(hazardKindForLabel('car'), HazardKind.motorVehicle);
      expect(hazardKindForLabel('truck'), HazardKind.motorVehicle);
      expect(hazardKindForLabel('bicycle'), HazardKind.nonMotorVehicle);
      expect(hazardKindForLabel('person'), HazardKind.person);
      expect(hazardKindForLabel('pole'), HazardKind.pole);
      expect(hazardKindName(HazardKind.motorVehicle), '机动车');
      expect(hazardKindName(HazardKind.nonMotorVehicle), '非机动车');
      expect(hazardKindName(HazardKind.clutter), '杂物');
    });
  });

  group('the three-condition rule (spec 7.7-11)', () {
    AvoidanceAdvisor primed() {
      final AvoidanceAdvisor a = AvoidanceAdvisor();
      // Three frames with the hazard in the corridor only:
      // both side streaks reach the required length.
      for (int i = 0; i < 3; i++) {
        a.observeFrame(<Detection>[det('car', 0.5, 0.9)]);
      }
      return a;
    }

    test('all three conditions hold -> a one-step direction is spoken', () {
      final AvoidanceAdvisor a = primed();
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.45, 0.92), orientationStable: true);
      expect(d.advice, StepAdvice.stepRight);
      expect(d.speech, '前方有机动车，向右迈一步。');
      expect(a.hasPendingAction, isTrue);
    });

    test('condition 1 fails (not near) -> stop only', () {
      final AvoidanceAdvisor a = primed();
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.7), orientationStable: true);
      expect(d.advice, StepAdvice.stopOnly);
      expect(d.speech, '前方有机动车，请停下。');
    });

    test('condition 1 fails (outside the corridor) -> stop only', () {
      final AvoidanceAdvisor a = primed();
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.2, 0.92), orientationStable: true);
      expect(d.advice, StepAdvice.stopOnly);
    });

    test('condition 2 fails (side streak too short) -> stop only', () {
      final AvoidanceAdvisor a = AvoidanceAdvisor();
      a.observeFrame(<Detection>[det('car', 0.5, 0.9)]);
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      expect(d.advice, StepAdvice.stopOnly);
    });

    test(
        'condition 2 fails (right side busy recently) -> step left '
        'only if left is clear', () {
      final AvoidanceAdvisor a = AvoidanceAdvisor();
      for (int i = 0; i < 3; i++) {
        a.observeFrame(<Detection>[
          det('car', 0.5, 0.9),
          det('person', 0.85, 0.8),
        ]);
      }
      expect(a.rightClearStreak, 0);
      expect(a.leftClearStreak, 3);
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      expect(d.advice, StepAdvice.stepLeft);
      expect(d.speech, '前方有机动车，向左迈一步。');
    });

    test('condition 3 fails (orientation unstable) -> stop only', () {
      final AvoidanceAdvisor a = primed();
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.92), orientationStable: false);
      expect(d.advice, StepAdvice.stopOnly);
    });

    test('unknown geometry never yields a direction (spec 7.7-15)', () {
      final AvoidanceAdvisor a = primed();
      final AvoidanceDecision d = a.decide(
        hazard:
            const Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.95),
        orientationStable: true,
      );
      expect(d.advice, StepAdvice.stopOnly);
    });

    test(
        'condition 2 counts ANY detection: a chair occupies '
        'the side it is seen on', () {
      final AvoidanceAdvisor a = primed();
      expect(a.leftClearStreak, 3);
      expect(a.rightClearStreak, 3);
      // A chair is not a hazard category, but it physically
      // occupies the left side: the streak must reset.
      a.observeFrame(<Detection>[
        det('car', 0.5, 0.9),
        det('chair', 0.15, 0.8),
      ]);
      expect(a.leftClearStreak, 0);
      expect(a.rightClearStreak, 4);
      // No step to the left any more; the still-clear right
      // side remains a legal step.
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      expect(d.advice, StepAdvice.stepRight);
      expect(d.speech, '前方有机动车，向右迈一步。');
    });

    test(
        'the Codex failure case: a chair on the right for '
        'three frames forbids the right step', () {
      final AvoidanceAdvisor a = primed();
      // Three consecutive frames with a chair (a NON-hazard
      // label) on the right side, cx > 0.67; the hazard car
      // stays central and near.
      for (int i = 0; i < 3; i++) {
        a.observeFrame(<Detection>[
          det('car', 0.5, 0.9),
          det('chair', 0.85, 0.8),
        ]);
      }
      expect(a.rightClearStreak, 0);
      expect(a.leftClearStreak, 6);
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      // The right step is forbidden; the clear left side is
      // the only legal step.
      expect(d.advice, StepAdvice.stepLeft);
      expect(d.speech, '前方有机动车，向左迈一步。');
      expect(d.speech, isNot(contains('向右')));
    });

    test(
        'condition 2: non-hazard objects on BOTH sides -> '
        'stop only', () {
      final AvoidanceAdvisor a = AvoidanceAdvisor();
      for (int i = 0; i < 3; i++) {
        a.observeFrame(<Detection>[
          det('car', 0.5, 0.9),
          det('chair', 0.15, 0.8),
          det('bench', 0.85, 0.8),
        ]);
      }
      expect(a.leftClearStreak, 0);
      expect(a.rightClearStreak, 0);
      final AvoidanceDecision d =
          a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      expect(d.advice, StepAdvice.stopOnly);
      expect(d.speech, '前方有机动车，请停下。');
    });
  });

  group(
      'action results come from frames, never from speech '
      '(spec 7.7-12)', () {
    test('a pending action confirms only when the centre clears', () {
      final AvoidanceAdvisor a = AvoidanceAdvisor();
      for (int i = 0; i < 3; i++) {
        a.observeFrame(<Detection>[det('car', 0.5, 0.9)]);
      }
      a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      expect(a.hasPendingAction, isTrue);
      // Hazard still central: no confirmation.
      expect(a.observeFrame(<Detection>[det('car', 0.5, 0.9)]), isNull);
      expect(a.hasPendingAction, isTrue);
      // Two clear frames confirm it.
      expect(a.observeFrame(const <Detection>[]), isNull);
      expect(
          a.observeFrame(const <Detection>[]), AvoidanceNotice.actionConfirmed);
      expect(a.hasPendingAction, isFalse);
    });

    test('a hazard that stays central makes the action unconfirmed', () {
      final AvoidanceAdvisor a = AvoidanceAdvisor();
      for (int i = 0; i < 3; i++) {
        a.observeFrame(<Detection>[det('car', 0.5, 0.9)]);
      }
      a.decide(hazard: det('car', 0.5, 0.92), orientationStable: true);
      AvoidanceNotice? notice;
      for (int i = 0; i < 6; i++) {
        notice = a.observeFrame(<Detection>[det('car', 0.5, 0.9)]);
      }
      expect(notice, AvoidanceNotice.actionUncertain);
      expect(a.hasPendingAction, isFalse);
    });
  });

  group('orientation judge', () {
    test('needs enough quiet samples; any fast sample breaks it', () {
      final GyroStabilityJudge j = GyroStabilityJudge();
      final DateTime t0 = DateTime(2026, 1, 1);
      for (int i = 0; i < 4; i++) {
        j.addSample(0.1, t0.add(Duration(milliseconds: 100 * i)));
      }
      expect(j.isStable, isFalse);
      j.addSample(0.1, t0.add(const Duration(milliseconds: 400)));
      expect(j.isStable, isTrue);
      j.addSample(1.2, t0.add(const Duration(milliseconds: 500)));
      expect(j.isStable, isFalse);
    });

    test('the unavailable monitor never reports stable', () {
      const UnavailableOrientationMonitor m = UnavailableOrientationMonitor();
      expect(m.isAvailable, isFalse);
      expect(m.isStable, isFalse);
    });

    test(
        'stale data is never stable: the 500 ms freshness '
        'bound', () {
      final GyroStabilityJudge j = GyroStabilityJudge();
      final DateTime t0 = DateTime(2026, 1, 1);
      // No samples at all: not stable at any time.
      expect(j.isStableAt(t0), isFalse);
      for (int i = 0; i < 5; i++) {
        j.addSample(0.1, t0.add(Duration(milliseconds: 100 * i)));
      }
      final DateTime last = t0.add(const Duration(milliseconds: 400));
      expect(j.isStableAt(last), isTrue);
      expect(
          j.isStableAt(last.add(const Duration(milliseconds: 400))), isTrue);
      expect(
          j.isStableAt(last.add(const Duration(milliseconds: 500))), isTrue);
      // The stream stopped more than 500 ms ago: the old
      // quiet samples must NOT keep the verdict stable.
      expect(
          j.isStableAt(last.add(const Duration(milliseconds: 600))), isFalse);
      expect(j.isStableAt(last.add(const Duration(seconds: 10))), isFalse);
    });
  });

  group('cloud hazard JSON: strict parse', () {
    Map<String, Object?> good() => <String, Object?>{
          'type': 'stairs_up',
          'direction': 'center',
          'distance_level': 'near',
          'confidence': 0.8,
          'path_status': <String, Object?>{
            'suggested_action': 'shift_left',
            'summary': '前方有台阶',
          },
          'parsed': true,
        };

    test('a conforming payload parses field by field', () {
      final HazardAssessment a = parseHazardAssessment(good());
      expect(a.parsed, isTrue);
      expect(a.type, HazardType.stairsUp);
      expect(a.suggestedAction, HazardSuggestedAction.shiftLeft);
    });

    test('any deviation collapses to unknown', () {
      final Map<String, Object?> badEnum = good()..['type'] = 'ramp';
      expect(parseHazardAssessment(badEnum).parsed, isFalse);
      final Map<String, Object?> longSummary = good()
        ..['path_status'] = <String, Object?>{
          'suggested_action': 'stop',
          'summary': '这是一个超过十五个字的很长的概括文字内容',
        };
      expect(parseHazardAssessment(longSummary).parsed, isFalse);
      expect(parseHazardAssessment('prose').parsed, isFalse);
      expect(parseHazardAssessment(null).type, HazardType.unknown);
    });

    test('the cloud shift suggestion NEVER becomes spoken direction', () {
      final HazardAssessment a = parseHazardAssessment(good());
      final String? speech = hazardGroundSpeech(a);
      expect(speech, startsWith('小心上台阶。'));
      expect(speech, isNot(contains('向左')));
      expect(speech, isNot(contains('向右')));
    });

    test('steps / curb / pit speeches; far stairs stay silent', () {
      HazardAssessment mk(String type, String dist) =>
          parseHazardAssessment(<String, Object?>{
            'type': type,
            'direction': 'center',
            'distance_level': dist,
            'confidence': 0.9,
            'path_status': <String, Object?>{
              'suggested_action': 'forward',
              'summary': '',
            },
            'parsed': true,
          });
      expect(hazardGroundSpeech(mk('stairs_down', 'immediate')),
          startsWith('小心下台阶。'));
      expect(hazardGroundSpeech(mk('curb', 'near')), startsWith('前方有路沿，请停下。'));
      expect(hazardGroundSpeech(mk('pit', 'near')), startsWith('前方有坑洼，请停下。'));
      expect(hazardGroundSpeech(mk('stairs_up', 'far')), isNull);
    });

    test(
        'tactile paving is identified, never judged clear, '
        'never a direction', () {
      final HazardAssessment a = parseHazardAssessment(<String, Object?>{
        'type': 'tactile_paving',
        'direction': 'center',
        'distance_level': 'near',
        'confidence': 0.9,
        'path_status': <String, Object?>{
          'suggested_action': 'forward',
          'summary': '',
        },
        'parsed': true,
      });
      final String? speech = hazardPavingSpeech(a);
      expect(speech, contains('识别到前方有盲道'));
      expect(speech, contains('是否畅通无法确认'));
      expect(speech, isNot(contains('向左')));
      expect(speech, isNot(contains('向右')));
    });

    test(
        'the joined-manual description is enum-templated and '
        'never speaks the model summary', () {
      final Map<String, Object?> payload = good()
        ..['path_status'] = <String, Object?>{
          'suggested_action': 'stop',
          'summary': 'MARKERTEXT',
        };
      final String speech =
          hazardDescriptionSpeech(parseHazardAssessment(payload));
      expect(speech, contains('上台阶'));
      expect(speech, isNot(contains('MARKERTEXT')));
    });
  });

  group('429 policy: announce once, exponential backoff', () {
    test('first 429 announces, later ones stay silent and wait grows', () {
      final VisionRateBackoff b = VisionRateBackoff();
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      expect(b.allow(t0), isTrue);
      expect(b.onRateLimited(t0), isTrue);
      expect(b.allow(t0.add(const Duration(seconds: 29))), isFalse);
      expect(b.allow(t0.add(const Duration(seconds: 30))), isTrue);
      expect(b.onRateLimited(t0.add(const Duration(seconds: 30))), isFalse);
      expect(b.allow(t0.add(const Duration(seconds: 89))), isFalse); // 60 s
      expect(b.allow(t0.add(const Duration(seconds: 90))), isTrue);
      b.onSuccess();
      expect(b.allow(t0), isTrue);
      expect(b.onRateLimited(t0), isTrue); // a new episode may speak
    });
  });

  group('vision cycle merging: one request per cycle', () {
    test('periodic + YOLO + manual triggers merge into one run', () {
      final VisionCycleCoordinator c = VisionCycleCoordinator();
      expect(c.trigger(VisionTrigger.periodic), CycleStart.hazardRun);
      expect(c.trigger(VisionTrigger.yoloHazard), CycleStart.coalesced);
      expect(c.trigger(VisionTrigger.manual), CycleStart.joined);
      expect(c.complete(), isTrue); // the manual join is answered
      expect(c.inFlight, isFalse);
    });

    test('a manual run makes scans coalesce and a second manual busy', () {
      final VisionCycleCoordinator c = VisionCycleCoordinator();
      expect(c.trigger(VisionTrigger.manual), CycleStart.manualRun);
      expect(c.trigger(VisionTrigger.periodic), CycleStart.coalesced);
      expect(c.trigger(VisionTrigger.manual), CycleStart.busy);
      expect(c.complete(), isFalse);
    });
  });

  group('hazard client call', () {
    test(
        'sends the hazard task + pinned prompt; a 429 maps to '
        'rateLimited', () async {
      String? sentBody;
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String body, Map<String, String> headers) async {
          sentBody = body;
          return jsonEncode(<String, Object?>{'error': 'rate_limited'});
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final HazardScanOutcome outcome = await client.describeHazardReserved(
          imageBytes: Uint8List.fromList(<int>[1, 2, 3]));
      expect(outcome.failure, CloudVisionFailure.rateLimited);
      final Map<String, Object?> sent =
          jsonDecode(sentBody!) as Map<String, Object?>;
      expect(sent['task'], 'hazard_scan');
      final List<Object?> messages = sent['messages'] as List<Object?>;
      final Map<String, Object?> message =
          messages.single as Map<String, Object?>;
      final List<Object?> content = message['content'] as List<Object?>;
      final Map<String, Object?> textPart =
          content.firstWhere((Object? p) => (p as Map)['type'] == 'text')
              as Map<String, Object?>;
      expect(textPart['text'], cloudHazardPrompt);
      expect(cloudHazardPrompt, contains('json'));
    });

    test('a conforming hazard answer parses through the client', () async {
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String body, Map<String, String> headers) async {
          return jsonEncode(<String, Object?>{
            'type': 'stairs_down',
            'direction': 'center',
            'distance_level': 'immediate',
            'confidence': 0.7,
            'path_status': <String, Object?>{
              'suggested_action': 'stop',
              'summary': '',
            },
            'parsed': true,
          });
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final HazardScanOutcome outcome = await client.describeHazardReserved(
          imageBytes: Uint8List.fromList(<int>[1]));
      expect(outcome.ok, isTrue);
      expect(outcome.assessment!.type, HazardType.stairsDown);
    });

    test(
        'an old-FC scene-shaped answer collapses to unknown '
        '(new client, old FC)', () async {
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String body, Map<String, String> headers) async {
          // The pre-hazard FC build answers in the scene
          // shape: it HAS "parsed" but none of the hazard
          // keys (no type / direction / path_status).
          return jsonEncode(<String, Object?>{
            'scene': '室外',
            'obstacles': <Object?>[],
            'parsed': true,
          });
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final HazardScanOutcome outcome = await client.describeHazardReserved(
          imageBytes: Uint8List.fromList(<int>[1]));
      expect(outcome.ok, isTrue);
      expect(outcome.failure, isNull);
      expect(outcome.assessment!.parsed, isFalse);
      expect(outcome.assessment!.type, HazardType.unknown);
    });

    test('a completely unrecognised answer shape collapses to unknown',
        () async {
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String body, Map<String, String> headers) async {
          return jsonEncode(<String, Object?>{'hello': 'world'});
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final HazardScanOutcome outcome = await client.describeHazardReserved(
          imageBytes: Uint8List.fromList(<int>[1]));
      expect(outcome.ok, isTrue);
      expect(outcome.failure, isNull);
      expect(outcome.assessment!.parsed, isFalse);
      expect(outcome.assessment!.type, HazardType.unknown);
    });

    test(
        'a transport exception maps to the network failure '
        '(a spoken fixed-text path, never a silent ok)', () async {
      final CloudVisionClient client = CloudVisionClient(
        proxyBaseUrl: 'https://fc.example.invalid',
        sender: (Uri url, String body, Map<String, String> headers) async {
          throw StateError('simulated transport failure');
        },
        downsampler: (Uint8List b, int d) async => b,
      );
      final HazardScanOutcome outcome = await client.describeHazardReserved(
          imageBytes: Uint8List.fromList(<int>[1]));
      expect(outcome.ok, isFalse);
      expect(outcome.failure, CloudVisionFailure.network);
    });
  });

  group('cloud-vision downgrade gate: announce once, rate-limited', () {
    test(
        'first failure speaks, repeats are muted for the '
        'cooldown, a success re-arms', () {
      final CloudVisionDowngradeGate g = CloudVisionDowngradeGate();
      final DateTime t0 = DateTime(2026, 1, 1, 12);
      expect(cloudVisionDowngradeSpeech, '云端识图暂不可用，请慢行。');
      expect(g.shouldAnnounce(t0), isTrue);
      expect(g.shouldAnnounce(t0.add(const Duration(seconds: 10))), isFalse);
      expect(g.shouldAnnounce(t0.add(const Duration(seconds: 59))), isFalse);
      expect(g.shouldAnnounce(t0.add(const Duration(seconds: 61))), isTrue);
      // Muted again right after the second announcement...
      expect(g.shouldAnnounce(t0.add(const Duration(seconds: 70))), isFalse);
      // ...until a success resets the gate.
      g.noteSuccess();
      expect(g.shouldAnnounce(t0.add(const Duration(seconds: 71))), isTrue);
    });
  });

  group('production wiring', () {
    test(
        'main routes danger speech, scans and orientation through '
        'the new modules', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('_avoidance.decide('));
      expect(mainDart, contains('_avoidance.observeFrame(detections)'));
      expect(mainDart, contains('createOrientationMonitor()'));
      expect(mainDart, contains('_triggerHazardScan(VisionTrigger.periodic)'));
      expect(
          mainDart, contains('_triggerHazardScan(VisionTrigger.yoloHazard)'));
      expect(mainDart, contains('describeHazardReserved'));
      expect(mainDart, contains('_visionBackoff.onRateLimited'));
      expect(mainDart, contains('_triggerManualVision()'));
    });
  });
}
