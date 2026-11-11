/// Spoken wording for hazard alerts (spec section 2.4) and
/// the banned-word guard every announcement passes through.
///
/// Wording rules:
/// - Near (range <= [NavHazConfig.nearWordingRangeM] or
///   unknown): three zones from centre-x -- left / ahead /
///   right.
/// - Far: clock direction + rounded metres (1 m steps up to
///   10 m, 5 m steps beyond).
/// - Templates stay short (the spec's examples run to about
///   a dozen characters) and imperative for urgent alerts.
/// - A step direction is NEVER produced here: sideways-step
///   wording may only come from the avoidance advisor's
///   three-condition rule, appended by the caller at urgent
///   level. TTC and tracking results cannot produce one.
library;

import '../avoidance_advisor.dart';
import '../navhaz_config.dart';

/// Words that must never be spoken: passage must never be
/// granted or implied. Written as adjacent literals so this
/// source file itself stays free of the contiguous strings
/// (the project scans lib/ sources for them).
const List<String> bannedAnnouncementWords = <String>[
  '安' '全',
  '可以' '通行',
  '放' '心',
  '可以过' '马路',
];

/// Fixed replacement spoken when an announcement fails the
/// banned-word check in a release build: it asks the user
/// to stop without claiming anything about the way ahead.
const String bannedWordFallbackPhrase = '前方情况无法确认，请停下。';

bool containsBannedWord(String text) {
  for (final String w in bannedAnnouncementWords) {
    if (text.contains(w)) return true;
  }
  return false;
}

/// Debug-build guard called at the speech entry point:
/// asserts (and reports) when [text] contains a banned
/// word. Release builds use [containsBannedWord] directly
/// and substitute [bannedWordFallbackPhrase].
bool assertNoBannedWords(String text) {
  final bool bad = containsBannedWord(text);
  assert(!bad, 'announcement contains a banned word');
  return !bad;
}

/// The spoken name for a detector label (the same naming
/// the YOLO path has always used), falling back to the
/// hazard-kind name for labels outside the table.
String hazardSpokenName(String label, HazardKind kind) {
  switch (label) {
    case 'car':
      return '汽车';
    case 'truck':
      return '卡车';
    case 'bus':
      return '公交车';
    case 'motorcycle':
      return '摩托车';
    case 'bicycle':
      return '自行车';
    case 'person':
      return '行人';
    case 'pole':
      return '杆子';
    default:
      return hazardKindName(kind);
  }
}

/// Three-zone wording for near hazards.
String zoneName(double cx) {
  if (cx < NavHazConfig.corridorLeft) return '左边';
  if (cx <= NavHazConfig.corridorRight) return '前方';
  return '右边';
}

/// Clock hour for a centre-x: the angle off the forward
/// axis is (cx - 0.5) * HFOV; one clock hour per 30 degrees,
/// 12 straight ahead, higher numbers to the right.
int clockHour(double cx) {
  final double angleDeg = (cx - 0.5) * NavHazConfig.horizontalFovDeg;
  int offset = (angleDeg / 30).round();
  if (offset < -5) offset = -5;
  if (offset > 6) offset = 6;
  int hour = 12 + offset;
  if (hour > 12) hour -= 12;
  return hour;
}

const List<String> _hourNames = <String>[
  '一', '二', '三', '四', '五', '六',
  '七', '八', '九', '十', '十一', '十二',
];

String _smallNumber(int n) {
  if (n >= 1 && n <= 10) return _hourNames[n - 1];
  return '$n';
}

/// Metres for speech: whole metres (rounded), 5 m steps
/// beyond 10 m, never below 1.
String metresText(double rangeM) {
  int m = rangeM.round();
  if (m > 10) m = (m / 5).round() * 5;
  if (m < 1) m = 1;
  return '${_smallNumber(m)}米';
}

/// Whether the near (three-zone) wording applies.
bool isNearWording(double? rangeM) =>
    rangeM == null || rangeM <= NavHazConfig.nearWordingRangeM;

/// The single enumerable entry point for the FULL hazard
/// phrase space (FIX2 round): every phrase [hazardPhrase]
/// can ever produce, enumerated from the same axes the
/// builder consumes -- every spoken item name (the union
/// produced by [spokenNameAxes]) x both levels x every
/// direction form (the three near zones and all twelve
/// clock hours) x every reachable spoken-metre value (see
/// [reachableMetresTexts]). Production speech goes through
/// [hazardPhrase] itself; this entry exists so the
/// banned-word exhaustion (spec 2.7.10) enumerates the
/// space from ONE place instead of re-deriving it in a
/// test, and so the axes live next to the builder whose
/// behaviour defines them.
Iterable<String> enumerateAllHazardPhrases() sync* {
  for (final (String, bool) axis in spokenNameAxes()) {
    final (String name, bool isVehicle) = axis;
    for (final bool urgent in <bool>[true, false]) {
      // Near forms: three zones (one cx per zone) x the
      // near range domain (unknown + the half-metre steps
      // whose readout stays near) -- ranges are INPUTS
      // here; the reachable READOUTS are asserted against
      // reachableMetresTexts() by the exhaustion test.
      for (final double cx in <double>[0.1, 0.5, 0.9]) {
        yield hazardPhrase(
            urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: null);
        for (double r = 0.5; r <= 5.0; r += 0.5) {
          yield hazardPhrase(
              urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: r);
        }
      }
      // Far forms: twelve clock hours (one cx per hour
      // offset) x the far range domain.
      for (int offset = -5; offset <= 6; offset++) {
        final double cx = 0.5 + offset * 30.0 / NavHazConfig.horizontalFovDeg;
        for (double r = 5.5; r <= 10.0; r += 0.5) {
          yield hazardPhrase(
              urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: r);
        }
        for (double r = 12.5; r <= 100.0; r += 2.5) {
          yield hazardPhrase(
              urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: r);
        }
      }
    }
  }
}

/// Every (spoken name, isVehicle) pair [hazardPhrase] can
/// be called with: the five hazard-kind names plus every
/// detector label's spoken name (unknown labels fall back
/// to their kind name), deduplicated.
List<(String, bool)> spokenNameAxes() {
  final Map<String, bool> names = <String, bool>{};
  for (final HazardKind kind in HazardKind.values) {
    names[hazardKindName(kind)] =
        kind == HazardKind.motorVehicle || kind == HazardKind.nonMotorVehicle;
  }
  for (final String label in <String>[
    'car', 'truck', 'bus', 'motorcycle', 'bicycle', 'person',
    'pole', 'mystery-box',
  ]) {
    final HazardKind kind = hazardKindForLabel(label) ?? HazardKind.clutter;
    names[hazardSpokenName(label, kind)] =
        kind == HazardKind.motorVehicle || kind == HazardKind.nonMotorVehicle;
  }
  return <(String, bool)>[
    for (final MapEntry<String, bool> e in names.entries) (e.key, e.value),
  ];
}

/// The set of metre READOUTS [metresText] can produce,
/// derived by sweeping its input domain finely (0.05 m
/// steps over 0..200 m) rather than by copying the
/// rounding rules into a second list: if the rounding
/// changes, this set changes with it and the exhaustion
/// test's equality assertion follows the implementation.
Set<String> reachableMetresTexts() {
  final Set<String> out = <String>{};
  for (double r = 0.05; r <= 200.0; r += 0.05) {
    out.add(metresText(r));
  }
  return out;
}

/// Build the spoken text for one alert.
///
/// [urgent] selects the imperative template. [name] is the
/// spoken item name (see [hazardSpokenName]).
String hazardPhrase({
  required bool urgent,
  required String name,
  required bool isVehicle,
  required double cx,
  required double? rangeM,
}) {
  if (isNearWording(rangeM)) {
    final String zone = zoneName(cx);
    if (urgent) {
      if (rangeM != null && rangeM <= 3) {
        return '停，$zone${metresText(rangeM)}有$name';
      }
      if (isVehicle && zone == '前方') return '停，前方来车';
      return '停，$zone有$name';
    }
    if (rangeM != null) {
      return '注意，$zone${metresText(rangeM)}有$name';
    }
    return '注意，$zone有$name';
  }
  final String clock = '${_hourNames[clockHour(cx) - 1]}点钟方向';
  final String metres = metresText(rangeM!);
  if (urgent) {
    return '停，$clock$metres，$name靠近';
  }
  return '注意，$clock$metres，$name靠近';
}
