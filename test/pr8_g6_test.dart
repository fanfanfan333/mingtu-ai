import 'dart:io';

import 'package:mingtu_ai/core/hazard/hazard_phrases.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/modules/blind_path.dart';
import 'package:test/test.dart';

void main() {
  test('blocked blind path stops even when an alternative is confirmed', () {
    final result = BlindPathService().assess(
      blindPathVisible: true,
      blocked: true,
      alternativeConfirmed: true,
      alternativeSideKnown: true,
    );
    expect(result.recommendation, BlindPathRecommendation.stopAndAskHelp);
    expect(result.speechText, contains('停下'));
    for (final forbidden in [
      '请等待具体绕行指令',
      '左',
      '右',
      '安全',
      '可以通行',
      '放心',
      '可以过马路',
      '畅通',
      '没有障碍',
      '放心走',
      '安全通过',
    ]) {
      expect(result.speechText, isNot(contains(forbidden)));
    }
  });

  test('urgent first sentence starts immediately and cane reminder queues', () {
    final scheduler = SpeechScheduler();
    final now = DateTime(2026);
    SpeechRequest request(String id, String text, SpeechKind kind) =>
        SpeechRequest(
          id: id,
          eventId: id.startsWith('cane') ? 'navhaz-cane' : id,
          text: text,
          kind: kind,
          createdAt: now,
          expiresAt: now.add(const Duration(seconds: 5)),
          navigationStateVersion: 'v1',
        );
    const phrase = '停，左有人';
    expect(voicedCharCount(phrase), 4);
    expect(
        scheduler.submit(request('urgent', '$phrase。', SpeechKind.danger), now),
        isTrue);
    expect(scheduler.active?.text, '$phrase。');
    expect(scheduler.active?.text, isNot(contains('用盲杖确认')));
    expect(scheduler.submit(request('cane', '用盲杖确认。', SpeechKind.alert), now),
        isTrue);
    expect(
        scheduler.submit(
            request('cane-track-2', '用盲杖确认。', SpeechKind.alert), now),
        isFalse);
    expect(scheduler.active?.text, '$phrase。');
    expect(scheduler.queue.single.text, '用盲杖确认。');
    expect(scheduler.queue.single.text, isNot(matches(RegExp('[左右]'))));
    scheduler.completeActive();
    expect(
        scheduler
            .promoteNext(now, straightSegmentConfirmed: false, riskActive: true)
            ?.text,
        '用盲杖确认。');
  });

  test('pipeline submits the unchanged alert before the urgent cane reminder',
      () {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('final String text = alert.phrase;');
    final end = source.indexOf("_logMsg('NAVHAZ", start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final dispatch = source.substring(start, end);
    final first = dispatch.indexOf("text: '\$text。'");
    final reminder = dispatch.indexOf("text: '用盲杖确认。'");
    expect(first, greaterThanOrEqualTo(0));
    expect(reminder, greaterThan(first));
    expect(dispatch, contains('kind: alert.speechKind'));
    expect(dispatch, contains('if (alert.urgent)'));
    expect(dispatch, contains('kind: SpeechKind.alert'));
    expect(dispatch, contains("eventId: 'navhaz-cane'"));
  });
}
