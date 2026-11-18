/// Hazard <-> guidance hand-back, end to end in the real app.
///
/// Three field complaints are pinned here:
///  1. after a hazard clears the user had to say 「继续」 to get
///     the next instruction -- guidance must come back by
///     itself, recomputed from the latest position;
///  2. one stationary obstacle re-announced itself forever and
///     outranked the turn prompt, so the user heard "obstacle"
///     and never heard where to go;
///  3. a hazard that would not clear produced no explanation at
///     all, only repeats.
///
/// The harness is the shared one from the push-to-talk suite: the
/// REAL app, a fake TTS channel whose utterances stay "playing"
/// until the test completes them, and a fake location / route
/// sender. No network, no GPS, no key.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:mingtu_ai/modules/visual_perception.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;

/// Two legs: A --~90 m north--> B --~75 m east--> C. Long enough
/// that the turn at B is never inside the 30 m announcement
/// radius from the start, so every guidance sentence in these
/// tests comes from the module under test, not from the
/// tracker's own turn event.
const String _twoLegWalkBody = '''
{
  "status": "1",
  "route": {
    "paths": [
      {
        "distance": "170",
        "duration": "130",
        "steps": [
          {
            "action": "直行",
            "orientation": "北",
            "polyline": "116.400000,39.900000;116.400100,39.900800",
            "distance": "90",
            "duration": "70"
          },
          {
            "action": "右转",
            "orientation": "东",
            "polyline": "116.400100,39.900800;116.401000,39.900700",
            "distance": "75",
            "duration": "60"
          }
        ]
      }
    ]
  }
}
''';

const GeoPoint _startFix =
    GeoPoint(latitude: 39.900000, longitude: 116.400000);

class FakeLocation implements CurrentLocationProvider {
  FakeLocation(this.results);

  final List<LocationResult> results;
  int calls = 0;

  @override
  Future<LocationResult> currentLocation() async {
    final int i = calls < results.length ? calls : results.length - 1;
    calls += 1;
    return results[i];
  }

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

class FakeSender {
  final List<Uri> urls = <Uri>[];

  Future<String> call(Uri url) async {
    urls.add(url);
    if (url.path.endsWith('/place/around')) {
      return jsonEncode(<String, Object?>{
        'status': '1',
        'pois': <Map<String, Object?>>[
          <String, Object?>{
            'name': '同仁堂药店',
            'location': '116.410000,39.910000',
            'distance': '120',
          },
        ],
      });
    }
    return _twoLegWalkBody;
  }
}

List<String> spokenTexts(ui.RecordingVoiceChannels h) => h.events
    .where((String e) => e.startsWith('tts.speak:'))
    .map((String e) => e.substring('tts.speak:'.length))
    .toList();

/// Complete the LAST utterance whose text contains [marker].
Future<void> completeSpeakContaining(WidgetTester tester,
    ui.RecordingVoiceChannels h, String marker) async {
  int index = -1;
  for (int i = 0; i < h.speakQueue.length; i++) {
    if (h.speakQueue[i].key.contains(marker)) index = i;
  }
  expect(index, greaterThanOrEqualTo(0),
      reason: 'no speak containing "$marker": ${h.events}');
  if (!h.speakQueue[index].value.isCompleted) {
    h.speakQueue[index].value.complete(1);
  }
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  setUp(() {
    mingtuPermissionGatewayOverride = s1.FakePermissionGateway();
    mingtuGuideStoreOverride = s1.FakeGuideStore(seen: true);
    mingtuYoloAvailableOverride = false;
  });

  tearDown(() {
    mingtuPermissionGatewayOverride = null;
    mingtuGuideStoreOverride = null;
    mingtuYoloAvailableOverride = null;
    mingtuLocationProviderOverride = null;
    mingtuYoloNowOverride = null;
  });

  /// Bring the app up and start REAL navigation to a pharmacy on
  /// the two-leg route. Speaks are completed as they appear
  /// unless [drain] is false.
  Future<ui.RecordingVoiceChannels> startNavigation(
    WidgetTester tester, {
    bool drain = true,
  }) async {
    mingtuLocationProviderOverride =
        FakeLocation(<LocationResult>[LocationResult.fix(_startFix, 12)]);
    final FakeSender sender = FakeSender();
    final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()..install();
    addTearDown(h.uninstall);
    await ui.settleRecordedApp(tester, h);
    mingtuHomeDebugHandle!.debugSetAmapClient(AmapWalkingClient(
      proxyBaseUrl: 'https://proxy.example.test',
      sender: sender.call,
    ));
    mingtuHomeDebugHandle!.voiceCommand('带我去药店');
    for (int i = 0;
        i < 80 && mingtuHomeDebugHandle!.taskState != TaskState.navigating;
        i++) {
      await tester.pump(const Duration(milliseconds: 50));
      h.completeAllSpeaks();
    }
    expect(mingtuHomeDebugHandle!.taskState, TaskState.navigating,
        reason: '${h.events}');
    // The start fix, so guidance has a position to work from.
    mingtuHomeDebugHandle!.debugLiveFix(_startFix, 12);
    await tester.pump(const Duration(milliseconds: 50));
    if (drain) {
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
    }
    return h;
  }

  /// Three confirmed frames of one stationary pedestrian dead
  /// ahead: an ordinary (non-urgent) obstacle warning.
  void feedStaticPerson() {
    for (int i = 0; i < 3; i++) {
      mingtuHomeDebugHandle!.simulateDetections(const <Detection>[
        Detection(
            label: 'person', confidence: 0.9, cx: 0.5, cy: 0.7, w: 0.2, h: 0.4),
      ]);
    }
  }

  group('guidance comes back by itself after a danger', () {
    testWidgets('the interrupted first instruction is replaced by a fresh one',
        (tester) async {
      final ui.RecordingVoiceChannels h =
          await startNavigation(tester, drain: false);
      // The first instruction must be playing right now (its
      // utterance is deliberately left open).
      expect(
        h.pendingSpeaks()
            .any((Completer<dynamic> c) => !c.isCompleted),
        isTrue,
        reason: '${h.events}',
      );
      expect(spokenTexts(h).any((String t) => t.startsWith('开始导航，先直走')),
          isTrue,
          reason: '${h.events}');

      // A danger interrupts it.
      mingtuHomeDebugHandle!.debugSpeakHazard('停，前方有车。');
      await tester.pump(const Duration(milliseconds: 50));
      expect(spokenTexts(h).last, contains('停，前方有车'));

      // The danger finishes. Nothing is left to replay (the
      // instruction's replay policy is drop on purpose), so
      // guidance must rebuild itself from the latest fix.
      await completeSpeakContaining(tester, h, '停，前方有车');
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      final List<String> texts = spokenTexts(h);
      final int dangerIdx =
          texts.indexWhere((String t) => t.contains('停，前方有车'));
      final List<String> after = texts.sublist(dangerIdx + 1);
      expect(after, isNotEmpty,
          reason: 'guidance must resume with no user request: $texts');
      expect(
        after.any((String t) => t.contains('继续直走') || t.contains('直走')),
        isTrue,
        reason: 'a fresh route instruction is expected: $texts',
      );
      // The complaint being fixed: the user was told to say
      // 「继续」. No prompt may ask for that any more.
      expect(
        texts.where((String t) => t.contains('请说继续')),
        isEmpty,
        reason: '$texts',
      );
      expect(mingtuHomeDebugHandle!.debugGuidanceDiag,
          contains('guidance_resumed'));
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
      await ui.shutdownVoice(tester, h);
    });
  });

  group('a stationary obstacle stops repeating itself', () {
    testWidgets('three identical non-urgent rounds are spoken once, and the '
        'turn prompt is no longer crowded out', (tester) async {
      final ui.RecordingVoiceChannels h = await startNavigation(tester);
      final DateTime base = DateTime.now();
      DateTime frameNow = base;
      mingtuYoloNowOverride = () => frameNow;

      // Round 1: the warning is new, so it is spoken.
      feedStaticPerson();
      await tester.pump();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
      expect(spokenTexts(h).where((String t) => t.contains('前方有行人')).length,
          1,
          reason: '${h.events}');
      expect(mingtuHomeDebugHandle!.debugRiskActive, isTrue);

      // Rounds 2 and 3: the SAME obstacle, the user not moving,
      // the range unchanged -- but the policy's own 4 s cooldown
      // has elapsed, so without the repeat gate each round would
      // be announced again.
      for (int round = 0; round < 2; round++) {
        frameNow = frameNow.add(const Duration(seconds: 5));
        feedStaticPerson();
        await tester.pump();
        for (int i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          h.completeAllSpeaks();
        }
      }
      expect(spokenTexts(h).where((String t) => t.contains('前方有行人')).length,
          1,
          reason: 'the same unchanged obstacle must not be re-announced: '
              '${h.events}');
      expect(mingtuHomeDebugHandle!.debugHazardSuppressed, isNotEmpty);
      // Suppression changes the SPEECH only: the risk state holds.
      expect(mingtuHomeDebugHandle!.debugRiskActive, isTrue);

      // And the turn instruction gets through while the obstacle
      // is still detected -- this is what used to be impossible.
      final int conflictsBefore =
          mingtuHomeDebugHandle!.debugDroppedConflicts.length;
      expect(
          mingtuHomeDebugHandle!
              .debugSayForTest(SpeechKind.turn, text: '前方约30米左转'),
          isTrue);
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
      expect(spokenTexts(h), contains('前方约30米左转'), reason: '${h.events}');
      expect(mingtuHomeDebugHandle!.debugDroppedConflicts.length,
          conflictsBefore,
          reason: 'the turn must not be dropped as a conflict');
      await ui.shutdownVoice(tester, h);
    });
  });

  group('a hazard that will not clear', () {
    testWidgets('says the navigation is paused, exactly once', (tester) async {
      final ui.RecordingVoiceChannels h = await startNavigation(tester);
      feedStaticPerson();
      await tester.pump();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
      expect(mingtuHomeDebugHandle!.debugRiskActive, isTrue);
      expect(spokenTexts(h).where((String t) => t.contains('前方情况持续')),
          isEmpty);

      // The episode is now over 15 s old (the frame clock is
      // advanced; the episode start was the real clock).
      final DateTime ahead = DateTime.now().add(const Duration(seconds: 16));
      mingtuYoloNowOverride = () => ahead;
      feedStaticPerson();
      await tester.pump();
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        h.completeAllSpeaks();
      }
      expect(spokenTexts(h).where((String t) => t.contains('前方情况持续')).length,
          1,
          reason: '${h.events}');
      expect(mingtuHomeDebugHandle!.debugGuidanceDiag,
          contains('nav_paused_no_fix'));

      // Still persisting: no second line, and never a nudge to
      // walk on.
      for (int round = 0; round < 3; round++) {
        feedStaticPerson();
        await tester.pump();
        for (int i = 0; i < 6; i++) {
          await tester.pump(const Duration(milliseconds: 50));
          h.completeAllSpeaks();
        }
      }
      expect(spokenTexts(h).where((String t) => t.contains('前方情况持续')).length,
          1,
          reason: '${h.events}');
      await ui.shutdownVoice(tester, h);
    });
  });
}
