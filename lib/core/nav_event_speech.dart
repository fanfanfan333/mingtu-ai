import 'navigation_tracker.dart';
import 'speech_scheduler.dart';

/// Speech fields for a navigation event, independent of playback and effects.
class NavEventSpeech {
  const NavEventSpeech(
      {required this.id,
      required this.eventId,
      required this.text,
      required this.kind,
      this.navStepIndex,
      this.replay = NavReplay.drop});

  final String id;
  final String eventId;
  final String text;
  final SpeechKind kind;
  final int? navStepIndex;
  final NavReplay replay;
}

NavEventSpeech navEventSpeech(
  NavEvent event, {
  required String timestamp,
  required String destinationName,
  RerouteDecision? rerouteDecision,
  String? entranceText,
  bool entranceCompleted = false,
}) {
  switch (event.kind) {
    case NavEventKind.turnAhead:
      return NavEventSpeech(
          id: 'nav-turn-$timestamp',
          eventId: 'nav-turn-$timestamp',
          text: event.text,
          kind: SpeechKind.turn,
          navStepIndex: event.stepIndex,
          replay: NavReplay.regenerate);
    case NavEventKind.weakSignal:
      return NavEventSpeech(
          id: 'nav-weak-$timestamp',
          eventId: 'nav-weak-$timestamp',
          text: event.text,
          kind: SpeechKind.info);
    case NavEventKind.arrived:
      if (entranceText == null) throw ArgumentError.notNull('entranceText');
      final String phase = entranceCompleted ? 'arrived' : 'start';
      return NavEventSpeech(
          id: 'entrance-$phase-$timestamp',
          eventId: 'entrance-$phase',
          text: entranceText,
          kind: entranceCompleted ? SpeechKind.alert : SpeechKind.turn);
    case NavEventKind.offRoute:
      switch (rerouteDecision) {
        case RerouteDecision.doIt:
          return NavEventSpeech(
              id: 'nav-offroute-$timestamp',
              eventId: 'nav-offroute-$timestamp',
              text: '你已偏离路线，正在重新规划。',
              kind: SpeechKind.info,
              replay: NavReplay.shortenedReplay);
        case RerouteDecision.exhausted:
          return NavEventSpeech(
              id: 'nav-offroute-max-$timestamp',
              eventId: 'nav-offroute-max',
              text: '你已偏离路线。已经多次重新规划仍未回到路线，'
                  '先停下来确认位置，再说“去$destinationName”重新开始。',
              kind: SpeechKind.alert);
        case RerouteDecision.throttled:
          return NavEventSpeech(
              id: 'nav-offroute-wait-$timestamp',
              eventId: 'nav-offroute-wait-$timestamp',
              text: '你已偏离路线。',
              kind: SpeechKind.info,
              replay: NavReplay.shortenedReplay);
        case null:
          throw ArgumentError.notNull('rerouteDecision');
      }
  }
}
