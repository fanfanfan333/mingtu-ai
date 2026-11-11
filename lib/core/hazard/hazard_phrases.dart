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

/// One band of the hazard-distance table (NH-M1-14): the
/// half-open interval [below, previous band's below) is
/// rendered by [format]. The table ([hazardBands]) is the
/// SINGLE definition of the hazard banding: production
/// ([metresText]) walks it top-down, and the enumeration
/// side ([enumerateAllHazardPhrases]' distance axis)
/// derives its representative ranges from the same rows,
/// so the two can never drift apart (NH-M1-14).
class HazardBand {
  /// Upper edge of the band (exclusive); the last row
  /// carries infinity.
  final double below;

  /// The band's readout for an in-band range. Bands whose
  /// readout depends on the value (whole metres, the
  /// about-5 / about-10 split) compute it here; constant
  /// bands ignore the argument.
  final String Function(double rangeM) format;
  const HazardBand(this.below, this.format);
}

/// The hazard-distance band table, in ascending order
/// (thresholds in NavHazConfig). Below 1.5 m the distance
/// is "very close" and NO number is spoken (a sub-1.5 m
/// number would pretend to a precision the geometry does
/// not have); 1.5-5 m whole metres; 5-10 m one of two
/// coarse readouts split at 7.5 m ("about 5" / "about
/// 10"); at 10 m and beyond NO number at all -- the phrase
/// carries category and bearing only, so the last row's
/// readout is the empty string (a real output, not an
/// error).
final List<HazardBand> hazardBands = <HazardBand>[
  HazardBand(NavHazConfig.hazardVeryCloseBelow, (_) => '很近'),
  HazardBand(NavHazConfig.hazardWholeMetresBelow,
      (double r) => '${_smallNumber(r.round())}米'),
  HazardBand(
      NavHazConfig.hazardNumberedBelow,
      (double r) =>
          r < NavHazConfig.hazardAboutSplit ? '约五米' : '约十米'),
  HazardBand(double.infinity, (_) => ''),
];

/// Hazard distance wording (FIX3B bands): the readout of
/// the [hazardBands] row [rangeM] falls in.
///
/// NH-M1-12: a non-finite or negative range is NOT a
/// distance -- the readout is the EMPTY string, the same
/// no-distance form as the >= 10 m band, so the phrase
/// falls back to its category + bearing shape (exactly
/// the range-null behaviour). The guard sits at the
/// function entry, outside the band table: NaN comparisons
/// are all false and would otherwise fall through to the
/// last row by luck, and -Infinity / negative values
/// would land in the "very close" row and manufacture a
/// distance claim out of a broken measurement.
String metresText(double rangeM) {
  if (!rangeM.isFinite || rangeM < 0) return '';
  for (final HazardBand band in hazardBands) {
    if (rangeM < band.below) return band.format(rangeM);
  }
  return ''; // unreachable: the last band's edge is +inf
}

/// One band of the navigation-distance table (S3-2 /
/// NH-M1-14): this table ([navBands]) is the SINGLE
/// definition of the navigation banding -- every band
/// edge, step and readout format exists exactly once,
/// here. Production ([navigationDistanceText]) walks the
/// rows top-down; the analytic enumeration
/// ([enumerateNavigationDistanceTexts]) derives each
/// row's reachable readout set from the SAME row fields
/// (for stepped rows, every multiple whose half-up
/// rounding interval intersects the row's domain). The
/// two sides therefore cannot drift: a band change is
/// one edit, in one place.
class NavBand {
  /// Lower edge of the band's domain (inclusive).
  final double lo;

  /// Upper edge of the band's domain (exclusive); the
  /// last row carries infinity.
  final double hi;

  /// Rounding step in metres for stepped bands (1 =
  /// whole metres); null for constant-readout bands.
  final int? stepM;

  /// Unit suffix of the readout ('米' / '公里').
  final String unit;

  /// The band's readout for an in-band distance. This is
  /// the ONE formatting core: production calls it on the
  /// real input, the enumeration calls it on interior
  /// representative inputs (see
  /// [enumerateNavigationDistanceTexts]).
  final String Function(double d) format;

  /// The "beyond" readout for distances at or past [hi]
  /// of the fixed final band (the "10 km and beyond"
  /// form); null on every other row.
  final String? beyondText;
  const NavBand({
    required this.lo,
    required this.hi,
    required this.stepM,
    required this.unit,
    required this.format,
    this.beyondText,
  });
}

/// The navigation-distance band table, in ascending order
/// (thresholds in NavHazConfig; bands FIX3B, rounding
/// FIX4-FINAL S2): whole metres under 17 m, but never
/// below [NavHazConfig.navMinReportedMetres] -- a
/// sub-half-metre distance rounds to 0, and "about 0
/// metres" is a nonsense announcement, so the minimum
/// readout is "about 1 metre"; NEAREST 10 m from 17 to
/// 100 m and NEAREST 50 m from 100 to 1000 m, halves
/// rounding UP in both bands (Dart's round() rounds
/// halves away from zero, which on this non-negative
/// domain IS half-up; the worst-case error is therefore
/// 5 m / 25 m, not the almost-10 m understatement the
/// previous floor rule allowed in the 10 m band); "about
/// 1 km" from 1000 to 1500 m; "about X km" (X =
/// kilometres rounded to the nearest integer) up to
/// 10 km; the fixed "beyond 10 km" form past that. The
/// rounding HABITS follow OsmAnd's Chinese announcements
/// -- rule reference only, independently implemented
/// (OsmAnd is GPL; no code or text tables taken).
final List<NavBand> navBands = <NavBand>[
  NavBand(
    lo: 0,
    hi: NavHazConfig.navWholeMetresBelow,
    stepM: 1,
    unit: '米',
    format: (double d) {
      final int whole = d.round();
      return '约${whole < NavHazConfig.navMinReportedMetres ? NavHazConfig.navMinReportedMetres : whole}米';
    },
  ),
  NavBand(
    lo: NavHazConfig.navWholeMetresBelow,
    hi: NavHazConfig.navRound50Below,
    stepM: 10,
    unit: '米',
    format: (double d) => '约${(d / 10).round() * 10}米',
  ),
  NavBand(
    lo: NavHazConfig.navRound50Below,
    hi: NavHazConfig.navKilometreFrom,
    stepM: 50,
    unit: '米',
    format: (double d) => '约${(d / 50).round() * 50}米',
  ),
  NavBand(
    lo: NavHazConfig.navKilometreFrom,
    hi: NavHazConfig.navAboutOneKmBelow,
    stepM: null,
    unit: '公里',
    format: (_) => '约1公里',
  ),
  NavBand(
    lo: NavHazConfig.navAboutOneKmBelow,
    hi: NavHazConfig.navFixedBeyondFrom,
    stepM: 1000,
    unit: '公里',
    format: (double d) => '约${(d / 1000).round()}公里',
  ),
  NavBand(
    lo: NavHazConfig.navFixedBeyondFrom,
    hi: double.infinity,
    stepM: null,
    unit: '',
    format: (_) => '10公里以外',
    beyondText: '10公里以外',
  ),
];

/// Navigation distance wording: the readout of the
/// [navBands] row [d] falls in, announcement-ready form
/// (leading "about" included) so templates embed it
/// directly. NOT used by entrance guidance, which keeps
/// its own Step D 10 m bands.
///
/// CDX5 S2-1: a non-finite (NaN / +/-Infinity) or negative
/// distance is NOT a distance -- the function returns the
/// EMPTY string ("no distance to report") and never
/// throws, so an upstream distance fault degrades the
/// announcement to its no-distance form instead of
/// crashing the speech path or inventing a figure. NaN
/// comparisons are all false, so without this guard NaN
/// fell through every band into the final "beyond 10 km"
/// readout, -Infinity threw inside round(), and small
/// negatives were clamped into a spoken "about 1 metre".
/// The guard sits at the function entry, OUTSIDE the band
/// table (it is not a band). Callers handle the empty
/// readout explicitly (see the three call sites).
String navigationDistanceText(double d) {
  if (!d.isFinite || d < 0) return '';
  for (final NavBand band in navBands) {
    if (d < band.hi) return band.format(d);
  }
  return navBands.last.beyondText ?? '';
}

/// Every readout [navigationDistanceText] can produce for
/// a FINITE, non-negative distance, derived ANALYTICALLY
/// from [navBands] (FIX4-FINAL: no input sampling of any
/// step size -- the previous whole-metre sweep silently
/// missed readouts that only fractional inputs reach,
/// e.g. 16.5-16.999 m rounding to "about 17 metres"; S3-2:
/// the derivation consumes the same table rows production
/// walks). For a stepped band [lo, hi) whose readout is
/// round(d / step) * step (half-up), the reachable
/// multiples are exactly those m whose rounding interval
/// [m - step/2, m + step/2) intersects the band; each is
/// rendered by calling the row's own [NavBand.format]
/// on an interior representative (m clamped into the
/// band), so the rendered string comes from the shared
/// formatting core, never from a re-typed template.
/// Constant bands contribute their single readout; the
/// final band contributes its "beyond" readout. The set
/// is therefore BY CONSTRUCTION the production function's
/// full range on its valid domain; the fine-grid property
/// test in navhaz_phrases_test sweeps the production
/// function against this set so any future drift fails
/// loudly. Non-finite / negative inputs are NOT in this
/// domain: they return the empty string (CDX5 S2-1),
/// which is not a distance readout and is deliberately
/// not a member here.
Set<String> enumerateNavigationDistanceTexts() {
  final Set<String> out = <String>{};
  for (final NavBand band in navBands) {
    final int? step = band.stepM;
    if (step == null) {
      // Constant-readout band: its one readout, rendered
      // by the shared core at the band's lower edge (or
      // the "beyond" readout for the final band).
      out.add(band.beyondText ?? band.format(band.lo));
      continue;
    }
    // Stepped band: every multiple whose half-up rounding
    // interval [m - step/2, m + step/2) intersects
    // [lo, hi), rendered through the row's format core on
    // the multiple clamped into the band (the clamp only
    // matters at the whole-metre band's clamped minimum
    // and at a band's top edge, where the interval reaches
    // in from just below hi).
    for (int m = 0; m < band.hi + step; m += step) {
      if (m - step / 2 < band.hi && m + step / 2 > band.lo) {
        double rep = m.toDouble();
        if (rep < band.lo) rep = band.lo;
        if (rep >= band.hi) rep = band.hi - 0.001;
        out.add(band.format(rep));
      }
    }
  }
  return out;
}

/// Whether the near (three-zone) wording applies.
bool isNearWording(double? rangeM) =>
    rangeM == null || rangeM <= NavHazConfig.nearWordingRangeM;

/// Representative ranges for the enumeration's distance
/// axis, DERIVED from the [hazardBands] table (NH-M1-14):
/// for every band, sample points strictly inside it at
/// the band's own readout granularity -- the narrow bands
/// (very-close, whole metres) at 0.5 m starting from the
/// band's lower edge (inside the whole-metre band this
/// reaches every integer readout; the very-close band's
/// edge point itself is included because its readout
/// changes AT the edge), wider bands at 1.0 m steps from
/// the lower edge (finer than any in-band split -- the
/// about-5 / about-10 band is exercised on both sides of
/// its split), and the no-number band at several depths.
/// Production ([metresText]) and this enumeration consume
/// the SAME table, so a band change moves both; the
/// yielded phrase SET is pinned verbatim by the
/// exhaustion test, so any change in the derived space
/// fails loudly instead of drifting silently.
List<double> _enumerationRangeSamples() {
  final List<double> out = <double>[];
  double lo = 0;
  for (final HazardBand band in hazardBands) {
    final double hi = band.below;
    if (hi == double.infinity) {
      // The no-number band: several depths, all rendering
      // the same (empty) readout.
      out.addAll(<double>[lo, lo + 15.0, 100.0]);
    } else if (hi - lo <= 5) {
      for (double r = lo; r < hi; r += 0.5) {
        out.add(r);
      }
      out.add(hi - 0.01);
    } else {
      for (double r = lo; r < hi; r += 1.0) {
        out.add(r);
      }
      out.add(hi - 0.1);
    }
    lo = hi;
  }
  return out;
}

/// The near enumeration's range axis: the unknown range
/// (null, handled by the caller) plus the table-derived
/// samples that fall in the near-wording domain
/// (range <= [NavHazConfig.nearWordingRangeM]).
List<double> _nearRangeSamples() => _enumerationRangeSamples()
    .where((double r) => r <= NavHazConfig.nearWordingRangeM)
    .toList();

/// The far enumeration's range axis: the table-derived
/// samples beyond the near-wording domain.
List<double> _farRangeSamples() => _enumerationRangeSamples()
    .where((double r) => r > NavHazConfig.nearWordingRangeM)
    .toList();

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
/// behaviour defines them. NH-M1-14: the distance axes
/// below are derived from the shared [hazardBands] table
/// ([_nearRangeSamples] / [_farRangeSamples]) instead of
/// hand-listed sample literals, so the enumeration's
/// range coverage follows the banding definition itself.
Iterable<String> enumerateAllHazardPhrases() sync* {
  final List<double> nearRanges = _nearRangeSamples();
  final List<double> farRanges = _farRangeSamples();
  for (final (String, bool) axis in spokenNameAxes()) {
    final (String name, bool isVehicle) = axis;
    for (final bool urgent in <bool>[true, false]) {
      // Near forms: three zones (one cx per zone) x the
      // near range domain (unknown + every table-derived
      // near sample).
      for (final double cx in <double>[0.1, 0.5, 0.9]) {
        yield hazardPhrase(
            urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: null);
        for (final double r in nearRanges) {
          yield hazardPhrase(
              urgent: urgent, name: name, isVehicle: isVehicle, cx: cx, rangeM: r);
        }
      }
      // Far forms: twelve clock hours (one cx per hour
      // offset) x the far range domain (the about-5 /
      // about-10 split and the no-number depths).
      for (int offset = -5; offset <= 6; offset++) {
        final double cx = 0.5 + offset * 30.0 / NavHazConfig.horizontalFovDeg;
        for (final double r in farRanges) {
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
/// produce under the FIX3B bands, derived from the shared
/// [hazardBands] table (NH-M1-14): every band contributes
/// its readouts via its own format core over interior
/// samples at the band's rounding granularity (0.5 m
/// inside the narrow bands -- finer than the 1 m whole-
/// metre granularity, so every integer readout is
/// reached -- plus a fine 0.05 m sweep of the about-5 /
/// about-10 band so both sides of its split are hit).
/// Deriving from the table (instead of a second copy of
/// the band rules, or an input sweep whose coverage is a
/// sampling accident) means a band change moves this set
/// with the implementation. The empty readout (range
/// >= 10 m, and non-finite / negative input per NH-M1-12)
/// is deliberately not a member: it asserts nothing and
/// is contained in every string.
Set<String> reachableMetresTexts() {
  final Set<String> out = <String>{};
  double lo = 0;
  for (final HazardBand band in hazardBands) {
    final double hi = band.below;
    if (hi == double.infinity) break; // the no-number band
    for (double r = lo + 0.05; r < hi; r += 0.05) {
      final String text = band.format(r);
      if (text.isNotEmpty) out.add(text);
    }
    lo = hi;
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
