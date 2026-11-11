/// NAVHAZ M3 pothole second detector (spec section 4.4,
/// this step's part): grading fixtures, the switch, the
/// walking gate, the scan cadence, the enumeration /
/// banned-word surface and the thermal intersection.
///
/// COMMIT23 rework (this commit): the thermal group no
/// longer pins "runs, then filtered at intake" as the
/// primary behaviour -- 大川 ruled the detector STOPS
/// RUNNING at applied SEVERE / CRITICAL (the intake
/// restriction remains only as a backstop, still pinned).
/// New groups pin the Sewage-Manhole EXPLICIT discard and
/// the zero-burden build / missing-model startup states.
///
/// Everything here runs on fakes and synthetic geometry:
/// the detector is a counting fake, the frame source is a
/// fake, and the pipeline fixtures feed constant boxes
/// whose ground range is fixed by the ground-plane
/// geometry (pitch + box bottom, the same construction
/// the other NAVHAZ fixtures use). Nothing here measures
/// real inference, real frames or real-device behaviour.
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/pothole_detector.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/core/avoidance_advisor.dart';
import 'package:mingtu_ai/core/camera_frame.dart';
import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/pothole_scan.dart';
import 'package:mingtu_ai/core/thermal_policy.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

class _FakePotholeDetector implements PotholeDetector {
  final List<Detection> canned;
  int calls = 0;
  _FakePotholeDetector(this.canned);

  @override
  bool get isAvailable => true;

  @override
  String get status => 'fake';

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) async {
    calls += 1;
    return canned;
  }
}

class _FakeFrameSource implements CameraFrameSource {
  final bool ok;
  int calls = 0;
  _FakeFrameSource({this.ok = true});

  @override
  Future<CameraFrameCapture> captureSingleFrame() async {
    calls += 1;
    if (!ok) {
      return CameraFrameCapture.failed(CameraFrameFailure.failure);
    }
    return CameraFrameCapture.ok(Uint8List.fromList(<int>[1, 2, 3]));
  }
}

const Detection _pitDetection = Detection(
  label: potholeLabel,
  confidence: 0.9,
  cx: 0.5,
  cy: 0.75,
  w: 0.3,
  h: 0.24,
);

/// Sink capture for the discard test (reset by that test
/// itself; file-scope because the sink is a closure).
List<Detection>? _lastDelivered;

/// Run ONE scan through a scanner fed by [detector] and
/// return what the sink received (the list the wiring
/// layer would store and merge into live frames).
Future<List<Detection>> _scanOnce(_FakePotholeDetector detector) async {
  List<Detection>? delivered;
  final PotholeScanner scanner = PotholeScanner(
    enabled: true,
    detector: detector,
    frameSource: _FakeFrameSource(),
    onDetections: (List<Detection> d, DateTime at) => delivered = d,
  );
  await scanner.maybeScan(
    walking: true,
    now: DateTime.fromMillisecondsSinceEpoch(0),
  );
  return delivered!;
}

/// Run one constant pit geometry through the real
/// pipeline for 15 frames at 100 ms and collect the
/// spoken alerts (the policy's cooldown yields exactly
/// one for these static geometries).
List<HazardAlert> _runPitGeometry(
  String backend, {
  required double bottom,
  required double h,
  required double pitchDeg,
}) =>
    _runLabelGeometry(
      backend,
      label: potholeLabel,
      bottom: bottom,
      h: h,
      pitchDeg: pitchDeg,
    );

/// The same constant-geometry run for an arbitrary label
/// (the Sewage-Manhole discard fixtures reuse the pit
/// geometry with the manhole label: if the class leaked
/// into grading, these are the boxes that would speak).
List<HazardAlert> _runLabelGeometry(
  String backend, {
  required String label,
  required double bottom,
  required double h,
  required double pitchDeg,
}) {
  final HazardPipeline pipeline =
      HazardPipeline(tracker: trackerForBackend(backend));
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final List<HazardAlert> alerts = <HazardAlert>[];
  for (int i = 0; i < 15; i++) {
    final HazardPipelineResult r = pipeline.processFrame(
      <Detection>[
        Detection(
          label: label,
          confidence: 0.9,
          cx: 0.5,
          cy: bottom - h / 2,
          w: 0.3,
          h: h,
        ),
      ],
      epoch.add(Duration(milliseconds: 100 * i)),
      pitchDeg: pitchDeg,
      ego: EgoMotion.still,
    );
    if (r.alert != null) alerts.add(r.alert!);
  }
  return alerts;
}

void main() {
  group('pit grading fixtures (section 4.4a)', () {
    for (final String backend in <String>['byteTrack', 'sort']) {
      test('near pit at Z ~= 2.0 m warns with the full sentence ($backend)',
          () {
        // bottom 0.8676 at pitch 10 -> ground range 2.00 m:
        // past the urgent range, inside the static warning
        // range, and box-bottom near.
        final List<HazardAlert> alerts = _runPitGeometry(
          backend,
          bottom: 0.8676,
          h: 0.24,
          pitchDeg: 10,
        );
        expect(alerts, hasLength(1));
        expect(alerts.single.level, HazardLevel.warning);
        expect(alerts.single.kind, HazardKind.pit);
        expect(alerts.single.phrase, '注意，前方两米有坑洞',
            reason: 'NH-M3-01: a whole-metre 2 reads 两米');
        expect(alerts.single.rangeM, closeTo(2.0, 0.05));
      });

      test('pit at Z ~= 1.2 m is urgent with the full sentence ($backend)',
          () {
        // bottom 0.9465 at pitch 20 -> ground range 1.20 m
        // <= pitUrgentRangeM (1.5). The phrase is the FULL
        // static-item form: the NH-M1-19 short-form gate
        // never applies to a pit (no TTC), which this
        // literal also proves -- a short form for pit does
        // not exist and would have thrown.
        final List<HazardAlert> alerts = _runPitGeometry(
          backend,
          bottom: 0.9465,
          h: 0.25,
          pitchDeg: 20,
        );
        expect(alerts, hasLength(1));
        expect(alerts.single.level, HazardLevel.urgent);
        expect(alerts.single.kind, HazardKind.pit);
        expect(alerts.single.phrase, '停，前方很近有坑洞');
        expect(alerts.single.rangeM, closeTo(1.2, 0.05));
      });

      test('pit at Z ~= 1.6 m does NOT go urgent; near gives a warning '
          '($backend)', () {
        // bottom 0.87 at pitch 16 -> ground range 1.60 m:
        // just past the urgent threshold, box-bottom near.
        final List<HazardAlert> alerts = _runPitGeometry(
          backend,
          bottom: 0.87,
          h: 0.24,
          pitchDeg: 16,
        );
        expect(alerts, hasLength(1));
        expect(alerts.single.level, HazardLevel.warning);
        expect(alerts.single.phrase, '注意，前方两米有坑洞',
            reason: 'NH-M3-01: the rounded whole-metre '
                'readout here is 2 m, read 两米');
        expect(alerts.single.rangeM, closeTo(1.6, 0.05));
      });
    }

    test('grading constants are the ruled values', () {
      expect(NavHazConfig.pitUrgentRangeM, 1.5);
      expect(NavHazConfig.potholeScanMinInterval,
          const Duration(milliseconds: 200));
    });

    test('the label maps to the pit kind and the spoken name 坑洞', () {
      expect(hazardKindForLabel(potholeLabel), HazardKind.pit);
      expect(hazardSpokenName(potholeLabel, HazardKind.pit), '坑洞');
      expect(hazardKindName(HazardKind.pit), '坑洞');
      // The model's second class has NO hazard kind: it
      // is discarded at the scanner by name (COMMIT23 --
      // see the discard group below), not graded.
      expect(sewageManholeLabel, 'sewage-manhole');
      expect(hazardKindForLabel(sewageManholeLabel), isNull);
    });
  });

  group('switch (section 4.4b)', () {
    test('the build-time switch defaults OFF', () {
      // No --dart-define=MINGTU_POTHOLE in the test build:
      // the single access point must read off.
      expect(AppConfig.potholeEnabled, isFalse);
      // COMMIT23: the weight moved into its own directory
      // (the pubspec directory-declaration form), so the
      // default asset path moved with it.
      expect(AppConfig.potholeModelPath,
          'assets/models/pothole/pothole2v.tflite');
    });

    test('off: the scanner never captures and never detects', () async {
      final _FakePotholeDetector detector =
          _FakePotholeDetector(<Detection>[_pitDetection]);
      final _FakeFrameSource frames = _FakeFrameSource();
      int sinkCalls = 0;
      final PotholeScanner scanner = PotholeScanner(
        enabled: false,
        detector: detector,
        frameSource: frames,
        onDetections: (_, __) => sinkCalls += 1,
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      for (int i = 0; i < 5; i++) {
        await scanner.maybeScan(
          walking: true,
          now: t0.add(Duration(milliseconds: 300 * i)),
        );
      }
      expect(scanner.scanCount, 0);
      expect(frames.calls, 0);
      expect(detector.calls, 0);
      expect(sinkCalls, 0);
    });

    test('off: the same pit geometry without scanner input stays silent',
        () {
      // Baseline equivalence at the pipeline surface: pit
      // detections only ever arrive via the scanner merge,
      // so with no scanner contribution a frame stream
      // without pit detections produces no pit alert --
      // the pre-M3 behaviour. (The pit fixtures above pin
      // what changes when input DOES arrive.)
      final HazardPipeline pipeline =
          HazardPipeline(tracker: trackerForBackend('byteTrack'));
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      for (int i = 0; i < 15; i++) {
        final HazardPipelineResult r = pipeline.processFrame(
          const <Detection>[],
          epoch.add(Duration(milliseconds: 100 * i)),
          pitchDeg: 20,
          ego: EgoMotion.still,
        );
        expect(r.alert, isNull);
      }
    });

    test('production wiring is gated on the single access point', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('if (AppConfig.potholeEnabled)'), isTrue,
          reason: 'the scanner is constructed only under the switch');
      expect(
          main.contains(
              'createPotholeDetector(AppConfig.potholeModelPath)'),
          isTrue);
    });
  });

  group('walking gate and scan behaviour (section 4.4c)', () {
    test('not walking: zero scans; walking: the scan runs and delivers '
        'only pothole detections', () async {
      final _FakePotholeDetector detector =
          _FakePotholeDetector(<Detection>[
        _pitDetection,
        const Detection(
          label: sewageManholeLabel,
          confidence: 0.8,
          cx: 0.4,
          cy: 0.7,
          w: 0.2,
          h: 0.2,
        ),
      ]);
      final _FakeFrameSource frames = _FakeFrameSource();
      final List<List<Detection>> delivered = <List<Detection>>[];
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: frames,
        onDetections: (List<Detection> d, DateTime at) => delivered.add(d),
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      await scanner.maybeScan(walking: false, now: t0);
      await scanner.maybeScan(
          walking: false, now: t0.add(const Duration(seconds: 1)));
      expect(scanner.scanCount, 0);
      expect(frames.calls, 0);
      expect(detector.calls, 0);

      await scanner.maybeScan(
          walking: true, now: t0.add(const Duration(seconds: 2)));
      expect(scanner.scanCount, 1);
      expect(detector.calls, 1);
      expect(delivered, hasLength(1));
      // The unmapped second class never reaches the sink.
      expect(delivered.single, hasLength(1));
      expect(delivered.single.single.label, potholeLabel);
    });

    test('a failed capture is silent: no sink call, no throw', () async {
      final _FakePotholeDetector detector =
          _FakePotholeDetector(<Detection>[_pitDetection]);
      final _FakeFrameSource frames = _FakeFrameSource(ok: false);
      int sinkCalls = 0;
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: frames,
        onDetections: (_, __) => sinkCalls += 1,
      );
      await scanner.maybeScan(
        walking: true,
        now: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(scanner.scanCount, 1);
      expect(detector.calls, 0);
      expect(sinkCalls, 0);
    });
  });

  group('cadence (section 4.4d)', () {
    test('at most 5 scans in the first second of walking frames', () async {
      final _FakePotholeDetector detector =
          _FakePotholeDetector(const <Detection>[]);
      final _FakeFrameSource frames = _FakeFrameSource();
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: frames,
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      // Ten offers inside the first second (100 ms apart,
      // the nominal pipeline frame rate): scans may start
      // at 0/200/400/600/800 ms only.
      for (int i = 0; i < 10; i++) {
        await scanner.maybeScan(
          walking: true,
          now: t0.add(Duration(milliseconds: 100 * i)),
        );
      }
      expect(scanner.scanCount, 5);
      expect(detector.calls, 5);
      expect(frames.calls, 5);
    });

    test('an in-flight scan blocks the next one past the interval',
        () async {
      int detectorCalls = 0;
      final PotholeDetector hanging = _HangingDetector(() => detectorCalls += 1);
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: hanging,
        frameSource: _FakeFrameSource(),
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      final Future<void> first = scanner.maybeScan(walking: true, now: t0);
      await scanner.maybeScan(
        walking: true,
        now: t0.add(const Duration(seconds: 1)),
      );
      expect(scanner.scanCount, 1);
      expect(detectorCalls, 1);
      unawaited(first);
    });
  });

  group('enumeration and banned words (section 4.4e)', () {
    test('the 坑洞 axis joins the phrase space: 1030 + 102 = 1132, all '
        'banned-clean', () {
      final Set<String> all = enumerateAllHazardPhrases().toSet();
      final Set<String> pit =
          all.where((String s) => s.contains('坑洞')).toSet();
      // The increment is exactly the one new (name,
      // isVehicle=false) axis: its near zone forms, its
      // no-range clock forms and its far clock forms --
      // 102 distinct strings, every one carrying the new
      // item name (measured by set difference against the
      // pre-M3 space: nothing else moved).
      expect(pit.length, 102);
      expect(all.length, 1132);
      for (final String phrase in all) {
        expect(containsBannedWord(phrase), isFalse, reason: phrase);
      }
      expect(pit.contains('注意，前方两米有坑洞'), isTrue,
          reason: 'NH-M3-01: the 2 m near form reads 两米');
      expect(pit.contains('停，前方很近有坑洞'), isTrue);
    });
  });

  group('thermal intersection (section 4.4f, COMMIT23 rework)', () {
    // COMMIT23 supersession, recorded per protocol: in
    // step 2 this group pinned "the detector runs and its
    // input is filtered at the intake" as THE thermal
    // behaviour. 大川 ruled the second model must instead
    // STOP RUNNING at applied SEVERE / CRITICAL (it is
    // itself a heat source, and stopping matches the
    // announced scope). The intake assertions below are
    // KEPT, but demoted to what they now are -- the
    // backstop for a result already in flight when the
    // heat spiked. The gate itself is pinned by the new
    // tests after them.
    test('backstop: SEVERE class restriction still filters pit input at '
        'the shared intake', () {
      // The restriction's pass set is judged by the same
      // label->kind mapping: vehicles and persons pass,
      // pit (like pole and clutter) does not.
      expect(ThermalPolicy.keepsLabelUnderRestriction(potholeLabel),
          isFalse);
      expect(ThermalPolicy.keepsLabelUnderRestriction('car'), isTrue);
      expect(ThermalPolicy.keepsLabelUnderRestriction('person'), isTrue);
    });

    test('the merge sits BEFORE the restriction in the shared intake', () {
      final String main = File('lib/main.dart').readAsStringSync();
      final int intake = main.indexOf('void _onYoloDetections(');
      final int merge = main.indexOf('_freshPotholeDetections(now)', intake);
      final int restriction =
          main.indexOf('_thermalCap.restrictClasses', intake);
      expect(intake, isNonNegative);
      expect(merge, greaterThan(intake));
      expect(restriction, greaterThan(merge),
          reason: 'pit detections merge first, so the '
              'thermal restriction gates them like any '
              'other intake input');
    });

    test('gate wiring: the applied cap feeds the scanner gate', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(
          main.contains(
              '_potholeScanner?.setThermalRestricted(cap.restrictClasses'),
          isTrue,
          reason: 'the gate follows the SAME applied cap '
              'that drives the restriction and the scope '
              'announcement');
    });

    test('gate closed at boot: no capture, no inference, no load', () async {
      // "No load" is observable here because loading is
      // lazy inside the first detectImage call: zero
      // detector calls means the model was never loaded.
      final _FakePotholeDetector detector =
          _FakePotholeDetector(<Detection>[_pitDetection]);
      final _FakeFrameSource frames = _FakeFrameSource();
      final List<List<Detection>> delivered = <List<Detection>>[];
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: frames,
        onDetections: (List<Detection> d, DateTime at) => delivered.add(d),
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      scanner.setThermalRestricted(true, now: t0);
      expect(scanner.thermalRestricted, isTrue);
      for (int i = 0; i < 5; i++) {
        await scanner.maybeScan(
          walking: true,
          now: t0.add(Duration(milliseconds: 300 * i)),
        );
      }
      expect(scanner.scanCount, 0);
      expect(frames.calls, 0);
      expect(detector.calls, 0);
      // The only sink call is the gate-close clearing
      // (an empty list): nothing was ever detected.
      expect(delivered, hasLength(1));
      expect(delivered.single, isEmpty);
    });

    test('gate closing clears the stored result and drops an in-flight '
        'scan', () async {
      final Completer<List<Detection>> completer =
          Completer<List<Detection>>();
      final _SwitchableDetector detector =
          _SwitchableDetector(() async => <Detection>[_pitDetection]);
      final _FakeFrameSource frames = _FakeFrameSource();
      final List<List<Detection>> delivered = <List<Detection>>[];
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: frames,
        onDetections: (List<Detection> d, DateTime at) => delivered.add(d),
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      // One healthy scan: the pit is stored (delivered).
      await scanner.maybeScan(walking: true, now: t0);
      expect(delivered, hasLength(1));
      expect(delivered.single.single.label, potholeLabel);
      // A second scan starts and hangs inside inference.
      detector.handler = () => completer.future;
      final Future<void> inFlight = scanner.maybeScan(
        walking: true,
        now: t0.add(const Duration(seconds: 1)),
      );
      await pumpEventQueue();
      expect(scanner.inFlight, isTrue);
      // The heat spike lands mid-scan: stored result is
      // cleared at once (empty delivery)...
      scanner.setThermalRestricted(
          true, now: t0.add(const Duration(seconds: 1, milliseconds: 100)));
      expect(delivered, hasLength(2));
      expect(delivered.last, isEmpty);
      // ...and when the stale scan finally returns its
      // pit, the result is DROPPED, never delivered.
      completer.complete(<Detection>[_pitDetection]);
      await inFlight;
      expect(delivered, hasLength(2));
      expect(scanner.scanCount, 2);
    });

    test('gate reopening resumes scanning on its own', () async {
      final _FakePotholeDetector detector =
          _FakePotholeDetector(<Detection>[_pitDetection]);
      final _FakeFrameSource frames = _FakeFrameSource();
      final List<List<Detection>> delivered = <List<Detection>>[];
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: frames,
        onDetections: (List<Detection> d, DateTime at) => delivered.add(d),
      );
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      // Settled severe: nothing runs.
      scanner.setThermalRestricted(true, now: t0);
      await scanner.maybeScan(walking: true, now: t0);
      expect(scanner.scanCount, 0);
      // The ladder settles back to a non-restricting rung
      // (NONE / LIGHT / MODERATE): the very next offer
      // scans again, with no restart and no speech from
      // this layer (the thermal recovery announcement is
      // the policy's, not the scanner's).
      scanner.setThermalRestricted(false,
          now: t0.add(const Duration(seconds: 30)));
      await scanner.maybeScan(
          walking: true, now: t0.add(const Duration(seconds: 30)));
      expect(scanner.scanCount, 1);
      expect(delivered.last.single.label, potholeLabel);
      // Re-closing is a transition again (idempotence:
      // feeding the same state twice clears only once).
      final int sinkCalls = delivered.length;
      scanner.setThermalRestricted(true,
          now: t0.add(const Duration(seconds: 31)));
      scanner.setThermalRestricted(true,
          now: t0.add(const Duration(seconds: 32)));
      expect(delivered.length, sinkCalls + 1);
    });
  });

  group('sewage-manhole explicit discard (COMMIT23)', () {
    const Detection sewageUrgent = Detection(
      label: sewageManholeLabel,
      confidence: 0.9,
      cx: 0.5,
      cy: 0.8215,
      w: 0.3,
      h: 0.25,
    );

    test('scanner: a manhole-only scan delivers an empty result', () async {
      _lastDelivered = null;
      final _FakePotholeDetector detector =
          _FakePotholeDetector(<Detection>[sewageUrgent]);
      final PotholeScanner scanner = PotholeScanner(
        enabled: true,
        detector: detector,
        frameSource: _FakeFrameSource(),
        onDetections: (List<Detection> d, DateTime at) =>
            _lastDelivered = d,
      );
      await scanner.maybeScan(
        walking: true,
        now: DateTime.fromMillisecondsSinceEpoch(0),
      );
      expect(detector.calls, 1,
          reason: 'the model DID see the manhole; the '
              'discard is a code path, not blindness');
      expect(_lastDelivered, isNotNull);
      expect(_lastDelivered, isEmpty);
    });

    // The two end-to-end fixtures below compose the
    // PRODUCTION path (fake detector -> scanner -> what
    // the wiring would merge -> pipeline). They do NOT
    // feed a raw manhole-labelled detection straight into
    // the pipeline, on purpose: the pipeline grades ANY
    // unmapped label as clutter -- a pre-existing,
    // deliberate fallback for the MAIN detector's unknown
    // labels (an unknown object in the corridor is still
    // an obstacle). The manhole class can never take that
    // path in production because the scanner is its only
    // door into the app and the discard happens there;
    // that is exactly why the ruling puts the discard at
    // the scanner, and why these tests compose through it.
    test('end-to-end: manhole frames reach the pipeline as nothing, on '
        'both backends', () async {
      // The sewage box IS the pit fixture's urgent
      // geometry (bottom 0.9465 at pitch 20 -> Z ~= 1.2 m
      // <= pitUrgentRangeM): if the class leaked past the
      // scanner, this is the box that would speak URGENT.
      final List<Detection> delivered = await _scanOnce(
          _FakePotholeDetector(<Detection>[sewageUrgent]));
      expect(delivered, isEmpty);
      for (final String backend in <String>['byteTrack', 'sort']) {
        final HazardPipeline pipeline =
            HazardPipeline(tracker: trackerForBackend(backend));
        final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
        for (int i = 0; i < 15; i++) {
          final HazardPipelineResult r = pipeline.processFrame(
            delivered,
            epoch.add(Duration(milliseconds: 100 * i)),
            pitchDeg: 20,
            ego: EgoMotion.still,
          );
          expect(r.alert, isNull, reason: backend);
        }
      }
    });

    test('end-to-end: manhole and pit in the same scan -- only the pit '
        'speaks', () async {
      const Detection pitUrgent = Detection(
        label: potholeLabel,
        confidence: 0.9,
        cx: 0.5,
        cy: 0.8215,
        w: 0.3,
        h: 0.25,
      );
      final List<Detection> delivered = await _scanOnce(
          _FakePotholeDetector(<Detection>[pitUrgent, sewageUrgent]));
      expect(delivered, hasLength(1));
      expect(delivered.single.label, potholeLabel);
      final HazardPipeline pipeline =
          HazardPipeline(tracker: trackerForBackend('byteTrack'));
      final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
      final List<HazardAlert> alerts = <HazardAlert>[];
      for (int i = 0; i < 15; i++) {
        final HazardPipelineResult r = pipeline.processFrame(
          delivered,
          epoch.add(Duration(milliseconds: 100 * i)),
          pitchDeg: 20,
          ego: EgoMotion.still,
        );
        if (r.alert != null) alerts.add(r.alert!);
      }
      expect(alerts, hasLength(1));
      expect(alerts.single.kind, HazardKind.pit);
      expect(alerts.single.phrase, '停，前方很近有坑洞');
    });
  });

  group('zero-burden startup (COMMIT23)', () {
    test('the three startup states', () {
      // Switch off: disabled, whatever the bundle holds
      // (the check never runs in this state at all).
      expect(
          potholeStartupState(enabled: false, modelBundled: false),
          PotholeStartupState.disabled);
      expect(
          potholeStartupState(enabled: false, modelBundled: true),
          PotholeStartupState.disabled);
      // Switch on: presence decides.
      expect(potholeStartupState(enabled: true, modelBundled: false),
          PotholeStartupState.unavailable);
      expect(potholeStartupState(enabled: true, modelBundled: true),
          PotholeStartupState.ready);
    });

    test('the unavailable notice latch fires exactly once per process',
        () {
      final PotholeUnavailableNoticeLatch latch =
          PotholeUnavailableNoticeLatch();
      expect(latch.claimed, isFalse);
      expect(latch.claimOnce(), isTrue);
      expect(latch.claimed, isTrue);
      expect(latch.claimOnce(), isFalse);
      expect(latch.claimOnce(), isFalse);
    });

    test('the unavailable sentence is the ruled literal and banned-clean',
        () {
      expect(NavHazConfig.potholeUnavailableAnnouncementText, '坑洞识别不可用');
      expect(
          containsBannedWord(
              NavHazConfig.potholeUnavailableAnnouncementText),
          isFalse);
    });

    test('zero-burden build shape: directory declared, single pothole '
        'file NOT declared, .gitkeep in place', () {
      final String pubspec = File('pubspec.yaml').readAsStringSync();
      expect(pubspec, contains('- assets/models/pothole/'));
      expect(pubspec, isNot(contains('- assets/models/pothole2v.tflite')),
          reason: 'a single-file declaration would make '
              'the build fail whenever the weight is absent');
      // The main model keeps its single-file discipline.
      expect(pubspec, contains('- assets/models/yolo11n.tflite'));
      expect(File('assets/models/pothole/.gitkeep').existsSync(), isTrue,
          reason: 'the declared directory must exist in a '
              'clean checkout, weight or no weight');
    });

    test('missing-model wiring goes through the asset system', () {
      final String main = File('lib/main.dart').readAsStringSync();
      expect(main.contains('rootBundle.load(AppConfig.potholeModelPath)'),
          isTrue,
          reason: 'presence is an asset-system question, '
              'never a file-system probe');
      expect(main.contains('_announcePotholeModelMissing'), isTrue);
      expect(
          main.contains(
              'NavHazConfig.potholeUnavailableAnnouncementText'),
          isTrue);
    });
  });

  group('adapter class mapping', () {
    test('card names win; the card index order is the fallback', () {
      expect(
          potholeClassLabel(classIndex: 0, className: 'Pothole'),
          potholeLabel);
      expect(
          potholeClassLabel(classIndex: 1, className: 'Sewage-Manhole'),
          'sewage-manhole');
      // The TFLite carries no name metadata, so an empty
      // or synthetic runtime name must still map by index.
      expect(potholeClassLabel(classIndex: 0, className: ''), potholeLabel);
      expect(potholeClassLabel(classIndex: 1, className: 'class_1'),
          'sewage-manhole');
    });
  });
}

class _HangingDetector implements PotholeDetector {
  final void Function() onCall;
  _HangingDetector(this.onCall);

  @override
  bool get isAvailable => true;

  @override
  String get status => 'hanging fake';

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) {
    onCall();
    return Completer<List<Detection>>().future;
  }
}

/// A detector whose behaviour the test can swap between
/// scans (healthy first, hanging on the gate test's
/// second scan).
class _SwitchableDetector implements PotholeDetector {
  Future<List<Detection>> Function() handler;
  int calls = 0;
  _SwitchableDetector(this.handler);

  @override
  bool get isAvailable => true;

  @override
  String get status => 'switchable fake';

  @override
  Future<List<Detection>> detectImage(List<int> imageBytes) {
    calls += 1;
    return handler();
  }
}
