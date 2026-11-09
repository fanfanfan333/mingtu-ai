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

  group('critical delivery (neverExpires + alert)', () {
    SpeechRequest req(
      String id,
      SpeechKind kind, {
      required DateTime at,
      bool neverExpires = false,
      int ttlSeconds = 5,
    }) =>
        SpeechRequest(
          id: id,
          eventId: 'e-$id',
          text: 'msg-$id',
          kind: kind,
          createdAt: at,
          expiresAt: at.add(Duration(seconds: ttlSeconds)),
          navigationStateVersion: 'v1',
          neverExpires: neverExpires,
        );

    test(
        'a neverExpires request is accepted long after its '
        'nominal expiry; a normal one is dropped', () {
      final s = SpeechScheduler();
      final t0 = DateTime(2026, 11, 9, 12);
      final late = t0.add(const Duration(minutes: 10));
      expect(
        s.submit(req('plain', SpeechKind.info, at: t0), late),
        isFalse,
      );
      expect(s.droppedExpiredLog, contains('plain'));
      expect(
        s.submit(
          req('crit', SpeechKind.alert, at: t0, neverExpires: true),
          late,
        ),
        isTrue,
      );
      expect(s.active?.id, 'crit');
    });

    test(
        'promoteNext never drops a neverExpires request as '
        'expired, while an expired info request is dropped', () {
      final s = SpeechScheduler();
      final t0 = DateTime(2026, 11, 9, 12);
      expect(s.submit(obstacle('o1', 'e-o1', t0), t0), isTrue);
      expect(
        s.submit(
          req('crit', SpeechKind.alert, at: t0, neverExpires: true),
          t0,
        ),
        isTrue,
      );
      expect(s.submit(req('plain', SpeechKind.info, at: t0), t0), isTrue);
      s.completeActive();
      final late = t0.add(const Duration(minutes: 10));
      final SpeechRequest? promoted = s.promoteNext(
        late,
        straightSegmentConfirmed: false,
        riskActive: false,
      );
      expect(promoted?.id, 'crit');
      s.completeActive();
      final SpeechRequest? after = s.promoteNext(
        late,
        straightSegmentConfirmed: false,
        riskActive: false,
      );
      expect(after, isNull);
      expect(s.droppedExpiredLog, contains('plain'));
    });

    test(
        'alert interrupts info, but turn/info/straight cannot '
        'interrupt an alert -- only an emergency can', () {
      final s = SpeechScheduler();
      final t0 = DateTime(2026, 11, 9, 12);
      expect(s.submit(req('info1', SpeechKind.info, at: t0), t0), isTrue);
      expect(
        s.submit(
          req('alert1', SpeechKind.alert, at: t0, neverExpires: true),
          t0,
        ),
        isTrue,
      );
      expect(s.active?.id, 'alert1');
      expect(s.interruptedLog, contains('info1'));
      // Lower/equal priority kinds queue behind the alert.
      expect(s.submit(req('turn1', SpeechKind.turn, at: t0), t0), isTrue);
      expect(s.active?.id, 'alert1');
      expect(
        s.submit(req('info2', SpeechKind.info, at: t0), t0),
        isTrue,
      );
      expect(s.active?.id, 'alert1');
      // Only the strictly higher emergency interrupts it.
      expect(
        s.submit(
          req('em1', SpeechKind.emergency, at: t0, neverExpires: true),
          t0,
        ),
        isTrue,
      );
      expect(s.active?.id, 'em1');
      expect(s.interruptedLog, contains('alert1'));
    });

    test(
        'a neverExpires alert blocks its duplicate even after '
        'the nominal expiry', () {
      final s = SpeechScheduler();
      final t0 = DateTime(2026, 11, 9, 12);
      expect(
        s.submit(
          req('a1', SpeechKind.alert, at: t0, neverExpires: true),
          t0,
        ),
        isTrue,
      );
      final SpeechRequest dup = SpeechRequest(
        id: 'a1-again',
        eventId: 'e-a1',
        text: 'msg-a1',
        kind: SpeechKind.alert,
        createdAt: t0,
        expiresAt: t0.add(const Duration(seconds: 5)),
        navigationStateVersion: 'v1',
        neverExpires: true,
      );
      expect(
        s.submit(dup, t0.add(const Duration(minutes: 10))),
        isFalse,
      );
      expect(s.droppedDuplicateLog, contains('a1-again'));
    });
  });
}
