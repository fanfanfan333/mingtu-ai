import 'package:mingtu_ai/core/speech_scheduler.dart';
import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:test/test.dart';

SpeechRequest _req(String id, SpeechKind kind, DateTime now) => SpeechRequest(
      id: id,
      eventId: id,
      text: id,
      kind: kind,
      createdAt: now,
      expiresAt: now.add(const Duration(seconds: 10)),
      navigationStateVersion: 'nav-v0',
    );

void main() {
  test('avoidance interrupts a turn, a turn never silences avoidance', () {
    final now = DateTime(2026, 11, 5, 12, 0, 0);
    final s1 = SpeechScheduler();
    expect(s1.submit(_req('turn-1', SpeechKind.turn, now), now), isTrue);
    // v0.5: a higher-priority avoidance warning must interrupt the turn.
    expect(s1.submit(_req('avoid-1', SpeechKind.obstacleAvoidance, now), now),
        isTrue);
    expect(s1.active?.id, 'avoid-1');
    expect(s1.droppedConflictLog, isEmpty);

    final s2 = SpeechScheduler();
    expect(s2.submit(_req('avoid-2', SpeechKind.obstacleAvoidance, now), now),
        isTrue);
    // A lower-priority turn while avoidance is active is dropped.
    expect(s2.submit(_req('turn-2', SpeechKind.turn, now), now), isFalse);
    expect(s2.droppedConflictLog, contains('turn-2'));
    expect(s2.active?.id, 'avoid-2');
  });

  test(
      'voice parser understands stop, where-am-I, confirm, environment and recording',
      () {
    expect(parseVoiceCommand('停下'), VoiceCommand.pause);
    expect(parseVoiceCommand('小途，别走了'), VoiceCommand.pause);
    expect(parseVoiceCommand('我在哪'), VoiceCommand.status);
    expect(parseVoiceCommand('前面有什么'), VoiceCommand.environment);
    expect(parseVoiceCommand('看看前面'), VoiceCommand.cloudVision);
    expect(parseVoiceCommand('小途，看一下前方'), VoiceCommand.cloudVision);
    expect(parseVoiceCommand('看一下前面有什么'), VoiceCommand.cloudVision);
    expect(parseVoiceCommand('确认'), VoiceCommand.confirmStep);
    expect(parseVoiceCommand('我到了'), VoiceCommand.confirmStep);
    expect(parseVoiceCommand('下一步'), VoiceCommand.confirmStep);
    expect(parseVoiceCommand('保存录像'), VoiceCommand.saveRecording);
    expect(parseVoiceCommand('删除录像'), VoiceCommand.deleteRecording);
    // Emergency still wins over generic help.
    expect(parseVoiceCommand('我需要帮助'), VoiceCommand.emergency);
    expect(voiceCommandHelpText(), contains('停下'));
    expect(voiceCommandHelpText(), contains('保存录像'));
  });
}
