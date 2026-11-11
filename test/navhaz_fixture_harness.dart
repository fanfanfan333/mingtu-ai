/// Shared fixture runner for the NAVHAZ M1 acceptance
/// tests: parses a JSONL fixture from test/fixtures/navhaz/
/// and feeds it through a [HazardPipeline] built on the
/// requested backend, collecting every frame's estimates
/// and every emitted alert with its fixture timestamp.
library;

import 'dart:convert';
import 'dart:io';

import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/hazard/ttc_estimator.dart';
import 'package:mingtu_ai/core/tracking/byte_track_backend.dart';
import 'package:mingtu_ai/core/tracking/sort_backend.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

class FixtureFrame {
  final int tMs;
  final List<Detection> dets;
  final double? pitchDeg;
  final EgoMotion ego;
  const FixtureFrame(this.tMs, this.dets, this.pitchDeg, this.ego);
}

class AlertRecord {
  final int tMs;
  final HazardAlert alert;
  const AlertRecord(this.tMs, this.alert);

  HazardLevel get level => alert.level;
  String get phrase => alert.phrase;
  int get trackId => alert.trackId;
}

class FixtureRun {
  final List<AlertRecord> alerts;
  final Map<int, List<TrackEstimate>> estimatesByTime;
  final List<int> frameTimes;
  const FixtureRun(this.alerts, this.estimatesByTime, this.frameTimes);

  List<AlertRecord> get urgents =>
      alerts.where((AlertRecord a) => a.level == HazardLevel.urgent).toList();
  List<AlertRecord> get warnings =>
      alerts.where((AlertRecord a) => a.level == HazardLevel.warning).toList();

  /// Every track id that ever carried an estimate.
  Set<int> get trackIds => <int>{
        for (final List<TrackEstimate> es in estimatesByTime.values)
          for (final TrackEstimate e in es) e.track.id,
      };
}

List<FixtureFrame> loadFixture(String name) {
  final List<String> lines =
      File('test/fixtures/navhaz/$name')
          .readAsLinesSync()
          .where((String l) => l.trim().isNotEmpty)
          .toList();
  return <FixtureFrame>[
    for (final String line in lines) _parseFrame(line),
  ];
}

FixtureFrame _parseFrame(String line) {
  final Map<String, dynamic> row = jsonDecode(line) as Map<String, dynamic>;
  final List<Detection> dets = <Detection>[
    for (final dynamic d in (row['dets'] as List<dynamic>? ?? <dynamic>[]))
      Detection(
        label: (d as Map<String, dynamic>)['label'] as String,
        confidence: (d['conf'] as num).toDouble(),
        cx: (d['cx'] as num).toDouble(),
        cy: (d['cy'] as num).toDouble(),
        w: (d['w'] as num).toDouble(),
        h: (d['h'] as num).toDouble(),
      ),
  ];
  final EgoMotion ego = (row['ego'] as String? ?? 'still') == 'walking'
      ? EgoMotion.judge(
          gpsSpeedMps: (row['gps_speed'] as num?)?.toDouble() ?? 1.2)
      : EgoMotion.still;
  return FixtureFrame(
    (row['t_ms'] as num).toInt(),
    dets,
    (row['pitch_deg'] as num?)?.toDouble(),
    ego,
  );
}

Tracker trackerForBackend(String backend) =>
    backend == 'sort' ? SortBackend() : ByteTrackBackend();

FixtureRun runFixture(String name, String backend) {
  final HazardPipeline pipeline =
      HazardPipeline(tracker: trackerForBackend(backend));
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final List<AlertRecord> alerts = <AlertRecord>[];
  final Map<int, List<TrackEstimate>> byTime = <int, List<TrackEstimate>>{};
  final List<int> times = <int>[];
  for (final FixtureFrame f in loadFixture(name)) {
    times.add(f.tMs);
    final HazardPipelineResult r = pipeline.processFrame(
      f.dets,
      epoch.add(Duration(milliseconds: f.tMs)),
      pitchDeg: f.pitchDeg,
      ego: f.ego,
    );
    byTime[f.tMs] = r.estimates;
    if (r.alert != null) alerts.add(AlertRecord(f.tMs, r.alert!));
  }
  return FixtureRun(alerts, byTime, times);
}

const List<String> kBackends = <String>['bytetrack', 'sort'];
