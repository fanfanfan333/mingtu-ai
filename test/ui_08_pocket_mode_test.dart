import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/adapters/pocket_mode_gateway.dart';
import 'package:mingtu_ai/core/pocket_mode.dart';
import 'package:mingtu_ai/core/voice_commands.dart';

void main() {
  test('continuous proximity, disable and foreground lifecycle', () async {
    var time = DateTime(2026);
    final events = StreamController<bool>.broadcast(sync: true);
    final mode = PocketMode(proximity: () => events.stream, now: () => time);
    events.add(true);
    time = time.add(const Duration(seconds: 3));
    expect(mode.ignoreTouches, false);
    mode.setEnabled(true);
    events.add(true);
    time = time.add(const Duration(milliseconds: 1499));
    events.add(true);
    expect(mode.ignoreTouches, false);
    events.add(false);
    events.add(true);
    time = time.add(pocketNearDuration);
    events.add(true);
    expect(mode.ignoreTouches, true);
    events.add(false);
    expect(mode.ignoreTouches, false);
    events.add(true);
    time = time.add(pocketNearDuration);
    events.add(true);
    mode.setForeground(false);
    expect(mode.ignoreTouches, false);
    await Future<void>.delayed(Duration.zero);
    expect(events.hasListener, false);
    mode.setForeground(true);
    events.add(true);
    time = time.add(pocketNearDuration);
    events.add(true);
    expect(mode.ignoreTouches, true);
    mode.setEnabled(false);
    expect(mode.ignoreTouches, false);
    mode.dispose();
    await events.close();
  });

  test('file store defaults off and persists', () async {
    final dir = await Directory.systemTemp.createTemp('pocket_test');
    addTearDown(() => dir.delete(recursive: true));
    final store = FilePocketModeStore(directory: () async => dir);
    expect(await store.load(), false);
    await store.save(true);
    expect(await store.load(), true);
    final broken =
        FilePocketModeStore(directory: () async => throw Exception());
    expect(await broken.load(), false);
    await broken.save(true);
  });

  test('voice phrases and production constraints', () {
    for (final phrase in ['打开口袋模式', '开启口袋模式', '打开口袋']) {
      expect(parseVoiceCommand(phrase), VoiceCommand.enablePocketMode);
    }
    for (final phrase in ['关闭口袋模式', '关掉口袋模式', '关闭口袋']) {
      expect(parseVoiceCommand(phrase), VoiceCommand.disablePocketMode);
    }
    expect(parseVoiceCommand('救命打开口袋模式'), VoiceCommand.emergency);
    expect(voiceCommandHelpText(), contains('打开口袋模式、关闭口袋模式'));
    for (final text in [pocketEnabledSpeech, pocketDisabledSpeech]) {
      expect(text, isNot(contains('安全')));
      expect(text, isNot(contains('可以过马路')));
    }
    final manifest =
        File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(
        manifest,
        contains(
            'android:name="android.hardware.sensor.proximity" tools:node="remove"'));
    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('_pocketMode.ignoreTouches'));
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))) {
      expect(file.readAsStringSync(), isNot(contains('setProximityScreenOff')));
    }
    final core = File('lib/core/pocket_mode.dart').readAsStringSync();
    expect(core, isNot(contains('_closeYoloLiveView')));
    expect(core, isNot(contains('_scheduler')));
    expect(core, isNot(contains('wakelock')));
  });
}
