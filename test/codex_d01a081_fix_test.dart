import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/main.dart';

/// Production-orchestration proof for the Codex re-test of
/// d01a081 (items 1 and 3), with a RECORDING fake TTS at the
/// platform-channel seam: the real app runs, the real
/// SystemVoiceOutput drives a mocked flutter_tts channel,
/// and every speak stays "playing" until the test completes
/// it. The assertions are about the ORDER of stop/speak
/// calls the platform actually received -- not source text.
void main() {
  group('recording fake TTS through the real app', () {
    final List<String> calls = <String>[];
    final List<Completer<dynamic>> pendingSpeaks = <Completer<dynamic>>[];

    void installMocks() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (MethodCall call) async {
          switch (call.method) {
            case 'getLanguages':
              return <String>['zh-CN', 'en-US'];
            case 'setLanguage':
              return 1;
            case 'speak':
              calls.add('speak:${call.arguments}');
              final Completer<dynamic> c = Completer<dynamic>();
              pendingSpeaks.add(c);
              return c.future;
            case 'stop':
              calls.add('stop');
              return 1;
            default:
              return 1;
          }
        },
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugin.csdcorp.com/speech_to_text'),
        (MethodCall call) async {
          // ASR down, TTS up: startup speaks the ASR-down
          // greeting and never opens a listening session.
          if (call.method == 'initialize') return false;
          return null;
        },
      );
      messenger.setMockMethodCallHandler(SystemChannels.platform,
          (MethodCall call) async {
        return null;
      });
    }

    void clearMocks() {
      final TestDefaultBinaryMessenger messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
          const MethodChannel('flutter_tts'), null);
      messenger.setMockMethodCallHandler(
          const MethodChannel('plugin.csdcorp.com/speech_to_text'), null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    }

    Future<void> tapText(WidgetTester tester, String text) async {
      final Finder finder = find.text(text);
      await tester.ensureVisible(finder);
      await tester.pump();
      await tester.tap(finder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(const Duration(milliseconds: 50));
    }

    Future<void> drainSpeech(WidgetTester tester) async {
      for (int round = 0; round < 12; round++) {
        final List<Completer<dynamic>> pending = pendingSpeaks
            .where((Completer<dynamic> c) => !c.isCompleted)
            .toList();
        if (pending.isEmpty) break;
        for (final Completer<dynamic> c in pending) {
          c.complete(1);
        }
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    testWidgets(
        'with a straight prompt genuinely playing, a YOLO '
        'danger stops it BEFORE speaking; a same-level danger '
        'then preempts the same way and is never replayed',
        (WidgetTester tester) async {
      calls.clear();
      pendingSpeaks.clear();
      installMocks();
      addTearDown(clearMocks);

      await tester.pumpWidget(const MingtuApp());
      for (int i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tapText(tester, '语音开始（演示输入：带我去图书馆）');
      await tapText(tester, '理解并规划路线');
      await tapText(tester, '开始导航（直行节奏启动）');
      expect(find.text('当前任务状态：正在导航'), findsOneWidget);

      // The straight prompt is genuinely PLAYING: its speak
      // future is still pending at the platform seam.
      final int straightIdx = calls.indexOf('speak:直走');
      expect(straightIdx, greaterThanOrEqualTo(0), reason: 'calls: $calls');
      final int straightSpeakPos = calls
              .sublist(0, straightIdx + 1)
              .where((String c) => c.startsWith('speak:'))
              .length -
          1;
      expect(pendingSpeaks[straightSpeakPos].isCompleted, isFalse);

      // YOLO path: the person danger arrives.
      await tapText(tester, '模拟 YOLO 检测：前方行人（演示，无摄像头）');
      final int personIdx = calls.indexOf('speak:前方有人，请停下。');
      expect(personIdx, greaterThan(straightIdx), reason: 'calls: $calls');
      // A physical stop was issued AFTER the straight speak
      // and BEFORE the danger speak -- unconditionally, not
      // keyed on any scheduler flag.
      final int stopIdx =
          calls.indexWhere((String c) => c == 'stop', straightIdx);
      expect(stopIdx, greaterThan(straightIdx), reason: 'calls: $calls');
      expect(stopIdx, lessThan(personIdx), reason: 'calls: $calls');

      // Same-level danger, different event: it preempts the
      // (still playing) person danger the same way.
      await tapText(tester, '模拟 YOLO 检测：前方车辆（演示，无摄像头）');
      final int carIdx = calls.indexOf('speak:前方有机动车，请停下。');
      expect(carIdx, greaterThan(personIdx), reason: 'calls: $calls');
      final int stop2Idx =
          calls.indexWhere((String c) => c == 'stop', personIdx);
      expect(stop2Idx, greaterThan(personIdx), reason: 'calls: $calls');
      expect(stop2Idx, lessThan(carIdx), reason: 'calls: $calls');
      // The interrupted person danger is never replayed.
      expect(
        calls.where((String c) => c == 'speak:前方有人，请停下。').length,
        1,
        reason: 'calls: $calls',
      );

      await drainSpeech(tester);
    });
  });
}
