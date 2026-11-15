import 'speech_scheduler.dart';

const String locationSignalLostText = '定位信号中断，暂时无法更新你的位置。';

/// Consume an interrupted original location failure and prepare one retry.
/// The retry has a different event ID, so it cannot qualify for another retry.
SpeechRequest? takeInterruptedLocationSignalReplay(
    SpeechScheduler scheduler, DateTime now) {
  for (final request in scheduler.interruptedRequests.toList()) {
    if (request.eventId != 'gps-lost' || request.kind != SpeechKind.alert) {
      continue;
    }
    scheduler.discardInterrupted(request);
    return SpeechRequest(
      id: 'gps-lost-replay-${request.id}',
      eventId: 'gps-lost-replay',
      text: locationSignalLostText,
      kind: SpeechKind.alert,
      createdAt: now,
      expiresAt: now,
      navigationStateVersion: request.navigationStateVersion,
      neverExpires: true,
      replay: NavReplay.drop,
    );
  }
  return null;
}
