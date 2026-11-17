import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/location_signal_speech.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

import 'support/posix_bash.dart';

class _LocationPlatform extends GeolocatorPlatform {
  _LocationPlatform(this.error, this.stream);
  final Object error;
  final Stream<Position> stream;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.whileInUse;
  @override
  Future<Position> getCurrentPosition(
          {LocationSettings? locationSettings}) async =>
      throw error;
  @override
  Stream<Position> getPositionStream({LocationSettings? locationSettings}) =>
      stream;
}

void _speak(String text, {SpeechKind kind = SpeechKind.alert}) {
  expect(text, isNot(contains('安全')));
  expect(text, isNot(contains('可以过马路')));
  final now = DateTime(2026);
  final scheduler = SpeechScheduler();
  expect(
      scheduler.submit(
          SpeechRequest(
              id: 'fault',
              eventId: 'fault',
              text: text,
              kind: kind,
              createdAt: now,
              expiresAt: now.add(const Duration(minutes: 1)),
              navigationStateVersion: ''),
          now),
      isTrue);
  expect(scheduler.active?.text, text);
  expect(scheduler.active?.kind, kind);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GeolocatorPlatform original;
  setUp(() => original = GeolocatorPlatform.instance);
  tearDown(() => GeolocatorPlatform.instance = original);

  test('Dart sources avoid background location settings', () {
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      final source = file.readAsStringSync();
      expect(source, isNot(contains('foregroundNotificationConfig')),
          reason: file.path);
      expect(source, isNot(contains('enableBackgroundMode')),
          reason: file.path);
    }
  });

  // Resolved once; `null` means this host has no runnable POSIX bash (e.g. a
  // Windows box whose only `bash` is the WSL stub). The case is then skipped
  // explicitly instead of asserting on a script that never ran.
  final posixBash = findUsableBash();

  test('manifest checker validates permissions and services', () {
    // Guarded by the skip below: this body only runs when
    // findUsableBash() actually found a shell that can run BOTH the
    // script and its external tools (dirname + python3). See
    // test/support/posix_bash.dart -- a bare `echo ok` probe is not
    // enough, because `echo` is a built-in.
    final bash = posixBash!;
    final script = File('tool/check_release_manifest.sh').readAsStringSync();
    expect(script, contains('processReleaseMainManifest'));
    expect(script, contains('android.permission.FOREGROUND_SERVICE_LOCATION'));
    expect(script, contains('android.permission.ACCESS_BACKGROUND_LOCATION'));
    expect(script, contains('android.permission.RECEIVE_BOOT_COMPLETED'));
    final dir = Directory.systemTemp.createTempSync('mingtu-manifest-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/AndroidManifest.xml');
    ProcessResult check(String body) {
      file.writeAsStringSync(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">$body</manifest>');
      return Process.runSync(
          bash, ['tool/check_release_manifest.sh', file.path]);
    }

    const geo =
        '<service android:name="com.baseflow.geolocator.GeolocatorLocationService" android:foregroundServiceType="location"/>';
    final legal =
        check('<application>$geo<service android:name="other"/></application>');
    expect(legal.exitCode, 0, reason: '${legal.stdout} ${legal.stderr}');
    expect(legal.stdout, contains('GeolocatorLocationService'));
    for (final body in [
      '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/><application>$geo</application>',
      '<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/><application>$geo</application>',
      '<application>$geo<receiver android:name="androidx.work.impl.background.systemalarm.RescheduleReceiver"/></application>',
      '<application>$geo<receiver android:name="other"><intent-filter><action android:name="android.intent.action.BOOT_COMPLETED"/></intent-filter></receiver></application>',
      '<application>$geo<service android:name="other" android:foregroundServiceType="dataSync"/></application>',
      '<application><service android:name="com.baseflow.geolocator.GeolocatorLocationService" android:foregroundServiceType="dataSync"/></application>',
      '<application/>',
    ]) {
      expect(check(body).exitCode, isNot(0));
    }
    final merged = Directory('build/app/intermediates/merged_manifest/release');
    final apk = File('build/app/outputs/flutter-apk/app-release.apk');
    if ((merged.existsSync() &&
            merged
                .listSync(recursive: true)
                .whereType<File>()
                .any((f) => f.path.endsWith('AndroidManifest.xml'))) ||
        apk.existsSync()) {
      final result = Process.runSync(bash, ['tool/check_release_manifest.sh']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
  }, skip: posixBash == null
      ? 'no usable POSIX bash (needs dirname/find/sort/tail/grep + python3) '
          'on this host'
      : null);

  for (final error in [
    PlatformException(code: 'location'),
    Exception('SecurityException')
  ]) {
    test('location exceptions become failures: ${error.runtimeType}', () async {
      final controller = StreamController<Position>();
      addTearDown(controller.close);
      GeolocatorPlatform.instance = _LocationPlatform(error, controller.stream);
      const provider = GeolocatorCurrentLocation();
      expect(
          (await provider.currentLocation()).failure, LocationFailure.failed);
      final starter = RealNavigationStarter(
          locationProvider: provider,
          client: AmapWalkingClient(
              proxyBaseUrl: 'https://proxy.example.test',
              sender: (_) async => throw StateError('unexpected request')),
          registry: const [
            VerifiedLocation(
                id: 'test',
                name: '图书馆',
                pointGcj02: GeoPoint(latitude: 39.9, longitude: 116.4))
          ]);
      final outcome = await starter.start('图书馆');
      expect(outcome.failure, RealNavigationFailure.locationFailed);
      // Pinned verbatim (real-device fix round): the old text said
      // "请到开阔处稍后重试", which asks a blind user to judge
      // "开阔" by eye and gives no next action. The rewrite keeps
      // "stay put", gives only a UI action (speak again) and, as a
      // last resort, asks a nearby PERSON for help -- never a
      // walking direction.
      expect(
          outcome.failureAnnouncement,
          '定位失败：还没拿到你的位置，导航未启动。'
          '请留在原地不要走动，等十几秒后再按住屏幕下方说一次“带我去图书馆”。'
          '如果连着几次都不行，可以请身边的人带你到室外再试。');
      _speak(outcome.failureAnnouncement);
      final results = <LocationResult>[];
      final subscription = provider.positions().listen(results.add);
      controller.addError(error);
      await Future<void>.delayed(Duration.zero);
      expect(results.single.failure, LocationFailure.failed);
      const text = locationSignalLostText;
      expect(File('lib/main.dart').readAsStringSync(),
          contains('text: locationSignalLostText'));
      _speak(text, kind: SpeechKind.alert);
      await subscription.cancel();
    });
  }

  test('silent location stream stalls at 30 seconds and callbacks postpone it',
      () {
    var now = DateTime(2026);
    final faults = <String>[];
    final watchdog = ForegroundWatchdog(
        now: () => now,
        onFault: (text) {
          faults.add(text);
          _speak(text);
        });
    void update() =>
        watchdog.update(foreground: true, camera: false, location: true);
    update();
    now = now.add(const Duration(seconds: 29));
    update();
    expect(faults, isEmpty);
    now = now.add(const Duration(seconds: 1));
    update();
    expect(faults, [foregroundLocationStallText]);
    watchdog.locationCallback();
    now = now.add(const Duration(seconds: 29));
    update();
    expect(faults, hasLength(1));
    watchdog.locationCallback();
    now = now.add(const Duration(seconds: 29));
    update();
    expect(faults, hasLength(1));
    now = now.add(const Duration(seconds: 1));
    update();
    expect(faults, hasLength(2));
  });

  // Real-device fix round: the two location-failure announcements
  // are pinned verbatim AND checked against the banned-word guard.
  //
  // History: the ORIGINAL texts said "请到开阔处稍后重试" (a blind
  // user cannot judge "开阔" by eye). The first rewrite then said
  // "请先站在原地不要走动，再走到室外或者靠窗的地方" -- which
  // contradicted itself (stand still AND walk out) and told a user
  // who cannot see the way to walk outside unaided. The current
  // texts keep "stay put", give only a UI action (hold the lower
  // part of the screen to speak again) and, as a last resort,
  // ASK A NEARBY PERSON for help -- never a walking direction.
  group('location failure texts are pinned, actionable and banned-clean',
      () {
    const String failedText = '定位失败：还没拿到你的位置，导航未启动。'
        '请留在原地不要走动，等十几秒后再按住屏幕下方说一次“带我去图书馆”。'
        '如果连着几次都不行，可以请身边的人带你到室外再试。';

    String tooInaccurateText(double? accuracyM) =>
        RealNavigationOutcome.failed(
          RealNavigationFailure.locationTooInaccurate,
          accuracyM: accuracyM,
        ).failureAnnouncement;

    test('locationFailed is pinned verbatim', () {
      expect(
          RealNavigationOutcome.failed(RealNavigationFailure.locationFailed)
              .failureAnnouncement,
          failedText);
    });

    test('locationTooInaccurate keeps the accuracy figure and says what to do',
        () {
      final String text = tooInaccurateText(87);
      expect(text, contains('精度不够'));
      expect(text, contains('约 87 米'));
      expect(text, contains('导航没有启动'));
      expect(text, contains('留在原地'));
      expect(text, contains('带我去图书馆'));
      // Escalation is "ask a person", never "walk outside yourself".
      expect(text, contains('身边的人'));
      expect(text, contains('室外'));
      // Unknown accuracy drops the WHOLE parenthetical. Reading a number
      // slot filled with the word "未知" ("当前定位精度不够（约 未知 米）")
      // is gibberish in speech, and a blind user cannot skim past it.
      final String unknown = tooInaccurateText(null);
      expect(unknown, isNot(contains('未知')));
      expect(unknown, isNot(contains('约')));
      // Dropping the figure must not break the sentence apart.
      expect(unknown, contains('当前定位精度不够，'));
      expect(unknown, contains('导航没有启动'));
    });

    test('the old dead-end wording is gone from both texts', () {
      for (final String text in <String>[failedText, tooInaccurateText(87)]) {
        expect(text, isNot(contains('开阔处')), reason: text);
        expect(text, isNot(contains('暂时得不到你的位置')), reason: text);
        // The self-contradictory "stand still, then walk outside"
        // instruction must not come back.
        expect(text, isNot(contains('再走到室外')), reason: text);
        expect(text, isNot(contains('靠窗')), reason: text);
      }
    });

    test('neither text gives a direction or promises a passable way', () {
      for (final String text in <String>[failedText, tooInaccurateText(87)]) {
        expect(text, isNot(contains('左')), reason: text);
        expect(text, isNot(contains('右')), reason: text);
        expect(text, isNot(contains('转')), reason: text);
        expect(text, isNot(contains('安全')), reason: text);
        expect(text, isNot(contains('可以过马路')), reason: text);
        expect(containsBannedWord(text), isFalse, reason: text);
        // The pinned copy must keep saying navigation did not start.
        // Either wording is allowed ("未启动" / "没有启动"), but it must
        // be there: silence would leave the user thinking it started.
        expect(text, anyOf(contains('导航未启动'), contains('导航没有启动')),
            reason: text);
        // "走错路" is a RISK statement about the fix, not a step.
        expect(text, isNot(contains('向前')), reason: text);
        expect(text, isNot(contains('直走')), reason: text);
      }
    });

    test('the progress prompts are pinned and banned-clean', () {
      expect(navLocationProgressSpeech, '正在获取你的位置，可能需要十几秒，请保持原地不要走动。');
      expect(navLocationProgressStillWaitingSpeech, '还是没拿到位置，请再等一会儿，不要走动。');
      for (final String text in <String>[
        navLocationProgressSpeech,
        navLocationProgressStillWaitingSpeech,
      ]) {
        expect(containsBannedWord(text), isFalse, reason: text);
        expect(text, isNot(contains('左')), reason: text);
        expect(text, isNot(contains('右')), reason: text);
        expect(text, isNot(contains('转')), reason: text);
        expect(text, isNot(contains('安全')), reason: text);
        expect(text, isNot(contains('室外')), reason: text);
        // Both say "stay put": a progress prompt must never send a
        // blind user walking while the fix is still settling.
        expect(text, contains('不要走动'), reason: text);
      }
    });
  });
}
