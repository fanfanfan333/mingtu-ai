/// Tracking layer for NAVHAZ M1 (spec section 2.1).
///
/// One narrow interface, two backends:
/// - [ByteTrackBackend] (default) wraps the MIT-licensed
///   byte_track_dart package;
/// - [SortBackend] is a hand-written SORT fallback for
///   devices where the default backend's IDs prove
///   unstable.
///
/// Both backends feed THIS file's [Track] model: the hazard
/// pipeline only ever sees [Track], with its per-frame
/// sample history, so alert timelines can be compared
/// backend-to-backend frame by frame.
///
/// The [Detection] type is the project's existing one
/// (modules/visual_perception.dart) -- deliberately not
/// redefined here.
library;

import '../../modules/visual_perception.dart';
import '../navhaz_config.dart';
import 'byte_track_backend.dart';
import 'sort_backend.dart';

/// One frame's observation of a tracked target: normalised
/// centre / size plus the detector confidence, stamped with
/// the frame time. Velocities and TTC are derived from a
/// track's sample history, never stored per-sample.
class TrackSample {
  final DateTime t;
  final double cx;
  final double cy;
  final double w;
  final double h;
  final double conf;
  const TrackSample({
    required this.t,
    required this.cx,
    required this.cy,
    required this.w,
    required this.h,
    required this.conf,
  });

  /// Normalised y of the box's bottom edge.
  double get bottom => cy + h / 2;
}

/// A tracked target with a stable [id] within one backend
/// instance (IDs are NOT comparable across backends or
/// across resets).
class Track {
  final int id;
  final String label;

  /// Ring buffer of the most recent samples (oldest first),
  /// capped at [NavHazConfig.sampleBufferFrames].
  final List<TrackSample> samples = <TrackSample>[];

  /// Total matched frames over the track's life.
  int hits = 0;

  /// Frames since the track was created (matched or not).
  int age = 0;

  /// Consecutive matched frames. This -- not the cumulative
  /// [hits] -- carries the confirmation semantics: a track
  /// is only trustworthy after an UNBROKEN run of matches.
  /// (byte_track_dart's own minHits is cumulative, which is
  /// why confirmation is judged here and not taken from the
  /// backend's state field.)
  int consecutiveHits = 0;

  /// Set once [consecutiveHits] first reaches
  /// [NavHazConfig.confirmFrames]; latched while the track
  /// lives, so a single dropped frame inside the retention
  /// window does not un-confirm a known target.
  bool confirmed = false;

  /// Consecutive frames with no match. While this stays at
  /// or below [NavHazConfig.lostRetentionFrames] the track
  /// (and its ID) is retained; beyond that the backend
  /// retires it.
  int lostFrames = 0;

  /// Hit/miss outcome of the most recent (up to) three
  /// frames, oldest first -- the raw material of the
  /// urgent confirmation predicate below.
  final List<bool> _recentOutcomes = <bool>[];

  /// URGENT confirmation (FIX3B): at least two hits among
  /// the most recent three frames AND the current frame a
  /// hit. This is deliberately a SEPARATE predicate from
  /// [confirmed] (an unbroken run of
  /// [NavHazConfig.confirmFrames]): the urgent judgement
  /// may fire one frame earlier than a warning, but the
  /// warning's 3-frame rule and everything built on it are
  /// untouched.
  bool get urgentConfirmed {
    if (_recentOutcomes.isEmpty || !_recentOutcomes.last) {
      return false;
    }
    int hits = 0;
    for (final bool outcome in _recentOutcomes) {
      if (outcome) hits += 1;
    }
    return hits >= 2;
  }

  Track({required this.id, required this.label});

  TrackSample? get latest => samples.isEmpty ? null : samples.last;

  /// The detection-shaped view of the latest sample, for
  /// consumers (avoidance advisor) that work on detections.
  Detection? get latestDetection {
    final TrackSample? s = latest;
    if (s == null) return null;
    return Detection(
      label: label,
      confidence: s.conf,
      cx: s.cx,
      cy: s.cy,
      w: s.w,
      h: s.h,
    );
  }

  /// Record a matched observation at [t].
  void recordMatch(Detection d, DateTime t) {
    samples.add(TrackSample(
      t: t,
      cx: d.cx,
      cy: d.cy,
      w: d.w,
      h: d.h,
      conf: d.confidence,
    ));
    while (samples.length > NavHazConfig.sampleBufferFrames) {
      samples.removeAt(0);
    }
    hits += 1;
    consecutiveHits += 1;
    lostFrames = 0;
    if (consecutiveHits >= NavHazConfig.confirmFrames) {
      confirmed = true;
    }
    _recentOutcomes.add(true);
    while (_recentOutcomes.length > 3) {
      _recentOutcomes.removeAt(0);
    }
  }

  /// Record a frame with no match for this track.
  void recordMiss() {
    lostFrames += 1;
    consecutiveHits = 0;
    _recentOutcomes.add(false);
    while (_recentOutcomes.length > 3) {
      _recentOutcomes.removeAt(0);
    }
  }
}

/// Advances a set of live [Track]s by one frame of
/// detections. Implementations own ID assignment.
abstract class Tracker {
  /// Feed one frame; returns the live tracks (including
  /// retained lost ones, marked via [Track.lostFrames]).
  List<Track> update(List<Detection> dets, DateTime t);

  /// Drop every track and restart ID assignment.
  void reset();
}

/// Build the configured backend (see
/// [NavHazConfig.trackerBackend]).
Tracker createTracker() => switch (NavHazConfig.trackerBackend) {
      TrackerBackend.byteTrack => ByteTrackBackend(),
      TrackerBackend.sort => SortBackend(),
    };
