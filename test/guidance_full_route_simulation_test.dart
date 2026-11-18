/// End-to-end guidance simulation: one trip, many legs.
///
/// This is the "does the whole thing actually guide someone"
/// check, driven entirely by hand-built geometry and hand-fed
/// fixes. It walks a four-leg route (two right turns and a left
/// turn), goes off route in the middle, has the route re-planned
/// from where the user stands, walks the rest, hands over to the
/// entrance phase and completes the trip.
///
/// Across the WHOLE trip the produced speech is collected and
/// swept once for the two things that must never appear:
/// a banned announcement word, and a raw coordinate.
///
/// Nothing here is a widget test on purpose: navigation guidance
/// is (and must stay) pure logic, so the simulation is exact and
/// runs in milliseconds.
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/core/entrance_guidance.dart';
import 'package:mingtu_ai/core/guidance/route_instruction.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/nav_event_speech.dart';
import 'package:mingtu_ai/core/navigation_tracker.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

/// Metres -> degrees at this latitude (the factor the other
/// navigation fixtures use).
const double _mPerDegLat = 111194.9;
const double _latCos = 0.7912;

GeoPoint offset(GeoPoint p, {double northM = 0, double eastM = 0}) => GeoPoint(
      latitude: p.latitude! + northM / _mPerDegLat,
      longitude: p.longitude! + eastM / _mPerDegLat / _latCos,
    );

/// Route: A --120 m N--> B --120 m E--> C --120 m N--> D --120 m E--> E.
const GeoPoint kA = GeoPoint(latitude: 37.724409, longitude: 120.441723);
final GeoPoint kB = offset(kA, northM: 120);
final GeoPoint kC = offset(kB, eastM: 120);
final GeoPoint kD = offset(kC, northM: 120);
final GeoPoint kE = offset(kD, eastM: 120);

/// The simulated compass reading on each leg (the user turns at
/// every corner, so the heading follows the leg).
double headingNorth = 0;
const double headingEast = 90;

/// Points every [stepM] metres from [from] towards [to],
/// INCLUDING both ends.
List<GeoPoint> walkLine(GeoPoint from, GeoPoint to, {double stepM = 10}) {
  final double dNorth = (to.latitude! - from.latitude!) * _mPerDegLat;
  final double dEast =
      (to.longitude! - from.longitude!) * _mPerDegLat * _latCos;
  final double length = math.sqrt(dNorth * dNorth + dEast * dEast);
  final int steps = (length / stepM).ceil();
  final List<GeoPoint> out = <GeoPoint>[];
  for (int i = 0; i <= steps; i++) {
    final double f = steps == 0 ? 0 : i / steps;
    out.add(offset(from, northM: dNorth * f, eastM: dEast * f));
  }
  return out;
}

NavigationTracker buildRoute({RerouteBudget? budget}) => NavigationTracker(
      steps: <AmapStep>[
        AmapStep(
            action: '直行',
            orientation: '北',
            polyline: <GeoPoint>[kA, kB],
            distanceM: 120,
            durationS: 90),
        AmapStep(
            action: '右转',
            orientation: '东',
            polyline: <GeoPoint>[kB, kC],
            distanceM: 120,
            durationS: 90),
        AmapStep(
            action: '左转',
            orientation: '北',
            polyline: <GeoPoint>[kC, kD],
            distanceM: 120,
            durationS: 90),
        AmapStep(
            action: '右转',
            orientation: '东',
            polyline: <GeoPoint>[kD, kE],
            distanceM: 120,
            durationS: 90),
      ],
      stepTexts: const <String>['直行', '右转', '左转', '右转'],
      destination: kE,
      destinationName: '图书馆',
      budget: budget,
    );

void main() {
  test('a four-leg trip is guided, re-planned, handed over and completed',
      () {
    final List<String> spoken = <String>[];
    final List<String> distinct = <String>[];
    void collect(String text) {
      if (text.isEmpty) return;
      spoken.add(text);
      if (distinct.isEmpty || distinct.last != text) distinct.add(text);
    }

    DateTime clock = DateTime(2026, 5, 1, 9);
    DateTime tick() {
      clock = clock.add(const Duration(seconds: 1));
      return clock;
    }

    final RerouteBudget budget = RerouteBudget();
    NavigationTracker nav = buildRoute(budget: budget);

    /// One fix through the production paths: tracker first, then
    /// the guidance instruction.
    void feed(GeoPoint p, {double headingDeg = 0, double accuracyM = 5}) {
      final DateTime at = tick();
      final List<NavEvent> events =
          nav.onFix(NavFix(point: p, accuracyM: accuracyM, at: at));
      for (final NavEvent e in events) {
        if (e.kind == NavEventKind.offRoute) {
          collect(navEventSpeech(e,
                  timestamp: 't',
                  destinationName: '图书馆',
                  rerouteDecision: RerouteDecision.doIt)
              .text);
        }
      }
      final RouteInstruction? r = nextRouteInstruction(
        nav: nav,
        fix: p,
        accuracyM: accuracyM,
        headingDeg: headingDeg,
      );
      if (r != null) collect(r.text);
    }

    // Leg 0 and leg 1: north, then east.
    for (final GeoPoint p in walkLine(kA, kB)) {
      feed(p, headingDeg: headingNorth);
    }
    for (final GeoPoint p in walkLine(kB, kC)) {
      feed(p, headingDeg: headingEast);
    }

    // The user wanders 90 m off the route (a side street).
    final GeoPoint offRoute = offset(kC, northM: 90);
    bool sawOffRoute = false;
    for (int i = 0; i < NavigationTracker.offRouteFixesNeeded; i++) {
      final DateTime at = tick();
      final List<NavEvent> events = nav.onFix(
          NavFix(point: offRoute, accuracyM: 5, at: at));
      if (events.any((NavEvent e) => e.kind == NavEventKind.offRoute)) {
        sawOffRoute = true;
        final NavEvent e =
            events.firstWhere((NavEvent x) => x.kind == NavEventKind.offRoute);
        collect(navEventSpeech(e,
                timestamp: 't',
                destinationName: '图书馆',
                rerouteDecision: RerouteDecision.doIt)
            .text);
      }
    }
    expect(sawOffRoute, isTrue, reason: 'the simulation must go off route');
    // The re-plan budget allows the first attempt...
    expect(nav.rerouteDecision(DateTime(2026, 5, 1, 9, 30)),
        RerouteDecision.doIt);

    // ...and the re-plan installs a NEW route from where the user
    // stands straight to the destination (that is what the app
    // does: `startToPoint` to the resolved POI).
    nav = NavigationTracker(
      steps: <AmapStep>[
        AmapStep(
            action: '直行',
            orientation: '东',
            polyline: <GeoPoint>[offRoute, kE],
            distanceM: 210,
            durationS: 150),
      ],
      stepTexts: const <String>['直行'],
      destination: kE,
      destinationName: '图书馆',
      // The trip-level budget survives the rebuild: a fresh
      // tracker must not hand the user a fresh set of retries.
      budget: budget,
    );
    expect(nav.rerouteDecision(DateTime(2026, 5, 1, 9, 30, 30)),
        RerouteDecision.throttled,
        reason: 'the re-plan budget is per TRIP, not per tracker');

    // Leg 2 and 3 on the NEW route: the guidance must still be
    // produced from the earliest metres of it.
    for (final GeoPoint p in walkLine(offRoute, kE, stepM: 20)) {
      if (nav.arrived) break;
      feed(p, headingDeg: headingEast);
    }

    // Hand-over to the entrance phase, then arrival.
    expect(nav.arrived, isTrue, reason: 'the trip must reach the destination');
    final EntranceGuidance guidance =
        EntranceGuidance(destinationName: '图书馆', destination: kE);
    const List<double> approachM = <double>[28, 24, 18, 14, 12];
    double metres = approachM.first;
    for (final double m in approachM) {
      metres = m;
      final GeoPoint p = offset(kE, northM: -m);
      final String? text =
          guidance.onFix(p, 10, tick(), headingDeg: headingEast);
      if (text != null) collect(text);
      if (guidance.completed) break;
    }
    expect(metres, lessThanOrEqualTo(EntranceGuidance.arriveRadiusM));
    expect(guidance.completed, isTrue, reason: 'the trip must complete');
    expect(spoken, contains(entranceArrivedSpeech));

    // ---- the assertions this simulation exists for ----
    // 1. It actually guided: several DIFFERENT instructions.
    expect(distinct.length, greaterThanOrEqualTo(3),
        reason: 'distinct instructions: $distinct');
    expect(distinct.any((String t) => t.contains('右转')), isTrue,
        reason: '$distinct');
    expect(distinct.any((String t) => t.contains('左转')), isTrue,
        reason: '$distinct');
    expect(distinct.any((String t) => t.contains('继续直走')), isTrue,
        reason: '$distinct');
    // 2. The off-route leg was announced and then re-planned.
    expect(spoken.any((String t) => t.contains('偏离路线')), isTrue,
        reason: '$spoken');
    // 3. Every sentence of the whole trip is clean.
    for (final String text in spoken) {
      expect(containsBannedWord(text), isFalse, reason: text);
      expect(RegExp(r'\d{2,3}\.\d+').hasMatch(text), isFalse, reason: text);
      expect(text, isNot(contains('://')), reason: text);
      expect(text, isNot(contains('第')), reason: 'no segment numbering: $text');
      expect(text, isNot(contains('共')), reason: 'no segment count: $text');
    }
  });

  test('the instruction stream never repeats the leg the user just walked',
      () {
    // A long straight leg: every instruction issued between the
    // two corners must refer to the turn AHEAD, never to the one
    // already taken.
    final NavigationTracker nav = buildRoute();
    final List<String> texts = <String>[];
    DateTime clock = DateTime(2026, 5, 1, 9);
    for (final GeoPoint p in walkLine(kA, kB)) {
      clock = clock.add(const Duration(seconds: 1));
      nav.onFix(NavFix(point: p, accuracyM: 5, at: clock));
      final RouteInstruction? r = nextRouteInstruction(
        nav: nav,
        fix: p,
        accuracyM: 5,
        headingDeg: headingNorth,
      );
      if (r != null) texts.add(r.text);
    }
    expect(texts, isNotEmpty);
    // 120 m before B the only meaningful thing to say is "keep
    // going, the turn is a long way off" (the shared distance
    // bands round 120 m to 100 m).
    expect(texts.first, contains('继续直走'));
    expect(RegExp(r'约\d+米').hasMatch(texts.first), isTrue,
        reason: texts.first);
    // Close to B the turn itself is announced, with the heading
    // agreeing (the user walks north into the corner).
    expect(texts.any((String t) => t.contains('右转')), isTrue,
        reason: '$texts');
    // Nothing tells the user to walk back onto the previous leg.
    for (final String t in texts) {
      expect(t, isNot(contains('向后')), reason: t);
      expect(t, isNot(contains('掉头')), reason: t);
    }
  });
}
