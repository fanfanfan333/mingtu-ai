/// Entrance guidance (step D): the phase AFTER the walking
/// route ends. The route tracker hands over once the user
/// is within 30 m of the destination point with a fix
/// accurate to 20 m or better; from there this module keeps
/// using the GPS fixes and the destination's verified
/// GCJ-02 coordinates to announce the remaining distance
/// and the direction of the destination point RELATIVE to
/// the phone's current heading （前方/左前方/右前方/左侧/右侧/
/// 身后）, until the user is within
/// [EntranceGuidance.arriveRadiusM] and the completion line
/// is spoken. Relative directions need the heading: when
/// heading data is stale (over 500 ms old) or unavailable,
/// only the distance is announced.
///
/// Honesty boundary (also stated in the README): phone GPS
/// near buildings can be off by tens of metres, so this guides
/// the user to the VICINITY of the destination coordinates.
/// It never confirms a doorway: the relative direction
/// points at the destination point, it is NOT a walking
/// instruction -- no step-left/step-right wording exists here,
/// and arrival copy says the entrance itself still has to
/// be confirmed by cane probing or by asking someone nearby.
///
/// Pure and fully testable with simulated fixes.
library;

import 'dart:math' as math;

import '../modules/map_navigation.dart';
import 'real_navigation.dart' show haversineMeters;

/// Spoken when the user reaches the arrival radius. Contains
/// the task-completion line the user asked for, and keeps the
/// honest boundary: being at the coordinates is NOT a
/// confirmed entrance.
const String entranceArrivedSpeech =
    '已到达目的地附近。小途已完成任务。入口的具体位置请通过盲杖探测或向身边的人确认。';

/// Initial great-circle bearing in degrees (0 = north,
/// clockwise, normalised to [0, 360)) from [from] to [to].
double bearingDegrees(GeoPoint from, GeoPoint to) {
  final double lat1 = from.latitude! * math.pi / 180.0;
  final double lat2 = to.latitude! * math.pi / 180.0;
  final double dLon = (to.longitude! - from.longitude!) * math.pi / 180.0;
  final double y = math.sin(dLon) * math.cos(lat2);
  final double x = math.cos(lat1) * math.sin(lat2) -
      math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
  final double deg = math.atan2(y, x) * 180.0 / math.pi;
  return (deg + 360.0) % 360.0;
}

/// The eight compass words, in clockwise order from north.
/// Index i covers bearings [i*45 - 22.5, i*45 + 22.5).
const List<String> compassWords = <String>[
  '正北',
  '东北',
  '正东',
  '东南',
  '正南',
  '西南',
  '正西',
  '西北',
];

/// Map a bearing in degrees to one of the eight compass
/// words: 22.5-degree half-sectors centred on each word.
String compassWord(double bearingDeg) {
  final double b = ((bearingDeg % 360.0) + 360.0) % 360.0;
  final int idx = ((b + 22.5) / 45.0).floor() % 8;
  return compassWords[idx];
}

/// Stateful entrance guidance for one destination. Feed GPS
/// fixes via [onFix]; it returns the text to speak, or null
/// when nothing should be said for this fix (untrusted fix,
/// throttled, or already completed).
class EntranceGuidance {
  /// Distance (m) at which the route tracker hands over to
  /// this phase (30 m, adjusted for the ~155 m demo route).
  /// NavigationTracker.entranceRadiusM mirrors this value:
  /// the tracker owns the hand-over event, this constant
  /// is the phase's own bound.
  static const double enterRadiusM = 30;

  /// Distance (m) at or below which the user counts as
  /// arrived and the completion line is spoken.
  static const double arriveRadiusM = 15;

  /// Minimum distance change (m) since the last announcement
  /// before another one may be spoken.
  static const double announceEveryM = 10;

  /// Minimum time between two announcements.
  static const Duration minAnnounceInterval = Duration(seconds: 15);

  /// Fixes with unknown accuracy, or accuracy worse than
  /// this (m), are not trusted: no numbers are derived from
  /// them (same bound as the tracker's weak-signal gate).
  static const double maxTrustedAccuracyM = 50;

  final String destinationName;
  final GeoPoint destination;

  bool _completed = false;
  bool _started = false;
  GeoPoint? _lastPoint;
  double? _lastDistanceM;
  double? _lastAnnouncedDistanceM;
  DateTime? _lastAnnouncedAt;

  EntranceGuidance({
    required this.destinationName,
    required this.destination,
  });

  bool get completed => _completed;

  /// The most recent trusted distance to the destination
  /// (metres, unrounded), or null before the first trusted
  /// fix. Used by the status line.
  double? get lastDistanceM => _lastDistanceM;

  /// The announcement for entering the phase, without a
  /// distance (used when the fix that triggered the hand-over
  /// is not in hand). The first trusted [onFix] afterwards
  /// still produces the full first announcement.
  String startAnnouncement() =>
      '已到达$destinationName附近，继续为你指引入口方向。'
      '请以盲杖探测和现场声音为准。';

  /// Distance as spoken: rounded DOWN to a 10 m step and
  /// announced as approximate （约）, because GPS error makes
  /// metre-exact numbers a false promise. The nanometre-scale
  /// epsilon only absorbs floating-point error at exact step
  /// boundaries (a true 40.0 m computed as 39.9999999998 must
  /// still announce 40); it does not change the floor rule.
  static int roundedDistanceM(double distanceM) =>
      ((distanceM + 1e-6) / 10).floor() * 10;

  /// The six relative direction words. The sector layout
  /// follows natural language, NOT equal slices: sounds
  /// from the user's own frame -- ahead means within
  /// +/-45 degrees, behind within 45 degrees of dead
  /// behind, and each SIDE (left/right) owns the full
  /// 90-degree quadrant between them, split at 45 degrees
  /// from the side axis into front-side and back-side:
  ///   前方   [-45, 45)     (centred on 0)
  ///   右前方  [45, 67.5)   (the front part of the
  ///                        front-right diagonal zone)
  ///   右侧    [67.5, 135)  (centred on 112.5: everything
  ///                        from past the diagonal to the
  ///                        behind boundary is the side)
  ///   身后    [135, 225)   (centred on 180)
  ///   左侧    [225, 292.5) (the mirror of the right side)
  ///   左前方  [292.5, 315) (up to the ahead boundary)
  /// So +80 degrees is 右侧 (not 右前方): at 80 degrees off
  /// the nose the destination is beside the user, and the
  /// announcement must say so.
  static String relativeDirectionWord(double relativeBearingDeg) {
    final double r =
        ((relativeBearingDeg % 360.0) + 360.0) % 360.0;
    if (r < 45.0 || r >= 315.0) return '前方';
    if (r < 67.5) return '右前方';
    if (r < 135.0) return '右侧';
    if (r < 225.0) return '身后';
    if (r < 292.5) return '左侧';
    return '左前方';
  }

  String _guidanceText(double distanceM,
      {required bool first, double? headingDeg}) {
    final int n = roundedDistanceM(distanceM);
    // The direction clause exists only with a heading: the
    // caller passes one only when the heading sample is
    // fresh (see HeadingTracker); a stale or missing
    // heading announces the distance alone.
    final String dirClause = headingDeg == null
        ? ''
        : '，入口大致在${relativeDirectionWord(bearingDegrees(_lastPoint!, destination) - headingDeg)}';
    if (first) {
      return '已到达$destinationName附近，继续为你指引入口方向。'
          '还剩约$n米$dirClause。请以盲杖探测和现场声音为准。';
    }
    return '还剩约$n米$dirClause。';
  }

  /// Feed one GPS fix. [accuracyM] is the fix's horizontal
  /// accuracy in metres (null when unknown). [headingDeg]
  /// is the phone's current heading in degrees clockwise
  /// from north, or null when no fresh heading is available
  /// (announcements then carry the distance only).
  String? onFix(GeoPoint point, double? accuracyM, DateTime now,
      {double? headingDeg}) {
    if (_completed) return null;
    if (accuracyM == null || accuracyM > maxTrustedAccuracyM) {
      // Untrusted fix: never derive a distance or bearing
      // from it. The caller may say (throttled) that guidance
      // is paused; this module stays silent.
      return null;
    }
    _lastPoint = point;
    final double d = haversineMeters(point, destination);
    _lastDistanceM = d;
    if (d <= arriveRadiusM) {
      _completed = true;
      return entranceArrivedSpeech;
    }
    if (!_started) {
      _started = true;
      _lastAnnouncedDistanceM = d;
      _lastAnnouncedAt = now;
      return _guidanceText(d, first: true, headingDeg: headingDeg);
    }
    final double changed = (d - _lastAnnouncedDistanceM!).abs();
    final bool waited = _lastAnnouncedAt == null ||
        now.difference(_lastAnnouncedAt!) >= minAnnounceInterval;
    if (changed >= announceEveryM && waited) {
      _lastAnnouncedDistanceM = d;
      _lastAnnouncedAt = now;
      return _guidanceText(d, first: false, headingDeg: headingDeg);
    }
    return null;
  }
}
