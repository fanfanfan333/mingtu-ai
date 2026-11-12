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
    case 'pothole':
      return '坑洞';
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

/// NH-M3-01: the whole-metre DISTANCE readout of exactly
/// 2 is spoken with the colloquial quantifier form
/// ('两米'), the same reading the navigation distance
/// texts get from their Arabic-digit '2米' under TTS
/// numeral rules -- the two distance systems now read a
/// 2 m distance identically. This is a distance-only
/// wrapper by design: [_smallNumber] and the shared
/// [_hourNames] table stay untouched, because the clock
/// forms read the same table (十二点钟 keeps its 二), and
/// compound numerals are not affected either (a 二 inside
/// 十二 / 二十 / 二十二 is part of the numeral, never a
/// standalone whole-metre value -- and this helper only
/// ever receives the whole-metre band's own rounded
/// value).
String _wholeMetresNumber(int n) => n == 2 ? '两' : _smallNumber(n);

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
/// not have); 1.5-5 m whole metres (a whole-metre 2 reads
/// 两米, NH-M3-01 -- see [_wholeMetresNumber]); 5-10 m one of two
/// coarse readouts split at 7.5 m ("about 5" / "about
/// 10"); at 10 m and beyond NO number at all -- the phrase
/// carries category and bearing only, so the last row's
/// readout is the empty string (a real output, not an
/// error).
final List<HazardBand> hazardBands = <HazardBand>[
  HazardBand(NavHazConfig.hazardVeryCloseBelow, (_) => '很近'),
  HazardBand(NavHazConfig.hazardWholeMetresBelow,
      (double r) => '${_wholeMetresNumber(r.round())}米'),
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

/// The no-range full sentence (M2-B item 2): the far
/// (clock) template with the distance segment omitted --
/// item and bearing kept, no metre readout. Spoken when
/// no range could be measured (scale-only evidence);
/// also exactly what the far template itself renders
/// for a range in the no-number band, so this form is
/// not a new shape, just the far form with the distance
/// left out. Never the short form: the short form is
/// the NH-M1-19 gate's decision at issuance, not a
/// fallback for missing geometry.
String hazardPhraseNoRange({
  required bool urgent,
  required String name,
  required double cx,
}) {
  final String clock = '${_hourNames[clockHour(cx) - 1]}点钟方向';
  return urgent ? '停，$clock，$name靠近' : '注意，$clock，$name靠近';
}

/// Whether the near (three-zone) wording applies to a
/// MEASURED range. A null range is not "near": since
/// M2-B item 2 it takes the no-range full sentence (see
/// [hazardPhraseNoRange]), so this predicate is only
/// ever consulted with a non-null range inside
/// [hazardPhrase]; it keeps its null-inclusive shape
/// for its other callers, whose semantics (an unmeasured
/// target is treated cautiously, like a near one) are
/// unchanged.
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
  // NH-M1-17 / NH-M1-19: the short urgent forms are a
  // production output surface of the policy, so they
  // belong to this space -- the exhaustion / banned-word
  // corpus covers them exactly like the templated forms.
  yield* shortUrgentPhrases();
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
    'pole', 'pothole', 'mystery-box',
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

/// NH-M1-17, forms reshaped by NH-M1-19: the SHORT form
/// of an urgent announcement, per hazard kind AND
/// bearing -- spoken INSTEAD of the normal [hazardPhrase]
/// only when the NH-M1-19 gate passes (see
/// [shortFormApplies]): inside the vibrate-first zone
/// AND too little time even at the fastest plausible
/// reading speed. NH-M1-17's original kind-only forms
/// carried no bearing at all, which the NH-M1-19 review
/// rejected (the short form is a last-resort fallback,
/// not a reason to throw away direction the user can
/// still act on); the forms below keep the shortest
/// bearing the wording system offers while staying
/// within the voiced-character caps in NavHazConfig
/// ([NavHazConfig.shortPhraseMaxCharsInVocabulary] for
/// in-vocabulary labels,
/// [NavHazConfig.shortPhraseMaxCharsFallback] for the
/// kind-name fallback entries, see the last bullet):
/// - bearing: the near templates' own zone words -- the
///   LEFT / RIGHT zones compress to their first character
///   (左 / 右, unambiguous next to 停), the centre zone
///   keeps 前方 (a bare 前 reads as part of a compound);
/// - item: the shortest honest word per label -- vehicle
///   labels keep their verb 来车 / 有车 (the template's
///   own words: a vehicle approaching vs a static item
///   present -- the short form never invents a motion
///   claim), person compresses 行人 to 人 (the NH-M1-17
///   form's word), bicycle keeps 车 like every vehicle
///   label, pole keeps 杆 (杆子's first character; a
///   standalone 杆 is a complete word for a pole).
/// The squeezes, each forced by the six-character cap:
/// - clutter's two-character name 杂物 cannot fit beside
///   a side bearing inside six characters (停，左有杂物
///   would be seven), so a SIDE clutter short form
///   drops the 有 and reads 停，左杂物 / 停，右杂物; the
///   centre form keeps 停，前方有杂物.
/// - the kind-name FALLBACK entries (机动车 / 非机动车,
///   reachable only for labels outside the detector
///   vocabulary) cannot fit AT ALL: their names are 3 /
///   4 characters, so even the centre form is 7 / 8
///   voiced characters and a side form 6 / 7. A fallback
///   target's kind name is its ONLY honest item word --
///   compressing 机动车 to 车 would misreport the
///   category -- so these two entries exceed the cap
///   rather than lie; every label in the current
///   detector vocabulary fits the cap.
/// NO distance figure and NO step direction, as before
/// (a sideways step still comes only from the avoidance
/// advisor's three-condition rule, appended at speech
/// time exactly as for the normal form). Every form
/// passes the banned-word scan (asserted in the phrase
/// tests and the exhaustion corpus: this table is part
/// of [enumerateAllHazardPhrases]' space via
/// [shortUrgentPhrases]).
const Map<(HazardKind, String), String> shortUrgentPhraseByKindAndName =
    <(HazardKind, String), String>{
  // (kind, spoken name) -> the short form. Vehicles are
  // keyed per LABEL name because 机动车 alone covers car /
  // truck / bus / motorcycle with different shortest
  // honest item words; the kind-name entries are the
  // fallback for labels outside the detector vocabulary.
  (HazardKind.motorVehicle, '汽车'): '停，前方来车|停，左来车|停，右来车',
  (HazardKind.motorVehicle, '卡车'): '停，前方来车|停，左来车|停，右来车',
  (HazardKind.motorVehicle, '公交车'): '停，前方来车|停，左来车|停，右来车',
  (HazardKind.motorVehicle, '摩托车'): '停，前方来车|停，左来车|停，右来车',
  (HazardKind.nonMotorVehicle, '自行车'): '停，前方来车|停，左来车|停，右来车',
  (HazardKind.motorVehicle, '机动车'): '停，前方有机动车|停，左有机动车|停，右有机动车',
  (HazardKind.nonMotorVehicle, '非机动车'):
      '停，前方有非机动车|停，左有非机动车|停，右有非机动车',
  (HazardKind.person, '行人'): '停，前方有人|停，左有人|停，右有人',
  (HazardKind.pole, '杆子'): '停，前方有杆|停，左有杆|停，右有杆',
  (HazardKind.clutter, '杂物'): '停，前方有杂物|停，左杂物|停，右杂物',
};

/// Bearing slots of a [shortUrgentPhraseByKindAndName]
/// entry, in order: 0 = ahead （前方）, 1 = left （左）,
/// 2 = right （右）. The bearings are the near templates'
/// three zones ([zoneName]).
const List<String> _shortBearingHeads = <String>['前方', '左', '右'];

/// The short form for an urgent alert (NH-M1-17,
/// reshaped by NH-M1-19): [kind] and the alert's spoken
/// [name] (see [hazardSpokenName]) select the item word,
/// and [cx] selects the bearing via the SAME zone rule
/// the normal templates use, so the short form's bearing
/// can never contradict the full sentence's.
String shortUrgentPhrase(HazardKind kind, String name, double cx) {
  final String packed =
      shortUrgentPhraseByKindAndName[(kind, name)] ??
          shortUrgentPhraseByKindAndName[(kind, hazardKindName(kind))]!;
  final List<String> forms = packed.split('|');
  final String zone = zoneName(cx);
  final int slot = zone == _shortBearingHeads[0]
      ? 0
      : (zone.startsWith(_shortBearingHeads[1]) ? 1 : 2);
  return forms[slot];
}

/// Every short form [shortUrgentPhrase] can produce --
/// the enumeration axis for the exhaustion tests.
Iterable<String> shortUrgentPhrases() sync* {
  for (final String packed in shortUrgentPhraseByKindAndName.values) {
    yield* packed.split('|');
  }
}

/// The voiced character count of [text] (NH-M1-17):
/// runes with the spoken-punctuation marks excluded --
/// they shape pauses but are not characters the TTS
/// voices. The single counting rule the speech-duration
/// estimate and the NH-M1-19 gate share.
int voicedCharCount(String text) => text.runes
    .where((int r) => r != 0xFF0C && r != 0x3002 && r != 0xFF01)
    .length;

/// Estimated spoken duration of [text] in seconds
/// (NH-M1-17): its voiced character count (see
/// [voicedCharCount]) times the conservative
/// per-character upper bound. This is an UPPER-bound
/// planning figure, not a timing promise.
double estimatedSpeechSeconds(String text) =>
    voicedCharCount(text) * NavHazConfig.ttsSecondsPerCharUpperBound;

/// The NH-M1-19 short-form gate: BOTH conditions must
/// hold for the short form, otherwise the alert keeps
/// its full sentence (see the rule's full statement at
/// NavHazConfig.shortPhraseSecondsPerChar):
///   condition 1: [remainingTtcS] < the vibrate-first
///     threshold (NavHazConfig.preVibrationTtcS);
///   condition 2: [remainingTtcS] < the normal phrase's
///     voiced character count x
///     NavHazConfig.shortPhraseSecondsPerChar.
/// Both comparisons are strict.
bool shortFormApplies(double remainingTtcS, String normalPhrase) =>
    remainingTtcS < NavHazConfig.preVibrationTtcS &&
    remainingTtcS <
        voicedCharCount(normalPhrase) *
            NavHazConfig.shortPhraseSecondsPerChar;

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
  // M2-B item 2: NO measured range (rangeM == null --
  // scale-only evidence, e.g. no pitch): the full
  // sentence keeps the item AND the bearing and omits
  // ONLY the distance segment -- it takes the FAR
  // (clock) template with an empty metre readout, the
  // ranged far form minus its distance, exactly the
  // shape a >= 10 m range already produces. The near
  // branch below previously swallowed this case
  // (isNearWording(null) is true): a dead-centre vehicle
  // collapsed to '停，前方来车' -- textually the SHORT
  // form, with the item name and the clock bearing
  // thrown away even though the alert was never gated
  // as a short form -- and every other kind collapsed
  // to a zone form with no distance segment to remove.
  // An unknown range asserts no distance; it must not
  // silently demote a full sentence to the short form.
  if (rangeM == null) {
    return hazardPhraseNoRange(urgent: urgent, name: name, cx: cx);
  }
  if (isNearWording(rangeM)) {
    final String zone = zoneName(cx);
    if (urgent) {
      if (rangeM <= 3) {
        return '停，$zone${metresText(rangeM)}有$name';
      }
      if (isVehicle && zone == '前方') return '停，前方来车';
      return '停，$zone有$name';
    }
    return '注意，$zone${metresText(rangeM)}有$name';
  }
  final String clock = '${_hourNames[clockHour(cx) - 1]}点钟方向';
  final String metres = metresText(rangeM);
  if (urgent) {
    return '停，$clock$metres，$name靠近';
  }
  return '注意，$clock$metres，$name靠近';
}
