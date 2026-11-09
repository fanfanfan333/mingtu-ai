/// Local pretrained-YOLO interface for Mingtu AI v0.1.
///
/// This file defines the detection / tracking / dedup contract. It does
/// NOT bundle a YOLO model, weights, or a phone-side inference engine:
/// that integration (model file, runtime, latency on a real phone) is
/// NOT_IMPLEMENTED and must be verified on device before any claim.
/// The dedup rule is implemented here and is testable in pure Dart:
/// the same object in consecutive frames is ONE tracked event, never a
/// new broadcast per frame.
library;

import 'dart:math' as math;

class Detection {
  final String label;
  final double confidence;
  final double cx; // normalised centre x, 0..1
  final double cy; // normalised centre y, 0..1

  /// Normalised box width / height, 0..1. Zero means the
  /// geometry is UNKNOWN (older callers, stub detectors):
  /// consumers that need box geometry (nearness estimates)
  /// must fail closed on zero, never guess.
  final double w;
  final double h;
  const Detection({
    required this.label,
    required this.confidence,
    required this.cx,
    required this.cy,
    this.w = 0,
    this.h = 0,
  });

  /// Normalised y of the box's bottom edge.
  double get bottom => cy + h / 2;
}

class TrackedObject {
  final int trackId;
  final String label;
  int detectionCount;
  DateTime firstSeen;
  DateTime lastSeen;
  double cx;
  double cy;
  TrackedObject({
    required this.trackId,
    required this.label,
    required this.detectionCount,
    required this.firstSeen,
    required this.lastSeen,
    required this.cx,
    required this.cy,
  });
}

class PerceptionEvent {
  final int trackId;
  final String label;
  final bool isNewTrack;
  final bool movedSignificantly;
  const PerceptionEvent({
    required this.trackId,
    required this.label,
    required this.isNewTrack,
    required this.movedSignificantly,
  });
}

class VisualPerception {
  final Map<int, TrackedObject> _tracks = {};
  int _nextTrackId = 1;

  List<TrackedObject> get tracks => List.unmodifiable(_tracks.values);

  /// Tracks not seen for longer than [staleAfter]. Callers must not
  /// use stale tracks to generate new step instructions.
  int staleTrackCount(DateTime now,
      {Duration staleAfter = const Duration(seconds: 3)}) {
    return _tracks.values
        .where((t) => now.difference(t.lastSeen) > staleAfter)
        .length;
  }

  /// Process one frame. Returns ONLY new tracks and tracks whose centre
  /// moved by more than [moveThreshold] since the last frame. Repeated
  /// detections of the same stationary object return an empty list.
  /// v0.4: low-confidence detections (< 0.3 by default) never create
  /// a track. A faint detection must not become a spoken obstacle.
  List<PerceptionEvent> processFrame(
    List<Detection> detections,
    DateTime now, {
    double moveThreshold = 0.15,
    Duration staleAfter = const Duration(seconds: 3),
    double minConfidence = 0.3,
  }) {
    final events = <PerceptionEvent>[];
    for (final d in detections) {
      if (d.confidence < minConfidence) continue;
      TrackedObject? match;
      for (final t in _tracks.values) {
        if (t.label != d.label) continue;
        final dist = math.sqrt(
          math.pow(t.cx - d.cx, 2) + math.pow(t.cy - d.cy, 2),
        );
        if (dist < 0.25) {
          match = t;
          break;
        }
      }
      if (match == null) {
        final track = TrackedObject(
          trackId: _nextTrackId++,
          label: d.label,
          detectionCount: 1,
          firstSeen: now,
          lastSeen: now,
          cx: d.cx,
          cy: d.cy,
        );
        _tracks[track.trackId] = track;
        events.add(
          PerceptionEvent(
            trackId: track.trackId,
            label: d.label,
            isNewTrack: true,
            movedSignificantly: false,
          ),
        );
      } else {
        final moved = math.sqrt(
              math.pow(match.cx - d.cx, 2) + math.pow(match.cy - d.cy, 2),
            ) >
            moveThreshold;
        match.detectionCount += 1;
        match.lastSeen = now;
        match.cx = d.cx;
        match.cy = d.cy;
        if (moved) {
          events.add(
            PerceptionEvent(
              trackId: match.trackId,
              label: d.label,
              isNewTrack: false,
              movedSignificantly: true,
            ),
          );
        }
      }
    }
    _tracks.removeWhere(
      (id, t) => now.difference(t.lastSeen) > staleAfter,
    );
    return events;
  }
}
