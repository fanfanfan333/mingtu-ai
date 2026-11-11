/// Hand-written SORT fallback tracker (spec section 2.1).
///
/// SORT in the classic shape: every track carries a
/// constant-velocity Kalman filter, detections associate by
/// IoU, unmatched detections start tracks, unmatched tracks
/// coast and are retired after the retention window.
///
/// Two deliberate simplifications, both safe at this app's
/// target counts (a handful of boxes per frame):
/// - Association is GREEDY (pairs taken in descending IoU)
/// rather than Hungarian: with so few targets the optimal
/// assignment and the greedy one differ only in contrived
/// crossings, and greedy keeps this file auditable.
/// - The Kalman filter is four DECOUPLED position/velocity
/// filters (one per box component) instead of one coupled
/// state vector: the components are independent under a
/// constant-velocity model, so nothing is lost but a few
/// hundred lines of matrix code.
///
/// No third-party code; written for this project as the
/// fallback for when the default backend's IDs prove
/// unstable on a real device.
library;

import 'dart:math' as math;

import '../../modules/visual_perception.dart';
import '../navhaz_config.dart';
import 'tracker.dart';

/// One-dimensional constant-velocity Kalman filter over
/// frame steps: state (position, velocity per frame).
class _AxisFilter {
double x;
double v = 0;
double _p00 = 10;
double _p01 = 0;
double _p11 = 100;

_AxisFilter(this.x);

/// Process-noise scale (per frame).
static const double _q = 0.05;

/// Measurement variance (normalised coordinates).
static const double _r = 0.0025;

void predict() {
x += v;
final double p00 = _p00 + 2 * _p01 + _p11 + _q * 0.25;
final double p01 = _p01 + _p11 + _q * 0.5;
final double p11 = _p11 + _q;
_p00 = p00;
_p01 = p01;
_p11 = p11;
}

void correct(double z) {
final double y = z - x;
final double s = _p00 + _r;
final double k0 = _p00 / s;
final double k1 = _p01 / s;
x += k0 * y;
v += k1 * y;
final double p00 = (1 - k0) * _p00;
final double p01 = (1 - k0) * _p01;
final double p11 = _p11 - k1 * _p01;
_p00 = p00;
_p01 = p01;
_p11 = p11;
}
}

class _SortTrack {
final Track track;
final _AxisFilter cx;
final _AxisFilter cy;
final _AxisFilter w;
final _AxisFilter h;

_SortTrack(this.track, Detection d)
: cx = _AxisFilter(d.cx),
cy = _AxisFilter(d.cy),
w = _AxisFilter(d.w),
h = _AxisFilter(d.h);

void predict() {
cx.predict();
cy.predict();
w.predict();
h.predict();
}

void correct(Detection d) {
cx.correct(d.cx);
cy.correct(d.cy);
w.correct(d.w);
h.correct(d.h);
}

/// The current estimated box as a detection (confidence
/// and label from the track / latest observation).
Detection estimate(double conf) => Detection(
label: track.label,
confidence: conf,
cx: cx.x,
cy: cy.x,
w: math.max(0, w.x),
h: math.max(0, h.x),
);
}

double _iou(Detection a, Detection b) {
final double ax1 = a.cx - a.w / 2, ay1 = a.cy - a.h / 2;
final double ax2 = a.cx + a.w / 2, ay2 = a.cy + a.h / 2;
final double bx1 = b.cx - b.w / 2, by1 = b.cy - b.h / 2;
final double bx2 = b.cx + b.w / 2, by2 = b.cy + b.h / 2;
final double iw = math.min(ax2, bx2) - math.max(ax1, bx1);
final double ih = math.min(ay2, by2) - math.max(ay1, by1);
if (iw <= 0 || ih <= 0) return 0;
final double inter = iw * ih;
final double union = a.w * a.h + b.w * b.h - inter;
return union <= 0? 0: inter / union;
}

class SortBackend implements Tracker {
final Map<int, _SortTrack> _tracks = <int, _SortTrack>{};
int _nextId = 1;

@override
List<Track> update(List<Detection> dets, DateTime t) {
final List<Detection> usable = dets
.where((Detection d) => d.confidence >= NavHazConfig.minDetectionConfidence)
.toList();
for (final _SortTrack st in _tracks.values) {
st.predict();
st.track.age += 1;
}

// Greedy association: every (track, detection) pair of
// the same label, best IoU first.
final List<({double iou, int trackId, int detIndex})> pairs =
<({double iou, int trackId, int detIndex})>[];
for (final _SortTrack st in _tracks.values) {
final Detection est = st.estimate(0);
for (int j = 0; j < usable.length; j++) {
if (usable[j].label!= st.track.label) continue;
final double v = _iou(est, usable[j]);
if (v >= NavHazConfig.sortIouThreshold) {
pairs.add((iou: v, trackId: st.track.id, detIndex: j));
}
}
}
pairs.sort((a, b) => b.iou.compareTo(a.iou));
final Set<int> usedTracks = <int>{};
final Set<int> usedDets = <int>{};
for (final p in pairs) {
if (usedTracks.contains(p.trackId) || usedDets.contains(p.detIndex)) {
continue;
}
usedTracks.add(p.trackId);
usedDets.add(p.detIndex);
final _SortTrack st = _tracks[p.trackId]!;
final Detection d = usable[p.detIndex];
st.correct(d);
st.track.recordMatch(st.estimate(d.confidence), t);
}

// Unmatched tracks coast; retire past the retention
// window so a reappearing target starts a NEW id only
// after a real absence.
_tracks.removeWhere((int id, _SortTrack st) {
if (usedTracks.contains(id)) return false;
st.track.recordMiss();
return st.track.lostFrames > NavHazConfig.lostRetentionFrames;
});

// Unmatched detections start tracks.
for (int j = 0; j < usable.length; j++) {
if (usedDets.contains(j)) continue;
final Detection d = usable[j];
final Track track = Track(id: _nextId++, label: d.label);
final _SortTrack st = _SortTrack(track, d);
track.age = 1;
track.recordMatch(d, t);
_tracks[track.id] = st;
}

return _tracks.values.map((_SortTrack st) => st.track).toList()
..sort((Track a, Track b) => a.id.compareTo(b.id));
}

@override
void reset() {
_tracks.clear();
_nextId = 1;
}
}
