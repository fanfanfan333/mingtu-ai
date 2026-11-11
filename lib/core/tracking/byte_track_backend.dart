/// Default tracking backend (spec section 2.1): wraps the
/// MIT-licensed byte_track_dart package (locked to 0.4.0 in
/// pubspec.yaml). This is the ONLY file that imports the
/// package, and it imports it with the `btd` prefix because
/// the package exports its own Tracker / Detection / Track
/// names that collide with this project's.
///
/// Coordinate mapping: the package works in absolute
/// (pixel) coordinates, so the normalised frame is treated
/// as a 1x1 canvas -- BBox(cx-w/2, cy-h/2, cx+w/2, cy+h/2).
/// All geometry stays in normalised units end to end.
///
/// What this layer adds on top of the package:
/// - label <-> classId mapping (the package knows only
///   integer class ids);
/// - the per-track SAMPLE HISTORY (the package keeps no
///   history, and TTC needs one);
/// - the confirmation rule. The package's own confirmed
///   state uses CUMULATIVE hits (ByteTrackConfig.minHits),
///   while the spec's confirmation is CONSECUTIVE matched
///   frames -- so confirmation is judged by this project's
///   [Track.consecutiveHits], never by the package's state.
/// - lost-frame bookkeeping in this project's terms
///   ([Track.lostFrames] mirrors the package's
///   timeSinceUpdate).
library;

import 'package:byte_track_dart/byte_track_dart.dart' as btd;

import '../../modules/visual_perception.dart';
import '../navhaz_config.dart';
import 'tracker.dart';

class ByteTrackBackend implements Tracker {
  /// One package tracker PER CLASS. The package's
  /// association is class-blind (its Track.classId is fixed
  /// at creation and never compared while matching), which
  /// is the stock ByteTrack design: deployments run it
  /// per class. A single shared instance would happily
  /// extend a person track with car detections whenever the
  /// boxes overlap -- and the hazard rules are class rules,
  /// so a class flip silently disarms them. Instances are
  /// created lazily per classId; own ids are allocated by
  /// this layer, so package ids colliding across instances
  /// are harmless.
  final Map<int, btd.Tracker> _trackersByClass = <int, btd.Tracker>{};

  btd.Tracker _trackerFor(int classId) =>
      _trackersByClass.putIfAbsent(classId, _newPackageTracker);

  static btd.Tracker _newPackageTracker() => btd.Tracker(
        algorithm: btd.ByteTrackAlgorithm(
          config: const btd.ByteTrackConfig(
            // Thresholds aligned with this project's long-standing
            // 0.3 confidence floor so both backends see the same
            // usable detection set.
            highThresh: NavHazConfig.minDetectionConfidence,
            lowThresh: 0.1,
            newTrackThresh: NavHazConfig.minDetectionConfidence,
            matchThresh: 0.3,
            secondPassMatchThresh: 0.5,
            // The package may coast a lost track for up to 30
            // frames internally; THIS project's retention rule
            // (lostRetentionFrames) is enforced in update(): a
            // target lost for longer is retired, and a later
            // reappearance is a new own track with a new own id.
            maxAge: 30,
            minHits: NavHazConfig.confirmFrames,
          ),
        ),
      );

  /// Own tracks, keyed by 'classId:packageId'. The own
  /// [Track.id] is allocated by THIS layer (see [_nextOwnId]),
  /// not copied from the package: when a target exceeds the
  /// retention window it is retired here even though the
  /// package coasts it for up to maxAge frames internally,
  /// and if the package later revives that internal track
  /// the target must come back as a NEW own track with a
  /// new own id -- exactly like the SORT backend, which
  /// deletes outright. (Otherwise the two backends would
  /// disagree about identity after a >5-frame occlusion.)
  final Map<String, Track> _own = <String, Track>{};
  final Set<String> _retiredKeys = <String>{};
  int _nextOwnId = 1;

  /// Retire [key] under the size cap (see
  /// [NavHazConfig.retiredKeyCap] for the trade-off): the
  /// set is insertion-ordered, so eviction removes the
  /// OLDEST retirements first.
  void _retire(String key) {
    _retiredKeys.add(key);
    while (_retiredKeys.length > NavHazConfig.retiredKeyCap) {
      _retiredKeys.remove(_retiredKeys.first);
    }
  }

  /// Retired-key count, exposed for the long-running cap
  /// test only.
  int get retiredKeyCountForTest => _retiredKeys.length;

  /// Seeded with the labels the hazard vocabulary knows;
  /// any other label is assigned the next free id on first
  /// sight and remembered for the backend's lifetime.
  final Map<String, int> _classIdByLabel = <String, int>{
    'person': 0,
    'bicycle': 1,
    'car': 2,
    'motorcycle': 3,
    'bus': 4,
    'truck': 5,
    'pole': 6,
  };
  int _nextClassId = 7;

  int _classIdFor(String label) =>
      _classIdByLabel.putIfAbsent(label, () => _nextClassId++);

  String _labelFor(int classId) {
    for (final MapEntry<String, int> e in _classIdByLabel.entries) {
      if (e.value == classId) return e.key;
    }
    return 'class$classId';
  }

  @override
  List<Track> update(List<Detection> dets, DateTime t) {
    final List<btd.Detection> mapped = <btd.Detection>[
      for (final Detection d in dets)
        if (d.confidence >= NavHazConfig.minDetectionConfidence)
          btd.Detection.xyxy(
            x1: d.cx - d.w / 2,
            y1: d.cy - d.h / 2,
            x2: d.cx + d.w / 2,
            y2: d.cy + d.h / 2,
            score: d.confidence,
            classId: _classIdFor(d.label),
          ),
    ];
    // Age every known class tracker (absent classes get an
    // empty update so their lost tracks keep ageing).
    final Map<int, List<btd.Detection>> byClass = <int, List<btd.Detection>>{};
    for (final btd.Detection d in mapped) {
      byClass.putIfAbsent(d.classId, () => <btd.Detection>[]).add(d);
    }
    final Set<String> seen = <String>{};
    for (final int classId in <int>{
      ..._trackersByClass.keys,
      ...byClass.keys,
    }) {
      final btd.Tracker tracker = _trackerFor(classId);
      tracker.update(byClass[classId] ?? const <btd.Detection>[]);
      for (final btd.Track bt in tracker.allTracks) {
        final String key = '$classId:${bt.id}';
        seen.add(key);
        final bool matched = bt.timeSinceUpdate == 0;
        Track? track = _own[key];
        if (track == null) {
          if (!matched && _retiredKeys.contains(key)) {
            // Retired here, still coasting inside the
            // package: stay invisible until (if ever) the
            // package matches it again, at which point it is
            // reborn below with a fresh own id.
            continue;
          }
          track = Track(id: _nextOwnId++, label: _labelFor(bt.classId));
          _own[key] = track;
          _retiredKeys.remove(key);
        }
        track.age += 1;
        if (matched) {
          // Matched this frame: sample the package's corrected
          // box (its Kalman estimate after consuming the
          // detection), in normalised units.
          track.recordMatch(
            Detection(
              label: track.label,
              confidence: bt.score,
              cx: bt.bbox.centerX,
              cy: bt.bbox.centerY,
              w: bt.bbox.width,
              h: bt.bbox.height,
            ),
            t,
          );
        } else {
          track.recordMiss();
          // Keep the frame count honest even if the package
          // and this layer ever disagree about the gap.
          if (track.lostFrames != bt.timeSinceUpdate) {
            track.lostFrames = bt.timeSinceUpdate;
          }
          if (track.lostFrames > NavHazConfig.lostRetentionFrames) {
            _own.remove(key);
            _retire(key);
          }
        }
      }
    }
    // Tracks the package has dropped are retired here too.
    _own.removeWhere((String key, Track _) => !seen.contains(key));

    return _own.values.toList()
      ..sort((Track a, Track b) => a.id.compareTo(b.id));
  }

  @override
  void reset() {
    _trackersByClass.clear();
    _own.clear();
    _retiredKeys.clear();
    _nextOwnId = 1;
  }
}
