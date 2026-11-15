import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:mingtu_ai/adapters/voice_io.dart';
import 'package:mingtu_ai/adapters/system_voice_io.dart';
import 'package:mingtu_ai/core/haptics.dart';
import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/tts_recovery.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/main.dart';

class FakeStartupTts extends SystemVoiceOutput {
  @override
  Future<bool> initialize() async => false;
}

class FakeOutput implements VoiceOutput {
  final spoken = <String>[];
  @override
  bool get isAvailable => true;
  @override
  String get status => 'ready';
  @override
  Future<void> speak(String text) async {
    spoken.add(text);
  }
}

void main() {
  test('retries after 1, 3, 10 and repeated 10 second delays', () {
    fakeAsync((clock) {
      var attempts = 0;
      final announcements = <String>[];
      final start = DateTime(2026);
      final controller = TtsRecoveryController(
        now: () => start.add(clock.elapsed),
        haptics: RecordingHaptics.new,
        rebuild: () async {
          attempts++;
          return attempts == 4 ? FakeOutput() : null;
        },
        onRecovered: (_, text) => announcements.add(text),
      );
      controller.fail();
      expect(controller.failedAt, start);
      clock.elapse(const Duration(milliseconds: 999));
      expect(attempts, 0);
      clock.elapse(const Duration(milliseconds: 1));
      expect(attempts, 1);
      clock.elapse(const Duration(milliseconds: 2999));
      expect(attempts, 1);
      clock.elapse(const Duration(milliseconds: 1));
      expect(attempts, 2);
      clock.elapse(const Duration(seconds: 10));
      expect(attempts, 3);
      clock.elapse(const Duration(seconds: 10));
      expect(attempts, 4);
      expect(announcements, ['语音已恢复']);
      expect(containsBannedWord(announcements.single), isFalse);
      clock.elapse(const Duration(seconds: 30));
      expect(announcements, hasLength(1));
      controller.dispose();
    });
  });

  test('active danger repeats until recovery and can start on another failure',
      () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      var attempts = 0;
      final announcements = <String>[];
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => ++attempts == 1 ? null : FakeOutput(),
        onRecovered: (_, text) => announcements.add(text),
      );
      controller.fail();
      controller.danger();
      controller.danger();
      clock.elapse(const Duration(milliseconds: 800));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent']);
      expect(controller.vibrating, isTrue);
      clock.elapse(const Duration(milliseconds: 3200));
      expect(controller.failed, isFalse);
      expect(controller.vibrating, isFalse);
      final count = haptics.calls.length;
      controller.danger();
      clock.elapse(const Duration(seconds: 1));
      expect(haptics.calls.length, count);
      controller.fail();
      controller.danger();
      expect(haptics.calls.length, count + 1);
      clock.elapse(const Duration(seconds: 1));
      expect(announcements, ['语音已恢复', '语音已恢复']);
      controller.dispose();
    });
  });
  test('cleared danger stops while failed and a new danger can restart', () {
    fakeAsync((clock) {
      final haptics = RecordingHaptics();
      final controller = TtsRecoveryController(
        haptics: () => haptics,
        rebuild: () async => null,
        onRecovered: (_, __) {},
      );
      controller.fail();
      controller.danger();
      clock.elapse(const Duration(milliseconds: 800));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent']);
      controller.stopDanger();
      expect(controller.failed, isTrue);
      expect(controller.vibrating, isFalse);
      clock.elapse(const Duration(seconds: 2));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent']);
      controller.danger();
      expect(haptics.calls, ['urgent', 'urgent', 'urgent', 'urgent']);
      clock.elapse(const Duration(milliseconds: 400));
      expect(haptics.calls, ['urgent', 'urgent', 'urgent', 'urgent', 'urgent']);
      controller.dispose();
    });
  });

  testWidgets('failed emergency and alert use one-shot haptics without speech',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    final haptics = RecordingHaptics();
    final output = FakeOutput();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => output);
    expect(handle.debugSayForTest(SpeechKind.emergency), isFalse);
    expect(handle.debugSayForTest(SpeechKind.alert), isFalse);
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls, ['urgent', 'warning']);
    expect(handle.activeSpeechKind, isNull);
    expect(handle.debugSpeechQueueLength, 0);
    expect(output.spoken, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
      'failed danger is not completed as speech; recovery restores speech',
      (tester) async {
    mingtuStartupTtsFactoryOverride = FakeStartupTts.new;
    addTearDown(() => mingtuStartupTtsFactoryOverride = null);
    await tester.pumpWidget(const MingtuApp());
    await tester.pump();
    final handle = mingtuHomeDebugHandle!;
    final haptics = RecordingHaptics();
    final output = FakeOutput();
    handle.debugSetHaptics(haptics);
    handle.debugFailTts(() async => output);
    handle.debugSpeakHazard('前方有障碍');
    await tester.pump(const Duration(milliseconds: 800));
    expect(haptics.calls.where((c) => c == 'urgent').length, greaterThan(1));
    expect(handle.activeSpeechKind, isNull);
    expect(output.spoken, isEmpty);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    await tester.pump();
    expect(output.spoken, contains('语音已恢复'));
    final count = haptics.calls.length;
    handle.debugSpeakHazard('前方有障碍');
    await tester.pump();
    await tester.pump();
    expect(output.spoken, contains('前方有障碍'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(haptics.calls.length, count);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 4));
  });
}
