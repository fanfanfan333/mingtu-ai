/// Cloud ASR fallback for Mingtu AI (real-device fix round).
///
/// Why this exists: on the Xiaomi 15 (HyperOS) the system
/// recogniser is Xiaomi's own speech engine, and that engine
/// itself may lack the microphone permission -- the system ASR
/// then dies with error_permission even though THIS app holds
/// RECORD_AUDIO. The fallback therefore records with the app's
/// own permission (press-and-hold, release to stop) and sends
/// the clip to the project proxy's /asr route; the proxy holds
/// the DashScope key server-side and calls the Beijing
/// qwen3-asr-flash model. The app never holds a key and never
/// calls DashScope directly.
///
/// Discipline mirrors cloud_vision.dart: fixed local texts for
/// every failure, nothing from a response or an exception is
/// ever copied into a detail, and the transcript text itself is
/// the ONLY thing taken from a successful response (it is the
/// user's own speech, routed through the ordinary command
/// pipeline exactly like a system-ASR final).
library;

import 'dart:convert';

/// The ASR model id pinned on BOTH sides (the proxy pins it
/// again server-side and rejects any other model in a request).
/// Chosen 2026-11-10 from the Bailian Beijing catalogue: the
/// cheapest tier that accepts a synchronous base64 data-URI
/// (paraformer-v2 is cheaper per second but async-only and
/// URL-only, so it cannot serve a press-and-hold clip).
const String asrModelId = 'qwen3-asr-flash';

/// Hard cap on one recording: press-and-hold clips are short
/// commands; 10 s matches the system recogniser's own limit.
const int asrMaxRecordMs = 10000;

/// Spoken when a press switches from the local recogniser
/// to the cloud ASR recording fallback (MT-1111-PTT-2):
/// fixed text, spoken exactly once per switch -- on the
/// press where the switch happens, never on later presses
/// that are already on the fallback.
const String asrCloudSwitchSpeechText = '改用云端识别';

/// Spoken when a recording reaches the [asrMaxRecordMs]
/// cap and is auto-stopped for transcription
/// (MT-1111-PTT-2), preceded by a short vibration. The
/// wording names the 10 s constant; a test injecting a
/// smaller cap still hears this exact text (the cap the
/// USER experiences is 10 s).
const String asrRecordCapSpeechText = '已录10秒，正在识别';

/// 10 s of 16 kHz mono 16-bit WAV is ~320 KB (plus the header).
const int asrMaxAudioBytes = 400000;

/// Whole-request body cap (base64 inflates the audio by ~4/3).
const int asrMaxBodyBytes = 1048576;

/// Client-side timeout for one /asr request.
const Duration asrRequestTimeout = Duration(seconds: 15);

/// Longest transcript accepted from the proxy (the proxy
/// truncates to the same bound; a longer value is clipped
/// here too rather than trusted).
const int asrMaxTranscriptChars = 200;

/// Build the /asr request body: exactly two keys. The audio
/// travels as a base64 data-URI because the upstream ASR API
/// takes input_audio data URIs; the model is NOT sent -- the
/// proxy pins it server-side.
Map<String, Object?> buildAsrRequestBody({required String audioBase64}) {
  return <String, Object?>{
    'audio': 'data:audio/wav;base64,$audioBase64',
    'format': 'wav',
  };
}

/// Parse the proxy's /asr success body: only the 'text' key is
/// read. Returns the trimmed transcript, or null for anything
/// else (missing/empty/non-string/whitespace). Overlong text
/// is truncated to [asrMaxTranscriptChars].
String? parseAsrResponse(Map<String, Object?> decoded) {
  final Object? raw = decoded['text'];
  if (raw is! String) return null;
  final String text = raw.trim();
  if (text.isEmpty) return null;
  if (text.length > asrMaxTranscriptChars) {
    return text.substring(0, asrMaxTranscriptChars);
  }
  return text;
}

/// Failure kinds for the cloud ASR path. Every kind maps to a
/// FIXED local Chinese detail via [asrFailureDetail]; no
/// exception text and no response text ever reaches a detail.
enum AsrFailure {
  /// No proxy base URL configured (or not https).
  notConfigured,

  /// The proxy refused or is not configured server-side
  /// (token rejected, asr_not_configured, body-too-large).
  unavailable,

  /// The proxy's ASR rate cap was hit.
  rateLimited,

  /// The request exceeded [asrRequestTimeout].
  timeout,

  /// Transport failed before any response.
  network,

  /// The response was not the expected shape.
  badResponse,

  /// The recorded clip exceeds [asrMaxAudioBytes].
  tooLarge,
}

/// Fixed Chinese detail per failure kind.
String asrFailureDetail(AsrFailure failure) => switch (failure) {
      AsrFailure.notConfigured => '云端识别未配置，无法识别。',
      AsrFailure.unavailable => '云端识别暂时不可用，请再试一次。',
      AsrFailure.rateLimited => '云端识别请求过于频繁，请稍后再试。',
      AsrFailure.timeout => '云端识别请求超时，请再试一次。',
      AsrFailure.network => '云端识别网络失败，请再试一次。',
      AsrFailure.badResponse => '云端识别返回无法理解，请再试一次。',
      AsrFailure.tooLarge => '录音太长，云端识别已跳过，请缩短后重试。',
    };

/// Encode clip bytes for [buildAsrRequestBody].
String encodeAsrAudio(List<int> bytes) => base64Encode(bytes);
