/// NAVHAZ M3 section 4.4 -- the DEPENDENCY-FREE Amap
/// TBT spike: (a) local-sample -> NavEvent mapping,
/// field by field; (b) source equivalence -- one
/// scripted arbitration sequence driven by Web-source
/// (NavigationTracker) events vs TBT mock-source
/// events, spoken sequences identical item by item;
/// (c) switch off => the source is never constructed
/// and behaviour is unchanged; (d) switch on with the
/// stub binding => start fails, the wiring falls back
/// to the Web source with its fixed log line, no
/// crash, no new speech; (e) both M3 switches off =>
/// neither new source is constructed.
///
/// Everything here is fixture-only: the TBT side is
/// driven by the scripted mock source over LOCALLY
/// DEFINED samples (lib/adapters/amap_navi_mock_source
/// .dart). No plugin, no platform channel, no network.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/amap_navi_mock_source.dart';
import 'package:mingtu_ai/adapters/amap_navi_source.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

const GeoPoint _destPoint =
    GeoPoint(latitude: 37.725307, longitude: 120.442404);
const String _destName = '图书馆';

AmapNaviInfoSample _info({
  int pathM = 850,
  int pathS = 600,
  int stepM = 120,
  int? stepS = 90,
  String next = '林荫道',
  String? current = '校门路',
  int? step = 3,
}) =>
    AmapNaviInfoSample(
      pathRetainDistanceM: pathM,
      pathRetainTimeS: pathS,
      curStepRetainDistanceM: stepM,
      curStepRetainTimeS: stepS,
      nextRoadName: next,
      currentRoadName: current,
      curStep: step,
    );

Future<void> _flush() async {
  await Future<void>.delayed(const Duration(milliseconds: 10));
  await Future<void>.delayed(Duration.zero);
}

/// The arbitration-facing projection of a NavEvent
/// stream, mirroring main.dart's _handleNavEvent
/// exactly at the speech surface: turn prompts speak
/// their text at turn level; weak signals speak their
/// text at info level; an off-route event with re-plan
/// budget speaks the fixed re-plan text (the event's
/// own text is the shorter marker); arrival hands over
/// (the event text is the hand-over marker, recorded
/// as such). Both sources are projected through this
/// ONE function, so the equivalence assertion compares
/// what the user would hear, in order.
List<(String, String)> _spokenFor(
  List<NavEvent> events,
  RerouteBudget budget,
) {
  final List<(String, String)> spoken = <(String, String)>[];
  for (final NavEvent e in events) {
    switch (e.kind) {
      case NavEventKind.turnAhead:
        spoken.add(('turn', e.text));
      case NavEventKind.weakSignal:
        spoken.add(('info', e.text));
      case NavEventKind.offRoute:
        final RerouteDecision d = budget.decision(DateTime.now());
        spoken.add((
          'info',
          d == RerouteDecision.doIt ? '你已偏离路线，正在重新规划。' : e.text,
        ));
      case NavEventKind.arrived:
        spoken.add(('hand-over', e.text));
    }
  }
  return spoken;
}

void main() {
  group('(a) mapping: local samples -> NavEvent / state', () {
    test('text maps verbatim (trimmed), stepIndex stays null; '
        'empty text drops', () {
      final NavEvent? e = mapAmapNaviText('  前方100米右转  ');
      expect(e, isNotNull);
      expect(e!.kind, NavEventKind.turnAhead);
      expect(e.text, '前方100米右转');
      expect(e.stepIndex, isNull,
          reason: 'the text stream carries no step index; '
              'borrowing one would fabricate it');
      expect(mapAmapNaviText(''), isNull);
      expect(mapAmapNaviText('   '), isNull);
    });

    test('an exact repeat of the previous text is suppressed; '
        'a later repeat after a different text is not', () async {
      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        const <AmapNaviMockStep>[
          AmapNaviMockStep.text('前方右转'),
          AmapNaviMockStep.text('前方右转'),
          AmapNaviMockStep.text('前方左转'),
          AmapNaviMockStep.text('前方右转'),
        ],
      );
      final List<NavEvent> got = <NavEvent>[];
      final sub = s.source.events.listen(got.add);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isTrue);
      await _flush();
      expect(got.map((NavEvent e) => e.text).toList(),
          <String>['前方右转', '前方左转', '前方右转']);
      expect(s.binding.startedDestinationName, _destName);
      await sub.cancel();
      await s.source.dispose();
    });

    test('info: pathRetainDistance lands in remainingM (the tracker '
        'state role); curStep fields stay on the raw sample; '
        'info emits NO event', () async {
      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        <AmapNaviMockStep>[AmapNaviMockStep.info(_info())],
      );
      final List<NavEvent> got = <NavEvent>[];
      final sub = s.source.events.listen(got.add);
      expect(s.source.remainingM, isNull);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isTrue);
      await _flush();
      expect(got, isEmpty, reason: 'info is state only, never speech');
      expect(s.source.remainingM, 850.0);
      final AmapNaviInfoSample info = s.source.lastInfo!;
      expect(info.pathRetainDistanceM, 850);
      expect(info.pathRetainTimeS, 600);
      expect(info.curStepRetainDistanceM, 120);
      expect(info.curStepRetainTimeS, 90);
      expect(info.nextRoadName, '林荫道');
      expect(info.currentRoadName, '校门路');
      expect(info.curStep, 3);
      await sub.cancel();
      await s.source.dispose();
    });

    test('location: every field lands on lastLocation; a good fix '
        'emits nothing', () async {
      const AmapNaviLocationSample sample = AmapNaviLocationSample(
        latitude: 37.7245,
        longitude: 120.4418,
        accuracyM: 12,
        bearingDeg: 88.5,
        speedKmh: 4.2,
        atMs: 1700000000000,
        curStepIndex: 2,
      );
      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        const <AmapNaviMockStep>[AmapNaviMockStep.location(sample)],
      );
      final List<NavEvent> got = <NavEvent>[];
      final sub = s.source.events.listen(got.add);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isTrue);
      await _flush();
      expect(got, isEmpty);
      final AmapNaviLocationSample loc = s.source.lastLocation!;
      expect(loc.latitude, 37.7245);
      expect(loc.longitude, 120.4418);
      expect(loc.accuracyM, 12);
      expect(loc.bearingDeg, 88.5);
      expect(loc.speedKmh, 4.2);
      expect(loc.atMs, 1700000000000);
      expect(loc.curStepIndex, 2);
      await sub.cancel();
      await s.source.dispose();
    });

    test('weak threshold matches the tracker exactly (null or '
        '> weakAccuracyM); cooldown throttles repeats', () async {
      expect(amapNaviLocationIsWeak(null), isTrue);
      expect(amapNaviLocationIsWeak(80), isTrue);
      expect(amapNaviLocationIsWeak(NavigationTracker.weakAccuracyM), isFalse);
      expect(amapNaviLocationIsWeak(10), isFalse);

      final DateTime now = DateTime.fromMillisecondsSinceEpoch(0);
      const AmapNaviLocationSample weak = AmapNaviLocationSample(
        latitude: 37.7244,
        longitude: 120.4417,
        accuracyM: 90,
      );
      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        const <AmapNaviMockStep>[
          AmapNaviMockStep.location(weak),
          AmapNaviMockStep.location(weak),
          AmapNaviMockStep.location(weak),
        ],
        clock: () => now,
      );
      final List<NavEvent> got = <NavEvent>[];
      final sub = s.source.events.listen(got.add);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isTrue);
      await _flush();
      expect(got.length, 1, reason: 'same-instant repeats are throttled');
      expect(got.single.kind, NavEventKind.weakSignal);
      expect(got.single.text, amapNaviWeakSignalText);
      await sub.cancel();
      await s.source.dispose();
    });

    test('arrived / yaw texts are the tracker\'s own texts '
        '(pinned against a real tracker drive)', () async {
      // Tracker-side ground truth for the same destination.
      final NavigationTracker tracker = _demoTracker();
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      final List<NavEvent> trackerEvents = <NavEvent>[
        ...tracker.onFix(NavFix(
            point: const GeoPoint(latitude: 37.724409, longitude: 120.441723),
            accuracyM: 90,
            at: t0)),
        ...tracker.onFix(NavFix(
            point: const GeoPoint(latitude: 37.725666, longitude: 120.442064),
            accuracyM: 10,
            at: t0.add(const Duration(seconds: 10)))),
        ...tracker.onFix(NavFix(
            point: const GeoPoint(latitude: 37.725711, longitude: 120.442064),
            accuracyM: 10,
            at: t0.add(const Duration(seconds: 20)))),
        ...tracker.onFix(NavFix(
            point: _destPoint, accuracyM: 10, at: t0.add(const Duration(seconds: 30)))),
      ];
      final String trackerWeak =
          trackerEvents.firstWhere((NavEvent e) => e.kind == NavEventKind.weakSignal).text;
      final String trackerOff =
          trackerEvents.firstWhere((NavEvent e) => e.kind == NavEventKind.offRoute).text;
      final String trackerArr =
          trackerEvents.firstWhere((NavEvent e) => e.kind == NavEventKind.arrived).text;
      expect(trackerWeak, amapNaviWeakSignalText);
      expect(trackerOff, amapNaviOffRouteText);
      expect(trackerArr, amapNaviArrivedText(_destName));
      expect(trackerArr, '已到达$_destName附近，进入入口指引。');

      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        const <AmapNaviMockStep>[
          AmapNaviMockStep.yaw(),
          AmapNaviMockStep.arrived(),
        ],
      );
      final List<NavEvent> got = <NavEvent>[];
      final sub = s.source.events.listen(got.add);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isTrue);
      await _flush();
      expect(
        got.map((NavEvent e) => (e.kind, e.text)).toList(),
        <(NavEventKind, String)>[
          (NavEventKind.offRoute, trackerOff),
          (NavEventKind.arrived, trackerArr),
        ],
      );
      await sub.cancel();
      await s.source.dispose();
    });
  });

  group('(b) source equivalence over one scripted sequence', () {
    test('Web-source events and TBT mock-source events produce '
        'the identical spoken sequence, item by item', () async {
      final DateTime t0 = DateTime.fromMillisecondsSinceEpoch(0);
      NavFix fix(double lat, double lng, double? acc, int s) => NavFix(
            point: GeoPoint(latitude: lat, longitude: lng),
            accuracyM: acc,
            at: t0.add(Duration(seconds: s)),
          );

      // ---- Web source: the tracker over the demo-shaped route.
      final NavigationTracker tracker = _demoTracker();
      final List<NavEvent> webEvents = <NavEvent>[
        // Weak fix first: unusable accuracy.
        ...tracker.onFix(fix(37.724409, 120.441723, 90, 0)),
        // Good fix at the start point: baseline, no event.
        ...tracker.onFix(fix(37.724409, 120.441723, 10, 5)),
        // 25 m before the step-2 start: the turn prompt.
        ...tracker.onFix(fix(37.725083, 120.441723, 10, 15)),
        // Two sustained off-route fixes: the off-route event.
        ...tracker.onFix(fix(37.725666, 120.442064, 10, 25)),
        ...tracker.onFix(fix(37.725711, 120.442064, 10, 35)),
        // Back at the destination with a trustworthy fix.
        ...tracker.onFix(fix(37.725307, 120.442290, 10, 45)),
      ];

      // ---- TBT source: the mock over the same beats.
      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        <AmapNaviMockStep>[
          const AmapNaviMockStep.location(AmapNaviLocationSample(
            latitude: 37.724409,
            longitude: 120.441723,
            accuracyM: 90,
          )),
          AmapNaviMockStep.info(_info(pathM: 160, pathS: 125, stepM: 100, stepS: 75, step: 0)),
          const AmapNaviMockStep.text('左转进入林荫道'),
          const AmapNaviMockStep.yaw(),
          AmapNaviMockStep.info(_info(pathM: 10, pathS: 8, stepM: 10, stepS: 8, step: 1)),
          const AmapNaviMockStep.arrived(),
        ],
        clock: () => t0,
      );
      final List<NavEvent> tbtEvents = <NavEvent>[];
      final sub = s.source.events.listen(tbtEvents.add);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isTrue);
      await _flush();

      final List<(String, String)> webSpoken =
          _spokenFor(webEvents, RerouteBudget());
      final List<(String, String)> tbtSpoken =
          _spokenFor(tbtEvents, RerouteBudget());
      const List<(String, String)> expected = <(String, String)>[
        ('info', 'GPS 信号较差，定位可能不准，导航提示仅供参考。'),
        ('turn', '左转进入林荫道'),
        ('info', '你已偏离路线，正在重新规划。'),
        ('hand-over', '已到达图书馆附近，进入入口指引。'),
      ];
      expect(webSpoken, expected,
          reason: 'the Web drive itself must hit every beat');
      expect(tbtSpoken, expected,
          reason: 'the TBT drive must hit the same beats');
      expect(tbtSpoken, webSpoken,
          reason: 'item-by-item identical spoken sequences');

      // Structured remaining distance: the TBT source's
      // state ends at the last info sample's
      // pathRetainDistance; the tracker's ends at its
      // own route accounting.
      expect(s.source.remainingM, 10.0);
      expect(tracker.remainingM, 0.0);
      await sub.cancel();
      await s.source.dispose();
    });
  });

  group('(c) switch off: never constructed, behaviour unchanged', () {
    test('AppConfig.amapNaviEnabled defaults OFF', () {
      expect(AppConfig.amapNaviEnabled, isFalse);
    });

    test('production wiring constructs the source only under '
        'the switch, and the mock is not wired anywhere', () {
      final String main = File('lib/main.dart').readAsStringSync();
      final int gate = main.indexOf('if (AppConfig.amapNaviEnabled)');
      final int call =
          main.indexOf('unawaited(_startAmapNaviSource(destinationName))');
      expect(gate, greaterThanOrEqualTo(0));
      expect(call, greaterThan(gate),
          reason: 'the only start call sits inside the switch gate');
      expect(main.contains('AmapNaviSource(binding: createAmapNaviBinding())'),
          isTrue);
      // Test support stays test support: main never
      // references the mock source.
      expect(main.contains('amap_navi_mock'), isFalse);
      expect(main.contains('MockAmapNavi'), isFalse);
      // And no lib file imports the mock at all (the
      // facade mentions the mock file in a doc comment;
      // the pin is on import lines, not mentions).
      for (final FileSystemEntity f
          in Directory('lib').listSync(recursive: true)) {
        if (f is File && f.path.endsWith('.dart') &&
            !f.path.endsWith('amap_navi_mock_source.dart')) {
          final bool importsMock = f
              .readAsStringSync()
              .split('\n')
              .any((String line) =>
                  line.trimLeft().startsWith('import') &&
                  line.contains('amap_navi_mock_source'));
          expect(importsMock, isFalse,
              reason: '${f.path} must not import the mock source');
        }
      }
    });

    test('the factory in this build yields the unavailable stub',
        () {
      expect(createAmapNaviBinding(), isA<UnavailableAmapNaviBinding>());
    });
  });

  group('(d) switch on, stub binding: fallback, fixed log, '
      'no crash, no new speech', () {
    test('start reports failure, stays inactive, emits nothing; '
        'stop and re-start are safe', () async {
      final AmapNaviSource source =
          AmapNaviSource(binding: createAmapNaviBinding());
      final List<NavEvent> got = <NavEvent>[];
      final sub = source.events.listen(got.add);
      expect(
          await source.start(
              destination: _destPoint, destinationName: _destName),
          isFalse);
      expect(source.isActive, isFalse);
      expect(source.remainingM, isNull);
      await _flush();
      expect(got, isEmpty);
      await source.stop();
      expect(
          await source.start(
              destination: _destPoint, destinationName: _destName),
          isFalse);
      await sub.cancel();
      await source.dispose();
    });

    test('a scripted initialize failure behaves the same way',
        () async {
      final ScriptedAmapNaviScenario s = ScriptedAmapNaviScenario(
        const <AmapNaviMockStep>[AmapNaviMockStep.text('前方右转')],
        failInitialize: true,
      );
      final List<NavEvent> got = <NavEvent>[];
      final sub = s.source.events.listen(got.add);
      expect(await s.source.start(destination: _destPoint, destinationName: _destName),
          isFalse);
      expect(s.binding.initializeCalls, 1);
      expect(s.binding.startCalls, 0,
          reason: 'a failed initialize never reaches start');
      await _flush();
      expect(got, isEmpty);
      await sub.cancel();
      await s.source.dispose();
    });

    test('the wiring fallback is exactly the fixed log line and '
        'contains no speech call', () {
      final String main = File('lib/main.dart').readAsStringSync();
      const String logLine = '高德 TBT 导航源启动失败，已回退 Web 源导航';
      expect(main.split(logLine).length - 1, 1,
          reason: 'the fallback log line exists exactly once');
      final int begin = main.indexOf('Future<void> _startAmapNaviSource');
      final int end = main.indexOf('void _onLiveNavFix', begin);
      final String body = main.substring(begin, end);
      expect(body.contains("mingtuVoiceLog('$logLine')"), isTrue);
      expect(body.contains('_say('), isFalse,
          reason: 'the fallback path speaks nothing new');
      expect(body.contains('_request('), isFalse);
    });
  });

  group('(e) both M3 switches off: neither new source exists', () {
    test('both build-time switches read OFF in the test build', () {
      expect(AppConfig.potholeEnabled, isFalse);
      expect(AppConfig.amapNaviEnabled, isFalse);
    });

    test('each construction sits behind its own switch gate', () {
      final String main = File('lib/main.dart').readAsStringSync();
      final int pitGate = main.indexOf('if (AppConfig.potholeEnabled)');
      final int pitMake =
          main.indexOf('createPotholeDetector(AppConfig.potholeModelPath)');
      expect(pitGate, greaterThanOrEqualTo(0));
      expect(pitMake, greaterThan(pitGate));
      final int tbtGate = main.indexOf('if (AppConfig.amapNaviEnabled)');
      final int tbtMake =
          main.indexOf('AmapNaviSource(binding: createAmapNaviBinding())');
      expect(tbtGate, greaterThanOrEqualTo(0));
      expect(tbtMake, greaterThan(tbtGate));
    });
  });
}

/// The demo-shaped two-step route used by the tracker
/// drives above: 100 m straight north, then 60 m east
/// to the destination (the campus demo route's shape,
/// synthetic coordinates).
NavigationTracker _demoTracker() {
  const GeoPoint a = GeoPoint(latitude: 37.724409, longitude: 120.441723);
  const GeoPoint b = GeoPoint(latitude: 37.725307, longitude: 120.441723);
  return NavigationTracker(
    steps: const <AmapStep>[
      AmapStep(
        action: '直行',
        orientation: '北',
        polyline: <GeoPoint>[a, b],
        distanceM: 100,
        durationS: 75,
      ),
      AmapStep(
        action: '左转',
        orientation: '东',
        polyline: <GeoPoint>[b, _destPoint],
        distanceM: 60,
        durationS: 45,
      ),
    ],
    stepTexts: const <String>['沿当前道路直行', '左转进入林荫道'],
    destination: _destPoint,
    destinationName: _destName,
  );
}
