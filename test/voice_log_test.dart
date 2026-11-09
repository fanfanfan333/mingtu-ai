import 'package:flutter/foundation.dart';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mingtu_ai/core/voice_log.dart';

/// The MingtuVoice tag contract: every voice diagnostic line
/// carries the single greppable tag, so a real-device logcat
/// can be filtered to exactly the voice-engine story.
void main() {
  test('mingtuVoiceLog prefixes the MingtuVoice tag', () {
    final List<String> captured = <String>[];
    final DebugPrintCallback original = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) captured.add(message);
    };
    try {
      mingtuVoiceLog('语音识别初始化：可用=false');
    } finally {
      debugPrint = original;
    }
    expect(captured, hasLength(1));
    expect(captured.single, startsWith('MingtuVoice: '));
    expect(captured.single, contains('语音识别初始化'));
  });

  test(
      'production wiring: voice outcomes are logged under '
      'the tag at the failure points', () {
    final String io =
        File('lib/adapters/system_voice_io.dart').readAsStringSync();
    expect(io, contains("mingtuVoiceLog('语音合成初始化"));
    expect(io, contains("mingtuVoiceLog('语音识别初始化"));
    expect(io, contains("mingtuVoiceLog('语音识别会话结束"));
    final String mainDart = File('lib/main.dart').readAsStringSync();
    expect(mainDart, contains("mingtuVoiceLog('用户打断（停下）"));
    expect(mainDart, contains('sessionEnded.listen'));
    expect(mainDart, contains('_onAsrSessionEnded'));
  });
}
