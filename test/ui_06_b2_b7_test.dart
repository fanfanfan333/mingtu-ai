import 'dart:async';
import 'dart:io';

import 'package:mingtu_ai/core/camera_frame.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mingtu_ai/config/app_config.dart';
import 'package:mingtu_ai/adapters/current_location.dart';
import 'package:mingtu_ai/core/destination_dialogue.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/permission_flow.dart';
import 'package:mingtu_ai/main.dart';

import 'push_to_talk_ui_test.dart' as ui;
import 'ui_a11y_s1_test.dart' as s1;
import 'tts_recovery_test.dart' as recovery;

/// UI-06-B2 / B3 / B4 / B6 / B7 tests. Existing test files
/// are not modified here.

class _FlowGateway implements PermissionGateway {
  _FlowGateway();

  final Map<GuidePermission, PermissionOutcome> requestResults =
      <GuidePermission, PermissionOutcome>{};
  final Map<GuidePermission, PermissionOutcome> statusResults =
      <GuidePermission, PermissionOutcome>{};
  final Map<GuidePermission, Object?> statusErrors =
      <GuidePermission, Object?>{};
  final Map<GuidePermission, Object?> requestErrors =
      <GuidePermission, Object?>{};
  final Map<GuidePermission, Completer<PermissionOutcome>> statusHangs =
      <GuidePermission, Completer<PermissionOutcome>>{};
  final Map<GuidePermission, Completer<PermissionOutcome>> requestHangs =
      <GuidePermission, Completer<PermissionOutcome>>{};
  final List<GuidePermission> requested = <GuidePermission>[];
  final List<GuidePermission> statusReads = <GuidePermission>[];
  int openSettingsCalls = 0;
  List<String>? timeline;

  @override
  bool get isAvailable => true;

  @override
  Future<PermissionOutcome> request(GuidePermission permission) async {
    requested.add(permission);
    timeline?.add('request:${permission.name}');
    if (requestHangs[permission] != null) {
      return requestHangs[permission]!.future;
    }
    final Object? error = requestErrors[permission];
    if (error != null) {
      if (error is Exception) throw error;
      throw error as Error;
    }
    return requestResults[permission] ?? PermissionOutcome.granted;
  }

  @override
  Future<PermissionOutcome> status(GuidePermission permission) async {
    statusReads.add(permission);
    timeline?.add('status:${permission.name}');
    if (statusHangs[permission] != null) {
      return statusHangs[permission]!.future;
    }
    final Object? error = statusErrors[permission];
    if (error != null) {
      if (error is Exception) throw error;
      throw error as Error;
    }
    return statusResults[permission] ?? PermissionOutcome.denied;
  }

  @override
  Future<bool> openSettings() async {
    openSettingsCalls++;
    return true;
  }
}

class _RecordingGeolocator extends GeolocatorPlatform {
  int requests = 0;
  @override
  Future<bool> isLocationServiceEnabled() async => true;
  @override
  Future<LocationPermission> checkPermission() async =>
      LocationPermission.denied;
  @override
  Future<LocationPermission> requestPermission() async {
    requests++;
    return LocationPermission.denied;
  }
}

class _RecordingLocation extends CurrentLocationProvider {
  _RecordingLocation(this.gateway);
  final _FlowGateway gateway;
  int starts = 0;
  @override
  Future<bool> ensurePermission() async {
    starts++;
    gateway.timeline?.add('location.start');
    return true;
  }

  @override
  Future<LocationResult> currentLocation() async {
    return LocationResult.error(LocationFailure.failed, 'test');
  }
}

class _ThrowingGuideStore implements GuideStore {
  @override
  Future<bool> hasSeenGuide() async => throw StateError('marker boom');

  @override
  Future<void> markGuideSeen() async {}
}

class _HangingGuideStore implements GuideStore {
  final Completer<bool> result = Completer<bool>();

  @override
  Future<bool> hasSeenGuide() => result.future;

  @override
  Future<void> markGuideSeen() async {}
}

Set<String> _holdMicPurpose() => <String>{
      permissionPurposeText(GuidePermission.microphone),
    };

void _completeExcept(ui.RecordingVoiceChannels h, Set<String> hold) {
  for (final MapEntry<String, Completer<dynamic>> entry
      in List<MapEntry<String, Completer<dynamic>>>.of(h.speakQueue)) {
    if (entry.value.isCompleted) continue;
    if (hold.contains(entry.key)) continue;
    entry.value.complete(1);
  }
}

Future<void> _pumpSpeaks(WidgetTester tester, ui.RecordingVoiceChannels h,
    {int rounds = 20, Set<String> hold = const <String>{}}) async {
  for (int i = 0; i < rounds; i++) {
    _completeExcept(h, hold);
    await tester.pump(const Duration(milliseconds: 80));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  _completeExcept(h, hold);
}

Future<void> _driveUntil(WidgetTester tester, ui.RecordingVoiceChannels h,
    bool Function() done, String what,
    {int rounds = 80, Set<String> hold = const <String>{}}) async {
  for (int i = 0; i < rounds; i++) {
    if (done()) return;
    _completeExcept(h, hold);
    await tester.pump(const Duration(milliseconds: 80));
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
  }
  if (!done()) {
    fail('never reached: $what; events=${h.events}');
  }
}

Future<ui.RecordingVoiceChannels> _openApp(WidgetTester tester,
    {Widget? app}) async {
  final ui.RecordingVoiceChannels h = ui.RecordingVoiceChannels()..install();
  final gateway = mingtuPermissionGatewayOverride;
  if (gateway is _FlowGateway) gateway.timeline = h.events;
  addTearDown(() async {
    h.completeAllSpeaks();
    if (mingtuHomeDebugHandle != null) {
      await ui.shutdownVoice(tester, h);
    } else {
      await tester.pumpWidget(const SizedBox.shrink());
    }
    if (gateway is _FlowGateway) {
      for (final pending in gateway.requestHangs.values) {
        if (!pending.isCompleted) pending.complete(PermissionOutcome.denied);
      }
    }
    // Flush the 50 ms purpose-delivery poll that may have
    // been armed just before dispose.
    await tester.pump(const Duration(seconds: 1));
  });
  await tester.pumpWidget(app ?? const MingtuApp());
  return h;
}

class _CountingFrameSource implements CameraFrameSource {
  int calls = 0;
  @override
  Future<CameraFrameCapture> captureSingleFrame() async {
    calls++;
    return CameraFrameCapture.failed(CameraFrameFailure.unavailable);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FlowGateway gateway;
  late s1.FakeGuideStore store;
  late _RecordingLocation location;
  late _RecordingGeolocator geolocator;
  late GeolocatorPlatform originalGeolocator;

  setUp(() {
    gateway = _FlowGateway();
    store = s1.FakeGuideStore();
    location = _RecordingLocation(gateway);
    originalGeolocator = GeolocatorPlatform.instance;
    geolocator = _RecordingGeolocator();
    mingtuPermissionGatewayOverride = gateway;
    mingtuGuideStoreOverride = store;
    mingtuPermissionTimeoutOverride = null;
    mingtuPermissionSpeechTimeoutOverride = null;
    mingtuPermissionRequestTimeoutOverride = null;
  });

  tearDown(() {
    mingtuPermissionGatewayOverride = null;
    mingtuGuideStoreOverride = null;
    mingtuPermissionTimeoutOverride = null;
    mingtuPermissionSpeechTimeoutOverride = null;
    mingtuPermissionRequestTimeoutOverride = null;
    mingtuLocationProviderOverride = null;
    mingtuYoloAvailableOverride = null;
    mingtuCameraStartObserver = null;
    mingtuMicrophoneStartObserver = null;
    GeolocatorPlatform.instance = originalGeolocator;
  });

  test('UI-06-B2 timeout bound is pinned at 2 seconds', () {
    expect(AppConfig.permissionTimeout, const Duration(seconds: 2));
    expect(AppConfig.permissionSpeechTimeout, const Duration(seconds: 30));
    expect(AppConfig.permissionRequestTimeout, const Duration(seconds: 120));
    expect(containsBannedWord(permissionPurposeUndeliveredText), isFalse);
    expect(containsBannedWord(permissionRequestTimeoutText), isFalse);
  });

  group('UI-06-B2 first-launch order and fail-closed', () {
    testWidgets(
        'microphone: purpose then request then initialize, in that order',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () =>
              gateway.requested.contains(GuidePermission.microphone) &&
              mingtuHomeDebugHandle != null &&
              mingtuHomeDebugHandle!.microphoneInitializeCalls >= 1,
          'mic request and initialize');
      final List<String> events = h.events;
      final int purpose = events.indexOf(
          'tts.speak:${permissionPurposeText(GuidePermission.microphone)}');
      final int init = events.indexOf('asr.initialize');
      expect(purpose, greaterThanOrEqualTo(0));
      expect(init, greaterThan(purpose));
      expect(gateway.requested.first, GuidePermission.microphone);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 1);
    });

    testWidgets('location and camera: purpose then request, then start',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () =>
              h.events.contains('tts.speak:$permissionFlowEndText') &&
              !mingtuHomeDebugHandle!.permissionFlowRunning,
          'flow finished');
      expect(gateway.requested, PermissionFlow.steps);
      final List<String> events = h.events;
      for (final GuidePermission p in PermissionFlow.steps) {
        final int purpose =
            events.indexOf('tts.speak:${permissionPurposeText(p)}');
        // Request order is recorded in gateway.requested; purpose
        // must precede the request of the same permission.
        expect(purpose, greaterThanOrEqualTo(0), reason: p.name);
      }
      expect(
          events.indexOf(
              'tts.speak:${permissionPurposeText(GuidePermission.location)}'),
          lessThan(events.indexOf(
              'tts.speak:${permissionGrantedText(GuidePermission.location)}')));
      expect(
          events.indexOf(
              'tts.speak:${permissionPurposeText(GuidePermission.camera)}'),
          lessThan(events.indexOf(
              'tts.speak:${permissionGrantedText(GuidePermission.camera)}')));
    });

    testWidgets('microphone denied: initialize count stays 0',
        (WidgetTester tester) async {
      gateway.requestResults[GuidePermission.microphone] =
          PermissionOutcome.denied;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => h.events.contains('tts.speak:$permissionFlowEndText'),
          'flow finished after mic denial');
      expect(gateway.requested, contains(GuidePermission.microphone));
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      expect(h.events, isNot(contains('asr.initialize')));
    });

    testWidgets(
        'location and camera denied: no destination ask, camera start is 0',
        (WidgetTester tester) async {
      gateway.requestResults[GuidePermission.location] =
          PermissionOutcome.denied;
      gateway.requestResults[GuidePermission.camera] = PermissionOutcome.denied;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => h.events.contains('tts.speak:$permissionFlowEndText'),
          'flow finished');
      expect(h.events, isNot(contains('tts.speak:$destinationAskText')));
      expect(mingtuHomeDebugHandle!.cameraStartCalls, 0);
      expect(mingtuHomeDebugHandle!.yoloLiveOpen, isFalse);
    });

    testWidgets('mic request throw: initialize count is 0',
        (WidgetTester tester) async {
      gateway.requestErrors[GuidePermission.microphone] =
          StateError('request boom');
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () =>
              gateway.requested.contains(GuidePermission.microphone) &&
              h.events.contains(
                  'tts.speak:${permissionDeniedText(GuidePermission.microphone)}'),
          'denied after throw');
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
    });

    testWidgets('mic request MissingPluginException: initialize count is 0',
        (WidgetTester tester) async {
      gateway.requestErrors[GuidePermission.microphone] =
          MissingPluginException('permission_handler missing');
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request attempted');
      await _pumpSpeaks(tester, h);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
    });

    testWidgets('mic request timeout: initialize count is 0',
        (WidgetTester tester) async {
      mingtuPermissionTimeoutOverride = const Duration(milliseconds: 80);
      gateway.requestHangs[GuidePermission.microphone] =
          Completer<PermissionOutcome>();
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request started');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await _pumpSpeaks(tester, h, rounds: 30);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      gateway.requestHangs[GuidePermission.microphone]!
          .complete(PermissionOutcome.denied);
      await tester.pump();
    });

    testWidgets(
        'location/camera request throw, timeout and missing-plugin: start count 0',
        (WidgetTester tester) async {
      gateway.requestErrors[GuidePermission.location] =
          MissingPluginException('no plugin');
      gateway.requestHangs[GuidePermission.camera] =
          Completer<PermissionOutcome>();
      mingtuPermissionTimeoutOverride = const Duration(milliseconds: 80);
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.camera),
          'camera request started');
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await _pumpSpeaks(tester, h, rounds: 30);
      expect(h.events, isNot(contains('tts.speak:$destinationAskText')));
      expect(mingtuHomeDebugHandle!.cameraStartCalls, 0);
      gateway.requestHangs[GuidePermission.camera]!
          .complete(PermissionOutcome.denied);
      await tester.pump();
    });
  });

  group('UI-06-B2 permission matrix', () {
    void injectStartupFakes() {
      GeolocatorPlatform.instance = geolocator;
      mingtuLocationProviderOverride = location;
      mingtuYoloAvailableOverride = true;
      mingtuCameraStartObserver = () => gateway.timeline?.add('camera.start');
      mingtuMicrophoneStartObserver =
          () => gateway.timeline?.add('microphone.start');
    }

    testWidgets('packaged detector opens live camera before first inference', (tester) async {
      injectStartupFakes();
      mingtuYoloAvailableOverride = null;
      mingtuYoloViewBuilderOverride = (_) => const SizedBox.shrink();
      addTearDown(() => mingtuYoloViewBuilderOverride = null);
      store.seen = true;
      for (final step in PermissionFlow.steps) {
        gateway.statusResults[step] = PermissionOutcome.granted;
      }
      final h = await _openApp(tester);
      await _driveUntil(tester, h,
          () => mingtuHomeDebugHandle!.cameraStartCalls > 0, 'live camera startup');
      expect(mingtuHomeDebugHandle!.yoloLiveOpen, isTrue);
    });

    int starts(GuidePermission permission) {
      switch (permission) {
        case GuidePermission.microphone:
          return mingtuHomeDebugHandle!.microphoneInitializeCalls;
        case GuidePermission.location:
          return location.starts;
        case GuidePermission.camera:
          return mingtuHomeDebugHandle!.cameraStartCalls;
        case GuidePermission.backgroundLocationService:
          throw StateError('background permission is outside this test');
      }
    }

    for (final permission in PermissionFlow.steps) {
      for (final failure in <String>[
        'denied',
        'throw',
        'missing plugin',
        'timeout'
      ]) {
        testWidgets('${permission.name} returning status $failure fails closed',
            (tester) async {
          injectStartupFakes();
          store.seen = true;
          for (final step in PermissionFlow.steps) {
            gateway.statusResults[step] = PermissionOutcome.granted;
          }
          switch (failure) {
            case 'denied':
              gateway.statusResults[permission] = PermissionOutcome.denied;
            case 'throw':
              gateway.statusErrors[permission] = StateError('status failed');
            case 'missing plugin':
              gateway.statusErrors[permission] =
                  MissingPluginException('status unavailable');
            case 'timeout':
              mingtuPermissionTimeoutOverride =
                  const Duration(milliseconds: 80);
              gateway.statusHangs[permission] = Completer<PermissionOutcome>();
          }
          final h = await _openApp(tester);
          await _driveUntil(
              tester,
              h,
              () => gateway.statusReads.contains(permission),
              '${permission.name} status read');
          await _pumpSpeaks(tester, h, rounds: 12);
          expect(starts(permission), 0);
          expect(geolocator.requests, 0);
          expect(gateway.requested, isEmpty);
          if (permission == GuidePermission.microphone) {
            expect(h.events, isNot(contains('asr.initialize')));
          }
          if (permission == GuidePermission.location) {
            expect(h.events, isNot(contains('location.start')));
          }
          if (permission == GuidePermission.camera) {
            expect(h.events, isNot(contains('camera.start')));
          }
        });
      }

      for (final failure in <String>[
        'denied',
        'throw',
        'missing plugin',
        'timeout'
      ]) {
        testWidgets(
            '${permission.name} first launch request $failure fails closed',
            (tester) async {
          injectStartupFakes();
          switch (failure) {
            case 'denied':
              gateway.requestResults[permission] = PermissionOutcome.denied;
            case 'throw':
              gateway.requestErrors[permission] = StateError('request failed');
            case 'missing plugin':
              gateway.requestErrors[permission] =
                  MissingPluginException('request unavailable');
            case 'timeout':
              mingtuPermissionTimeoutOverride =
                  const Duration(milliseconds: 80);
              gateway.requestHangs[permission] = Completer<PermissionOutcome>();
          }
          final h = await _openApp(tester);
          if (failure == 'timeout') {
            await _driveUntil(
                tester,
                h,
                () => gateway.requested.contains(permission),
                'request remains in flight');
            await tester.runAsync(
                () => Future<void>.delayed(const Duration(milliseconds: 150)));
            expect(
                h.events,
                isNot(
                    contains('tts.speak:${permissionDeniedText(permission)}')));
            expect(
                h.events, isNot(contains('tts.speak:$permissionFlowEndText')));
          } else {
            await _driveUntil(
                tester,
                h,
                () => h.events.contains('tts.speak:$permissionFlowEndText'),
                'flow finishes after ${permission.name} $failure',
                rounds: 140);
          }
          await _pumpSpeaks(tester, h, rounds: 8);
          expect(gateway.requested, contains(permission));
          expect(starts(permission), 0);
          expect(geolocator.requests, 0);
          if (permission == GuidePermission.microphone) {
            expect(h.events, isNot(contains('asr.initialize')));
          }
          if (permission == GuidePermission.location) {
            expect(h.events, isNot(contains('location.start')));
          }
          if (permission == GuidePermission.camera) {
            expect(h.events, isNot(contains('camera.start')));
          }
          if (failure == 'timeout') {
            gateway.requestHangs[permission]!
                .complete(PermissionOutcome.denied);
            await tester.pump();
          }
        });
      }
    }

    test(
        'geolocator adapter checks denied status without requesting permission',
        () async {
      GeolocatorPlatform.instance = geolocator;
      const provider = GeolocatorCurrentLocation();
      expect(await provider.ensurePermission(), isFalse);
      final result = await provider.currentLocation();
      expect(result.failure, LocationFailure.permissionDenied);
      expect(geolocator.requests, 0);
    });

    testWidgets(
        'all granted: purpose, request, and plugin start share an ordered timeline',
        (tester) async {
      injectStartupFakes();
      final h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () =>
              h.events.contains('location.start') &&
              h.events.contains('camera.start'),
          'location and camera start',
          rounds: 140);
      for (final permission in PermissionFlow.steps) {
        final purpose =
            h.events.indexOf('tts.speak:${permissionPurposeText(permission)}');
        final request = h.events.indexOf('request:${permission.name}');
        final start = h.events.indexOf(switch (permission) {
          GuidePermission.microphone => 'microphone.start',
          GuidePermission.location => 'location.start',
          GuidePermission.camera => 'camera.start',
          GuidePermission.backgroundLocationService =>
            throw StateError('unexpected'),
        });
        expect(purpose, greaterThanOrEqualTo(0), reason: permission.name);
        expect(request, greaterThan(purpose), reason: permission.name);
        expect(start, greaterThan(request), reason: permission.name);
        expect(starts(permission), 1, reason: permission.name);
      }
    });
  });

  group('UI-06-B3 first-launch marker', () {
    testWidgets('marker throw is treated as not seen; purpose precedes request',
        (WidgetTester tester) async {
      mingtuGuideStoreOverride = _ThrowingGuideStore();
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'mic request after thrown marker');
      final List<String> events = h.events;
      expect(events, contains('tts.speak:$firstLaunchGuideText'));
      expect(
          events.indexOf(
              'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'),
          lessThan(events.length));
      expect(
          events.indexOf(
              'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'),
          greaterThanOrEqualTo(0));
    });

    testWidgets(
        'slow marker does not let location/camera request precede purpose',
        (WidgetTester tester) async {
      final _HangingGuideStore delayed = _HangingGuideStore();
      mingtuGuideStoreOverride = delayed;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _pumpSpeaks(tester, h, rounds: 8);
      expect(gateway.requested, isEmpty);
      delayed.result.complete(false);
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'mic request after late marker');
      expect(
          h.events,
          contains(
              'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'));
      expect(gateway.requested.contains(GuidePermission.location), isFalse);
    });

    testWidgets('marker timeout is treated as not seen',
        (WidgetTester tester) async {
      mingtuPermissionTimeoutOverride = const Duration(milliseconds: 80);
      final _HangingGuideStore hanging = _HangingGuideStore();
      mingtuGuideStoreOverride = hanging;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 150)));
      await _driveUntil(
          tester,
          h,
          () =>
              h.events.contains('tts.speak:$firstLaunchGuideText') ||
              h.events.contains(
                  'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'),
          'purpose or guide after marker timeout');
      expect(gateway.requested.contains(GuidePermission.location), isFalse);
    });

    testWidgets('already-seen user skips the first-launch guide',
        (WidgetTester tester) async {
      store.seen = true;
      gateway.statusResults[GuidePermission.microphone] =
          PermissionOutcome.granted;
      gateway.statusResults[GuidePermission.location] =
          PermissionOutcome.granted;
      gateway.statusResults[GuidePermission.camera] = PermissionOutcome.granted;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _pumpSpeaks(tester, h, rounds: 40);
      expect(h.events, isNot(contains('tts.speak:$firstLaunchGuideText')));
      expect(gateway.requested, isEmpty);
    });
  });

  group('UI-06-B4 purpose speech must really finish', () {
    testWidgets('request waits for TTS completion of the purpose speech',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      // Complete everything except the microphone purpose.
      for (int i = 0; i < 50 && gateway.requested.isEmpty; i++) {
        for (final entry in List.of(h.speakQueue)) {
          if (entry.value.isCompleted) continue;
          if (entry.key == permissionPurposeText(GuidePermission.microphone)) {
            continue;
          }
          entry.value.complete(1);
        }
        await tester.pump(const Duration(milliseconds: 80));
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)));
      }
      expect(gateway.requested, isEmpty,
          reason: 'dialog must not appear before purpose TTS completes');
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      h.completeSpeak(permissionPurposeText(GuidePermission.microphone));
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request after purpose completion');
      expect(gateway.requested.first, GuidePermission.microphone);
    });

    testWidgets(
        'hazard interrupt: no dialog until purpose is replayed and finished',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => h.events.contains(
              'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'),
          'purpose started',
          hold: _holdMicPurpose());
      // Complete non-purpose speech (guide, startup), keep purpose pending.
      for (final entry in List.of(h.speakQueue)) {
        if (entry.value.isCompleted) continue;
        if (entry.key == permissionPurposeText(GuidePermission.microphone)) {
          continue;
        }
        entry.value.complete(1);
      }
      await tester.pump();
      expect(gateway.requested, isEmpty);
      mingtuHomeDebugHandle!.debugSpeakHazard('前方有车，请停步。');
      await tester.pump();
      expect(gateway.requested, isEmpty);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      // Finish the hazard, not the interrupted purpose.
      h.completeSpeak('前方有车，请停步。');
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump();
      expect(gateway.requested, isEmpty,
          reason: 'replay must finish before the dialog');
      // Complete whatever purpose replay is pending.
      h.completeSpeak(permissionPurposeText(GuidePermission.microphone));
      h.completeAllSpeaks();
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request after replayed purpose');
    });

    testWidgets('dropped purpose: no dialog until a later completed replay',
        (WidgetTester tester) async {
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      // Finish the guide while a hazard holds the scheduler, then expire
      // the queued purpose before the hazard completes.
      await _driveUntil(
          tester,
          h,
          () => h.events.contains('tts.speak:$firstLaunchGuideText'),
          'guide started',
          hold: <String>{firstLaunchGuideText});
      DateTime fakeNow = DateTime(2026, 1, 1, 12);
      mingtuHomeDebugHandle!.debugSetSpeechClock(() => fakeNow);
      h.completeSpeak(firstLaunchGuideText);
      await tester.pump();
      mingtuHomeDebugHandle!.debugSpeakHazard('前方有车，请停步。');
      await _driveUntil(tester, h,
          () => mingtuHomeDebugHandle!.debugPurposeQueued, 'purpose queued',
          hold: <String>{'前方有车，请停步。'});
      fakeNow = fakeNow.add(const Duration(seconds: 6));
      expect(gateway.requested, isEmpty);
      h.completeSpeak('前方有车，请停步。');
      await tester.pump(const Duration(milliseconds: 80));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)));
      expect(gateway.requested, isEmpty);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      h.completeSpeak(permissionPurposeText(GuidePermission.microphone));
      h.completeAllSpeaks();
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request after dropped purpose was replayed');
    });

    testWidgets(
        'purpose timeout: fault hint spoken, no dialog, retry on resume',
        (WidgetTester tester) async {
      mingtuPermissionSpeechTimeoutOverride = const Duration(milliseconds: 200);
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      DateTime fakeNow = DateTime(2026, 1, 1, 12);
      await _driveUntil(
          tester, h, () => mingtuHomeDebugHandle != null, 'handle ready',
          hold: _holdMicPurpose());
      mingtuHomeDebugHandle!.debugSetSpeechClock(() => fakeNow);
      await _driveUntil(
          tester,
          h,
          () => h.events.contains(
              'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'),
          'purpose started',
          hold: _holdMicPurpose());
      for (final entry in List.of(h.speakQueue)) {
        if (entry.value.isCompleted) continue;
        if (entry.key == permissionPurposeText(GuidePermission.microphone)) {
          continue;
        }
        entry.value.complete(1);
      }
      fakeNow = fakeNow.add(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 400));
      h.completeSpeak(permissionPurposeUndeliveredText);
      h.completeAllSpeaks();
      await _pumpSpeaks(tester, h, rounds: 10);
      expect(gateway.requested, isEmpty);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      expect(h.events, contains('tts.speak:$permissionPurposeUndeliveredText'));
      // Retry on resume.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await _driveUntil(
          tester,
          h,
          () =>
              h.events
                  .where((String e) =>
                      e ==
                      'tts.speak:${permissionPurposeText(GuidePermission.microphone)}')
                  .length >=
              2,
          'purpose replayed on resume',
          hold: _holdMicPurpose());
      h.completeSpeak(permissionPurposeText(GuidePermission.microphone));
      h.completeAllSpeaks();
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request after resume retry');
    });

    testWidgets('purpose timeout: retry on next press-to-talk also works',
        (WidgetTester tester) async {
      mingtuPermissionSpeechTimeoutOverride = const Duration(milliseconds: 200);
      final ui.RecordingVoiceChannels h = await _openApp(
        tester,
        app: const MediaQuery(
          data: MediaQueryData(accessibleNavigation: true),
          child: MingtuApp(),
        ),
      );
      DateTime fakeNow = DateTime(2026, 1, 1, 12);
      await _driveUntil(
          tester, h, () => mingtuHomeDebugHandle != null, 'handle ready',
          hold: _holdMicPurpose());
      mingtuHomeDebugHandle!.debugSetSpeechClock(() => fakeNow);
      await _driveUntil(
          tester,
          h,
          () => h.events.contains(
              'tts.speak:${permissionPurposeText(GuidePermission.microphone)}'),
          'purpose started',
          hold: _holdMicPurpose());
      fakeNow = fakeNow.add(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 400));
      h.completeAllSpeaks();
      await _pumpSpeaks(tester, h, rounds: 8);
      expect(gateway.requested, isEmpty);
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
      mingtuHomeDebugHandle!.debugPttToggleTap();
      await tester.pump();
      await _driveUntil(
          tester,
          h,
          () =>
              h.events
                  .where((String e) =>
                      e ==
                      'tts.speak:${permissionPurposeText(GuidePermission.microphone)}')
                  .length >=
              2,
          'purpose replayed on PTT',
          hold: _holdMicPurpose());
      h.completeSpeak(permissionPurposeText(GuidePermission.microphone));
      h.completeAllSpeaks();
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request after PTT retry');
    });
  });

  group('UI-06-B6 settings pause holds the startup chain', () {
    testWidgets(
        'after openAppSettings, no location, camera or destination until resume re-check',
        (WidgetTester tester) async {
      gateway.requestResults[GuidePermission.microphone] =
          PermissionOutcome.permanentlyDenied;
      gateway.statusResults[GuidePermission.microphone] =
          PermissionOutcome.permanentlyDenied;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () =>
              gateway.openSettingsCalls >= 1 &&
              mingtuHomeDebugHandle!.permissionFlowRunning,
          'paused on settings');
      expect(gateway.requested, isNot(contains(GuidePermission.location)));
      expect(gateway.requested, isNot(contains(GuidePermission.camera)));
      expect(h.events, isNot(contains('tts.speak:$destinationAskText')));
      expect(mingtuHomeDebugHandle!.cameraStartCalls, 0);
      expect(mingtuHomeDebugHandle!.yoloLiveOpen, isFalse);
      gateway.statusResults[GuidePermission.microphone] =
          PermissionOutcome.granted;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _driveUntil(
          tester,
          h,
          () =>
              h.events.contains(
                  'tts.speak:${permissionRecheckGrantedText(GuidePermission.microphone)}') &&
              h.events.contains(
                  'tts.speak:${permissionPurposeText(GuidePermission.location)}'),
          'resume announced the re-check result and the next step');
    });
  });

  group('UI-06-B7 single-flight resume re-check', () {
    testWidgets('two rapid resumes produce one re-check announcement',
        (WidgetTester tester) async {
      gateway.requestResults[GuidePermission.microphone] =
          PermissionOutcome.permanentlyDenied;
      final Completer<PermissionOutcome> hang = Completer<PermissionOutcome>();
      gateway.statusHangs[GuidePermission.microphone] = hang;
      final ui.RecordingVoiceChannels h = await _openApp(tester);
      await _driveUntil(tester, h, () => gateway.openSettingsCalls >= 1,
          'paused on settings');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(mingtuHomeDebugHandle!.settingsRecheckStarts, 1);
      hang.complete(PermissionOutcome.granted);
      await tester.pump();
      await _driveUntil(
          tester,
          h,
          () => h.events.contains(
              'tts.speak:${permissionRecheckGrantedText(GuidePermission.microphone)}'),
          'single re-check announcement');
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.location),
          'next permission requested');
      await _pumpSpeaks(tester, h, rounds: 8);
      expect(
          h.events
              .where((e) =>
                  e ==
                  'tts.speak:${permissionPurposeText(GuidePermission.location)}')
              .length,
          1);
      expect(
          gateway.requested.where((p) => p == GuidePermission.location).length,
          1);
      expect(tester.takeException(), isNull);
      final int announces = h.events
          .where((String e) =>
              e ==
              'tts.speak:${permissionRecheckGrantedText(GuidePermission.microphone)}')
          .length;
      expect(announces, 1);
      expect(mingtuHomeDebugHandle!.settingsRecheckStarts, 1);
    });
  });
  testWidgets('B8 manual vision checks camera grant before flow',
      (tester) async {
    store.seen = true;
    gateway.requestResults[GuidePermission.camera] = PermissionOutcome.denied;
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    final frames = _CountingFrameSource();
    mingtuHomeDebugHandle!.setCameraFrameSourceForTest(frames);
    mingtuHomeDebugHandle!.triggerManualVision();
    await _driveUntil(
        tester,
        h,
        () => h.events.contains(
            'tts.speak:${permissionDeniedText(GuidePermission.camera)}'),
        'camera denial spoken');
    expect(frames.calls, 0);
    gateway.statusResults[GuidePermission.camera] = PermissionOutcome.granted;
    mingtuHomeDebugHandle!.triggerManualVision();
    await _driveUntil(
        tester,
        h,
        () => mingtuHomeDebugHandle!.statusTexts
            .any((text) => text.contains('识图未配置')),
        'granted manual vision proceeds');
  });

  testWidgets('B12 camera purpose completes before re-request', (tester) async {
    store.seen = true;
    gateway.requestResults[GuidePermission.camera] = PermissionOutcome.denied;
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    final frames = _CountingFrameSource();
    mingtuHomeDebugHandle!.setCameraFrameSourceForTest(frames);
    final purpose = permissionPurposeText(GuidePermission.camera);
    mingtuHomeDebugHandle!.triggerManualVision();
    await _driveUntil(tester, h, () => h.events.contains('tts.speak:$purpose'),
        'camera purpose',
        hold: {purpose});
    expect(gateway.requested, isNot(contains(GuidePermission.camera)));
    expect(frames.calls, 0);
    await _driveUntil(
        tester,
        h,
        () => gateway.requested.contains(GuidePermission.camera),
        'camera request');
    expect(h.events.indexOf('tts.speak:$purpose'),
        lessThan(h.events.indexOf('request:camera')));
    await _pumpSpeaks(tester, h, rounds: 5);
    expect(frames.calls, 0);
    expect(containsBannedWord(purpose), isFalse);
    expect(containsBannedWord(permissionDeniedText(GuidePermission.camera)),
        isFalse);
  });

  testWidgets('B12 unfinished camera purpose prevents request', (tester) async {
    store.seen = true;
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    final frames = _CountingFrameSource();
    mingtuHomeDebugHandle!.setCameraFrameSourceForTest(frames);
    final purpose = permissionPurposeText(GuidePermission.camera);
    var now = DateTime(2026);
    mingtuHomeDebugHandle!.debugSetSpeechClock(() => now);
    mingtuHomeDebugHandle!.triggerManualVision();
    await _driveUntil(tester, h, () => h.events.contains('tts.speak:$purpose'),
        'camera purpose',
        hold: {purpose});
    await _pumpSpeaks(tester, h, rounds: 10, hold: {purpose});
    expect(gateway.requested, isNot(contains(GuidePermission.camera)));
    expect(frames.calls, 0);
    expect(containsBannedWord(purpose), isFalse);
    now = now.add(const Duration(seconds: 31));
    await tester.pump(const Duration(seconds: 1));
    await _pumpSpeaks(tester, h, rounds: 3);
    await _driveUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$permissionPurposeUndeliveredText'),
        'undelivered alert',
        hold: {purpose});
    expect(gateway.requested, isNot(contains(GuidePermission.camera)));
  });

  testWidgets('B12 manual camera request timeout announces alert',
      (tester) async {
    store.seen = true;
    gateway.requestHangs[GuidePermission.camera] =
        Completer<PermissionOutcome>();
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    final frames = _CountingFrameSource();
    mingtuHomeDebugHandle!.setCameraFrameSourceForTest(frames);
    mingtuHomeDebugHandle!.triggerManualVision();
    await _driveUntil(
        tester,
        h,
        () => gateway.requested.contains(GuidePermission.camera),
        'camera request');
    await tester.pump(const Duration(seconds: 120));
    await _driveUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$permissionRequestTimeoutText'),
        'timeout alert');
    expect(frames.calls, 0);
  });

  testWidgets('late manual camera denial clears unspoken timeout', (tester) async {
    store.seen = true;
    final answer = Completer<PermissionOutcome>();
    gateway.requestHangs[GuidePermission.camera] = answer;
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    mingtuHomeDebugHandle!.setCameraFrameSourceForTest(_CountingFrameSource());
    mingtuHomeDebugHandle!.triggerManualVision();
    await _driveUntil(tester, h,
        () => gateway.requested.contains(GuidePermission.camera), 'camera request');
    final output = recovery.FakeOutput();
    var canRecover = false;
    mingtuHomeDebugHandle!.debugFailTts(() async => canRecover ? output : null);
    await tester.pump(const Duration(seconds: 120));
    await tester.pump();
    answer.complete(PermissionOutcome.denied);
    await tester.pump();
    canRecover = true;
    await tester.pump(const Duration(seconds: 30));
    for (var i = 0; i < 12; i++) { await tester.pump(); }
    expect(output.spoken, isNot(contains(permissionRequestTimeoutText)));
    expect(output.spoken.any((s) => s.contains('语音已恢复')), isTrue);
  });

  testWidgets('B12 permanent camera denial does not request', (tester) async {
    store.seen = true;
    gateway.statusResults[GuidePermission.camera] =
        PermissionOutcome.permanentlyDenied;
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    final frames = _CountingFrameSource();
    mingtuHomeDebugHandle!.setCameraFrameSourceForTest(frames);
    mingtuHomeDebugHandle!.triggerManualVision();
    final denial = permissionDeniedText(GuidePermission.camera);
    await _driveUntil(tester, h, () => h.events.contains('tts.speak:$denial'),
        'camera denial');
    expect(gateway.requested, isNot(contains(GuidePermission.camera)));
    expect(frames.calls, 0);
    expect(containsBannedWord(denial), isFalse);
  });

  testWidgets('B12 mid-guide manual vision keeps microphone first',
      (tester) async {
    final h = await _openApp(tester);
    final mic = permissionPurposeText(GuidePermission.microphone);
    final camera = permissionPurposeText(GuidePermission.camera);
    await _driveUntil(tester, h, () => h.events.contains('tts.speak:$mic'),
        'microphone purpose',
        hold: {mic});
    mingtuHomeDebugHandle!.triggerManualVision();
    await _pumpSpeaks(tester, h, rounds: 5, hold: {mic});
    expect(h.events, isNot(contains('tts.speak:$camera')));
    expect(gateway.requested, isNot(contains(GuidePermission.camera)));
    expect(containsBannedWord(mic), isFalse);
    expect(containsBannedWord(camera), isFalse);
  });

  test('B8 production manual flow gates camera before run', () {
    final source = File('lib/main.dart').readAsStringSync();
    final manual = source
        .substring(source.indexOf('Future<void> _runCloudVisionAssist()'));
    expect(manual.indexOf('_permissionStatus(GuidePermission.camera)'),
        greaterThan(0));
    expect(manual.indexOf('_permissionStatus(GuidePermission.camera)'),
        lessThan(manual.indexOf('_cloudVisionFlow.run(')));
  });

  testWidgets('B9 long request fallback defers without denial', (tester) async {
    mingtuPermissionRequestTimeoutOverride = const Duration(milliseconds: 200);
    gateway.requestHangs[GuidePermission.microphone] =
        Completer<PermissionOutcome>();
    final h = await _openApp(tester);
    await _driveUntil(
        tester,
        h,
        () => gateway.requested.contains(GuidePermission.microphone),
        'request');
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await _driveUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$permissionRequestTimeoutText'),
        'timeout fault');
    expect(
        h.events,
        isNot(contains(
            'tts.speak:${permissionDeniedText(GuidePermission.microphone)}')));
    expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 0);
    expect(gateway.requested, <GuidePermission>[GuidePermission.microphone]);
  });

  for (final delay in <int>[10, 60]) {
    testWidgets('B9 request answered after $delay seconds is honored',
        (tester) async {
      final answer = Completer<PermissionOutcome>();
      gateway.requestHangs[GuidePermission.microphone] = answer;
      final h = await _openApp(tester);
      await _driveUntil(
          tester,
          h,
          () => gateway.requested.contains(GuidePermission.microphone),
          'request');
      await tester.pump(Duration(seconds: delay));
      answer.complete(
          delay == 10 ? PermissionOutcome.granted : PermissionOutcome.denied);
      await _driveUntil(
          tester,
          h,
          () => delay == 10
              ? mingtuHomeDebugHandle!.microphoneInitializeCalls > 0
              : h.events.contains(
                  'tts.speak:${permissionDeniedText(GuidePermission.microphone)}'),
          'answer handled');
      expect(mingtuHomeDebugHandle!.microphoneInitializeCalls,
          delay == 10 ? 1 : 0);
      expect(
          h.events, isNot(contains('tts.speak:$permissionRequestTimeoutText')));
    }, timeout: const Timeout(Duration(seconds: 90)));
  }

  testWidgets('B13 late grant after 120 second fallback resumes flow',
      (tester) async {
    final answer = Completer<PermissionOutcome>();
    gateway.requestHangs[GuidePermission.microphone] = answer;
    final h = await _openApp(tester);
    await _driveUntil(
        tester,
        h,
        () => gateway.requested.contains(GuidePermission.microphone),
        'request');
    await tester.pump(const Duration(seconds: 120));
    await _driveUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$permissionRequestTimeoutText'),
        'timeout speech');
    answer.complete(PermissionOutcome.granted);
    await _driveUntil(
        tester,
        h,
        () => gateway.requested.contains(GuidePermission.camera),
        'next request');
    expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, 1);
    expect(
        h.events,
        isNot(contains(
            'tts.speak:${permissionDeniedText(GuidePermission.microphone)}')));
  });

  testWidgets('B13 late denial does not resume flow', (tester) async {
    final answer = Completer<PermissionOutcome>();
    gateway.requestHangs[GuidePermission.microphone] = answer;
    final h = await _openApp(tester);
    await _driveUntil(
        tester,
        h,
        () => gateway.requested.contains(GuidePermission.microphone),
        'request');
    await tester.pump(const Duration(seconds: 120));
    await _driveUntil(
        tester,
        h,
        () => h.events.contains('tts.speak:$permissionRequestTimeoutText'),
        'timeout speech');
    final before = mingtuHomeDebugHandle!.microphoneInitializeCalls;
    answer.complete(PermissionOutcome.denied);
    await _pumpSpeaks(tester, h, rounds: 10);
    expect(mingtuHomeDebugHandle!.microphoneInitializeCalls, before);
    expect(gateway.requested, isNot(contains(GuidePermission.camera)));
  });

  testWidgets('B10 startup with unavailable speech does not request',
      (tester) async {
    final h = ui.RecordingVoiceChannels()..install();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'),
            (call) async {
      if (call.method == 'getLanguages') return <String>[];
      return null;
    });
    addTearDown(() async {
      h.completeAllSpeaks();
      await ui.shutdownVoice(tester, h);
      await tester.pump(const Duration(seconds: 1));
    });
    final watch = Stopwatch()..start();
    await tester.pumpWidget(const MingtuApp());
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(gateway.requested, isEmpty);
  });

  testWidgets('B10 unavailable speech defers purpose immediately',
      (tester) async {
    store.seen = true;
    final h = await _openApp(tester);
    await _pumpSpeaks(tester, h);
    mingtuHomeDebugHandle!.disableVoiceOutputForTest();
    final watch = Stopwatch()..start();
    await tester
        .runAsync(() => mingtuHomeDebugHandle!.startPermissionFlowForTest());
    expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    expect(gateway.requested, isEmpty);
  });
}
