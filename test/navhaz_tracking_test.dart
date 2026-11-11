/// NAVHAZ M1, spec section 2.2: tracking semantics that
/// BOTH backends must honour identically -- confirmation is
/// three CONSECUTIVE hits (never the cumulative counter),
/// a lost target keeps its ID for up to 5 missed frames,
/// and the sample ring holds at most 30 frames.
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/navhaz_config.dart';
import 'package:mingtu_ai/core/tracking/tracker.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'navhaz_fixture_harness.dart';

Detection carAt(double cx, {double s = 0.2}) => Detection(
      label: 'car',
      confidence: 0.9,
      cx: cx,
      cy: 0.55,
      w: s,
      h: s,
    );

void main() {
  final DateTime epoch = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime at(int ms) => epoch.add(Duration(milliseconds: ms));

  for (final String backend in kBackends) {
    group('tracker backend $backend', () {
      test('confirmation needs 3 consecutive hits, not 3 total', () {
        final Tracker tracker = trackerForBackend(backend);
        // hit, miss, hit, hit: cumulative 3 but never 3 in a
        // row -> still unconfirmed.
        tracker.update(<Detection>[carAt(0.5)], at(0));
        tracker.update(const <Detection>[], at(100));
        tracker.update(<Detection>[carAt(0.5)], at(200));
        List<Track> tracks = tracker.update(<Detection>[carAt(0.5)], at(300));
        expect(tracks, hasLength(1));
        expect(tracks.single.hits, 3,
            reason: 'cumulative hits reach 3 across the gap');
        expect(tracks.single.consecutiveHits, 2);
        expect(tracks.single.confirmed, isFalse,
            reason: 'a gap resets the consecutive run');
        // Third consecutive hit confirms.
        tracks = tracker.update(<Detection>[carAt(0.5)], at(400));
        expect(tracks.single.consecutiveHits, 3);
        expect(tracks.single.confirmed, isTrue);
      });

      test('lost ID is retained for 5 missed frames, then dropped', () {
        final Tracker tracker = trackerForBackend(backend);
        tracker.update(<Detection>[carAt(0.5)], at(0));
        tracker.update(<Detection>[carAt(0.5)], at(100));
        final List<Track> confirmed =
            tracker.update(<Detection>[carAt(0.5)], at(200));
        final int id = confirmed.single.id;
        // 5 missed frames: still the same track object / ID.
        List<Track> tracks = confirmed;
        for (int i = 1; i <= NavHazConfig.lostRetentionFrames; i++) {
          tracks = tracker.update(const <Detection>[], at(200 + i * 100));
        }
        expect(tracks.map((Track t) => t.id), contains(id),
            reason: 'retained through the full lost window');
        expect(tracks.single.lostFrames, NavHazConfig.lostRetentionFrames);
        // 6th missed frame: gone.
        tracks = tracker.update(const <Detection>[], at(900));
        expect(tracks.map((Track t) => t.id), isNot(contains(id)));
        // A reappearing target is a NEW track.
        final List<Track> back =
            tracker.update(<Detection>[carAt(0.5)], at(1000));
        expect(back.single.id, isNot(id));
      });

      test('sample ring is capped at 30 and keeps the latest', () {
        final Tracker tracker = trackerForBackend(backend);
        List<Track> tracks = const <Track>[];
        for (int i = 0; i < 40; i++) {
          tracks = tracker.update(
              <Detection>[carAt(0.5 + i * 0.001)], at(i * 100));
        }
        expect(tracks.single.samples.length,
            NavHazConfig.sampleBufferFrames);
        expect(tracks.single.samples.last.cx, closeTo(0.539, 0.01));
        expect(tracks.single.hits, 40);
      });

      test('two targets keep separate IDs', () {
        final Tracker tracker = trackerForBackend(backend);
        List<Track> tracks = const <Track>[];
        for (int i = 0; i < 4; i++) {
          tracks = tracker.update(
            <Detection>[carAt(0.3), carAt(0.7)],
            at(i * 100),
          );
        }
        expect(tracks, hasLength(2));
        expect(tracks.map((Track t) => t.id).toSet(), hasLength(2));
        expect(tracks.every((Track t) => t.confirmed), isTrue);
      });

      test('a track is never extended by another class', () {
        // Association is per class on both backends (the
        // byte_track_dart matcher is class-blind, so its
        // backend runs one package tracker per class; SORT
        // compares labels). An overlapping car detection
        // must start a CAR track, not hijack the person one:
        // the hazard rules are class rules.
        final Tracker tracker = trackerForBackend(backend);
        for (int i = 0; i < 3; i++) {
          tracker.update(
            const <Detection>[
              Detection(
                  label: 'person',
                  confidence: 0.9,
                  cx: 0.5,
                  cy: 0.7,
                  w: 0.2,
                  h: 0.4),
            ],
            at(i * 100),
          );
        }
        final List<Track> tracks = tracker.update(
          const <Detection>[
            Detection(
                label: 'car',
                confidence: 0.9,
                cx: 0.5,
                cy: 0.55,
                w: 0.45,
                h: 0.45),
          ],
          at(300),
        );
        final Track person =
            tracks.firstWhere((Track t) => t.label == 'person');
        final Track car = tracks.firstWhere((Track t) => t.label == 'car');
        expect(person.id, isNot(car.id));
        expect(person.consecutiveHits, 0,
            reason: 'the person track only lost a frame');
        expect(car.hits, 1);
        expect(car.samples.single.cx, closeTo(0.5, 0.05));
      });

      test('factory honours the configured default backend', () {
        final Tracker t = createTracker();
        expect(t.runtimeType.toString(),
            NavHazConfig.trackerBackend == TrackerBackend.sort
                ? 'SortBackend'
                : 'ByteTrackBackend');
      });
    });
  }

  test('jitter fixture: one stable ID per backend', () {
    for (final String backend in kBackends) {
      final FixtureRun run = runFixture('jitter_car.jsonl', backend);
      expect(run.trackIds, hasLength(1),
          reason: '$backend must never switch IDs mid-approach');
    }
  });
}
