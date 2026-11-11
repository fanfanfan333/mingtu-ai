import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/startup_guard.dart';
import 'package:mingtu_ai/main.dart';

/// P0 startup resilience: simulate EVERY startup module
/// throwing (missing plugin class, native load failure -- the
/// release-APK failure shape). Startup must still complete with
/// fallbacks, and the failures must be announced by name.
void main() {
  group('guardStartupStep', () {
    test(
        'a throwing step returns the fallback and records '
        'the module; startup continues', () async {
      final StartupFailureLog log = StartupFailureLog();
      final bool ttsOk = await guardStartupStep<bool>(
        '语音合成',
        () async => throw StateError('plugin class stripped'),
        fallback: false,
        log: log,
      );
      final bool asrOk = await guardStartupStep<bool>(
        '语音识别',
        () async => throw StateError('no recogniser'),
        fallback: false,
        log: log,
      );
      final String yolo = await guardStartupStep<String>(
        '目标检测',
        () async => throw StateError('native lib missing'),
        fallback: 'unavailable',
        log: log,
      );
      // Startup "completed" with fallbacks everywhere:
      expect(ttsOk, isFalse);
      expect(asrOk, isFalse);
      expect(yolo, 'unavailable');
      expect(log.modules, <String>['语音合成', '语音识别', '目标检测']);
    });

    test(
        'a succeeding step passes its value through and '
        'records nothing', () async {
      final StartupFailureLog log = StartupFailureLog();
      final bool ok = await guardStartupStep<bool>(
        '语音合成',
        () async => true,
        fallback: false,
        log: log,
      );
      expect(ok, isTrue);
      expect(log.hasFailures, isFalse);
    });

    test(
        'the announcement names every failed module and '
        'states the degradation honestly', () {
      final String text = startupFailureAnnouncement(
        <String>['语音合成', '语音识别', '目标检测'],
      );
      expect(text, contains('启动时有模块不可用'));
      expect(text, contains('语音合成'));
      expect(text, contains('语音识别'));
      expect(text, contains('目标检测'));
      expect(text, contains('已降级启动'));
      expect(startupFailureAnnouncement(const <String>[]), '');
    });
  });

  group('runStartupSteps: per-module fault injection', () {
    const List<String> modules = <String>[
      '摄像头',
      '配置',
      '高德',
      '权限',
      '语音合成',
      '语音识别',
      '目标检测',
    ];

    for (final String module in modules) {
      test(
          'when $module throws, startup still completes, the '
          'module is recorded, and the announcement names it', () async {
        final StartupFailureLog log = StartupFailureLog();
        final List<String> ran = <String>[];
        await runStartupSteps(
          <StartupStep>[
            for (final String m in modules)
              StartupStep(m, () async {
                ran.add(m);
                if (m == module) {
                  throw StateError('injected $m failure');
                }
              }),
          ],
          log: log,
        );
        // Every step ran (a throw never aborts the sequence):
        expect(ran, modules);
        expect(log.modules, <String>[module]);
        expect(startupFailureAnnouncement(log.modules), contains(module));
      });
    }

    test(
        'when EVERY module throws, startup still completes '
        'and the announcement names all of them', () async {
      final StartupFailureLog log = StartupFailureLog();
      await runStartupSteps(
        <StartupStep>[
          for (final String m in modules)
            StartupStep(m, () async => throw StateError(m)),
        ],
        log: log,
      );
      expect(log.modules, modules);
      final String text = startupFailureAnnouncement(log.modules);
      for (final String m in modules) {
        expect(text, contains(m));
      }
    });
  });

  testWidgets(
      'the app still starts with the guarded startup '
      'path (no exception escapes)', (WidgetTester tester) async {
    startupFailures.clear();
    await tester.pumpWidget(const MingtuApp());
    // Drain the chained simulated-speech timers before
    // teardown (same pattern as the v0_7 UI test): the demo
    // voice path simulates speech with timers, and the test
    // binding fails on any timer left pending at dispose.
    for (int i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 1500));
    }
    expect(tester.takeException(), isNull);
    expect(find.byType(MaterialApp), findsOneWidget);
  });

  group('production wiring (source level)', () {
    test(
        'main() runs in the guarded zone with the framework '
        'backstop and delegates module init to the production '
        'initializer', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      expect(mainDart, contains('runGuardedMain(()'));
      expect(mainDart, contains('installFrameworkErrorBackstop()'));
      expect(mainDart, contains('initializeStartup('));
      expect(mainDart, contains('frameSourceFactory:'));
      expect(mainDart, contains('client: _amapClient'));
      expect(mainDart, contains('locationProvider: _locationProvider'));
      expect('startupFailureAnnouncement('.allMatches(mainDart).length, 1);
    });

    test(
        'the announcement is the tail of startup, reached '
        'even on an early throw', () {
      final String mainDart = File('lib/main.dart').readAsStringSync();
      final int catchIdx = mainDart.indexOf("record('应用初始化')");
      final int announceIdx =
          mainDart.indexOf('_announceStartupFailures(speechUsable:');
      expect(catchIdx, greaterThanOrEqualTo(0));
      expect(announceIdx, greaterThan(catchIdx));
    });

    test(
        'the production initializer guards every module by '
        'name', () {
      final String init =
          File('lib/adapters/startup_initializer.dart').readAsStringSync();
      expect(init, contains("failures.record('摄像头')"));
      expect(init, contains('LastResortCameraFrameSource'));
      expect(init, contains("StartupStep('配置'"));
      expect(init, contains("StartupStep('高德'"));
      expect(init, contains("StartupStep('权限'"));
      expect(init, contains("'语音合成'"));
      expect(init, contains("'语音识别'"));
      expect(init, contains("'目标检测'"));
      expect(init, contains('guardStartupStep'));
      expect(init, contains('runStartupSteps'));
    });
  });
}
