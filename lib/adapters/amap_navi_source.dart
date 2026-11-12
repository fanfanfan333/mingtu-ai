/// Amap turn-by-turn (TBT) navigation event source
/// (NAVHAZ M3, DEPENDENCY-FREE form): a local adapter
/// that maps navi-engine-shaped samples -- defined in
/// this file, with NO plugin import anywhere -- into
/// the exact [NavEvent] stream the live-navigation
/// wiring already consumes from [NavigationTracker]
/// (see lib/core/navigation_tracker.dart and main.dart's
/// _handleNavEvent). The speech arbitration above that
/// stream is source-agnostic and is NOT changed here.
///
/// Why there is no plugin: the spike evaluated one TBT
/// plugin and the final ruling was NOT to adopt it
/// (the default package would grow by about 35 MB per
/// ABI for a proprietary navigation SDK, in exchange
/// for one structured remaining-distance field; and
/// its start call opens the vendor's own navigation
/// page, which would take the camera + push-to-talk
/// surface and the audio focus away from a blind
/// user). The full evaluation is
/// docs/amap_navi_spike_report.md; the removed plugin
/// binding is archived, outside every compile path, in
/// docs/amap_navi_plugin_integration.md.
///
/// What remains, and why: this adapter (so the mapping
/// is pinned by tests and a future binding has a fixed
/// target), a scripted mock source for tests
/// (amap_navi_mock_source.dart), and the wiring in
/// main.dart behind AppConfig.amapNaviEnabled (default
/// off). The only binding in this build is the stub
/// (amap_navi_source_stub.dart): its initialize always
/// fails, so with the switch on every trip falls back
/// to the Web source with one fixed log line and no new
/// announcement -- the honest state until a binding is
/// adopted by a future ruling.
///
/// Sample shapes mirror the fields measured on the
/// evaluated plugin's event payloads (2026-11-11):
/// - text: the navi engine's own spoken prompt string;
/// - location: position / bearing / speed in km/h /
///   accuracy / current step index / epoch ms;
/// - info (the plugin's info stream name was
///   onNaviInfoUpdate): STRUCTURED REMAINING DISTANCE --
///   pathRetainDistance (int, metres, whole route) and
///   pathRetainTime (int, seconds), plus
///   curStepRetainDistance / curStepRetainTime for the
///   current step, road names and the step index. The
///   mapping carries pathRetainDistance into
///   [AmapNaviSource.remainingM], the same state role
///   NavigationTracker.remainingM plays for the Web
///   source;
/// - arrival and yaw signals: the tracker stream this
///   source mirrors HAS arrived / offRoute kinds, so
///   the binding surface carries them; without them a
///   TBT trip could never hand over to entrance
///   guidance or trigger the re-plan path.
///
/// Mapping rules (pure, unit-tested in
/// test/navhaz_amap_navi_test.dart):
/// - navi text -> NavEventKind.turnAhead with the text
///   verbatim (trimmed). stepIndex is NULL: the text
///   stream carries no step index (the info stream's
///   step index belongs to a different, unsynchronised
///   stream; borrowing it would fabricate the index).
///   Consequence, by design: an interrupted TBT turn
///   prompt cannot be regenerated from a fix (the
///   arbitration's regenerate path needs a step index)
///   and is dropped instead of replayed -- the same
///   treatment as any non-step prompt. Empty texts are
///   dropped, and a text identical to the immediately
///   previous one is suppressed (the navi engine repeats
///   prompts as distance closes; the tracker, by
///   construction, emits one prompt per step).
/// - location -> STATE ONLY (latest position/accuracy),
///   plus a weakSignal NavEvent when the fix is
///   unusable (accuracy null or worse than
///   NavigationTracker.weakAccuracyM), throttled by
///   NavigationTracker.weakSignalCooldown and carrying
///   the tracker's exact weak-signal text, so the two
///   sources are indistinguishable to the arbitration.
///   Positions do NOT drive the tracker here: the Web
///   source's GPS subscription keeps feeding it (trip
///   state, entrance hand-over geometry, re-plan
///   decisions, cloud triggers all stay tracker-owned).
/// - info -> STATE ONLY: remainingM (and the raw sample
///   as lastInfo). The navi engine announces its own
///   distance call-outs through the text stream; turning
///   numbers into extra speech here would double-speak.
/// - arrive -> NavEventKind.arrived with the tracker's
///   exact hand-over text for the destination;
/// - yaw -> NavEventKind.offRoute with the tracker's
///   exact off-route text (the existing handler runs
///   the re-plan decision against the tracker, unchanged).
library;

import 'dart:async';

import '../core/navigation_tracker.dart';
import '../modules/map_navigation.dart';

export 'amap_navi_source_stub.dart';

/// One location sample from the navi engine, as a
/// LOCALLY DEFINED struct (field shape measured on the
/// evaluated plugin's location payload: position /
/// bearing / speed in km/h / accuracy / current step
/// index; time is epoch milliseconds). No plugin type
/// appears anywhere in this adapter.
class AmapNaviLocationSample {
  final double latitude;
  final double longitude;
  final double? accuracyM;
  final double? bearingDeg;
  final double? speedKmh;
  final int? atMs;
  final int? curStepIndex;

  const AmapNaviLocationSample({
    required this.latitude,
    required this.longitude,
    this.accuracyM,
    this.bearingDeg,
    this.speedKmh,
    this.atMs,
    this.curStepIndex,
  });
}

/// One guidance-info sample from the navi engine, as a
/// LOCALLY DEFINED struct (field shape measured on the
/// evaluated plugin's info payload:
/// pathRetainDistance / pathRetainTime are the whole
/// route's remaining distance in metres / time in
/// seconds; curStepRetain* are the current step's).
class AmapNaviInfoSample {
  final int pathRetainDistanceM;
  final int pathRetainTimeS;
  final int curStepRetainDistanceM;
  final int? curStepRetainTimeS;
  final String nextRoadName;
  final String? currentRoadName;
  final int? curStep;

  const AmapNaviInfoSample({
    required this.pathRetainDistanceM,
    required this.pathRetainTimeS,
    required this.curStepRetainDistanceM,
    this.curStepRetainTimeS,
    required this.nextRoadName,
    this.currentRoadName,
    this.curStep,
  });
}

/// The binding seam: three sample streams (text /
/// location / info) plus the arrival and yaw signals
/// the mirrored NavEvent surface requires, and the
/// init / start / stop verbs. The only implementation
/// in this build is the stub (always unavailable); a
/// future real binding translates its SDK's events
/// into the local samples at this seam. Tests
/// substitute scripted fakes and the mock source.
abstract class AmapNaviBinding {
  /// Prepare the navi SDK. Throws when the SDK is not
  /// configured (no deployer console configuration) or
  /// the platform is unavailable.
  Future<void> initialize();

  Stream<String> get textEvents;
  Stream<AmapNaviLocationSample> get locationEvents;
  Stream<AmapNaviInfoSample> get infoEvents;

  /// Emits (true) once when the navi engine reports
  /// arrival at the destination.
  Stream<bool> get arrivedEvents;

  /// Emits (true) when the navi engine reports a yaw
  /// (off-route) re-calculation.
  Stream<bool> get yawEvents;

  /// Start turn-by-turn navigation to [destination]
  /// (GCJ-02, the coordinates the app already holds
  /// for the destination).
  Future<void> startNavigation({
    required GeoPoint destination,
    required String destinationName,
  });

  Future<void> stopNavigation();
}

/// The tracker's exact weak-signal text, reused so a
/// TBT weak-signal event is indistinguishable from a
/// Web-source one. Pinned against the tracker's own
/// output in the tests.
const String amapNaviWeakSignalText =
    'GPS 信号较差，定位可能不准，导航提示仅供参考。';

/// The tracker's exact off-route text (same pinning).
const String amapNaviOffRouteText = '你已偏离路线。';

/// The tracker's exact arrival hand-over text for
/// [destinationName] (same pinning). The wiring does
/// not speak this text as-is on either source: it is
/// the hand-over marker that starts entrance guidance.
String amapNaviArrivedText(String destinationName) =>
    '已到达$destinationName附近，进入入口指引。';

/// Map one navi text to its NavEvent: a turn-ahead
/// prompt with the text verbatim (trimmed) and NO step
/// index (the text stream carries none). Null for an
/// empty / whitespace-only text.
NavEvent? mapAmapNaviText(String rawText) {
  final String text = rawText.trim();
  if (text.isEmpty) return null;
  return NavEvent(NavEventKind.turnAhead, text);
}

/// Whether a navi location sample is too weak to trust,
/// judged by the SAME threshold the tracker applies to
/// Web-source fixes (NavigationTracker.weakAccuracyM).
bool amapNaviLocationIsWeak(double? accuracyM) =>
    accuracyM == null || accuracyM > NavigationTracker.weakAccuracyM;

/// The NavEvent source: subscribes to a binding's
/// streams, maps them per the rules at the top of this
/// file, and exposes the resulting [NavEvent] stream.
///
/// [events] is single-subscription: subscribe BEFORE
/// calling [start] (events emitted before a listener
/// attaches are lost). [start] returns false on ANY
/// failure (unavailable binding, engine error) and
/// leaves the source inactive with no
/// subscriptions held; the caller then simply keeps the
/// Web source. No failure is ever thrown across [start]
/// and none produces speech: failure handling (one log
/// line) is the caller's.
class AmapNaviSource {
  final AmapNaviBinding _binding;
  final DateTime Function() _clock;

  final StreamController<NavEvent> _out = StreamController<NavEvent>();
  final List<StreamSubscription<dynamic>> _subs =
      <StreamSubscription<dynamic>>[];

  bool _active = false;
  String _destinationName = '';
  String? _lastText;
  DateTime? _lastWeakAt;
  double? _remainingM;
  AmapNaviInfoSample? _lastInfo;
  AmapNaviLocationSample? _lastLocation;

  AmapNaviSource({
    required AmapNaviBinding binding,
    DateTime Function()? clock,
  })  : _binding = binding,
        _clock = clock ?? DateTime.now;

  Stream<NavEvent> get events => _out.stream;
  bool get isActive => _active;

  /// Whole-route remaining distance in metres, from the
  /// info stream's structured pathRetainDistance -- the
  /// same state role NavigationTracker.remainingM plays
  /// for the Web source. Null until the first info
  /// sample arrives.
  double? get remainingM => _remainingM;
  AmapNaviInfoSample? get lastInfo => _lastInfo;
  AmapNaviLocationSample? get lastLocation => _lastLocation;

  /// Subscribe to the binding and start navigation.
  /// Subscriptions are taken BEFORE the start call, so
  /// no early prompt is missed. Returns false -- and
  /// releases every
  /// subscription -- when anything throws.
  Future<bool> start({
    required GeoPoint destination,
    required String destinationName,
  }) async {
    if (_active) return true;
    _destinationName = destinationName;
    try {
      await _binding.initialize();
      _subs.add(_binding.textEvents.listen(_onText));
      _subs.add(_binding.locationEvents.listen(_onLocation));
      _subs.add(_binding.infoEvents.listen(_onInfo));
      _subs.add(_binding.arrivedEvents.listen(_onArrived));
      _subs.add(_binding.yawEvents.listen(_onYaw));
      await _binding.startNavigation(
        destination: destination,
        destinationName: destinationName,
      );
    } catch (_) {
      await _cancelSubs();
      return false;
    }
    _active = true;
    return true;
  }

  /// Stop navigation and release the subscriptions.
  /// Safe to call when inactive; binding errors during
  /// stop are swallowed (the trip is ending either way).
  Future<void> stop() async {
    _active = false;
    await _cancelSubs();
    try {
      await _binding.stopNavigation();
    } catch (_) {
      // Ending the trip must not fail because the navi
      // engine is already gone.
    }
  }

  Future<void> dispose() async {
    await stop();
    await _out.close();
  }

  Future<void> _cancelSubs() async {
    for (final StreamSubscription<dynamic> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
  }

  void _onText(String raw) {
    final NavEvent? event = mapAmapNaviText(raw);
    if (event == null) return;
    // The navi engine repeats its prompt as the turn
    // approaches; the tracker emits one prompt per
    // step. Suppress an exact repeat of the immediately
    // previous text so the arbitration sees a tracker-
    // shaped stream, not the engine's repetition.
    if (event.text == _lastText) return;
    _lastText = event.text;
    _out.add(event);
  }

  void _onLocation(AmapNaviLocationSample sample) {
    _lastLocation = sample;
    if (!amapNaviLocationIsWeak(sample.accuracyM)) return;
    final DateTime now = _clock();
    final DateTime? last = _lastWeakAt;
    if (last != null &&
        now.difference(last) < NavigationTracker.weakSignalCooldown) {
      return;
    }
    _lastWeakAt = now;
    _out.add(const NavEvent(NavEventKind.weakSignal, amapNaviWeakSignalText));
  }

  void _onInfo(AmapNaviInfoSample sample) {
    _lastInfo = sample;
    _remainingM = sample.pathRetainDistanceM.toDouble();
  }

  void _onArrived(bool arrived) {
    if (!arrived) return;
    _out.add(NavEvent(
      NavEventKind.arrived,
      amapNaviArrivedText(_destinationName),
    ));
  }

  void _onYaw(bool yaw) {
    if (!yaw) return;
    _out.add(const NavEvent(NavEventKind.offRoute, amapNaviOffRouteText));
  }
}
