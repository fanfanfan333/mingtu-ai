/// The first actionable instruction must survive the trip's
/// first few seconds.
///
/// The field report this file is built around: the user said a
/// destination, immediately heard an obstacle warning, and then
/// never heard where to walk. Root cause: the first step was
/// glued onto the route-ready sentence, which is the LOWEST
/// delivery class ([SpeechKind.info]); the warning interrupted
/// it, an interrupted info prompt is never replayed, and five
/// seconds later it expired.
///
/// So the two things pinned here are structural, not cosmetic:
///  1. the route-ready sentence carries NO step text;
///  2. a separate turn / straight request carries the
///     instruction, and an interruption never replays the old
///     copy verbatim.
///
/// Fixtures are local (fake location, fake Amap sender, fake
/// TTS channels); nothing here touches the network or GPS.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/task_manager.dart';
import 'package:mingtu_ai/main.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;

const String _walkBody = '''
{
  "status": "1",
  "route": {
    "paths": [
      {
        "distance": "420",
        "duration": "330",
        "steps": [
          {
            "action": "直行",
            "orientation": "北",
            "polyline": "116.400000,39.900000;116.400100,39.900800",
            "distance": "420",
            "duration": "330"
          }
        ]
      }
    ]
  }
}
''';

const GeoPoint _beijingFix =
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

String _poiBody(List<Map<String, Object?>> pois) =>
    jsonEncode(<String, Object?>{'status': '1', 'pois': pois});

class FakeSender {
  final List<Uri> urls = <Uri>[];

  Future<String> call(Uri url) async {
    urls.add(url);
    if (url.path.endsWith('/place/around')) {
      return _poiBody(<Map<String, Object?>>[
        <String, Object?>{
          'name': '同仁堂药店',
          'location': '116.410000,39.910000',
          'distance': '120',
        },
      ]);
    }
    return _walkBody;
  }
}

/// The spoken texts on the fake TTS channel, in playback order.
List<String> spokenTexts(ui.RecordingVoiceChannels h) => h.events
    .where((String e) => e.startsWith('tts.speak:'))
    .map((String e) => e.substring('tts.speak:'.length))
    .toList();

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
  });

  Future<ui.RecordingVoiceChannels> startToPharmacy(
      WidgetTester tester) async {
    mingtuLocationProviderOverride =
        FakeLocation(<LocationResult>[LocationResult.fix(_beijingFix, 12)]);
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
    return h;
  }

  Future<void> drain(WidgetTester tester, ui.RecordingVoiceChannels h) async {
    for (int i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      h.completeAllSpeaks();
    }
  }

  group('the route-ready sentence is adoption only', () {
    testWidgets('it carries no step text and is announced as info',
        (tester) async {
      final ui.RecordingVoiceChannels h = await startToPharmacy(tester);
      await drain(tester, h);

      final List<String> texts = spokenTexts(h);
      final int readyIdx = texts.indexWhere(
          (String t) => t.contains('真实步行路线'));
      expect(readyIdx, greaterThanOrEqualTo(0), reason: '$texts');
      // The summary names the place that was actually found.
      expect(texts[readyIdx], contains('同仁堂药店'));
      // ...and NOT the first step. This is the exact defect:
      // with the step glued on, one interruption destroyed it.
      expect(texts[readyIdx], isNot(contains('第一段')));
      expect(texts[readyIdx], isNot(contains('直行')));
      await ui.shutdownVoice(tester, h);
    });

    testWidgets('the source keeps the step text out of that call site',
        (tester) async {
      final String source = File('lib/main.dart').readAsStringSync();
      final int start = source.indexOf("id: 'real-nav-ready-");
      expect(start, greaterThanOrEqualTo(0));
      final int end = source.indexOf('kind: SpeechKind.info,', start);
      expect(end, greaterThan(start));
      // Comments explain the OLD defect by quoting it; the pin is
      // on the CODE, so drop comment lines first.
      final String body = source
          .substring(start, end)
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');
      expect(body, isNot(contains('第一段')));
      expect(body, isNot(contains('firstStep')));
      expect(body, isNot(contains('_amapSpeaker')));
      // The second speaker creation (which consumed step 0 and
      // made 「下一步」 repeat it) is gone: exactly one remains.
      expect(RegExp(r'_amapSpeaker = AmapStepSpeaker\(').allMatches(source),
          hasLength(1));
    });
  });

  group('the instruction is its own turn / straight request', () {
    testWidgets('it is spoken right after adoption, before the summary',
        (tester) async {
      final ui.RecordingVoiceChannels h = await startToPharmacy(tester);
      await drain(tester, h);

      final List<String> texts = spokenTexts(h);
      final int firstIdx =
          texts.indexWhere((String t) => t.startsWith('开始导航，先直走'));
      expect(firstIdx, greaterThanOrEqualTo(0), reason: '$texts');
      final int readyIdx =
          texts.indexWhere((String t) => t.contains('真实步行路线'));
      expect(readyIdx, greaterThanOrEqualTo(0), reason: '$texts');
      // The instruction is heard FIRST: it is the thing that
      // must not be lost, and as info it would have lost the
      // arbitration to any warning.
      expect(firstIdx, lessThan(readyIdx), reason: '$texts');
      // No "前方0米" nonsense at the route's own start.
      expect(texts[firstIdx], isNot(contains('前方')));
      expect(texts[firstIdx], isNot(contains('约0米')));
      expect(texts[firstIdx], isNot(contains('约1米')));

      // The delivery class is pinned by the diagnostic line,
      // which records the class the instruction was submitted
      // with.
      final String diag = mingtuHomeDebugHandle!.debugGuidanceDiag;
      expect(diag, contains('route_adopted'));
      expect(diag, contains('first_instruction_enqueued'));
      expect(diag, contains('kind=straight'), reason: diag);
      expect(diag, contains('match=matched'), reason: diag);
      await ui.shutdownVoice(tester, h);
    });
  });

  group('an interrupted first instruction is never replayed verbatim', () {
    testWidgets('a danger in the first seconds does not resurrect it',
        (tester) async {
      final ui.RecordingVoiceChannels h = await startToPharmacy(tester);
      // Let the instruction START playing but do NOT complete
      // it: it is now the active prompt.
      await tester.pump(const Duration(milliseconds: 50));
      final List<String> before = spokenTexts(h);
      expect(before.any((String t) => t.startsWith('开始导航，先直走')), isTrue,
          reason: '$before');

      // A danger arrives: it outranks the instruction and
      // interrupts it.
      mingtuHomeDebugHandle!.debugSpeakHazard('停，前方有车。');
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        mingtuHomeDebugHandle!.debugInterrupted
            .any((String id) => id.startsWith('nav-first-instruction-')),
        isTrue,
        reason: 'the instruction really was interrupted',
      );

      await drain(tester, h);
      final List<String> texts = spokenTexts(h);
      // The stale copy is NOT replayed: the instruction is
      // submitted with NavReplay.drop on purpose (a direction
      // that was true twenty metres ago must never be spoken
      // late). A replacement, if any, is recomputed instead.
      expect(
        texts.where((String t) => t.startsWith('开始导航，先直走')).length,
        1,
        reason: '$texts',
      );
      // And guidance is not left dangling: something about the
      // route comes back after the danger clears.
      expect(texts.last, isNot(contains('停，前方有车')));
      await ui.shutdownVoice(tester, h);
    });
  });
}
