/// FIX4-FINAL S3: the two latency segments added around
/// the pipeline's existing stamp -- segment 1 (frame
/// timestamp -> detection-callback arrival) and segment 2
/// (pipeline return -> TTS speak start). Both segments are
/// computed by the single helper [latencySegmentMs], so
/// fake-timestamp assertions on the helper pin both
/// segments' values at once; the wiring itself is guarded
/// by the source assertions in navhaz_ego_test (main
/// wiring) and below (the adapter's frame stamp).
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/hazard/hazard_pipeline.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

void main() {
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  DateTime at(int ms) => epoch.add(Duration(milliseconds: ms));

  group('latencySegmentMs (both S3 segments share it)', () {
    test('segment values equal the injected differences', () {
      // Segment 1 shape: frame stamp -> callback arrival.
      expect(latencySegmentMs(at(1000), at(1012)), 12,
          reason: 'frame-to-callback = callback - frame');
      // Segment 2 shape: pipeline return -> speak start.
      expect(latencySegmentMs(at(2000), at(2180)), 180,
          reason: 'pipeline-to-speak = speak start - '
              'pipeline return');
      expect(latencySegmentMs(at(500), at(500)), 0,
          reason: 'a zero-length segment is a real stamp');
    });

    test('implausible pairs stamp nothing', () {
      expect(latencySegmentMs(at(2000), at(1000)), isNull,
          reason: 'out-of-order stamps (negative) never '
              'reach the log');
      expect(latencySegmentMs(at(0), at(10000)), isNull,
          reason: 'at / past 10 s can only be a synthetic '
              'or replay timestamp');
      expect(latencySegmentMs(at(0), at(9999)), 9999,
          reason: 'just inside the window still stamps');
    });
  });

  test('pipeline result carries the frame stamp it was '
      'fed (segment 1 start point)', () {
    final HazardPipeline pipeline = HazardPipeline();
    final HazardPipelineResult r = pipeline.processFrame(
      const <Detection>[
        Detection(label: 'car', confidence: 0.9, cx: 0.5, cy: 0.55, w: 0.2, h: 0.2),
      ],
      at(42000),
    );
    expect(r.frameCapturedAt, at(42000),
        reason: 'the result exposes the exact frame '
            'timestamp processFrame received');
  });

  test('the YOLO adapter stamps the frame at delivery '
      '(segment 1 origin)', () {
    final String src =
        File('lib/adapters/yolo_live_view_mobile.dart').readAsStringSync();
    expect(src.contains('frameCapturedAt'), isTrue,
        reason: 'the adapter stamps each frame as the '
            'plugin delivers it');
    final String view =
        File('lib/adapters/yolo_live_view.dart').readAsStringSync();
    expect(view.contains('DateTime frameCapturedAt'), isTrue,
        reason: 'the stamp travels with the detections '
            'callback');
  });
}
