/// NAVHAZ M2 section 3.2 / acceptance 3.4.2: thermal
/// derating -- the status-to-cap mapping, the CRITICAL
/// announcement throttle (at most once per interval), the
/// stepwise 30 s recovery ladder, immediate re-derating
/// during recovery, the unknown-status fail-open
/// behaviour, the min(scene, cap) composition, and the
/// vehicle/pedestrian class restriction.
///
/// Everything runs on caller-supplied stamps (the
/// policy's injectable clock) behind a fake [ThermalMonitor]
/// stream; the "speech sink" is the policy's one-shot
/// announcementDue flag, which is exactly what the wiring
/// layer turns into one scheduler submission. All
/// thresholds are read from NavHazConfig -- no literal
/// tier/hold number is restated here.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/thermal.dart';
import 'package:mingtu_ai/core/thermal_policy.dart';

/// An in-memory [ThermalMonitor]: tests push statuses and
/// the monitor behaves like the real seam (current status
/// tracks the last push, the stream carries changes).
class FakeThermalMonitor implements ThermalMonitor {
  final StreamController<ThermalStatus> _controller =
      StreamController<ThermalStatus>.broadcast();
  ThermalStatus _current = ThermalStatus.unknown;
  bool started = false;
  bool disposed = false;

  @override
  Stream<ThermalStatus> get statuses => _controller.stream;

  @override
  ThermalStatus get currentStatus => _current;

  @override
  double? get currentHeadroom => null;

  @override
  void start() {
    started = true;
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_controller.close());
  }

  void push(ThermalStatus status) {
    _current = status;
    _controller.add(status);
  }
}

/// A fake speech sink: records every announcement the
/// policy flags as due, in order.
class FakeSpeechSink {
  final List<String> spoken = <String>[];

  void recordDue(ThermalCap cap) {
    if (cap.announcementDue) {
      spoken.add(NavHazConfig.thermalCriticalAnnouncementText);
    }
  }
}

void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 12);

  group('acceptance 3.4.2 (1): status sequence maps to caps, '
      'announcement fires once, recovery is stepwise', () {
    test('NONE -> MODERATE -> SEVERE -> CRITICAL -> NONE', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();

      // NONE: unconstrained.
      ThermalCap cap = policy.evaluate(status: ThermalStatus.none, now: t0);
      sink.recordDue(cap);
      expect(cap.maxFps, isNull);
      expect(cap.analysisResolution720p, isFalse);
      expect(cap.restrictClasses, isFalse);

      // MODERATE: FPS ceiling + 720p ceiling, no class
      // restriction, no announcement.
      cap = policy.evaluate(
          status: ThermalStatus.moderate,
          now: t0.add(const Duration(seconds: 1)));
      sink.recordDue(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.analysisResolution720p, isTrue);
      expect(cap.restrictClasses, isFalse);
      expect(cap.announcementDue, isFalse);

      // SEVERE: the 5 FPS tier + class restriction.
      cap = policy.evaluate(
          status: ThermalStatus.severe,
          now: t0.add(const Duration(seconds: 2)));
      sink.recordDue(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcementDue, isFalse);

      // CRITICAL: same tier, and the announcement fires
      // exactly once for this evaluation.
      cap = policy.evaluate(
          status: ThermalStatus.critical,
          now: t0.add(const Duration(seconds: 3)));
      sink.recordDue(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcementDue, isTrue);
      expect(sink.spoken, <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
      ]);

      // Back to NONE: the cap does NOT fall away at once.
      final DateTime cooled = t0.add(const Duration(seconds: 4));
      cap = policy.evaluate(status: ThermalStatus.none, now: cooled);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);

      // One tick before the recovery hold completes:
      // still the severe tier.
      cap = policy.evaluate(
          status: ThermalStatus.none,
          now: cooled
              .add(NavHazConfig.thermalRecoveryHold)
              .subtract(const Duration(milliseconds: 1)));
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);

      // Hold complete: ONE step up -- the moderate tier
      // (10 FPS + 720p, restriction lifted), NOT straight
      // back to unconstrained.
      final DateTime step1 = cooled.add(NavHazConfig.thermalRecoveryHold);
      cap = policy.evaluate(status: ThermalStatus.none, now: step1);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.analysisResolution720p, isTrue);
      expect(cap.restrictClasses, isFalse);

      // A second full hold: fully unconstrained.
      cap = policy.evaluate(
          status: ThermalStatus.none,
          now: step1.add(NavHazConfig.thermalRecoveryHold));
      expect(cap, ThermalCap.unconstrained);
      // And the whole sequence announced exactly once.
      expect(sink.spoken, hasLength(1));
    });

    test('the announcement text is the dictated wording, '
        'verbatim, and carries no banned word', () {
      expect(NavHazConfig.thermalCriticalAnnouncementText,
          '手机较热，识别已降频，请放慢脚步注意脚下');
      expect(
          containsBannedWord(NavHazConfig.thermalCriticalAnnouncementText),
          isFalse);
    });

    test('LIGHT takes the moderate tier; EMERGENCY and '
        'SHUTDOWN ride the critical tier and announce', () {
      final ThermalPolicy policy = ThermalPolicy();
      ThermalCap cap =
          policy.evaluate(status: ThermalStatus.light, now: t0);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.analysisResolution720p, isTrue);
      cap = policy.evaluate(
          status: ThermalStatus.emergency,
          now: t0.add(const Duration(seconds: 1)));
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcementDue, isTrue);
      // SHUTDOWN is the same tier; its announcement is
      // throttled by the firing just above.
      cap = policy.evaluate(
          status: ThermalStatus.shutdown,
          now: t0.add(const Duration(seconds: 2)));
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.announcementDue, isFalse);
    });
  });

  group('acceptance 3.4.2 (2): announcement throttle', () {
    test('repeated CRITICAL inside the interval announces '
        'once; after the interval it may announce again', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      void at(Duration offset) {
        sink.recordDue(policy.evaluate(
            status: ThermalStatus.critical, now: t0.add(offset)));
      }

      at(Duration.zero); // fires
      at(const Duration(minutes: 1)); // throttled
      at(NavHazConfig.thermalCriticalAnnouncementInterval -
          const Duration(seconds: 1)); // still throttled
      expect(sink.spoken, hasLength(1));
      at(NavHazConfig.thermalCriticalAnnouncementInterval); // fires again
      expect(sink.spoken, hasLength(2));
      expect(
          sink.spoken,
          everyElement(
              equals(NavHazConfig.thermalCriticalAnnouncementText)));
    });
  });

  group('acceptance 3.4.2 (3): unknown never constrains', () {
    test('unknown status (incl. simulated pre-API-29) -> '
        'unconstrained, composed fps equals the scene fps', () {
      final ThermalPolicy policy = ThermalPolicy();
      final ThermalCap cap =
          policy.evaluate(status: ThermalStatus.unknown, now: t0);
      expect(cap, ThermalCap.unconstrained);
      for (final int scene in <int>[
        NavHazConfig.frameRateStillFps,
        NavHazConfig.frameRateWalkingFps,
        NavHazConfig.frameRateDangerFps,
      ]) {
        expect(ThermalPolicy.composeFps(scene, cap), scene);
      }
    });

    test('platform payload decoding: 0..6 map one to one, '
        'everything else is unknown', () {
      expect(thermalStatusFromPlatformValue(0), ThermalStatus.none);
      expect(thermalStatusFromPlatformValue(1), ThermalStatus.light);
      expect(thermalStatusFromPlatformValue(2), ThermalStatus.moderate);
      expect(thermalStatusFromPlatformValue(3), ThermalStatus.severe);
      expect(thermalStatusFromPlatformValue(4), ThermalStatus.critical);
      expect(thermalStatusFromPlatformValue(5), ThermalStatus.emergency);
      expect(thermalStatusFromPlatformValue(6), ThermalStatus.shutdown);
      // The native side answers -1 below API 29.
      expect(thermalStatusFromPlatformValue(-1), ThermalStatus.unknown);
      expect(thermalStatusFromPlatformValue(99), ThermalStatus.unknown);
      expect(thermalStatusFromPlatformValue(null), ThermalStatus.unknown);
      expect(
          thermalStatusFromPayload(
              <String, Object?>{'status': -1, 'headroom': null}),
          ThermalStatus.unknown);
      expect(thermalStatusFromPayload('garbage'), ThermalStatus.unknown);
      expect(thermalStatusFromPayload(null), ThermalStatus.unknown);
      expect(
          thermalHeadroomFromPayload(
              <String, Object?>{'status': 3, 'headroom': 0.5}),
          0.5);
      expect(
          thermalHeadroomFromPayload(
              <String, Object?>{'status': 3, 'headroom': null}),
          isNull);
    });

    test('the unavailable monitor stays unknown and silent',
        () async {
      const UnavailableThermalMonitor monitor = UnavailableThermalMonitor();
      expect(monitor.currentStatus, ThermalStatus.unknown);
      expect(monitor.currentHeadroom, isNull);
      expect(await monitor.statuses.isEmpty, isTrue);
      monitor.start();
      monitor.dispose();
    });

    test('a fake monitor stream drives the policy end to end',
        () async {
      final FakeThermalMonitor monitor = FakeThermalMonitor();
      final ThermalPolicy policy = ThermalPolicy();
      final List<ThermalCap> caps = <ThermalCap>[];
      DateTime now = t0;
      final StreamSubscription<ThermalStatus> sub =
          monitor.statuses.listen((ThermalStatus status) {
        caps.add(policy.evaluate(status: status, now: now));
      });
      monitor.start();
      monitor.push(ThermalStatus.none);
      monitor.push(ThermalStatus.severe);
      now = t0.add(const Duration(seconds: 10));
      monitor.push(ThermalStatus.critical);
      await pumpEventQueue();
      expect(monitor.started, isTrue);
      expect(monitor.currentStatus, ThermalStatus.critical);
      expect(caps, hasLength(3));
      expect(caps[0], ThermalCap.unconstrained);
      expect(caps[1].maxFps, NavHazConfig.thermalCapSevereFps);
      expect(caps[2].announcementDue, isTrue);
      await sub.cancel();
      monitor.dispose();
      expect(monitor.disposed, isTrue);
    });
  });

  group('acceptance 3.4.2 (4): min composition', () {
    test('scene 20 + cap 10 -> 10; scene 2 + cap 10 -> 2; '
        'scene 20 + cap 5 -> 5', () {
      final ThermalPolicy moderatePolicy = ThermalPolicy();
      final ThermalCap cap10 = moderatePolicy.evaluate(
          status: ThermalStatus.moderate, now: t0);
      expect(cap10.maxFps, 10);
      expect(
          ThermalPolicy.composeFps(
              NavHazConfig.frameRateDangerFps, cap10),
          10);
      expect(
          ThermalPolicy.composeFps(NavHazConfig.frameRateStillFps, cap10),
          2);

      final ThermalPolicy severePolicy = ThermalPolicy();
      final ThermalCap cap5 = severePolicy.evaluate(
          status: ThermalStatus.severe, now: t0);
      expect(cap5.maxFps, 5);
      expect(
          ThermalPolicy.composeFps(NavHazConfig.frameRateDangerFps, cap5),
          5);
    });
  });

  group('acceptance 3.4.2 (5): worsening during recovery', () {
    test('a SEVERE event mid-recovery snaps straight back '
        'to the severe tier, and recovery restarts from zero',
        () {
      final ThermalPolicy policy = ThermalPolicy();
      policy.evaluate(status: ThermalStatus.critical, now: t0);
      final DateTime cooled = t0.add(const Duration(seconds: 1));
      policy.evaluate(status: ThermalStatus.none, now: cooled);
      // One recovery step lands (moderate tier).
      final DateTime step1 = cooled.add(NavHazConfig.thermalRecoveryHold);
      ThermalCap cap = policy.evaluate(status: ThermalStatus.none, now: step1);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      // Ten seconds into the next hold the device heats up
      // again: the severe tier applies IMMEDIATELY, with
      // no hold at all.
      final DateTime reheated = step1.add(const Duration(seconds: 10));
      cap = policy.evaluate(status: ThermalStatus.severe, now: reheated);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      // Cooling again needs a FRESH full hold before the
      // first step back up.
      policy.evaluate(status: ThermalStatus.none, now: reheated);
      cap = policy.evaluate(
          status: ThermalStatus.none,
          now: reheated
              .add(NavHazConfig.thermalRecoveryHold)
              .subtract(const Duration(milliseconds: 1)));
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      cap = policy.evaluate(
          status: ThermalStatus.none,
          now: reheated.add(NavHazConfig.thermalRecoveryHold));
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
    });
  });

  group('class restriction set', () {
    test('vehicles and pedestrians pass; poles, clutter '
        'and out-of-vocabulary labels are held back', () {
      // Vehicle classes (the repo label->kind mapping's
      // motorVehicle + nonMotorVehicle sets).
      for (final String label in <String>[
        'car',
        'truck',
        'bus',
        'motorcycle',
        'bicycle',
      ]) {
        expect(ThermalPolicy.keepsLabelUnderRestriction(label), isTrue,
            reason: label);
      }
      expect(ThermalPolicy.keepsLabelUnderRestriction('person'), isTrue);
      // Not vehicles, not pedestrians.
      for (final String label in <String>['pole', 'dog', 'chair', '']) {
        expect(ThermalPolicy.keepsLabelUnderRestriction(label), isFalse,
            reason: label);
      }
    });
  });

  group('flag surface', () {
    test('the thermal flag exists, defaults ON, and the '
        'constants match the spec values', () {
      expect(NavHazConfig.thermalDeratingEnabled, isTrue);
      expect(NavHazConfig.thermalCapModerateFps, 10);
      expect(NavHazConfig.thermalCapSevereFps, 5);
      expect(NavHazConfig.thermalRecoveryHold,
          const Duration(seconds: 30));
      expect(NavHazConfig.thermalCriticalAnnouncementInterval,
          const Duration(minutes: 5));
    });
  });
}
