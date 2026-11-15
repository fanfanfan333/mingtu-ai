import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mingtu_ai/adapters/amap_client.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/config/verified_locations.dart';
import 'package:mingtu_ai/core/foreground_watchdog.dart';
import 'package:mingtu_ai/core/real_navigation.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/modules/map_navigation.dart';

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

  test('manifest checker validates permissions and services', () {
    final script = File('tool/check_release_manifest.sh').readAsStringSync();
    expect(script, contains('processReleaseMainManifest'));
    expect(script, contains('android.permission.FOREGROUND_SERVICE_LOCATION'));
    expect(script, contains('android.permission.ACCESS_BACKGROUND_LOCATION'));
    final dir = Directory.systemTemp.createTempSync('mingtu-manifest-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/AndroidManifest.xml');
    ProcessResult check(String body) {
      file.writeAsStringSync(
          '<manifest xmlns:android="http://schemas.android.com/apk/res/android">$body</manifest>');
      return Process.runSync(
          'bash', ['tool/check_release_manifest.sh', file.path]);
    }

    const geo =
        '<service android:name="com.baseflow.geolocator.GeolocatorLocationService" android:foregroundServiceType="location"/>';
    final legal =
        check('<application>$geo<service android:name="other"/></application>');
    expect(legal.exitCode, 0, reason: '${legal.stdout} ${legal.stderr}');
    expect(legal.stdout, contains('GeolocatorLocationService'));
    for (final body in [
      '<uses-permission android:name="android.permission.FOREGROUND_SERVICE_LOCATION"/><application>$geo</application>',
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
      final result =
          Process.runSync('bash', ['tool/check_release_manifest.sh']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    }
  });

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
      expect(outcome.failureAnnouncement, '定位失败：暂时得不到你的位置，导航未启动。请到开阔处稍后重试。');
      _speak(outcome.failureAnnouncement);
      final results = <LocationResult>[];
      final subscription = provider.positions().listen(results.add);
      controller.addError(error);
      await Future<void>.delayed(Duration.zero);
      expect(results.single.failure, LocationFailure.failed);
      const text = '定位信号中断，暂时无法更新你的位置。';
      expect(File('lib/main.dart').readAsStringSync(), contains(text));
      _speak(text, kind: SpeechKind.info);
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
}
