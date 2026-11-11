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

/// Hazard distance wording (FIX3B bands; thresholds in
/// NavHazConfig): below 1.5 m the distance is "very
/// close" and NO number is spoken (a sub-1.5 m number
/// would pretend to a precision the geometry does not
/// have); 1.5-5 m whole metres; 5-10 m one of two coarse
/// readouts split at 7.5 m ("about 5" / "about 10"); at
/// 10 m and beyond NO number at all -- the phrase carries
/// category and bearing only. The empty string is a real
/// output (the >= 10 m band), not an error.
String metresText(double rangeM) {
  if (rangeM < NavHazConfig.hazardVeryCloseBelow) return '很近';
  if (rangeM < NavHazConfig.hazardWholeMetresBelow) {
    return '${_smallNumber(rangeM.round())}米';
  }
  if (rangeM < NavHazConfig.hazardNumberedBelow) {
    return rangeM < NavHazConfig.hazardAboutSplit ? '约五米' : '约十米';
  }
  return '';
}

/// Navigation distance wording (bands FIX3B; rounding
/// FIX4-FINAL S2; thresholds in NavHazConfig): whole
/// metres under 17 m, but never below
/// [NavHazConfig.navMinReportedMetres] -- a sub-half-metre
/// distance rounds to 0, and "about 0 metres" is a
/// nonsense announcement, so the minimum readout is
/// "about 1 metre"; NEAREST 10 m from 17 to 100 m and
/// NEAREST 50 m from 100 to 1000 m, halves rounding UP in
/// both bands (Dart's round() rounds halves away from
/// zero, which on this non-negative domain IS half-up;
/// the worst-case error is therefore 5 m / 25 m, not the
/// almost-10 m understatement the previous floor rule
/// allowed in the 10 m band); "about 1 km" from 1000 to
/// 1500 m; "about X km" (X = kilometres rounded to the
/// nearest integer) up to 10 km; the fixed "beyond 10 km"
/// form past that. The rounding HABITS follow OsmAnd's
/// Chinese announcements -- rule reference only,
/// independently implemented (OsmAnd is GPL; no code or
/// text tables taken). Returns the announcement-ready
/// form, leading "about" included, so templates embed it
/// directly. NOT used by entrance guidance, which keeps
/// its own Step D 10 m bands.
String navigationDistanceText(double d) {
  if (d < NavHazConfig.navWholeMetresBelow) {
    final int whole = d.round();
    return '约${whole < NavHazConfig.navMinReportedMetres ? NavHazConfig.navMinReportedMetres : whole}米';
  }
  if (d < NavHazConfig.navRound50Below) {
    return '约${(d / 10).round() * 10}米';
  }
  if (d < NavHazConfig.navKilometreFrom) {
    return '约${(d / 50).round() * 50}米';
  }
  if (d < NavHazConfig.navAboutOneKmBelow) return '约1公里';
  if (d < NavHazConfig.navFixedBeyondFrom) {
    return '约${(d / 1000).round()}公里';
  }
  return '10公里以外';
}

/// Every readout [navigationDistanceText] can produce,
/// derived ANALYTICALLY from the band table (FIX4-FINAL:
/// no input sampling of any step size -- the previous
/// whole-metre sweep silently missed readouts that only
/// fractional inputs reach, e.g. 16.5-16.999 m rounding
/// to "about 17 metres"). For a band [lo, hi) whose
/// readout is round(d / step) * step (half-up), the
/// reachable multiples are exactly those m whose rounding
/// interval [m - step/2, m + step/2) intersects the band;
/// the whole-metre band's reachable integers are the
/// clamped rounding range. The set is therefore BY
/// CONSTRUCTION the production function's full range; the
/// fine-grid property test in navhaz_phrases_test sweeps
/// the production function against this set so any future
/// drift between the two fails loudly.
Set<String> enumerateNavigationDistanceTexts() {
  final Set<String> out = <String>{};
  // Whole-metre band [0, navWholeMetresBelow): round(d)
  // spans 0..navWholeMetresBelow (the top value is
  // reached from just under the band edge), clamped
  // below at navMinReportedMetres.
  final int wholeTop = NavHazConfig.navWholeMetresBelow.round();
  for (int k = NavHazConfig.navMinReportedMetres; k <= wholeTop; k++) {
    out.add('约$k米');
  }
  // Stepped bands: every multiple whose half-up rounding
  // interval intersects the band.
  void stepped(double lo, double hi, int step, String unit) {
    for (int m = 0; m < hi + step; m += step) {
      if (m - step / 2 < hi && m + step / 2 > lo) {
        out.add('约$m$unit');
      }
    }
  }

  stepped(NavHazConfig.navWholeMetresBelow,
      NavHazConfig.navRound50Below, 10, '米');
  stepped(NavHazConfig.navRound50Below,
      NavHazConfig.navKilometreFrom, 50, '米');
  out.add('约1公里');
  // Kilometre band: multiples of 1000 m with the same
  // interval rule, rendered in kilometres.
  for (int k = 0; k * 1000 < NavHazConfig.navFixedBeyondFrom + 1000; k++) {
    final int m = k * 1000;
    if (m - 500 < NavHazConfig.navFixedBeyondFrom &&
        m + 500 > NavHazConfig.navAboutOneKmBelow) {
      out.add('约$k公里');
    }
  }
  out.add('10公里以外');
  return out;
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
      // near range domain (unknown + samples across every
      // FIX3B band the near wording can render: very
      // close, whole metres, and the 5.0 edge).
      for (final double cx in <double>[0.1, 0.5, 0.9]) {
        yield hazardPhrase(
            urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: null);
        for (final double r in <double>[0.5, 1.0, 1.4, 1.5, 2.5, 3.5, 4.5, 5.0]) {
          yield hazardPhrase(
              urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: r);
        }
      }
      // Far forms: twelve clock hours (one cx per hour
      // offset) x the far range domain across the
      // remaining bands: the about-5 / about-10 split and
      // the no-number domain (>= 10 m) at several depths.
      for (int offset = -5; offset <= 6; offset++) {
        final double cx = 0.5 + offset * 30.0 / NavHazConfig.horizontalFovDeg;
        for (final double r in <double>[5.5, 6.5, 7.5, 8.5, 9.9, 10.0, 25.0, 100.0]) {
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

/// The set of NON-EMPTY metre readouts [metresText] can
/// produce under the FIX3B bands, derived by sweeping its
/// input domain finely (0.05 m steps over 0..30 m, which
/// covers every band including the no-number domain)
/// rather than by copying the band rules into a second
/// list: if the bands change, this set changes with them
/// and the exhaustion test follows the implementation.
/// The empty readout (range >= 10 m) is deliberately not
/// a member: it asserts nothing and is contained in every
/// string.
Set<String> reachableMetresTexts() {
  final Set<String> out = <String>{};
  for (double r = 0.05; r <= 30.0; r += 0.05) {
    final String text = metresText(r);
    if (text.isNotEmpty) out.add(text);
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
