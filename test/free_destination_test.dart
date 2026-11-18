/// Free-destination round: the app must navigate to whatever place the
/// user NAMES, from wherever the user IS.
///
/// The two complaints this file pins down:
///   1. 「这个软件只能在固定位置」 -- the 300 m demo-proximity gate is
///      gone; a fix 1000 km from the repository's demo coordinates still
///      starts (see `RealNavigationStarter.startNearby`);
///   2. 「目的地为用户的地点」 -- 「带我去药店」 is a navigation request,
///      not a single hard-coded library word. The place name comes from
///      the transcript, the coordinate from the nearby search.
///
/// Everything is local: no real API call, no real GPS, no key.
library;

import 'dart:convert';

import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';
import 'package:test/test.dart';

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

/// ~1000 km from the shipped registry's demo start point (Hangzhou), so
/// any test that succeeds here proves the position is not restricted.
const GeoPoint _beijingFix =
    GeoPoint(latitude: 39.900000, longitude: 116.400000);

class FakeLocation implements CurrentLocationProvider {
  final LocationResult result;
  FakeLocation(this.result);
  @override
  Future<LocationResult> currentLocation() async => result;

  @override
  Future<bool> ensurePermission() async => true;

  @override
  Stream<LocationResult> positions() => const Stream<LocationResult>.empty();
}

Map<String, Object?> _poi(String name, String lonLat, Object? distance) =>
    <String, Object?>{
      'name': name,
      'location': lonLat,
      'distance': distance,
    };

String _poiBody(List<Map<String, Object?>> pois) =>
    jsonEncode(<String, Object?>{'status': '1', 'pois': pois});

/// Records the endpoints the starter hit, and answers per path so a test
/// can prove WHICH one was (and was not) called.
class RecordingSender {
  final List<String> paths = <String>[];
  final List<Uri> urls = <Uri>[];
  final String poiBody;

  RecordingSender({required this.poiBody});

  Future<String> call(Uri url) async {
    paths.add(url.path);
    urls.add(url);
    if (url.path.endsWith('/place/around')) return poiBody;
    return _walkBody;
  }

  int countOf(String suffix) => paths.where((p) => p.endsWith(suffix)).length;

  Uri? get lastSearch => urls.where((u) => u.path.endsWith('/place/around')).isEmpty
      ? null
      : urls.lastWhere((u) => u.path.endsWith('/place/around'));
}

RealNavigationStarter _starter(RecordingSender sender) => RealNavigationStarter(
      locationProvider: FakeLocation(LocationResult.fix(_beijingFix, 12)),
      client: AmapWalkingClient(
        proxyBaseUrl: 'https://proxy.example.test',
        sender: sender.call,
      ),
    );

void main() {
  group('「带我去X」 is a navigation request for ANY place', () {
    test('带我去药店 -> startPlace, with 药店 as the place', () {
      expect(parseVoiceCommand('带我去药店'), VoiceCommand.startPlace);
      expect(parseDestinationPhrase('带我去药店'), '药店');
    });

    test('trailing fillers, punctuation and polite prefixes are stripped', () {
      expect(parseDestinationPhrase('去超市吧'), '超市');
      expect(parseDestinationPhrase('我要去地铁站。'), '地铁站');
      expect(parseDestinationPhrase('我想去药店'), '药店');
      expect(parseDestinationPhrase('到北京大学第三医院'), '北京大学第三医院');
      // 吧/了 are kept when they are part of the word: 网吧 is a place,
      // 网 is not.
      expect(parseDestinationPhrase('带我去网吧'), '网吧');
    });

    test('a negated destination is NOT a destination', () {
      for (final String phrase in <String>['我不去药店了', '别去药店', '我不想去药店']) {
        expect(parseDestinationPhrase(phrase), isNull, reason: phrase);
        expect(parseVoiceCommand(phrase), isNot(VoiceCommand.startPlace),
            reason: phrase);
      }
    });

    test('a question is NOT a destination', () {
      for (final String phrase in <String>[
        '我要不要去药店',
        '去药店吗',
      ]) {
        expect(parseDestinationPhrase(phrase), isNull, reason: phrase);
        expect(parseVoiceCommand(phrase), isNot(VoiceCommand.startPlace),
            reason: phrase);
      }
      // A trailing ？ is only visible on the RAW text, and
      // parseVoiceCommand deliberately strips punctuation before matching
      // (that is what makes 「停。」 a stop). The guard therefore lives in
      // parseDestinationPhrase, which main.dart calls with the raw
      // transcript.
      expect(parseDestinationPhrase('带我去药店？'), isNull);
      expect(parseDestinationPhrase('带我去药店?'), isNull);
    });

    test('other commands keep their own meaning', () {
      expect(parseVoiceCommand('停下'), VoiceCommand.pause);
      expect(parseVoiceCommand('取消'), VoiceCommand.cancel);
      expect(parseVoiceCommand('紧急求助'), VoiceCommand.emergency);
      // A destination-shaped sentence carrying another command's word is
      // not a place: 「去停下」 must not send the user to a landmark
      // called 停下.
      expect(parseDestinationPhrase('去停下'), isNull);
    });

    test('an empty or oversized place is refused, never guessed', () {
      expect(parseDestinationPhrase('带我去'), isNull);
      expect(parseDestinationPhrase('去'), isNull);
      expect(parseDestinationPhrase(''), isNull);
      expect(parseDestinationPhrase('   '), isNull);
      expect(parseDestinationPhrase('带我去${'图' * 21}'), isNull);
      // 20 characters is still allowed.
      expect(parseDestinationPhrase('带我去${'图' * 20}'), '图' * 20);
    });

    test('a bare place name is NOT a command (it answers the question)', () {
      // The destination question consumes bare names; the command parser
      // must not turn every noun into a trip.
      expect(parseVoiceCommand('药店'), VoiceCommand.unknown);
      expect(parseVoiceCommand('图书馆'), VoiceCommand.startLibrary);
      expect(parseVoiceCommand('今天天气怎么样'), VoiceCommand.unknown);
      expect(parseVoiceCommand('我要停车'), VoiceCommand.unknown);
    });
  });

  group('the position is not restricted (300 m gate is gone)', () {
    test('startNearby(药店) succeeds 1000 km from the demo start', () async {
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('同仁堂药店', '116.401000,39.900800', '120'),
        ]),
      );
      final RealNavigationOutcome outcome =
          await _starter(sender).startNearby('药店');

      expect(outcome.ready, isTrue, reason: '${outcome.failure}');
      expect(outcome.viaNearbySearch, isTrue);
      // The user's own word is the search keyword, and the search runs
      // around the CURRENT fix with the fixed 3 km radius. No registry
      // entry is consulted, so nothing fixes the position.
      expect(sender.lastSearch!.queryParameters['keywords'], '药店');
      expect(sender.lastSearch!.queryParameters['location'],
          '116.400000,39.900000');
      expect(sender.lastSearch!.queryParameters['radius'], '3000');
      expect(outcome.destination!.name, '同仁堂药店');
    });

    test('nothing within 3 km -> not found, and NO route is requested',
        () async {
      // The only POI the service knows about is 5 km away: the client
      // drops anything beyond the radius, so the answer is "not found"
      // -- not a 5 km walk, and not a widened radius.
      final RecordingSender sender = RecordingSender(
        poiBody: _poiBody(<Map<String, Object?>>[
          _poi('远处药店', '116.450000,39.950000', '5000'),
        ]),
      );
      final RealNavigationOutcome outcome =
          await _starter(sender).startNearby('药店');

      expect(outcome.failure, RealNavigationFailure.nearbyPlaceNotFound);
      expect(sender.countOf('/walking'), 0,
          reason: 'without a destination there is nothing to route to');
      expect(sender.lastSearch!.queryParameters['radius'], '3000',
          reason: 'the radius is not widened when nothing is found');
    });
  });

  group('failure texts name the place the user asked for', () {
    test('「附近没有找到药店」 speaks 药店, never 图书馆', () async {
      final RecordingSender sender =
          RecordingSender(poiBody: _poiBody(<Map<String, Object?>>[]));
      final RealNavigationOutcome outcome =
          await _starter(sender).startNearby('药店');

      expect(outcome.failure, RealNavigationFailure.nearbyPlaceNotFound);
      final String text = outcome.failureAnnouncement;
      expect(text, contains('没有找到药店'));
      expect(text, isNot(contains('图书馆')),
          reason: 'a user who said 药店 must not be told to say '
              '「带我去图书馆」: $text');
      // The retry hint offers the same place back, and only a UI action.
      expect(text, contains('带我去药店'));
      expect(text, contains('按住屏幕下方'));
      expect(containsBannedWord(text), isFalse, reason: text);
      for (final String step in <String>['左', '右', '转', '向前', '直走', '安全']) {
        expect(text, isNot(contains(step)), reason: text);
      }
    });

    test('a search failure names 药店 too', () async {
      final RealNavigationOutcome outcome = await RealNavigationStarter(
        locationProvider: FakeLocation(LocationResult.fix(_beijingFix, 12)),
        client: AmapWalkingClient(
          proxyBaseUrl: 'https://proxy.example.test',
          sender: (Uri url) async {
            if (url.path.endsWith('/place/around')) {
              throw Exception('network down');
            }
            return _walkBody;
          },
        ),
      ).startNearby('药店');
      expect(outcome.failure, RealNavigationFailure.nearbyPlaceSearchFailed);
      final String text = outcome.failureAnnouncement;
      expect(text, contains('带我去药店'));
      expect(text, isNot(contains('图书馆')));
      expect(containsBannedWord(text), isFalse, reason: text);
    });

    test('with no place known the hint asks for the destination', () {
      // A failure that never resolved a place (no destination, no
      // category) cannot name one -- and must not name the library
      // either.
      final String text = RealNavigationOutcome.failed(
        RealNavigationFailure.locationFailed,
      ).failureAnnouncement;
      expect(text, contains('再说一次你的目的地'));
      expect(text, isNot(contains('图书馆')));
    });
  });
}
