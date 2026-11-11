/// Voice diagnostics under ONE greppable tag.
///
/// Real-device voice failures (no TTS engine, no recognition
/// service, a session that ends in silence) are otherwise
/// invisible: the app degrades honestly on screen, but the
/// reason only exists in fleeting status strings. Every
/// voice-engine outcome worth diagnosing is logged through
/// here as `MingtuVoice: ...` so `logcat | grep MingtuVoice`
/// (or the in-app log mirror) shows WHY.
///
/// Messages carry module states and reasons only -- never a
/// key, a token, a URL with credentials, or transcript text.
library;

import 'package:flutter/foundation.dart';

void mingtuVoiceLog(String message) {
  debugPrint('MingtuVoice: $message');
}
