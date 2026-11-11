/// NAVHAZ M2 section 3.2 / acceptance 3.4.2: thermal
/// derating -- the status-to-cap mapping, the stepwise
/// 30 s recovery ladder, immediate re-derating during
/// recovery, the unknown-status fail-open behaviour,
/// the min(scene, cap) composition, and the
/// vehicle/pedestrian class restriction.
///
/// Announcements follow the EPISODE-LATCH model (the
/// ruling that superseded the original section 3.2
/// "CRITICAL announces at most once per five minutes"
/// rule): inside one derating episode the FPS latch and
/// the scope latch each speak at most once, and a full
/// recovery speaks the restoration text once. The
/// five-minute re-announcement and its interval
/// constant are gone; the tests below pin the new model
/// and each rewritten assertion carries its reason.
///
/// Everything runs on caller-supplied stamps (the
/// policy's injectable clock) behind a fake [ThermalMonitor]
/// stream; the "speech sink" records the text the
/// wiring layer would speak for the policy's one-shot
/// announcement event -- the same event-to-text mapping
/// main.dart performs. All thresholds are read from
/// NavHazConfig -- no literal tier/hold number is
/// restated here.
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

/// A fake speech sink: records, in order, the text the
/// wiring layer speaks for each announcement event the
/// policy raises (event -> dictated text, mirroring the
/// mapping in main.dart's thermal handler).
class FakeSpeechSink {
  final List<String> spoken = <String>[];

  void record(ThermalCap cap) {
    switch (cap.announcement) {
      case ThermalAnnouncement.fpsDrop:
        spoken.add(NavHazConfig.thermalCriticalAnnouncementText);
      case ThermalAnnouncement.scopeRestricted:
        spoken.add(NavHazConfig.thermalScopeRestrictedAnnouncementText);
      case ThermalAnnouncement.recovered:
        spoken.add(NavHazConfig.thermalRecoveryAnnouncementText);
      case ThermalAnnouncement.none:
        break;
    }
  }
}

void main() {
  final DateTime t0 = DateTime(2026, 1, 1, 12);

  group('acceptance 3.4.2 (1): status sequence maps to caps, '
      'episode announcements fire once each, recovery is stepwise',
      () {
    test('NONE -> MODERATE -> SEVERE -> CRITICAL -> NONE', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();

      // NONE: unconstrained, nothing to announce.
      ThermalCap cap = policy.evaluate(status: ThermalStatus.none, now: t0);
      sink.record(cap);
      expect(cap.maxFps, isNull);
      expect(cap.analysisResolution720p, isFalse);
      expect(cap.restrictClasses, isFalse);
      expect(cap.announcement, ThermalAnnouncement.none);

      // MODERATE: FPS ceiling + 720p ceiling, no class
      // restriction.
      // REWRITTEN (episode-latch ruling): the old model
      // expected NO announcement here -- only CRITICAL
      // ever spoke. Under the latch model the FPS latch
      // fires the moment any cap first limits the frame
      // rate, so this evaluation raises fpsDrop.
      cap = policy.evaluate(
          status: ThermalStatus.moderate,
          now: t0.add(const Duration(seconds: 1)));
      sink.record(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.analysisResolution720p, isTrue);
      expect(cap.restrictClasses, isFalse);
      expect(cap.announcement, ThermalAnnouncement.fpsDrop);

      // SEVERE: the 5 FPS tier + class restriction.
      // REWRITTEN (episode-latch ruling): the old model
      // expected no announcement here either; the scope
      // latch now speaks the narrowing the moment the
      // restriction first applies.
      cap = policy.evaluate(
          status: ThermalStatus.severe,
          now: t0.add(const Duration(seconds: 2)));
      sink.record(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcement, ThermalAnnouncement.scopeRestricted);

      // CRITICAL: same tier, and NO new announcement.
      // REWRITTEN (episode-latch ruling): the old model
      // fired its (throttled) announcement exactly here.
      // Severe -> critical changes no cap fact -- the
      // scope was already announced at SEVERE -- so this
      // evaluation raises nothing.
      cap = policy.evaluate(
          status: ThermalStatus.critical,
          now: t0.add(const Duration(seconds: 3)));
      sink.record(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcement, ThermalAnnouncement.none);
      expect(sink.spoken, <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
      ]);

      // Back to NONE: the cap does NOT fall away at once.
      final DateTime cooled = t0.add(const Duration(seconds: 4));
      cap = policy.evaluate(status: ThermalStatus.none, now: cooled);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcement, ThermalAnnouncement.none);

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
      // back to unconstrained. A PARTIAL recovery speaks
      // no recovery text.
      final DateTime step1 = cooled.add(NavHazConfig.thermalRecoveryHold);
      cap = policy.evaluate(status: ThermalStatus.none, now: step1);
      sink.record(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.analysisResolution720p, isTrue);
      expect(cap.restrictClasses, isFalse);
      expect(cap.announcement, ThermalAnnouncement.none);

      // A second full hold: fully unconstrained, and the
      // recovery latch fires exactly here.
      // REWRITTEN (episode-latch ruling): the old model
      // compared this cap to ThermalCap.unconstrained;
      // the settled cap now also carries the one-shot
      // recovered event, so the fields are asserted
      // individually.
      cap = policy.evaluate(
          status: ThermalStatus.none,
          now: step1.add(NavHazConfig.thermalRecoveryHold));
      sink.record(cap);
      expect(cap.maxFps, isNull);
      expect(cap.analysisResolution720p, isFalse);
      expect(cap.restrictClasses, isFalse);
      expect(cap.announcement, ThermalAnnouncement.recovered);
      // The whole sequence spoke each text exactly once,
      // in episode order.
      expect(sink.spoken, <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
      ]);
    });

    test('the announcement texts are the dictated wordings, '
        'verbatim, and carry no banned word', () {
      // Literal pins: the config constants must equal
      // these dictated strings character for character
      // (and the constants' presence is asserted by
      // referencing them here).
      expect(NavHazConfig.thermalCriticalAnnouncementText,
          '手机较热，识别已降频，请放慢脚步注意脚下');
      expect(NavHazConfig.thermalScopeRestrictedAnnouncementText,
          '手机过热，暂时只提醒车辆和行人，请放慢脚步');
      expect(NavHazConfig.thermalRecoveryAnnouncementText, '障碍提醒已恢复');
      for (final String text in <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
      ]) {
        expect(containsBannedWord(text), isFalse, reason: text);
      }
    });

    test('LIGHT takes the moderate tier; EMERGENCY and '
        'SHUTDOWN ride the severe tier', () {
      final ThermalPolicy policy = ThermalPolicy();
      // LIGHT: the moderate tier, and the FPS latch fires
      // (first frame-rate cap of the episode).
      ThermalCap cap = policy.evaluate(status: ThermalStatus.light, now: t0);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.analysisResolution720p, isTrue);
      expect(cap.announcement, ThermalAnnouncement.fpsDrop);
      // EMERGENCY: the severe tier with the restriction.
      // REWRITTEN (episode-latch ruling): the old model
      // flagged this evaluation with its throttled
      // CRITICAL announcement; under the latch model the
      // newly-true fact here is the scope restriction
      // (the FPS latch was consumed at LIGHT), so this
      // evaluation raises the scope event.
      cap = policy.evaluate(
          status: ThermalStatus.emergency,
          now: t0.add(const Duration(seconds: 1)));
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.restrictClasses, isTrue);
      expect(cap.announcement, ThermalAnnouncement.scopeRestricted);
      // SHUTDOWN is the same tier.
      // REWRITTEN (episode-latch ruling): the old model
      // expected silence here because of the five-minute
      // throttle; the silence now comes from both
      // episode latches already being consumed -- no
      // throttle exists anymore.
      cap = policy.evaluate(
          status: ThermalStatus.shutdown,
          now: t0.add(const Duration(seconds: 2)));
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.announcement, ThermalAnnouncement.none);
    });
  });

  group('episode latches (the ruling superseding the '
      'five-minute throttle)', () {
    test('a direct NONE -> SEVERE jump speaks ONLY the '
        'scope text, once; the FPS latch is consumed '
        'silently', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      final ThermalCap cap =
          policy.evaluate(status: ThermalStatus.severe, now: t0);
      sink.record(cap);
      expect(cap.announcement, ThermalAnnouncement.scopeRestricted);
      // The episode continues: severe and critical
      // repetitions raise nothing, and the FPS text is
      // never spoken in this episode at all.
      sink.record(policy.evaluate(
          status: ThermalStatus.severe,
          now: t0.add(const Duration(seconds: 1))));
      sink.record(policy.evaluate(
          status: ThermalStatus.critical,
          now: t0.add(const Duration(seconds: 2))));
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
      ]);
    });

    test('a direct NONE -> CRITICAL jump speaks the scope '
        'text once (where the old rule\'s once-only '
        'critical announcement lands)', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      sink.record(policy.evaluate(status: ThermalStatus.critical, now: t0));
      sink.record(policy.evaluate(
          status: ThermalStatus.critical,
          now: t0.add(const Duration(minutes: 1))));
      sink.record(policy.evaluate(
          status: ThermalStatus.critical,
          now: t0.add(const Duration(minutes: 30))));
      // Exactly one scope announcement, however long the
      // device stays critical -- the old five-minute
      // re-announcement is gone.
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
      ]);
    });

    test('oscillation inside one episode (severe <-> '
        'critical, moderate reported during the hold) '
        'repeats no announcement', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      void at(ThermalStatus status, Duration offset) {
        sink.record(policy.evaluate(status: status, now: t0.add(offset)));
      }

      at(ThermalStatus.moderate, Duration.zero); // fpsDrop
      at(ThermalStatus.severe, const Duration(seconds: 1)); // scope
      at(ThermalStatus.critical, const Duration(seconds: 2)); // -
      at(ThermalStatus.severe, const Duration(seconds: 3)); // -
      at(ThermalStatus.critical, const Duration(seconds: 4)); // -
      // A MODERATE report during the episode only starts
      // the recovery hold; the applied tier stays severe
      // and nothing is announced.
      at(ThermalStatus.moderate, const Duration(seconds: 5)); // -
      at(ThermalStatus.severe, const Duration(seconds: 6)); // -
      expect(sink.spoken, <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
      ]);
    });

    test('a partial recovery speaks no recovery text, and '
        're-worsening to severe does not re-speak the '
        'scope text', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      // Direct jump to CRITICAL: the scope latch fires
      // (FPS latch consumed silently).
      sink.record(policy.evaluate(status: ThermalStatus.critical, now: t0));
      // Cool: the first hold lands the moderate tier --
      // a PARTIAL recovery, no recovery text.
      final DateTime cooled = t0.add(const Duration(seconds: 1));
      sink.record(policy.evaluate(status: ThermalStatus.none, now: cooled));
      final DateTime step1 = cooled.add(NavHazConfig.thermalRecoveryHold);
      final ThermalCap partial =
          policy.evaluate(status: ThermalStatus.none, now: step1);
      sink.record(partial);
      expect(partial.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(partial.announcement, ThermalAnnouncement.none);
      // Re-worsen to SEVERE inside the same episode: the
      // scope latch is already consumed, nothing repeats.
      final ThermalCap again = policy.evaluate(
          status: ThermalStatus.severe,
          now: step1.add(const Duration(seconds: 10)));
      sink.record(again);
      expect(again.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(again.announcement, ThermalAnnouncement.none);
      // A full recovery now speaks the recovery text
      // exactly once.
      final DateTime cooled2 = step1.add(const Duration(seconds: 11));
      sink.record(policy.evaluate(status: ThermalStatus.none, now: cooled2));
      final DateTime back1 = cooled2.add(NavHazConfig.thermalRecoveryHold);
      sink.record(policy.evaluate(status: ThermalStatus.none, now: back1));
      final ThermalCap done = policy.evaluate(
          status: ThermalStatus.none,
          now: back1.add(NavHazConfig.thermalRecoveryHold));
      sink.record(done);
      expect(done.announcement, ThermalAnnouncement.recovered);
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
      ]);
    });

    test('after a full recovery a NEW episode may speak '
        'both latches and the recovery text again', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      DateTime at = t0;
      void feed(ThermalStatus status) {
        sink.record(policy.evaluate(status: status, now: at));
      }

      // Episode 1: moderate (FPS text), then a full
      // recovery (one hold from the moderate tier).
      feed(ThermalStatus.moderate);
      at = at.add(const Duration(seconds: 1));
      feed(ThermalStatus.none);
      at = at.add(NavHazConfig.thermalRecoveryHold);
      feed(ThermalStatus.none); // unconstrained + recovered
      // Episode 2: both latches are fresh again.
      at = at.add(const Duration(seconds: 1));
      feed(ThermalStatus.moderate); // FPS text again
      at = at.add(const Duration(seconds: 1));
      feed(ThermalStatus.severe); // scope text again
      at = at.add(const Duration(seconds: 1));
      feed(ThermalStatus.none);
      at = at.add(NavHazConfig.thermalRecoveryHold);
      feed(ThermalStatus.none); // steps to moderate, silent
      at = at.add(NavHazConfig.thermalRecoveryHold);
      feed(ThermalStatus.none); // unconstrained + recovered
      expect(sink.spoken, <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
        NavHazConfig.thermalCriticalAnnouncementText,
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
      ]);
    });

    test('unknown readings between severe readings never '
        'speak the recovery text and never end the '
        'episode; the ladder walked under NONE does', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      sink.record(policy.evaluate(status: ThermalStatus.severe, now: t0));
      // Unknown inserted: the cap still reads severe
      // (the recovery hold only just started), and no
      // recovery text is spoken.
      final DateTime dark = t0.add(const Duration(seconds: 1));
      ThermalCap cap =
          policy.evaluate(status: ThermalStatus.unknown, now: dark);
      sink.record(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapSevereFps);
      expect(cap.announcement, ThermalAnnouncement.none);
      // A full hold under unknown steps the LADDER to
      // the moderate tier (the cap treats unknown as
      // unconstrained-tier evidence) -- but the episode
      // is still open and still silent.
      cap = policy.evaluate(
          status: ThermalStatus.unknown,
          now: dark.add(NavHazConfig.thermalRecoveryHold));
      sink.record(cap);
      expect(cap.maxFps, NavHazConfig.thermalCapModerateFps);
      expect(cap.announcement, ThermalAnnouncement.none);
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
      ]);
      // A real NONE now walks the remaining rung: one
      // hold later the cap is unconstrained and the
      // recovery text fires exactly there.
      final DateTime back = dark
          .add(NavHazConfig.thermalRecoveryHold)
          .add(const Duration(seconds: 1));
      sink.record(policy.evaluate(status: ThermalStatus.none, now: back));
      final ThermalCap done = policy.evaluate(
          status: ThermalStatus.none,
          now: back.add(NavHazConfig.thermalRecoveryHold));
      sink.record(done);
      expect(done.maxFps, isNull);
      expect(done.announcement, ThermalAnnouncement.recovered);
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
      ]);
    });

    test('unknown readings long enough to relax the cap '
        'completely still speak no recovery text; the '
        'first real NONE after that does', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      sink.record(policy.evaluate(status: ThermalStatus.severe, now: t0));
      // Two full holds under unknown: the cap settles
      // back to unconstrained on sensor silence alone.
      final DateTime dark = t0.add(const Duration(seconds: 1));
      sink.record(policy.evaluate(status: ThermalStatus.unknown, now: dark));
      sink.record(policy.evaluate(
          status: ThermalStatus.unknown,
          now: dark.add(NavHazConfig.thermalRecoveryHold)));
      final ThermalCap relaxed = policy.evaluate(
          status: ThermalStatus.unknown,
          now: dark.add(NavHazConfig.thermalRecoveryHold * 2));
      sink.record(relaxed);
      expect(relaxed.maxFps, isNull);
      expect(relaxed.announcement, ThermalAnnouncement.none);
      // No recovery text, and the latches were NOT
      // reset: the episode is still open.
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
      ]);
      // The first genuine NONE reading confirms the
      // cool-down and speaks the recovery text once.
      final ThermalCap confirmed = policy.evaluate(
          status: ThermalStatus.none,
          now: dark
              .add(NavHazConfig.thermalRecoveryHold * 2)
              .add(const Duration(seconds: 1)));
      sink.record(confirmed);
      expect(confirmed.announcement, ThermalAnnouncement.recovered);
      expect(sink.spoken, <String>[
        NavHazConfig.thermalScopeRestrictedAnnouncementText,
        NavHazConfig.thermalRecoveryAnnouncementText,
      ]);
    });

    test('booting straight into MODERATE speaks the FPS '
        'text once (the first evaluation may open an '
        'episode)', () {
      final ThermalPolicy policy = ThermalPolicy();
      final FakeSpeechSink sink = FakeSpeechSink();
      sink.record(policy.evaluate(status: ThermalStatus.moderate, now: t0));
      sink.record(policy.evaluate(
          status: ThermalStatus.moderate,
          now: t0.add(const Duration(seconds: 5))));
      expect(sink.spoken, <String>[
        NavHazConfig.thermalCriticalAnnouncementText,
      ]);
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
      // REWRITTEN (episode-latch ruling): the old model
      // flagged the CRITICAL cap with its announcement;
      // under the latch model the SEVERE cap carries the
      // scope event (both latches trip there), and the
      // CRITICAL cap raises nothing new.
      expect(caps[1].announcement, ThermalAnnouncement.scopeRestricted);
      expect(caps[2].announcement, ThermalAnnouncement.none);
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
      // REMOVED (episode-latch ruling): the old surface
      // also pinned thermalCriticalAnnouncementInterval
      // at five minutes. That constant no longer exists
      // -- the re-announcement it throttled was abolished
      // with the throttle model itself, so there is
      // nothing left to pin here; the announcement texts
      // are pinned verbatim in the 3.4.2 (1) group above.
    });
  });
}
