/// NAVHAZ M1 offline replay tool.
///
/// Runs recorded detection fixtures (JSONL, one frame per
/// line) through the same tracking + TTC + policy pipeline
/// the app uses, and prints the alert timeline. Pure Dart:
/// it imports only lib/core, never main.dart, and performs
/// no network or device access.
///
/// Usage:
///   dart run tool/navhaz_replay.dart <file.jsonl> [--backend sort|bytetrack]
///
/// Frame format (10 FPS fixtures live in
/// test/fixtures/navhaz/):
///   {"t_ms": 0,
///    "dets": [{"label": "car", "conf": 0.9,
///              "cx": 0.5, "cy": 0.55, "w": 0.1, "h": 0.1}],
///    "pitch_deg": 10, "ego": "still", "gps_speed": 0}
///
/// An optional "expect" field in a fixture line is a human
/// note about the expected outcome (recall / false-alarm
/// bookkeeping is done by the acceptance tests, which carry
/// their own assertions; this tool only prints the note).
library;

import 'dart:convert';
import 'dart:io';

import 'package:mingtu_ai/core/hazard/ego_motion.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/core/hazard/hazard_policy.dart';
import 'package:mingtu_ai/core/tracking/byte_track_backend.dart';
import 'package:mingtu_ai/core/tracking/sort_backend.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
        'usage: dart run tool/navhaz_replay.dart <file.jsonl> '
        '[--backend sort|bytetrack]');
    exitCode = 64;
    return;
  }
  final String path = args[0];
  String backend = 'bytetrack';
  for (int i = 1; i < args.length; i++) {
    if (args[i] == '--backend' && i + 1 < args.length) {
      backend = args[i + 1];
    }
  }
  final Tracker tracker = switch (backend) {
    'sort' => SortBackend(),
    'bytetrack' => ByteTrackBackend(),
    _ => throw ArgumentError('unknown backend: $backend'),
  };
  final HazardPipeline pipeline = HazardPipeline(tracker: tracker);

  final List<String> lines = await File(path).readAsLines();
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  int frames = 0;
  int urgent = 0;
  int warning = 0;
  String? lastExpect;
  for (final String line in lines) {
    if (line.trim().isEmpty) continue;
    final Map<String, dynamic> row =
        jsonDecode(line) as Map<String, dynamic>;
    final int tMs = (row['t_ms'] as num).toInt();
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
    final double? pitch = (row['pitch_deg'] as num?)?.toDouble();
    final EgoMotion ego = (row['ego'] as String? ?? 'still') == 'walking'
        ? EgoMotion.judge(
            gpsSpeedMps: (row['gps_speed'] as num?)?.toDouble() ?? 1.2)
        : EgoMotion.still;
    if (row['expect'] is String) lastExpect = row['expect'] as String;
    frames++;
    final HazardPipelineResult result = pipeline.processFrame(
      dets,
      epoch.add(Duration(milliseconds: tMs)),
      pitchDeg: pitch,
      ego: ego,
    );
    final HazardAlert? alert = result.alert;
    if (alert != null) {
      if (alert.urgent) {
        urgent++;
      } else {
        warning++;
      }
      stdout.writeln('t=${tMs}ms level=${alert.level.name} '
          'track=${alert.trackId} '
          'vibration=${alert.urgent ? 'urgent' : 'warning'} '
          'phrase=${alert.phrase}');
    }
  }
  stdout.writeln('---');
  stdout.writeln('backend=$backend frames=$frames '
      'alerts=${urgent + warning} urgent=$urgent warning=$warning');
  if (lastExpect != null) {
    stdout.writeln('expect: $lastExpect');
  }
}
