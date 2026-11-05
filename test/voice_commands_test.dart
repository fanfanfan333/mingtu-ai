import 'package:mingtu_ai/core/voice_commands.dart';
import 'package:test/test.dart';

void main() {
  test('emergency wins over generic help', () {
    expect(parseVoiceCommand('小途，我需要帮助'), VoiceCommand.emergency);
    expect(parseVoiceCommand('救命'), VoiceCommand.emergency);
    expect(parseVoiceCommand('能做什么'), VoiceCommand.help);
  });

  test('pause, resume, cancel, repeat, status, start', () {
    expect(parseVoiceCommand('暂停一下'), VoiceCommand.pause);
    expect(parseVoiceCommand('继续走'), VoiceCommand.resume);
    expect(parseVoiceCommand('取消任务'), VoiceCommand.cancel);
    expect(parseVoiceCommand('再说一遍'), VoiceCommand.repeat);
    expect(parseVoiceCommand('现在到哪了'), VoiceCommand.status);
    expect(parseVoiceCommand('带我去图书馆'), VoiceCommand.startLibrary);
    expect(parseVoiceCommand('今天天气怎么样'), VoiceCommand.unknown);
    expect(parseVoiceCommand(''), VoiceCommand.unknown);
  });
}
