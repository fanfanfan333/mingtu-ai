/// Press-and-hold voice recorder factory (cloud ASR fallback).
///
/// Conditional export, same pattern as camera_frame_source.dart:
/// on a phone (dart:io) the `record` package implementation is
/// used; elsewhere the stub honestly reports unavailable. The
/// contract lives here: one press = one short clip (16 kHz mono
/// WAV, capped at 10 s by the caller), no streaming, no
/// background recording.
library;

import 'dart:typed_data';

export 'voice_recorder_stub.dart'
    if (dart.library.io) 'voice_recorder_mobile.dart';

/// Records one short clip with the APP's own microphone
/// permission (the fallback for devices whose system speech
/// engine cannot record -- see core/cloud_asr.dart).
abstract class VoiceRecorder {
  /// Whether the app may record. Implementations may request
  /// the permission when it has not been decided yet.
  Future<bool> hasPermission();

  /// Start recording a 16 kHz mono WAV clip.
  Future<void> start();

  /// Stop and return the clip bytes (null when nothing was
  /// recorded). The temporary file is deleted by the
  /// implementation before this returns.
  Future<Uint8List?> stop();

  /// Discard the in-progress clip without reading it.
  Future<void> cancel();

  bool get isRecording;
}

/// Optional capability: a live amplitude feed while
/// recording, in dBFS (the `record` package's
/// `AudioRecorder.onAmplitudeChanged` reports
/// `Amplitude.current`, documented as dBFS amplitude in
/// record_platform_interface: 0 is full scale, speech peaks
/// sit well above -30, a quiet room's floor is around
/// -50 to -60).
///
/// This is a SEPARATE interface on purpose: the existing
/// [VoiceRecorder] contract is implemented by test fakes
/// across the suite, and growing a member onto it would
/// break every one of them. The app checks for this
/// capability with `is` and only then arms the
/// silence auto-end (core/recording_silence.dart); a
/// recorder without it simply never auto-ends on silence
/// (release / toggle / hard cap still apply).
abstract class VoiceRecorderAmplitude {
  /// Amplitude samples (dBFS) while recording.
  Stream<double> amplitudeDbfs();
}

/// Fallback used until the platform implementation is created
/// (and the only implementation off-device): every operation
/// reports unavailable; it never fakes audio.
class UnavailableVoiceRecorder implements VoiceRecorder {
  const UnavailableVoiceRecorder();

  @override
  Future<bool> hasPermission() async => false;

  @override
  Future<void> start() async =>
      throw StateError('本平台不支持录音（云端识别兜底不可用）。');

  @override
  Future<Uint8List?> stop() async => null;

  @override
  Future<void> cancel() async {}

  @override
  bool get isRecording => false;
}
