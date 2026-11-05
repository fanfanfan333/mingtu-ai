import 'package:test/test.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';

SpeechRequest straight(String id, String eventId, DateTime now) =>
    SpeechRequest(
      id: id,
      eventId: eventId,
      text: '直走',
      kind: SpeechKind.straight,
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 30)),
      navigationStateVersion: 'v1',
      requiresStraightSegment: true,
    );

SpeechRequest obstacle(String id, String eventId, DateTime now) =>
    SpeechRequest(
      id: id,
      eventId: eventId,
      text: '前方有障碍',
      kind: SpeechKind.obstacleAvoidance,
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 30)),
      navigationStateVersion: 'v1',
    );

void main() {
  test('high-priority obstacle interrupts straight prompt', () {
    final s = SpeechScheduler();
    final now = DateTime(2026, 11, 5, 10, 0, 0);
    expect(s.submit(straight('s1', 'e-straight', now), now), isTrue);
    expect(s.active?.id, 's1');
    expect(s.submit(obstacle('o1', 'e-obstacle', now), now), isTrue);
    expect(s.active?.id, 'o1');
    expect(s.interruptedLog, contains('s1'));
  });

  test('resume after interrupt requires re-check and restarts timer', () {
    final s = SpeechScheduler();
    final now = DateTime(2026, 11, 5, 10, 0, 0);
    // Risk still active -> must not resume.
    expect(
      s.resumeStraight(
        now: now,
        straightSegmentConfirmed: true,
        riskActive: true,
        currentNavigationVersion: 'v1',
        straightNavigationVersion: 'v1',
      ),
      isFalse,
    );
    // Navigation version changed -> must not resume.
    expect(
      s.resumeStraight(
        now: now,
        straightSegmentConfirmed: true,
        riskActive: false,
        currentNavigationVersion: 'v2',
        straightNavigationVersion: 'v1',
      ),
      isFalse,
    );
    // All re-checked -> resume and timer restarts.
    expect(
      s.resumeStraight(
        now: now,
        straightSegmentConfirmed: true,
        riskActive: false,
        currentNavigationVersion: 'v1',
        straightNavigationVersion: 'v1',
      ),
      isTrue,
    );
    expect(
      s.shouldPlayStraight(
        now: now.add(const Duration(milliseconds: 1000)),
        straightSegmentConfirmed: true,
        riskActive: false,
      ),
      isFalse,
    );
    expect(
      s.shouldPlayStraight(
        now: now.add(const Duration(milliseconds: 3000)),
        straightSegmentConfirmed: true,
        riskActive: false,
      ),
      isTrue,
    );
  });

  test('expired prompts are dropped, never played', () {
    final s = SpeechScheduler();
    final now = DateTime(2026, 11, 5, 10, 0, 0);
    final expired = SpeechRequest(
      id: 'old',
      eventId: 'e-old',
      text: '过期指令',
      kind: SpeechKind.info,
      createdAt: now.subtract(const Duration(seconds: 60)),
      expiresAt: now.subtract(const Duration(seconds: 1)),
      navigationStateVersion: 'v1',
    );
    expect(s.submit(expired, now), isFalse);
    expect(s.active, isNull);
    expect(s.droppedExpiredLog, contains('old'));
  });

  test('duplicate event is deduped, not replayed', () {
    final s = SpeechScheduler();
    final now = DateTime(2026, 11, 5, 10, 0, 0);
    expect(s.submit(obstacle('o1', 'e-same', now), now), isTrue);
    expect(s.submit(obstacle('o2', 'e-same', now), now), isFalse);
    expect(s.droppedDuplicateLog, contains('o2'));
  });
}
