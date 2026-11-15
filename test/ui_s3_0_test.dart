import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/location_signal_speech.dart';
import 'package:mingtu_ai/core/speech_scheduler.dart';

void main() {
  final now = DateTime(2026);
  SpeechRequest request(String id, SpeechKind kind, {String? eventId}) =>
      SpeechRequest(
        id: id,
        eventId: eventId ?? id,
        text: kind == SpeechKind.alert ? locationSignalLostText : '危险',
        kind: kind,
        createdAt: now,
        expiresAt: now.add(const Duration(seconds: 5)),
        navigationStateVersion: '1',
        neverExpires: true,
      );

  test('location alert queues behind danger without expiring', () {
    final scheduler = SpeechScheduler();
    scheduler.submit(request('danger', SpeechKind.danger), now);
    expect(
        scheduler.submit(
            request('gps', SpeechKind.alert, eventId: 'gps-lost'), now),
        isTrue);
    expect(scheduler.queue.single.text, locationSignalLostText);
    scheduler.completeActive();
    final promoted = scheduler.promoteNext(now.add(const Duration(minutes: 1)),
        straightSegmentConfirmed: true, riskActive: false);
    expect(promoted?.text, locationSignalLostText);
    expect(scheduler.active?.kind, SpeechKind.alert);
  });

  test('interrupted location alert is recovered once after hazard', () {
    final scheduler = SpeechScheduler();
    scheduler.submit(
        request('gps', SpeechKind.alert, eventId: 'gps-lost'), now);
    scheduler.submit(request('danger', SpeechKind.danger), now);
    expect(scheduler.active?.kind, SpeechKind.danger);
    scheduler.completeActive();
    final replay = takeInterruptedLocationSignalReplay(scheduler, now)!;
    expect(replay.text, locationSignalLostText);
    expect(replay.kind, SpeechKind.alert);
    expect(replay.neverExpires, isTrue);
    expect(replay.replay, NavReplay.drop);
    expect(scheduler.submit(replay, now), isTrue);
    expect(scheduler.active, same(replay));
    scheduler.submit(request('danger-2', SpeechKind.danger), now);
    scheduler.completeActive();
    expect(takeInterruptedLocationSignalReplay(scheduler, now), isNull);
    expect(scheduler.playedLog.where((id) => id == replay.id), hasLength(1));
  });

  test(
      'production uses the alert and recovery hook; wording avoids banned phrases',
      () {
    final source = File('lib/main.dart').readAsStringSync();
    expect(
        source,
        contains(
            'text: locationSignalLostText,\n          kind: SpeechKind.alert'));
    expect(
        source,
        contains(
            'takeInterruptedLocationSignalReplay(_scheduler, _speechNow())'));
    expect(locationSignalLostText, isNot(contains('安全')));
    expect(locationSignalLostText, isNot(contains('可以过马路')));
  });
}
